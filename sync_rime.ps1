# Rime 自动同步脚本
# 用途: 调用 WeaselDeployer 进行同步操作
# 使用方式: pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File sync_rime.ps1
#
# 为什么这么复杂：
# /sync 要独占各个 *.userdb（LevelDB），而常驻的 WeaselServer 一直持有它们的句柄。
# 不停服务直接 /sync，sequence / stats / zc 会稳定报
#   level_db.cc:259 Error opening db 'X': IO error: ...X.userdb/LOCK
# 并连带 failed to merge snapshot file，表现为每次都是 "2 success, 1 failure"。
#
# 只停一次服务也不够：杀掉 WeaselServer 后，只要有应用请求输入法，系统会在零点几秒内
# 把它重新拉起，重新占住 LOCK。而 /sync 要跑十几秒，中途被抢占照样失败。
# 所以流程是：记录原始状态 -> 停服务 -> 运行期间持续压制复活 -> 按日志校验 -> 失败重试
# -> finally 无条件恢复服务。

$ErrorActionPreference = 'Stop'

# 失败重试上限
$MaxAttempts = 3

# 重试之间的等待秒数。
# /sync 内部关闭 '.temp' 库后约 40ms 就会重开它，立刻重跑会原地撞回同一竞态窗口，
# 所以必须让上一次的句柄和杀软扫描先结束。
$RetryDelaySeconds = 8

# 停服务后等待进程退出的上限（秒）
$StopTimeoutSeconds = 10

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

$serverPath = Join-Path (Split-Path $deployerPath -Parent) "WeaselServer.exe"

# Rime 日志目录，用于判定本次同步是否真的成功
$logDir = Join-Path $env:TEMP "rime.weasel"

Write-Host "开始同步 Rime 配置..."
Write-Host "使用: $deployerPath"

# 记录服务原本是否在运行，结束时恢复到该状态
$serverWasRunning = $false
try {
    $serverWasRunning = [bool](Get-Process -Name WeaselServer -ErrorAction SilentlyContinue)
} catch {
    $serverWasRunning = $false
}

# 跑一次 /sync，期间持续压制被系统重新拉起的 WeaselServer
function Wait-WeaselServerStopped {
    param([int]$TimeoutSeconds = 10)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Name WeaselServer -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Invoke-SyncOnce {
    Stop-Process -Name WeaselServer -Force -ErrorAction SilentlyContinue

    # 必须确认进程真的退出了再跑 /sync：服务若还在，它会一直占着 userdb 的 LOCK，
    # 这一轮注定失败，还会白白多断一次输入。
    if (-not (Wait-WeaselServerStopped -TimeoutSeconds $StopTimeoutSeconds)) {
        return [pscustomobject]@{
            ExitCode   = -1
            Suppressed = 0
            EndTime    = Get-Date
            Skipped    = $true
        }
    }

    # 进程退出后 LevelDB 句柄释放有延迟，给一点余量再让 deployer 进场
    Start-Sleep -Milliseconds 500

    $process = Start-Process -FilePath $deployerPath -ArgumentList "/sync" -PassThru
    $suppressed = 0
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 250
        $revived = Get-Process -Name WeaselServer -ErrorAction SilentlyContinue
        if ($revived) {
            Stop-Process -Id $revived.Id -Force -ErrorAction SilentlyContinue
            $suppressed++
        }
    }
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode   = $process.ExitCode
        Suppressed = $suppressed
        EndTime    = Get-Date
        Skipped    = $false
    }
}

# 判定这一次同步是否真的成功：本次结束后不应再产生含 LOCK 错误的 ERROR 日志
function Test-SyncSucceeded {
    param([datetime]$Since)

    if (-not (Test-Path $logDir)) {
        return $true
    }

    $newLogs = Get-ChildItem $logDir -Filter "*.ERROR.*" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Since }

    foreach ($log in $newLogs) {
        $hit = Select-String -Path $log.FullName -Pattern "Error opening db" -SimpleMatch -ErrorAction SilentlyContinue
        if ($hit) {
            return $false
        }
    }
    return $true
}

$exitCode = 1
$attempt = 0
$succeeded = $false

try {
    while ($attempt -lt $MaxAttempts -and -not $succeeded) {
        $attempt++
        if ($attempt -gt 1) {
            Write-Host "第 $attempt 次尝试..."
        }

        $startedAt = Get-Date
        $result = Invoke-SyncOnce
        $exitCode = $result.ExitCode

        if ($result.Skipped) {
            Write-Warning "WeaselServer 在 ${StopTimeoutSeconds}s 内没有退出，跳过本轮（避免必然失败的同步）"
            $exitCode = 1
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
            continue
        }

        if ($exitCode -ne 0) {
            Write-Warning "WeaselDeployer 返回 $exitCode"
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
            continue
        }

        # 只按退出码不够：内部合并失败时退出码仍是 0
        # 稍等等日志落盘，再判定
        Start-Sleep -Seconds 1
        if (Test-SyncSucceeded -Since $startedAt) {
            $succeeded = $true
            Write-Host "同步完成（压制复活实例 $($result.Suppressed) 次）"
        } else {
            Write-Warning "检测到 userdb LOCK 失败，准备重试"
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }
} catch {
    Write-Error "调用 WeaselDeployer 失败：$($_.Exception.Message)"
    $exitCode = 1
} finally {
    # 无论成败，都把服务恢复到原有状态
    if ($serverWasRunning -and (Test-Path $serverPath)) {
        try {
            $stillDown = -not (Get-Process -Name WeaselServer -ErrorAction SilentlyContinue)
            if ($stillDown) {
                Start-Process -FilePath $serverPath -WindowStyle Hidden
                Start-Sleep -Seconds 1
                $restored = Get-Process -Name WeaselServer -ErrorAction SilentlyContinue
                Write-Host "已重新启动 WeaselServer（PID $($restored.Id)，会话 $($restored.SessionId)）"
            }
        } catch {
            Write-Warning "重新启动 WeaselServer 失败：$($_.Exception.Message)"
        }
    }
}

if ($succeeded) {
    Write-Host "同步完成"
} else {
    Write-Error "同步失败：连续 $MaxAttempts 次仍未通过 userdb 校验"
    exit 1
}
