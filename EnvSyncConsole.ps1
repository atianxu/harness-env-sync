# Harness 环境同步控制台（GUI）
# 只做界面外壳，真正干活的是同目录 engine\env-sync.ps1（backup / restore / status）。
# 兼容 Windows PowerShell 5.1：长任务走后台 Job + 定时器，界面不冻结。
#
# 路径全部运行期解析，不写死某一台机器：
#   数据目录   = 配置 dataRoot  ->  $env:DSH_HOME  ->  本脚本上级目录\data
#   同步仓库   = 配置 repoDir   ->  数据目录\env-sync-repo
#   git.exe    = 配置 git       ->  上级目录\tools\MinGit\cmd\git.exe  ->  PATH 里的 git
# 界面上可随时改这些路径（设置对话框），保存后立即生效。
#
# 参数：
#   -SelfTest            只打印解析结果并跑一次 status，不起窗（供脚本取证）
#   -RunMode <mode>      -SelfTest 时指定要跑的模式，默认 status
#   -SmokeTest <mode>    起窗但自动执行一次任务，任务结束自动关闭（回归用）
[CmdletBinding()]
param(
  [switch]$SelfTest,
  [string]$RunMode,
  [string]$SmokeTest,
  [switch]$SettingsSmoke,
  [switch]$SettingsOnly
)

$ErrorActionPreference = 'Stop'
$script:here = Split-Path -Parent $PSCommandPath

# ---- 路径解析 -------------------------------------------------------------
$script:root = Split-Path -Parent $script:here
$script:engine = Join-Path $script:here 'engine\env-sync.ps1'
$script:cfgFile = Join-Path $script:here 'env-sync.json'
$script:logFile = Join-Path $script:root 'logs\env-sync-gui.log'

function Mask-Secret([string]$text) {
  if (-not $text) { return $text }
  $t = [regex]::Replace($text, 'oauth2:[^@\s]+@', 'oauth2:***@')
  $t = [regex]::Replace($t, '(https?://)[^/@\s:]+:[^/@\s]+@', '$1***@')
  return $t
}

function Read-Config {
  if (-not (Test-Path -LiteralPath $script:cfgFile)) { throw "缺少配置文件: $script:cfgFile" }
  return (Get-Content -Raw -LiteralPath $script:cfgFile | ConvertFrom-Json)
}

function Get-CfgValue($cfg, [string]$name) {
  if ($cfg -and $cfg.PSObject.Properties[$name] -and $cfg.$name) { return $cfg.$name }
  return $null
}

# 自动探测值（配置留空时实际生效的值）。保存设置时若用户没改，就写回空串，
# 保持配置可移植——不会把某台机器的路径固化进发布版。
function Get-AutoDataRoot {
  if ($env:DSH_HOME -and (Test-Path -LiteralPath $env:DSH_HOME)) { return [IO.Path]::GetFullPath($env:DSH_HOME) }
  return [IO.Path]::GetFullPath((Join-Path $script:root 'data'))
}

function Get-AutoRepoDir([string]$dataRoot) {
  return [IO.Path]::GetFullPath((Join-Path $dataRoot 'env-sync-repo'))
}

function Get-AutoGit {
  $mini = Join-Path $script:root 'tools\MinGit\cmd\git.exe'
  if (Test-Path -LiteralPath $mini) { return $mini }
  $cmd = Get-Command git -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# 数据目录：配置 -> DSH_HOME -> 上级目录\data
function Resolve-DataRoot($cfg) {
  $v = Get-CfgValue $cfg 'dataRoot'
  if ($v) { return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($v)) }
  return (Get-AutoDataRoot)
}

# 同步仓库：配置 -> 数据目录\env-sync-repo
function Resolve-RepoDir($cfg, [string]$dataRoot) {
  $v = Get-CfgValue $cfg 'repoDir'
  if ($v) { return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($v)) }
  return (Get-AutoRepoDir $dataRoot)
}

# git：配置 -> tools\MinGit -> PATH
function Resolve-Git($cfg) {
  $v = Get-CfgValue $cfg 'git'
  if ($v -and (Test-Path -LiteralPath $v)) { return $v }
  return (Get-AutoGit)
}

