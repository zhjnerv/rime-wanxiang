# Rime 自动同步脚本
# 用途: 调用 WeaselDeployer 进行同步操作
# 使用方式: pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File sync_rime.ps1

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

# 执行同步
Write-Host "开始同步 Rime 配置..."
Write-Host "使用: $deployerPath"

# 使用 Start-Process 获取退出码，避免 PowerShell 无法捕获 GUI 程序退出码的问题
$process = Start-Process -FilePath $deployerPath -ArgumentList "/sync" -Wait -PassThru
$exitCode = $process.ExitCode

if ($exitCode -eq 0) {
    Write-Host "同步完成"
} else {
    Write-Error "同步失败，退出码: $exitCode"
    exit $exitCode
}
