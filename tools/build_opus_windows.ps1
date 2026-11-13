#!/usr/bin/env pwsh
#
# 为 Windows x64 静态编译 libogg + libopus，装到 windows/Vendor/。
#
# 和 tools/build_opus_macos.sh 用同一组上游版本与 SHA-256；区别只在于
# 这里走 MSVC / Visual Studio 17 2022 生成器，产物是 .lib 而不是 .a。
#
# 只出 x64 静态库：Windows 包不需要额外分发 ogg/opus 的 DLL。
#
# 用法：pwsh -File tools/build_opus_windows.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProgressPreference = 'SilentlyContinue'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $RepoRoot

$OpusVersion = '1.6.1'
$OggVersion = '1.3.6'
$OpusSha = '6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1'
$OggSha = '83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638'

# Visual Studio 自带 CMake，但不在普通 shell 的 PATH 上；CI 上通常直接有 cmake。
# 两处都找一下，避免本地构建必须手动开 Developer PowerShell。
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
  if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products '*' -property installationPath
    if ($vsPath) {
      $candidate = Join-Path $vsPath 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin'
      if (Test-Path (Join-Path $candidate 'cmake.exe')) {
        $env:PATH = "$candidate;$env:PATH"
      }
    }
  }
}

# 2026 年的 windows-latest 已经迁到 Visual Studio 2026，CMake 4.2+ 的生成器
# 叫 "Visual Studio 18 2026"；本地 VS 2022 仍是 "Visual Studio 17 2022"。
# 用 vswhere 看实际装了哪个，再确认 CMake 认识这个生成器。
function Resolve-VSGenerator {
  $help = (& cmake --help 2>&1) -join "`n"
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
  $vs2026 = $null
  $vs2022 = $null
  if (Test-Path $vswhere) {
    $vs2026 = & $vswhere -latest -products '*' -version '[18.0,19.0)' `
      -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $vs2022 = & $vswhere -latest -products '*' -version '[17.0,18.0)' `
      -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  }
  if ($vs2026 -and $help -match 'Visual Studio 18 2026') {
    return 'Visual Studio 18 2026'
  }
  if ($vs2022 -and $help -match 'Visual Studio 17 2022') {
    return 'Visual Studio 17 2022'
  }
  if ($help -match 'Visual Studio 18 2026') { return 'Visual Studio 18 2026' }
  if ($help -match 'Visual Studio 17 2022') { return 'Visual Studio 17 2022' }
  return $null
}

$CMakeGenerator = Resolve-VSGenerator
if (-not $CMakeGenerator) {
  Fail '找不到可用的 Visual Studio C++ 生成器（需要 VS 2022 或 VS 2026 + CMake）'
}
Write-Host "==> CMake generator: $CMakeGenerator"

$VendorDir = Join-Path $RepoRoot 'windows/Vendor'
$IncludeDir = Join-Path $VendorDir 'include'
$LibDir = Join-Path $VendorDir 'lib'
$Cache = Join-Path $RepoRoot 'windows/.build/opus'

# 公共头文件：Dart/FFI 侧和 CMake 只认这几个。
$OpusHeaders = @(
  'opus.h',
  'opus_defines.h',
  'opus_types.h',
  'opus_multistream.h',
  'opus_projection.h'
)
$OggHeaders = @('ogg.h', 'os_types.h')

