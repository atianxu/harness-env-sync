# 打发布包：把 GUI（ps1 + exe）、引擎、插件包和说明文档打成干净 zip。
# 干净 = 不带本机仓库地址、令牌、数据目录；配置一律留空，由运行期自动探测。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File Build-Release.ps1 [-Version 0.2.0]

[CmdletBinding()]
param(
  [string]$Version = '0.2.0'
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$pkgName = 'HarnessEnvSync-' + $Version
$dist = $here + '\dist'
$stage = $dist + '\_stage-' + $Version
$outDir = $stage + '\' + $pkgName

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
New-Item -ItemType Directory -Path $dist -Force | Out-Null

# 1) 图形控制台 + 启动器 + 引擎
Copy-Item -LiteralPath ($here + '\EnvSyncConsole.ps1') -Destination $outDir
$exe = $here + '\HarnessEnvSync.exe'
if (Test-Path -LiteralPath $exe) { Copy-Item -LiteralPath $exe -Destination $outDir }
$vbs = $here + '\启动环境同步控制台.vbs'
if (Test-Path -LiteralPath $vbs) { Copy-Item -LiteralPath $vbs -Destination $outDir }
New-Item -ItemType Directory -Path ($outDir + '\engine') -Force | Out-Null
Copy-Item -LiteralPath ($here + '\engine\env-sync.ps1') -Destination ($outDir + '\engine')

# 2) 插件包（不带调试残留）
$pluginOut = $outDir + '\plugin\dsh-env-sync'
New-Item -ItemType Directory -Path ($pluginOut + '\engine') -Force | Out-Null
$pluginSrc = $here + '\plugin\dsh-env-sync'
foreach ($name in @('index.js', 'package.json', 'cordis.patch.yml', 'README.md', 'LICENSE')) {
  Copy-Item -LiteralPath ($pluginSrc + '\' + $name) -Destination $pluginOut
}
Copy-Item -LiteralPath ($pluginSrc + '\engine\env-sync.ps1') -Destination ($pluginOut + '\engine')

# 3) 配置：全部留空 = 运行期自动探测
$template = [ordered]@{
  repoUrl             = ''
  dataRoot            = ''
  repoDir             = ''
  branch              = 'env-sync'
  git                 = ''
  include             = @(
    '.credentials.yaml', '.anonymous-user-id', '.meow-smooth', 'attachments', 'dsh-market',
    'dsh-windows-mcp.settings.json', 'dsh-windows-mcp.state.json', 'dsh-windows-mcp.versions.json',
    'mnemon', 'sessions', 'skills', 'storages',
    'profiles/desktop/cordis.patch.yml', 'profiles/desktop/cordis.yml', 'profiles/desktop/package.json',
    'profiles/desktop/pnpm-lock.yaml', 'profiles/desktop/.npmrc', 'profiles/desktop/pnpm-workspace.yaml',
    'profiles/desktop/.dsh-market'
  )
  excludeNamePatterns = @('*.lock', '*.bak', '*.bak_*', '*.log', '*.tmp', '*.crdownload', '*.pyc', '*.db-shm', '*.db-wal')
  excludeDirNames     = @('node_modules', 'logs')
}
$json = $template | ConvertTo-Json -Depth 6
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText(($outDir + '\env-sync.json'), $json, $utf8NoBom)
[IO.File]::WriteAllText(($pluginOut + '\env-sync.json'), $json, $utf8NoBom)

# 4) 说明文档
Copy-Item -LiteralPath ($here + '\发布说明.md') -Destination ($outDir + '\安装说明.md')

# 5) 干净性检查：令牌、私有仓库地址、本机绝对路径都不许进包
$bad = @()
Get-ChildItem -LiteralPath $outDir -Recurse -File |
  Where-Object { @('.ps1', '.json', '.js', '.yml', '.md', '.txt', '.vbs') -contains $_.Extension } |
  ForEach-Object {
    $text = [IO.File]::ReadAllText($_.FullName)
    if ($text -match 'oauth2:[A-Za-z0-9_\-\.]{16,}@' -or $text -match 'gitee\.com/[A-Za-z0-9_\-]+/' -or $text -match 'D:\\DeepSeekHarness') {
      $bad += $_.FullName
    }
  }
if ($bad.Count -gt 0) {
  Write-Output 'RELEASE REJECTED — 这些文件含私有信息：'
  foreach ($f in $bad) { Write-Output ('  ' + $f) }
  exit 2
}

# 6) 打包
$zip = $dist + '\' + $pkgName + '.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $outDir -DestinationPath $zip -CompressionLevel Optimal

Write-Output ('RELEASE OK: ' + $zip + ' (' + (Get-Item -LiteralPath $zip).Length + ' bytes)')