# ---- 自检模式（供脚本取证，不起窗）--------------------------------------
if ($SelfTest) {
  $cfg = Read-Config
  $dataRoot = Resolve-DataRoot $cfg
  $repoDir = Resolve-RepoDir $cfg $dataRoot
  $gitExe = Resolve-Git $cfg
  Write-Output "engine=$script:engine"
  Write-Output "config=$script:cfgFile"
  Write-Output "dataRoot=$dataRoot"
  Write-Output "repoDir=$repoDir"
  Write-Output "git=$gitExe"
  if (-not (Test-Path -LiteralPath $script:engine)) { Write-Output 'SELFTEST FAIL: engine missing'; exit 2 }
  if (-not (Test-Path -LiteralPath $dataRoot)) { Write-Output 'SELFTEST FAIL: data root missing'; exit 2 }
  if (-not $gitExe) { Write-Output 'SELFTEST FAIL: git missing'; exit 2 }
  $mode = $RunMode
  if (-not $mode) { $mode = 'status' }
  & $script:engine -Mode $mode -DataRoot $dataRoot -RepoDir $repoDir -GitExe $gitExe -ConfigPath $script:cfgFile 2>&1 |
    ForEach-Object { Write-Output (Mask-Secret ([string]$_)) }
  Write-Output 'SELFTEST OK'
  exit 0
}

# ---- WinForms ------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$bg = [System.Drawing.Color]::FromArgb(246, 247, 250)
$panel = [System.Drawing.Color]::FromArgb(255, 255, 255)
$edge = [System.Drawing.Color]::FromArgb(210, 216, 226)
$textCol = [System.Drawing.Color]::FromArgb(30, 34, 42)
$muted = [System.Drawing.Color]::FromArgb(104, 113, 128)
$accent = [System.Drawing.Color]::FromArgb(22, 93, 255)
$green = [System.Drawing.Color]::FromArgb(22, 163, 74)
$red = [System.Drawing.Color]::FromArgb(200, 32, 42)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Harness 环境同步控制台'
$form.Size = New-Object System.Drawing.Size(880, 640)
$form.MinimumSize = New-Object System.Drawing.Size(780, 540)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bg
$form.ForeColor = $textCol
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Harness 环境同步'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = $textCol
$title.Location = New-Object System.Drawing.Point(20, 14)
$title.AutoSize = $true
$form.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = '配置、插件清单、会话、技能、记忆库一键备份到 Git，换机器一键恢复。'
$sub.ForeColor = $muted
$sub.Location = New-Object System.Drawing.Point(22, 46)
$sub.AutoSize = $true
$form.Controls.Add($sub)

$statusDot = New-Object System.Windows.Forms.Label
$statusDot.Text = '●'
$statusDot.ForeColor = $green
$statusDot.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
$statusDot.Location = New-Object System.Drawing.Point(716, 18)
$statusDot.AutoSize = $true
$form.Controls.Add($statusDot)

$statusText = New-Object System.Windows.Forms.Label
$statusText.Text = '空闲'
$statusText.ForeColor = $muted
$statusText.Location = New-Object System.Drawing.Point(738, 20)
$statusText.AutoSize = $true
$form.Controls.Add($statusText)

# 信息卡
$info = New-Object System.Windows.Forms.Panel
$info.BackColor = $panel
$info.Location = New-Object System.Drawing.Point(20, 72)
$info.Size = New-Object System.Drawing.Size(826, 102)
$info.Anchor = 'Top,Left,Right'
$info.BorderStyle = 'FixedSingle'
$form.Controls.Add($info)

