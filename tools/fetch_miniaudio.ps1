#!/usr/bin/env pwsh
#
# 下载 miniaudio 单头文件，放到 windows/Vendor/。
#
# 只做一件事：确保 windows/Vendor/miniaudio.h 和锁定版本、锁定哈希一致。
# 已存在且哈希匹配时直接跳过；哈希对不上就删掉重下，重下后仍对不上则
# 大声失败 —— 版本号没变而内容变了，要么上游重发，要么下载链路有问题。
#
# 用法：pwsh -File tools/fetch_miniaudio.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Invoke-WebRequest 的进度条在 CI 日志里既没用又拖慢下载。
$ProgressPreference = 'SilentlyContinue'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $RepoRoot

$MiniAudioVersion = '0.11.22'
$MiniAudioUrl = "https://raw.githubusercontent.com/mackron/miniaudio/$MiniAudioVersion/miniaudio.h"
$MiniAudioSha = '9019743287e443c55e5737a7297f38e5e358561701d6db2d905afb114390c410'

$VendorDir = Join-Path $RepoRoot 'windows/Vendor'
$Dest = Join-Path $VendorDir 'miniaudio.h'

function Fail([string]$Message) {
  Write-Host "错误：$Message" -ForegroundColor Red
  exit 1
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

Write-Host "==> miniaudio $MiniAudioVersion"

if (Test-Path $Dest) {
  $got = Get-Sha256 $Dest
  if ($got -eq $MiniAudioSha) {
    Write-Host '    已是最新，跳过'
    Write-Host "    → $Dest ($((Get-Item $Dest).Length) bytes, sha256 $got)"
    exit 0
  }
  Write-Host '    sha256 不匹配，重新下载' -ForegroundColor Yellow
  Remove-Item $Dest -Force
}

New-Item -ItemType Directory -Force -Path $VendorDir | Out-Null

$Tmp = "$Dest.tmp"
try {
  Write-Host "    下载 $MiniAudioUrl"
  Invoke-WebRequest -Uri $MiniAudioUrl -OutFile $Tmp -UseBasicParsing

  $got = Get-Sha256 $Tmp
  if ($got -ne $MiniAudioSha) {
    Fail "sha256 不匹配：$MiniAudioUrl（拿到 $got，期望 $MiniAudioSha）"
  }

  Move-Item -Force $Tmp $Dest
}
finally {
  if (Test-Path $Tmp) { Remove-Item $Tmp -Force }
}

$size = (Get-Item $Dest).Length
$hash = Get-Sha256 $Dest
Write-Host "    → $Dest ($size bytes, sha256 $hash)"
exit 0
