# dsh-env-sync engine (release copy inside tools\env-sync).
# Back up a DeepSeek Harness environment to a Git repository and restore it.
#
# Modes:
#   backup   copy the configured paths into the repo, then commit and push
#   restore  snapshot the current data, pull the repo, then copy it back
#   status   report repository state and the last commit
#
# All machine-specific paths are resolved at run time:
#   data root : -DataRoot / config dataRoot / $env:DSH_HOME / <exe root>\data
#   repo dir  : -RepoDir  / config repoDir  / <data root>\env-sync-repo
#   git exe   : -GitExe   / config git      / <root>\tools\MinGit\cmd\git.exe / git on PATH
# Nothing here is tied to one computer, so the same files work on a new machine.

[CmdletBinding()]
param(
  [ValidateSet('backup', 'restore', 'status')]
  [string]$Mode = 'status',

  [string]$ConfigPath,
  [string]$DataRoot,
  [string]$RepoDir,
  [string]$Branch,

  # Optional remote URL used only when initializing the repo on first backup.
  [string]$RepoUrl,

  [string]$GitExe
)

$ErrorActionPreference = 'Stop'

$script:root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

if (-not $ConfigPath) {
  $candidate = Join-Path $script:root 'env-sync.json'
  if (Test-Path -LiteralPath $candidate) { $ConfigPath = $candidate }
}

if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
  $cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
} else {
  $cfg = New-Object PSObject
}

function Get-CfgValue($name) {
  if ($cfg -and $cfg.PSObject.Properties[$name] -and $cfg.$name) { return $cfg.$name }
  return $null
}

# Resolve the data root without hard-coding one machine's layout.
function Resolve-DataRoot {
  if ($DataRoot) { return [IO.Path]::GetFullPath($DataRoot) }
  $fromCfg = Get-CfgValue 'dataRoot'
  if ($fromCfg) { return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($fromCfg)) }
  if ($env:DSH_HOME -and (Test-Path -LiteralPath $env:DSH_HOME)) { return [IO.Path]::GetFullPath($env:DSH_HOME) }
  # 向上一层层找“像数据目录”的 data（含 profiles 或 sessions），
  # 这样引擎放在 tools\...\engine 或插件包里都能自己找到，不写死任何机器路径。
  $walk = $script:root
  for ($i = 0; $i -lt 4 -and $walk; $i++) {
    $cand = Join-Path $walk 'data'
    if ((Test-Path -LiteralPath (Join-Path $cand 'profiles')) -or (Test-Path -LiteralPath (Join-Path $cand 'sessions'))) {
      return [IO.Path]::GetFullPath($cand)
    }
    $walk = Split-Path -Parent $walk
  }
  throw 'Data root not found. Pass -DataRoot or set dataRoot in the config file.'
}

function Resolve-GitExe {
  if ($GitExe) { return $GitExe }
  $fromCfg = Get-CfgValue 'git'
  if ($fromCfg -and (Test-Path -LiteralPath $fromCfg)) { return $fromCfg }
  # 便携版自带 MinGit：从引擎目录向上找 tools\MinGit，插件包和 tools 目录两种布局都适用。
  $walk = $script:root
  for ($i = 0; $i -lt 4 -and $walk; $i++) {
    $minGit = Join-Path $walk 'tools\MinGit\cmd\git.exe'
    if (Test-Path -LiteralPath $minGit) { return $minGit }
    $walk = Split-Path -Parent $walk
  }
  $cmd = Get-Command git -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw 'git.exe not found. Pass -GitExe or install Git.'
}

$dataRoot = Resolve-DataRoot
if (-not (Test-Path -LiteralPath $dataRoot)) { throw "data root does not exist: $dataRoot" }

if ($RepoDir) {
  $repoDir = [IO.Path]::GetFullPath($RepoDir)
} elseif (Get-CfgValue 'repoDir') {
  $repoDir = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables((Get-CfgValue 'repoDir')))
} else {
  $repoDir = Join-Path $dataRoot 'env-sync-repo'
}
if ($Branch) { $branch = $Branch }
elseif (Get-CfgValue 'branch') { $branch = Get-CfgValue 'branch' }
else { $branch = 'env-sync' }

$script:gitExe = Resolve-GitExe

