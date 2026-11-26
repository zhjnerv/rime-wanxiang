# Rime 自动同步脚本
# 用途: 调用 WeaselDeployer 进行同步操作
# 使用方式: pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File sync_rime.ps1
#
# 为什么需要先停 WeaselServer：
# /sync 要独占 SQLite/LevelDB 形式的 *.userdb，而常驻的 WeaselServer 一直持有这些库的句柄。
# 不停服务直接 /sync，sequence / stats / zc 三个库会稳定报
#   level_db.cc:259 Error opening db 'X': IO error: ...X.userdb/LOCK
# 并连带 failed to merge snapshot file，表现为每次 sync 都是 "2 success, 1 failure"。
# 因此流程固定为：停服务 -> /sync -> 恢复服务原有状态。

$ErrorActionPreference = 'Stop'

# 查找 WeaselDeployer.exe 路径（支持不同版本和安装位置）
$possiblePaths = @(
    "C:\Program Files\Rime\weasel-*\WeaselDeployer.exe",
    "C:\Program Files (x86)\Rime\weasel-*\WeaselDeployer.exe"
)

$deployerPath = $null
foreach ($pattern in $possiblePaths) {
    $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $deployerPath = $found.FullName
        break
    }
}

if (-not $deployerPath) {
    Write-Error "未找到 WeaselDeployer.exe，请检查 Rime 是否已正确安装"
    exit 1
}

# WeaselServer.exe 与 WeaselDeployer.exe 同目录
$serverPath = Join-Path (Split-Path $deployerPath -Parent) "WeaselServer.exe"

Write-Host "开始同步 Rime 配置..."
Write-Host "使用: $deployerPath"

# 记录服务原本是否在运行，同步结束后恢复到该状态
$serverWasRunning = $false
try {
    $serverWasRunning = [bool](Get-Process -Name WeaselServer -ErrorAction SilentlyContinue)
} catch {
    $serverWasRunning = $false
}

# 停服务，释放 userdb 句柄
if ($serverWasRunning) {
    try {
        Stop-Process -Name WeaselServer -Force -ErrorAction SilentlyContinue
        # 等待进程真正退出，最多 10 秒
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Process -Name WeaselServer -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 200
        }
        Write-Host "已停止 WeaselServer，准备同步"
    } catch {
        Write-Warning "停止 WeaselServer 失败：$($_.Exception.Message)"
    }
}

$exitCode = 1
try {
    # 使用 Start-Process 获取退出码，避免 PowerShell 无法捕获 GUI 程序退出码的问题
    $process = Start-Process -FilePath $deployerPath -ArgumentList "/sync" -Wait -PassThru
    $exitCode = $process.ExitCode
} catch {
    Write-Error "调用 WeaselDeployer 失败：$($_.Exception.Message)"
    $exitCode = 1
} finally {
    # 无论同步成功与否，都要把服务恢复到原有状态
    if ($serverWasRunning -and (Test-Path $serverPath)) {
        try {
            $stillDown = -not (Get-Process -Name WeaselServer -ErrorAction SilentlyContinue)
            if ($stillDown) {
                Start-Process -FilePath $serverPath
                Start-Sleep -Seconds 1
                Write-Host "已重新启动 WeaselServer"
            }
        } catch {
            Write-Warning "重新启动 WeaselServer 失败：$($_.Exception.Message)"
        }
    }
}

if ($exitCode -eq 0) {
    Write-Host "同步完成"
} else {
    Write-Error "同步失败，退出码: $exitCode"
    exit $exitCode
}