$infoLabels = @{}
$rows = @(
  @{ k = 'dataRoot'; cap = '数据目录' },
  @{ k = 'repo'; cap = '同步仓库' },
  @{ k = 'branch'; cap = '分支 / 最近提交' },
  @{ k = 'remote'; cap = '远端' }
)
$i = 0
foreach ($r in $rows) {
  $cap = New-Object System.Windows.Forms.Label
  $cap.Text = $r.cap
  $cap.ForeColor = $muted
  $cap.Location = New-Object System.Drawing.Point(14, (8 + $i * 23))
  $cap.AutoSize = $true
  $info.Controls.Add($cap)
  $val = New-Object System.Windows.Forms.Label
  $val.Text = '-'
  $val.ForeColor = $textCol
  $val.Location = New-Object System.Drawing.Point(100, (8 + $i * 23))
  $val.AutoSize = $true
  $info.Controls.Add($val)
  $infoLabels[$r.k] = $val
  $i++
}

# 按钮
function New-Button($caption, $x, $w, $primary) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $caption
  $b.Location = New-Object System.Drawing.Point($x, 190)
  $b.Size = New-Object System.Drawing.Size($w, 34)
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 1
  $b.FlatAppearance.BorderColor = $edge
  if ($primary) {
    $b.BackColor = $accent
    $b.FlatAppearance.BorderColor = $accent
    $b.ForeColor = [System.Drawing.Color]::White
  } else {
    $b.BackColor = [System.Drawing.Color]::FromArgb(243, 245, 249)
    $b.ForeColor = $textCol
  }
  $b.Cursor = [System.Windows.Forms.Cursors]::Hand
  return $b
}

$btnStatus = New-Button '刷新状态' 20 100 $false
$btnBackup = New-Button '立即备份并推送' 132 140 $true
$btnRestore = New-Button '从仓库恢复' 284 110 $false
$btnSettings = New-Button '设置' 406 80 $false
$btnOpen = New-Button '打开仓库' 498 100 $false
$btnCopy = New-Button '复制日志' 610 100 $false
$btnClear = New-Button '清空日志' 722 100 $false
foreach ($b in @($btnStatus, $btnBackup, $btnRestore, $btnSettings, $btnOpen, $btnCopy, $btnClear)) { $form.Controls.Add($b) }

# 日志
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::White
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(58, 64, 74)
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.Location = New-Object System.Drawing.Point(20, 240)
$logBox.Size = New-Object System.Drawing.Size(826, 316)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$logBox.BorderStyle = 'FixedSingle'
$form.Controls.Add($logBox)

$footer = New-Object System.Windows.Forms.Label
$footer.Text = '备份=复制配置/插件清单/会话/技能/记忆后 commit+push    恢复=先快照本地再 pull 并写回'
$footer.ForeColor = $muted
$footer.Location = New-Object System.Drawing.Point(20, 572)
$footer.AutoSize = $true
$footer.Anchor = 'Bottom,Left'
$form.Controls.Add($footer)

# ---- 状态 ---------------------------------------------------------------
$script:job = $null
$script:timer = $null
$script:jobLabel = ''
$script:collected = @()

function Append-Log([string]$line) {
  if (-not $logBox) { return }
  $stamp = Get-Date -Format 'HH:mm:ss'
  $logBox.AppendText("[$stamp] $line`r`n")
}

function Append-Raw([string]$line) {
  $logBox.AppendText("$line`r`n")
  if ($logBox.TextLength -gt 200000) {
    # 长备份会刷很多行，只保留尾部，避免界面越来越卡。
    $logBox.Text = $logBox.Text.Substring($logBox.TextLength - 150000)
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
  }
}

function Set-Busy([bool]$busy, [string]$label) {
  $btnStatus.Enabled = -not $busy
  $btnBackup.Enabled = -not $busy
  $btnRestore.Enabled = -not $busy
  $btnSettings.Enabled = -not $busy
  if ($busy) {
    $statusDot.ForeColor = $accent
    $statusText.ForeColor = $accent
    $statusText.Text = $label
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
  } else {
    $statusDot.ForeColor = $green
    $statusText.ForeColor = $muted
    $statusText.Text = '空闲'
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
  }
}