function Fail([string]$Message) {
  Write-Host "错误：$Message" -ForegroundColor Red
  exit 1
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# 外部命令（cmake / tar / git 之类）不会因为 $ErrorActionPreference 而抛异常，
# 必须自己看退出码。
function Invoke-Native([string]$FilePath, [string[]]$Arguments) {
  Write-Host "    $FilePath $($Arguments -join ' ')"
  & $FilePath @Arguments
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    throw "命令失败（退出码 $code）：$FilePath $($Arguments -join ' ')"
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
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
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

function Expand-Tarball([string]$Archive, [string]$DestDir) {
  New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
  Invoke-Native 'tar' @('-xzf', $Archive, '-C', $DestDir)
}

function Invoke-CMakeBuild([string]$SourceDir, [string]$BuildDir) {
  Remove-Item -Recurse -Force $BuildDir -ErrorAction SilentlyContinue
  # 多配置生成器（VS）不看 CMAKE_BUILD_TYPE，Release 在 --build 时指定。
  Invoke-Native 'cmake' @(
    '-S', $SourceDir,
    '-B', $BuildDir,
    '-G', $CMakeGenerator,
    '-A', 'x64',
    '-DBUILD_SHARED_LIBS=OFF',
    '-DBUILD_TESTING=OFF',
    '-DOPUS_BUILD_PROGRAMS=OFF',
    '-DOPUS_BUILD_TESTING=OFF',
    '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL'
  )
  Invoke-Native 'cmake' @('--build', $BuildDir, '--config', 'Release')
}

# 不假设 install 布局：直接去构建树里找目标名对应的 .lib。
# CMakeFiles 下可能有中间产物同名，排除掉。
function Find-BuiltLib([string]$BuildDir, [string]$Name) {
  $found = Get-ChildItem -LiteralPath $BuildDir -Recurse -File -Filter $Name -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '[\\/]CMakeFiles[\\/]' } |
    Select-Object -First 1
  if (-not $found) {
    Fail "构建树里找不到 $Name：$BuildDir"
  }
  return $found.FullName
}

function Test-AllOutputs {
  foreach ($name in $OpusHeaders) {
    if (-not (Test-Path (Join-Path $IncludeDir $name))) { return $false }
  }
  foreach ($name in $OggHeaders) {
    if (-not (Test-Path (Join-Path $IncludeDir "ogg/$name"))) { return $false }
  }
  if (-not (Test-Path (Join-Path $LibDir 'opus.lib'))) { return $false }
  if (-not (Test-Path (Join-Path $LibDir 'ogg.lib'))) { return $false }
  return $true
}

Write-Host "==> libogg $OggVersion / opus $OpusVersion (Windows x64, MSVC)"

if (Test-AllOutputs) {
  Write-Host '    产物已齐全，跳过下载与构建'
}
else {
  foreach ($tool in @('cmake', 'tar')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
      Fail "找不到 $tool，请先安装（Windows runner 自带）"
    }
  }

  New-Item -ItemType Directory -Force -Path $Cache, $IncludeDir, $LibDir | Out-Null

  # ------------------------------------------------------------ libogg

  Write-Host "==> libogg $OggVersion"
  $OggTgz = Join-Path $Cache "libogg-$OggVersion.tar.gz"
  $OggSrc = Join-Path $Cache "libogg-$OggVersion"
  $OggBuild = Join-Path $Cache 'build-ogg'

  Get-File "https://downloads.xiph.org/releases/ogg/libogg-$OggVersion.tar.gz" $OggTgz $OggSha
  Remove-Item -Recurse -Force $OggSrc -ErrorAction SilentlyContinue
  Expand-Tarball $OggTgz $Cache
  if (-not (Test-Path $OggSrc)) { Fail "解压后找不到 $OggSrc" }

  Invoke-CMakeBuild $OggSrc $OggBuild
  $OggLib = Find-BuiltLib $OggBuild 'ogg.lib'
  Copy-Item -Force $OggLib (Join-Path $LibDir 'ogg.lib')

  # ------------------------------------------------------------ opus

  Write-Host "==> opus $OpusVersion"
  $OpusTgz = Join-Path $Cache "opus-$OpusVersion.tar.gz"
  $OpusSrc = Join-Path $Cache "opus-$OpusVersion"
  $OpusBuild = Join-Path $Cache 'build-opus'

  Get-File "https://downloads.xiph.org/releases/opus/opus-$OpusVersion.tar.gz" $OpusTgz $OpusSha
  Remove-Item -Recurse -Force $OpusSrc -ErrorAction SilentlyContinue
  Expand-Tarball $OpusTgz $Cache
  if (-not (Test-Path $OpusSrc)) { Fail "解压后找不到 $OpusSrc" }

  Invoke-CMakeBuild $OpusSrc $OpusBuild
  $OpusLib = Find-BuiltLib $OpusBuild 'opus.lib'
  Copy-Item -Force $OpusLib (Join-Path $LibDir 'opus.lib')

  # ------------------------------------------------------------ 公共头文件

  New-Item -ItemType Directory -Force -Path (Join-Path $IncludeDir 'ogg') | Out-Null
  foreach ($name in $OpusHeaders) {
    $src = Join-Path $OpusSrc "include/$name"
    if (-not (Test-Path $src)) { Fail "opus 源码里找不到 $src" }
    Copy-Item -Force $src (Join-Path $IncludeDir $name)
  }
  foreach ($name in $OggHeaders) {
    $src = Join-Path $OggSrc "include/ogg/$name"
    if (-not (Test-Path $src)) { Fail "ogg 源码里找不到 $src" }
    Copy-Item -Force $src (Join-Path $IncludeDir "ogg/$name")
  }
}

# ------------------------------------------------------------ 结果

# 不管走没走构建分支，最终文件必须齐全。
if (-not (Test-AllOutputs)) {
  Fail "最终产物不完整，检查 $IncludeDir 和 $LibDir"
}

Write-Host
Write-Host '==> 产物'
foreach ($path in @(
    (Join-Path $LibDir 'opus.lib'),
    (Join-Path $LibDir 'ogg.lib')
  )) {
  $item = Get-Item $path
  $hash = Get-Sha256 $path
  Write-Host "    $($item.FullName) ($($item.Length) bytes, sha256 $hash)"
}
exit 0
