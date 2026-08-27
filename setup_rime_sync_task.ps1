# 创建 Windows 任务计划程序任务 - Rime 自动同步
# 需要管理员权限运行

$ErrorActionPreference = 'Stop'

$taskName = "Rime Auto Sync"
$scriptPath = "C:\Users\ZhouH\AppData\Roaming\Rime\sync_rime.ps1"
$pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
$userName = $env:USERNAME

# 检查任务是否已存在
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "任务 '$taskName' 已存在，将先删除..."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# 创建触发器 - 每30分钟执行一次
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30)

# 创建操作（使用 pwsh 以避免 UTF-8 无 BOM 脚本编码问题）
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
$principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType S4U

# 注册任务
Register-ScheduledTask `
    -TaskName $taskName `
    -Trigger $trigger `
    -Action $action `
    -Settings $settings `
    -Principal $principal `
    -Description "每30分钟自动同步 Rime 输入法配置到 D:\rimesync"

Write-Host "任务创建成功！"
Write-Host "任务名称: $taskName"
Write-Host "执行间隔: 每30分钟"
Write-Host "执行引擎: pwsh"
Write-Host "脚本路径: $scriptPath"
Write-Host ""
Write-Host "可以在任务计划程序中查看和管理此任务"