function Refresh-Info {
  try {
    $cfg = Read-Config
    $dataRoot = Resolve-DataRoot $cfg
    $repoDir = Resolve-RepoDir $cfg $dataRoot
    $gitExe = Resolve-Git $cfg
    $infoLabels['dataRoot'].Text = $dataRoot
    $infoLabels['repo'].Text = $repoDir

    $remoteText = '-'
    $branchText = '-'
    $lastText = '-'
    if ($gitExe -and (Test-Path -LiteralPath (Join-Path $repoDir '.git'))) {
      try { $remoteText = Mask-Secret ((& $gitExe -C $repoDir remote get-url origin 2>&1) -join ' ') } catch { $remoteText = '(未配置远端)' }
      try { $branchText = ((& $gitExe -C $repoDir branch --show-current 2>&1) -join ' ').Trim() } catch { $branchText = '-' }
      try { $lastText = ((& $gitExe -C $repoDir log -1 --pretty=format:'%h %s' 2>&1) -join ' ').Trim() } catch { $lastText = '(暂无提交)' }
    } else {
      $remoteText = '(同步仓库尚未初始化)'
    }
    if ($remoteText -eq '') { $remoteText = '(未配置远端)' }
    if ($branchText -eq '') { $branchText = '-' }
    if ($lastText -eq '') { $lastText = '(暂无提交)' }
    $infoLabels['branch'].Text = "$branchText  ·  $lastText"
    $infoLabels['remote'].Text = $remoteText
  } catch {
    Append-Raw ("读取配置失败: " + $_.Exception.Message)
  }
}

function Start-Engine([string]$mode, [string]$label) {
  if ($script:job) { return }
  Set-Busy $true $label
  Append-Log "开始: $label"
  $script:collected = @()
  $script:jobLabel = $label
  $cfg = Read-Config
  $script:dataRootNow = Resolve-DataRoot $cfg
  $script:repoDirNow = Resolve-RepoDir $cfg $script:dataRootNow
  $script:gitNow = Resolve-Git $cfg
  $script:job = Start-Job -ScriptBlock {
    param($engine, $cfgPath, $mode, $dataRoot, $repoDir, $gitExe)
    & $engine -Mode $mode -ConfigPath $cfgPath -DataRoot $dataRoot -RepoDir $repoDir -GitExe $gitExe 2>&1 |
      ForEach-Object { [string]$_ }
  } -ArgumentList $script:engine, $script:cfgFile, $mode, $script:dataRootNow, $script:repoDirNow, $script:gitNow
  $script:timer.Start()
}

function Finish-Engine {
  $state = $script:job.State
  if (-not ($state -eq 'Completed')) { Append-Raw "任务结束状态: $state" }
  Append-Log ("完成: " + $script:jobLabel)
  try {
    $dir = Split-Path -Parent $script:logFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $block = "[$stamp] " + $script:jobLabel + " (" + $state + ")`r`n" + (($script:collected | ForEach-Object { Mask-Secret $_ }) -join "`r`n") + "`r`n"
    Add-Content -LiteralPath $script:logFile -Value $block -Encoding UTF8
  } catch { Append-Raw "日志落盘失败: $($_.Exception.Message)" }
  Stop-Job -Job $script:job -ErrorAction SilentlyContinue
  Remove-Job -Job $script:job -Force -ErrorAction SilentlyContinue
  $script:job = $null
  $script:timer.Stop()
  Set-Busy $false ''
  Refresh-Info
  if ($script:smoke) {
    $script:smokeCode = 0
    $form.Close()
  }
}

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 700
$script:timer.Add_Tick({
  if (-not $script:job) { $script:timer.Stop(); return }
  $chunk = Receive-Job -Job $script:job 2>&1
  foreach ($line in $chunk) {
    $script:collected += [string]$line
    Append-Raw (Mask-Secret ([string]$line))
  }
  if (@('Completed', 'Failed', 'Stopped') -contains $script:job.State) { Finish-Engine }
})

