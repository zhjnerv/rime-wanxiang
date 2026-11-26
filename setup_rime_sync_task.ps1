# 创建 Windows 任务计划程序任务 - Rime 自动同步
# 需要管理员权限运行
#
# 本脚本可从任意机器、任意用户名使用：脚本自身路径取自 $PSScriptRoot，
# PowerShell 解释器按 pwsh.exe -> powershell.exe 顺序自动探测，
# 不依赖固定用户名或固定安装路径。

$ErrorActionPreference = 'Stop'

# 检查管理员权限
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "需要管理员权限。请以管理员身份运行 PowerShell 后重试。"
    exit 1
}

$taskName = "Rime Auto Sync"
$scriptPath = Join-Path $PSScriptRoot "sync_rime.ps1"

if (-not (Test-Path $scriptPath)) {
    Write-Error "未找到同步脚本：$scriptPath。请确认本脚本与 sync_rime.ps1 在同一目录。"
    exit 1
}

# 探测 PowerShell 解释器：优先 PowerShell 7，回退到 Windows PowerShell 5.1
$pwshPath = $null
$pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($pwshCmd) {
    $pwshPath = $pwshCmd.Source
} elseif (Test-Path "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe") {
    $pwshPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

if (-not $pwshPath) {
    Write-Error "未找到可用的 PowerShell 解释器（pwsh.exe 或 powershell.exe）。"
    exit 1
}

$userName = $env:USERNAME

# 检查任务是否已存在
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "任务 '$taskName' 已存在，将先删除..."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# 创建触发器 - 每30分钟执行一次
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30)

# 创建操作（使用 PowerShell 而非直接调用，避免 UTF-8 无 BOM 脚本编码问题）
$action = New-ScheduledTaskAction `
    -Execute $pwshPath `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

# 创建任务设置
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable `
    -MultipleInstances IgnoreNew

# 创建任务主体
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $userName -LogonType S4U

# 注册任务
Register-ScheduledTask `
    -TaskName $taskName `
    -Trigger $trigger `
    -Action $action `
    -Settings $settings `
    -Principal $taskPrincipal `
    -Description "每30分钟自动同步 Rime 输入法配置到 sync_dir"

Write-Host "任务创建成功！"
Write-Host "任务名称: $taskName"
Write-Host "执行间隔: 每30分钟"
Write-Host "执行引擎: $pwshPath"
Write-Host "脚本路径: $scriptPath"
Write-Host ""
Write-Host "可以在任务计划程序中查看和管理此任务"