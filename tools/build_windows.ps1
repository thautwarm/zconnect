#!/usr/bin/env pwsh
#
# Windows 原生依赖总入口：miniaudio 头文件 → ogg/opus 静态库 → Rust DLL + ORT。
# 任一步失败立即停止，并把退出码透传出去。
#
# 用法：pwsh -File tools/build_windows.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $RepoRoot

# 子脚本用独立进程跑：它们内部的 exit 只结束自己，不会把总入口一起带走，
# 而且退出码干净。优先 pwsh 7，退回 Windows PowerShell 5.1。
$PSHost = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

$Steps = @(
  'tools/fetch_miniaudio.ps1',
  'tools/build_opus_windows.ps1',
  'tools/build_rust_windows.ps1'
)

foreach ($step in $Steps) {
  $script = Join-Path $RepoRoot $step
  if (-not (Test-Path $script)) {
    Write-Host "错误：找不到 $script" -ForegroundColor Red
    exit 1
  }

  Write-Host
  Write-Host "==> $step"
  & $PSHost -NoProfile -File $script
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Write-Host "错误：$step 失败（退出码 $code）" -ForegroundColor Red
    exit $code
  }
}

Write-Host
Write-Host 'Windows 原生依赖全部就绪。'
exit 0