$btnStatus.Add_Click({ Start-Engine 'status' '读取状态' })
$btnBackup.Add_Click({ Start-Engine 'backup' '备份并推送' })
$btnRestore.Add_Click({
  $ans = [System.Windows.Forms.MessageBox]::Show(
    "恢复会用仓库里的内容覆盖数据目录（配置、插件清单、会话、技能、记忆）。`r`n" +
    "覆盖前会自动做一份本地快照，但仍建议先确认仓库里是你要的那一版。继续吗？",
    '确认恢复', 'YesNo', 'Warning')
  if ($ans -eq 'Yes') { Start-Engine 'restore' '从仓库恢复' }
})
$btnOpen.Add_Click({
  try {
    $cfg = Read-Config
    $repoDir = Resolve-RepoDir $cfg (Resolve-DataRoot $cfg)
    if (Test-Path -LiteralPath $repoDir) { Start-Process -FilePath $repoDir } else { Append-Log "仓库目录不存在: $repoDir" }
  } catch { Append-Log ("打开仓库失败: " + $_.Exception.Message) }
})
$btnCopy.Add_Click({
  [System.Windows.Forms.Clipboard]::SetText($logBox.Text)
  Append-Log '日志已复制到剪贴板'
})
$btnClear.Add_Click({ $logBox.Clear() })

