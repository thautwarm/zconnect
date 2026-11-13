#!/usr/bin/env pwsh
#
# 把 Rust 侧的本地断句（Silero VAD）编译成 Windows x64 DLL，并把
# ONNX Runtime 一起暂存到 windows/Vendor/，供 Flutter 的 Windows 构建嵌入。
#
# 和 macOS/Android 一样，不用 flutter_rust_bridge 自带的 cargokit，
# 只借它的代码生成；构建自己来。
#
# 用法：pwsh -File tools/build_rust_windows.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProgressPreference = 'SilentlyContinue'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $RepoRoot

$LibStem = 'rust_lib_pp_friend'
$Target = 'x86_64-pc-windows-msvc'
$VendorDir = Join-Path $RepoRoot 'windows/Vendor'
$Cache = Join-Path $RepoRoot 'windows/.build'

$OrtVersion = '1.24.3'
$OrtUrl = "https://github.com/microsoft/onnxruntime/releases/download/v$OrtVersion/onnxruntime-win-x64-$OrtVersion.zip"
$OrtSha = '4fbfb85d0e9de9bb6fb8a9866a7cb477cbad404d889b236931bf3f5d547e5f48'

function Fail([string]$Message) {
  Write-Host "错误：$Message" -ForegroundColor Red
  exit 1
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-Native([string]$FilePath, [string[]]$Arguments) {
  Write-Host "    $FilePath $($Arguments -join ' ')"
  & $FilePath @Arguments
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    throw "命令失败（退出码 $code）：$FilePath $($Arguments -join ' ')"
  }
}

# GitHub release 下载偶发断流，单次失败不代表文件不可用。
function Invoke-Download([string]$Url, [string]$OutFile) {
  $attempts = 4
  for ($i = 1; $i -le $attempts; $i++) {
    try {
      Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
      return
    }
    catch {
      if ($i -eq $attempts) { throw }
      Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
      Write-Host "    下载失败（第 $i 次）：$($_.Exception.Message)，重试" -ForegroundColor Yellow
      Start-Sleep -Seconds (3 * $i)
    }
  }
}

function Get-File([string]$Url, [string]$Dest, [string]$WantSha) {
  if (Test-Path $Dest) {
    $got = Get-Sha256 $Dest
    if ($got -eq $WantSha) {
      Write-Host '    已是最新，跳过'
      return
    }
    Write-Host '    sha256 不匹配，重新下载' -ForegroundColor Yellow
    Remove-Item $Dest -Force
  }

  New-Item -ItemType Directory -Force -Path (Split-Path $Dest -Parent) | Out-Null
  $tmp = "$Dest.tmp"
  try {
    Write-Host "    下载 $Url"
    Invoke-Download $Url $tmp
    $got = Get-Sha256 $tmp
    if ($got -ne $WantSha) {
      Fail "sha256 不匹配：$Url（拿到 $got，期望 $WantSha）"
    }
    Move-Item -Force $tmp $Dest
  }
  finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
  }
}

function Show-File([string]$Path) {
  if (-not (Test-Path $Path)) { Fail "没找到 $Path" }
  $item = Get-Item $Path
  $hash = Get-Sha256 $Path
  Write-Host "    $($item.FullName) ($($item.Length) bytes, sha256 $hash)"
}

if ($env:OS -ne 'Windows_NT') {
  Fail '只能在 Windows 上构建 Windows 产物'
}

# ---------------------------------------------------------------- Rust

foreach ($tool in @('rustup', 'cargo')) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    Fail "找不到 $tool，先装 Rust（https://rustup.rs/）"
  }
}

$installedTargets = & rustup target list --installed
if ($LASTEXITCODE -ne 0) { Fail 'rustup target list 失败' }
if ($installedTargets -notcontains $Target) {
  Write-Host "==> 安装 Rust target $Target"
  Invoke-Native 'rustup' @('target', 'add', $Target)
}

Write-Host "==> cargo build (release, $Target)"
Invoke-Native 'cargo' @(
  'build',
  '--release',
  '--target', $Target,
  '--manifest-path', (Join-Path $RepoRoot 'rust/Cargo.toml')
)

$Dll = Join-Path $RepoRoot "rust/target/$Target/release/$LibStem.dll"
if (-not (Test-Path $Dll)) { Fail "没找到 $Dll" }

New-Item -ItemType Directory -Force -Path $VendorDir, (Join-Path $RepoRoot 'rust/target/release') | Out-Null

# 开发期（flutter run 从仓库根启动）frb 的默认加载路径是
# rust/target/release/，顺手放一份，省得每次手动拷。
Copy-Item -Force $Dll (Join-Path $RepoRoot "rust/target/release/$LibStem.dll")

# 打成 Windows 包时从这里嵌入到 exe 旁边。
Copy-Item -Force $Dll (Join-Path $VendorDir "$LibStem.dll")

# ---------------------------------------------------------------- ONNX Runtime

Write-Host "==> ONNX Runtime $OrtVersion (win-x64)"
$OrtZip = Join-Path $Cache "onnxruntime-win-x64-$OrtVersion.zip"
$OrtDll = Join-Path $VendorDir 'onnxruntime.dll'
$OrtStamp = Join-Path $VendorDir '.onnxruntime-version'

$ortUpToDate = $false
if ((Test-Path $OrtDll) -and (Test-Path $OrtStamp)) {
  $ortUpToDate = ((Get-Content -LiteralPath $OrtStamp -Raw).Trim() -eq $OrtVersion)
}

if ($ortUpToDate) {
  Write-Host '    已是最新，跳过'
}
else {
  Get-File $OrtUrl $OrtZip $OrtSha

  $extractDir = Join-Path $Cache "ort-$OrtVersion"
  Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
  Expand-Archive -Path $OrtZip -DestinationPath $extractDir -Force

  $member = Join-Path $extractDir "onnxruntime-win-x64-$OrtVersion/lib/onnxruntime.dll"
  if (-not (Test-Path $member)) { Fail "压缩包里找不到 $member" }

  Copy-Item -Force $member $OrtDll
  Set-Content -LiteralPath $OrtStamp -Value $OrtVersion -NoNewline
}

# ---------------------------------------------------------------- 结果

Write-Host
Write-Host '==> 产物'
Show-File (Join-Path $RepoRoot "rust/target/release/$LibStem.dll")
Show-File (Join-Path $VendorDir "$LibStem.dll")
Show-File $OrtDll
exit 0