# Never let the repository directory collide with the data root: backup wipes
# the repo working tree, so a collision would delete the environment.
$dataFull = [IO.Path]::GetFullPath($dataRoot).TrimEnd('\')
$repoFull = [IO.Path]::GetFullPath($repoDir).TrimEnd('\')
if ($dataFull -eq $repoFull) { throw 'repoDir must not be the same directory as dataRoot.' }

$include = @(Get-CfgValue 'include')
if (-not $include -or $include.Count -eq 0) {
  $include = @('.credentials.yaml', '.anonymous-user-id', 'sessions', 'storages', 'skills', 'mnemon',
    'profiles/desktop/cordis.patch.yml', 'profiles/desktop/cordis.yml', 'profiles/desktop/package.json',
    'profiles/desktop/pnpm-lock.yaml', 'profiles/desktop/.npmrc', 'profiles/desktop/pnpm-workspace.yaml',
    'profiles/desktop/.dsh-market')
}
$excludeDirs = @(Get-CfgValue 'excludeDirNames')
if (-not $excludeDirs -or $excludeDirs.Count -eq 0) { $excludeDirs = @('node_modules', 'logs', 'cache') }
$excludePatterns = @(Get-CfgValue 'excludeNamePatterns')
if (-not $excludePatterns -or $excludePatterns.Count -eq 0) {
  $excludePatterns = @('*.lock', '*.bak', '*.bak_*', '*.log', '*.tmp', '*.crdownload', '*.pyc', '*.db-shm', '*.db-wal')
}

function Test-Excluded($name, $isDir) {
  if ($isDir -and $excludeDirs -contains $name) { return $true }
  foreach ($pattern in $excludePatterns) {
    if ($name -like $pattern) { return $true }
  }
  return $false
}

# Copy one include entry (file or directory tree) into the destination root.
function Copy-Entry($relPath, $srcRoot, $dstRoot) {
  $src = Join-Path $srcRoot $relPath
  if (-not (Test-Path -LiteralPath $src)) { return }
  $dst = Join-Path $dstRoot $relPath

  if (Test-Path -LiteralPath $src -PathType Leaf) {
    if (Test-Excluded (Split-Path $src -Leaf) $false) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
    return
  }

  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Get-ChildItem -LiteralPath $src -Recurse -Force | ForEach-Object {
    if (Test-Excluded $_.Name $_.PSIsContainer) { return }
    $target = $_.FullName.Substring($srcRoot.Length).TrimStart('\','/')
    $out = Join-Path $dstRoot $target
    if ($_.PSIsContainer) {
      New-Item -ItemType Directory -Force -Path $out | Out-Null
    } else {
      New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
      Copy-Item -LiteralPath $_.FullName -Destination $out -Force
    }
  }
}

function Invoke-Git([string[]]$gitArgs, [string]$workDir) {
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $script:gitExe -C $workDir @gitArgs 2>&1 | ForEach-Object { $_.ToString() }
    if ($LASTEXITCODE -ne 0) {
      throw "git $($gitArgs -join ' ') failed (exit $LASTEXITCODE): $($output -join ' ')"
    }
    return ($output -join "`n")
  } finally {
    $ErrorActionPreference = $prevEap
  }
}

# Same as Invoke-Git but reports a failure instead of throwing, for probes such
# as "does this repository have a first commit yet".
function Invoke-GitProbe([string[]]$gitArgs, [string]$workDir) {
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $script:gitExe -C $workDir @gitArgs 2>&1 | ForEach-Object { $_.ToString() }
    return @{ code = $LASTEXITCODE; text = ($output -join "`n") }
  } finally {
    $ErrorActionPreference = $prevEap
  }
}

# Reset the repository working tree, preserving .git.
function Clear-WorkTree($dir) {
  Get-ChildItem -LiteralPath $dir -Force | Where-Object Name -ne '.git' |
    Remove-Item -Recurse -Force
}

# Before a restore overwrites local data, keep a copy of everything that will be
# touched, so an unwanted restore can be undone by hand.
function Save-PreRestoreSnapshot {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $snap = Join-Path (Split-Path -Parent $dataRoot) ("env-restore-backup-" + $stamp)
  New-Item -ItemType Directory -Force -Path $snap | Out-Null
  $count = 0
  foreach ($entry in $include) {
    $src = Join-Path $dataRoot $entry
    if (-not (Test-Path -LiteralPath $src)) { continue }
    Copy-Entry $entry $dataRoot $snap
    $count++
  }
  Write-Output ("PRE-RESTORE snapshot ($count entries): $snap")
  return $snap
}

if (-not (Test-Path -LiteralPath $repoDir)) {
  New-Item -ItemType Directory -Force -Path $repoDir | Out-Null
}

if (-not (Test-Path -LiteralPath (Join-Path $repoDir '.git'))) {
  Invoke-Git @('init', '-b', $branch) $repoDir | Out-Null
  if ($RepoUrl) { Invoke-Git @('remote', 'add', 'origin', $RepoUrl) $repoDir | Out-Null }
}

switch ($Mode) {
  'backup' {
    Clear-WorkTree $repoDir
    foreach ($entry in $include) { Copy-Entry $entry $dataRoot $repoDir }
    Invoke-Git @('add', '-A') $repoDir | Out-Null
    $staged = Invoke-Git @('status', '--porcelain') $repoDir
    if ($staged.Trim()) {
      $msg = "env backup $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') on $env:COMPUTERNAME"
      Invoke-Git @('commit', '-m', $msg) $repoDir | Out-Null
      $hasRemote = Invoke-Git @('remote') $repoDir
      if ($hasRemote -match 'origin') {
        Invoke-Git @('push', '-u', 'origin', $branch) $repoDir | Out-Null
        Write-Output "BACKUP committed and pushed to origin/$branch"
      } else {
        Write-Output 'BACKUP committed locally (no remote configured)'
      }
    } else {
      Write-Output 'BACKUP no changes since last commit'
    }
  }

  'restore' {
    $hasRemote = Invoke-Git @('remote') $repoDir
    if ($hasRemote -match 'origin') {
      Invoke-Git @('pull', 'origin', $branch) $repoDir | Out-Null
    }
    Save-PreRestoreSnapshot | Out-Null
    foreach ($entry in $include) { Copy-Entry $entry $repoDir $dataRoot }
    Write-Output "RESTORE pulled $branch and copied configured paths into data root"
  }

  'status' {
    Write-Output "data root : $dataRoot"
    Write-Output "repo dir  : $repoDir"
    Write-Output "branch    : $branch"
    Write-Output '--- git status ---'
    Write-Output (Invoke-Git @('status', '-sb') $repoDir)
    $head = Invoke-GitProbe @('rev-parse', '--verify', 'HEAD') $repoDir
    if ($head.code -eq 0) {
      Write-Output '--- last commit ---'
      Write-Output (Invoke-Git @('log', '-1', '--stat') $repoDir)
    } else {
      Write-Output '--- no commits yet ---'
    }
  }
}