# ---- 设置对话框 ---------------------------------------------------------
# 写回配置：设置对话框与自检共用同一条路径，保证“界面上能存”和“脚本里能测”是同一段代码。
function Save-Settings([string]$dataRootValue, [string]$repoDirValue, [string]$remoteValue, [string]$branchValue, [string]$gitValue) {
  # 与自动探测值相同就写空串，避免把本机路径固化进配置（发布版要能换机器直接用）。
  $autoData = (Get-AutoDataRoot).TrimEnd('\')
  $autoGit = Get-AutoGit
  if ($dataRootValue -and ([IO.Path]::GetFullPath($dataRootValue).TrimEnd('\') -ieq $autoData)) { $dataRootValue = '' }
  $effectiveData = $dataRootValue
  if (-not $effectiveData) { $effectiveData = $autoData }
  $autoRepo = (Get-AutoRepoDir $effectiveData).TrimEnd('\')
  if ($repoDirValue -and ([IO.Path]::GetFullPath($repoDirValue).TrimEnd('\') -ieq $autoRepo)) { $repoDirValue = '' }
  if ($gitValue -and $autoGit -and ($gitValue -ieq $autoGit)) { $gitValue = '' }

  $newCfg = Get-Content -Raw -LiteralPath $script:cfgFile | ConvertFrom-Json
  $newCfg.dataRoot = $dataRootValue
  $newCfg.repoDir = $repoDirValue
  $newCfg.branch = $branchValue
  if (-not $newCfg.PSObject.Properties['git']) { $newCfg | Add-Member -NotePropertyName git -NotePropertyValue '' }
  $newCfg.git = $gitValue
  $json = $newCfg | ConvertTo-Json -Depth 6
  [IO.File]::WriteAllText($script:cfgFile, $json, (New-Object Text.UTF8Encoding $false))

  $repoDirNew = $repoDirValue
  if (-not $repoDirNew) { $repoDirNew = Join-Path $effectiveData 'env-sync-repo' }
  $gitEffective = $gitValue
  if (-not $gitEffective) { $gitEffective = $autoGit }
  if ($remoteValue -and $gitEffective -and (Test-Path -LiteralPath (Join-Path $repoDirNew '.git'))) {
    & $gitEffective -C $repoDirNew remote set-url origin $remoteValue 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      & $gitEffective -C $repoDirNew remote add origin $remoteValue 2>&1 | Out-Null
    }
    Append-Log ('远端已更新为 ' + (Mask-Secret $remoteValue))
  }
}

# ---- 设置保存自检：不起窗，直接把“设置->保存”这段代码跑一遍并回读 JSON ----
if ($SettingsSmoke) {
  $cfg = Read-Config
  $dataRoot = Resolve-DataRoot $cfg
  $repoDir = Resolve-RepoDir $cfg $dataRoot
  $gitExe = Resolve-Git $cfg
  $branch = Get-CfgValue $cfg 'branch'
  if (-not $branch) { $branch = 'env-sync' }
  $remote = ''
  if ($gitExe -and (Test-Path -LiteralPath (Join-Path $repoDir '.git'))) {
    try { $remote = ((& $gitExe -C $repoDir remote get-url origin 2>&1) -join ' ').Trim() } catch { $remote = '' }
  }
  Save-Settings $dataRoot $repoDir $remote $branch $gitExe
  $after = Get-Content -Raw -LiteralPath $script:cfgFile
  $parsed = $after | ConvertFrom-Json
  Write-Output ('cfgDataRoot=' + $parsed.dataRoot)
  Write-Output ('cfgRepoDir=' + $parsed.repoDir)
  Write-Output ('cfgBranch=' + $parsed.branch)
  Write-Output ('cfgGit=' + $parsed.git)
  Write-Output ('cfgInclude=' + $parsed.include.Count)
  Write-Output ('remote=' + (Mask-Secret $remote))
  Write-Output 'SETTINGS-SMOKE OK'
  exit 0
}

function Show-Settings {
  $cfg = Read-Config
  $dataRoot = Resolve-DataRoot $cfg
  $repoDir = Resolve-RepoDir $cfg $dataRoot
  $gitExe = Resolve-Git $cfg
  $branch = Get-CfgValue $cfg 'branch'
  if (-not $branch) { $branch = 'env-sync' }
  $remote = ''
  if ($gitExe -and (Test-Path -LiteralPath (Join-Path $repoDir '.git'))) {
    try { $remote = ((& $gitExe -C $repoDir remote get-url origin 2>&1) -join ' ').Trim() } catch { $remote = '' }
  }

  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = '同步设置'
  $dlg.Size = New-Object System.Drawing.Size(760, 330)
  $dlg.StartPosition = 'CenterParent'
  $dlg.FormBorderStyle = 'FixedDialog'
  $dlg.MaximizeBox = $false
  $dlg.MinimizeBox = $false
  $dlg.BackColor = $bg
  $dlg.ForeColor = $textCol
  $dlg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

  function New-Label($text, $x, $y, $w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.ForeColor = $muted
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, 20)
    return $l
  }
  function New-Input($text, $x, $y, $w) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $text
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, 24)
    $t.BackColor = [System.Drawing.Color]::White
    $t.BorderStyle = 'FixedSingle'
    return $t
  }
  function New-Browse($x, $y) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = '浏览…'
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size(72, 24)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = $edge
    $b.BackColor = [System.Drawing.Color]::FromArgb(243, 245, 249)
    $b.ForeColor = $textCol
    return $b
  }

  $hint = New-Label '留空即自动探测：数据目录取 DSH_HOME，仓库取数据目录下的 env-sync-repo。' 20 12 700
  $dlg.Controls.Add($hint)

  $dlg.Controls.Add((New-Label '数据目录' 20 48 90))
  $tbData = New-Input $dataRoot 120 46 500
  $dlg.Controls.Add($tbData)
  $bData = New-Browse 630 46
  $dlg.Controls.Add($bData)

  $dlg.Controls.Add((New-Label '同步仓库' 20 84 90))
  $tbRepo = New-Input $repoDir 120 82 500
  $dlg.Controls.Add($tbRepo)
  $bRepo = New-Browse 630 82
  $dlg.Controls.Add($bRepo)

  $dlg.Controls.Add((New-Label '远端地址' 20 120 90))
  $remoteShown = Mask-Secret $remote
  $tbRemote = New-Input $remoteShown 120 118 500
  $dlg.Controls.Add($tbRemote)

  $dlg.Controls.Add((New-Label '分支' 20 156 90))
  $tbBranch = New-Input $branch 120 154 200
  $dlg.Controls.Add($tbBranch)

  $dlg.Controls.Add((New-Label 'git.exe' 20 192 90))
  $tbGit = New-Input $gitExe 120 190 500
  $dlg.Controls.Add($tbGit)
  $bGit = New-Browse 630 190
  $dlg.Controls.Add($bGit)

  $tip = New-Label '远端可留空：只做本地备份仓；填 Gitee 私有仓地址即可换机恢复。' 20 224 700
  $tip.ForeColor = $muted
  $dlg.Controls.Add($tip)

  $btnSave = New-Object System.Windows.Forms.Button
  $btnSave.Text = '保存'
  $btnSave.Location = New-Object System.Drawing.Point(470, 256)
  $btnSave.Size = New-Object System.Drawing.Size(120, 32)
  $btnSave.FlatStyle = 'Flat'
  $btnSave.BackColor = $accent
  $btnSave.FlatAppearance.BorderColor = $accent
  $btnSave.ForeColor = [System.Drawing.Color]::White
  $dlg.Controls.Add($btnSave)

  $btnCancel = New-Object System.Windows.Forms.Button
  $btnCancel.Text = '取消'
  $btnCancel.Location = New-Object System.Drawing.Point(600, 256)
  $btnCancel.Size = New-Object System.Drawing.Size(100, 32)
  $btnCancel.FlatStyle = 'Flat'
  $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(243, 245, 249)
  $btnCancel.FlatAppearance.BorderColor = $edge
  $btnCancel.FlatAppearance.BorderSize = 1
  $btnCancel.ForeColor = $textCol
  $btnCancel.Add_Click({ $dlg.Close() })
  $dlg.Controls.Add($btnCancel)

  $bData.Add_Click({
    $f = New-Object System.Windows.Forms.FolderBrowserDialog
    if (Test-Path -LiteralPath $tbData.Text) { $f.SelectedPath = $tbData.Text }
    if ($f.ShowDialog() -eq 'OK') { $tbData.Text = $f.SelectedPath }
  })
  $bRepo.Add_Click({
    $f = New-Object System.Windows.Forms.FolderBrowserDialog
    if (Test-Path -LiteralPath $tbRepo.Text) { $f.SelectedPath = $tbRepo.Text }
    if ($f.ShowDialog() -eq 'OK') { $tbRepo.Text = $f.SelectedPath }
  })
  $bGit.Add_Click({
    $f = New-Object System.Windows.Forms.OpenFileDialog
    $f.Filter = 'git.exe|git.exe|所有文件|*.*'
    $f.FileName = $tbGit.Text
    if ($f.ShowDialog() -eq 'OK') { $tbGit.Text = $f.FileName }
  })

  $btnSave.Add_Click({
    try {
      $remoteValue = $tbRemote.Text.Trim()
      # 没动过就保留原地址（含令牌），避免把脱敏串 "***" 写回仓库。
      if ($remoteValue -eq $remoteShown) { $remoteValue = $remote }
      Save-Settings $tbData.Text.Trim() $tbRepo.Text.Trim() $remoteValue $tbBranch.Text.Trim() $tbGit.Text.Trim()
      Append-Log '设置已保存'
      $dlg.Close()
      Refresh-Info
    } catch {
      [System.Windows.Forms.MessageBox]::Show(("保存失败: " + $_.Exception.Message), '设置', 'OK', 'Error') | Out-Null
    }
  })

  [void]$dlg.ShowDialog($form)
}

$btnSettings.Add_Click({ Show-Settings })

$form.Add_Shown({
  Refresh-Info
  Append-Log '控制台已就绪'
  if ($script:smoke) { Start-Engine $script:smoke ('自动回归: ' + $script:smoke) }
})
$form.Add_FormClosing({
  # PowerShell 的 WinForms 事件处理器拿到 $args[0]=sender / $args[1]=EventArgs；用 $_ 赋值 Cancel 不生效。
  if ($script:job) {
    $ans = [System.Windows.Forms.MessageBox]::Show('还有任务在跑，确定关闭？任务会被中止。', '关闭', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { $args[1].Cancel = $true; return }
    Stop-Job -Job $script:job -ErrorAction SilentlyContinue
    Remove-Job -Job $script:job -Force -ErrorAction SilentlyContinue
    $script:timer.Stop()
  }
})

$script:smoke = $SmokeTest
$script:smokeCode = 1
if ($SettingsOnly) { Show-Settings; exit 0 }
[void]$form.ShowDialog()
if ($script:smoke) { exit $script:smokeCode }
