<#
.SYNOPSIS
    Build RetroDebugger for Windows.
.DESCRIPTION
    Full build pipeline: initializes submodules, builds dependencies,
    builds MTEngineSDL, builds RetroDebugger, and optionally the CUDA plugin.
    Output: platform/Windows/bin/<Platform>/<Configuration>/
.PARAMETER Platform
    Target architecture: x64 or ARM64. Default: auto-detect from OS.
.PARAMETER Configuration
    Build configuration: Debug or Release. Default: Release.
.PARAMETER Compiler
    Compiler toolchain: Clang (ClangCL) or MSVC (v143). Default: Clang.
    Clang requires "C++ Clang Compiler for Windows" VS component.
    CUDA plugin always builds with MSVC regardless of this setting.
.PARAMETER Clean
    Clean all build artifacts and exit. Runs MSBuild /t:Clean on both
    MTEngineSDL and RetroDebugger, removes dependency build dirs and built libs.
.PARAMETER SkipDeps
    Skip dependency builds (use if libs are already built).
.PARAMETER SkipCuda
    Skip CUDA plugin build.
.EXAMPLE
    .\build-windows.ps1
    .\build-windows.ps1 -Compiler MSVC
    .\build-windows.ps1 -Clean
    .\build-windows.ps1 -Platform ARM64 -Configuration Debug
    .\build-windows.ps1 -SkipDeps
#>
param(
    [ValidateSet('x64','ARM64')]
    [string]$Platform,

    [ValidateSet('Debug','Release')]
    [string]$Configuration = 'Release',

    [ValidateSet('Clang','MSVC')]
    [string]$Compiler = 'Clang',

    [switch]$Clean,
    [switch]$SkipDeps,
    [switch]$SkipCuda,
    [switch]$Help
)

if ($Help) {
    Write-Host @"
RetroDebugger Windows Build Script

Usage: .\build-windows.ps1 [options]

Options:
  -Platform <x64|ARM64>       Target architecture (default: auto-detect)
  -Configuration <Debug|Release>  Build configuration (default: Release)
  -Compiler <Clang|MSVC>      Compiler toolchain (default: Clang)
                               Clang requires "C++ Clang Compiler for Windows" VS component
  -Clean                       Clean all build artifacts and exit (does not build)
  -SkipDeps                    Skip dependency builds (llama.cpp, FTXUI, mbedTLS)
  -SkipCuda                    Skip CUDA plugin build
  -Help                        Show this help message

Examples:
  .\build-windows.ps1                              # Clang Release x64
  .\build-windows.ps1 -Compiler MSVC               # MSVC Release x64
  .\build-windows.ps1 -Clean                        # Clean rebuild with Clang
  .\build-windows.ps1 -Clean -Compiler MSVC         # Clean rebuild with MSVC
  .\build-windows.ps1 -Configuration Debug          # Debug build
  .\build-windows.ps1 -SkipDeps                     # Rebuild without deps
  .\build-windows.ps1 -Platform ARM64               # ARM64 build

Notes:
  - CUDA plugin always builds with MSVC regardless of -Compiler setting
  - Output: platform\Windows\bin\<Platform>\<Configuration>\
"@
    exit 0
}

$ErrorActionPreference = 'Stop'

if (-not $Platform) {
    $arch = $env:PROCESSOR_ARCHITECTURE
    $Platform = if ($arch -eq 'ARM64') { 'ARM64' } else { 'x64' }
    Write-Host "Auto-detected platform: $Platform"
}

$c64dDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$mtDir = Join-Path (Split-Path -Parent $c64dDir) 'MTEngineSDL'

foreach ($tool in @('cmake','git')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$tool not found in PATH"
        exit 1
    }
}

# The required PlatformToolset decides which VS instance to use.
# vcxproj files default to ClangCL; override to v143 when MSVC is selected.
$requiredToolset = if ($Compiler -eq 'MSVC') { 'v143' } else { 'ClangCL' }
$toolsetArgs = @()
if ($Compiler -eq 'MSVC') {
    $toolsetArgs = @('/p:PlatformToolset=v143')
    Write-Host "Compiler: MSVC (v143 toolset)" -ForegroundColor Cyan
} else {
    Write-Host "Compiler: Clang (ClangCL toolset)" -ForegroundColor Cyan
}

# Pick the VS instance that actually HAS $requiredToolset, not merely the newest
# one. With side-by-side installs, `vswhere -latest` returns the newest instance,
# which may carry neither ClangCL nor v143 (e.g. VS 2026 ships v145 only) while an
# older instance has both. Selecting by toolset keeps both lookups on one instance;
# picking MSBuild from one and the VC tools from another mismatches cl/lib/link.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$candidates = @(& $vswhere -products * -requires Microsoft.Component.MSBuild `
    -property installationPath 2>$null) | Where-Object { $_ } | Select-Object -Unique

$vsInstall = $candidates | Where-Object {
    Test-Path (Join-Path $_ "MSBuild\Microsoft\VC\*\Platforms\$Platform\PlatformToolsets\$requiredToolset")
} | Select-Object -First 1

if (-not $vsInstall) {
    Write-Error @"
No Visual Studio instance provides the '$requiredToolset' platform toolset for $Platform.
Instances checked: $($candidates -join '; ')
Install it via the VS Installer:
  ClangCL -> "C++ Clang Compiler for Windows" + "MSBuild support for LLVM (clang-cl) toolset"
  v143    -> "MSVC v143 - VS 2022 C++ build tools"
"@
    exit 1
}
Write-Host "Using VS instance: $vsInstall (toolset $requiredToolset)"

$msbuild = Get-ChildItem (Join-Path $vsInstall "MSBuild") -Recurse -Filter MSBuild.exe `
    -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\Bin\\MSBuild\.exe$' } |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $msbuild) {
    Write-Error "MSBuild.exe not found under $vsInstall"
    exit 1
}
Write-Host "Using MSBuild: $msbuild"

# Add MSBuild and VC tools (lib.exe, cl.exe) to PATH so child scripts can find them
$env:PATH = (Split-Path $msbuild) + ";$env:PATH"

if ($vsInstall) {
    $hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'Hostx64' }
    $vcToolsDir = Join-Path $vsInstall "VC\Tools\MSVC"
    if (Test-Path $vcToolsDir) {
        $latestVc = Get-ChildItem $vcToolsDir -Directory | Sort-Object Name | Select-Object -Last 1
        if ($latestVc) {
            $vcBin = Join-Path $latestVc.FullName "bin\$hostArch\x64"
            if (-not (Test-Path $vcBin)) { $vcBin = Join-Path $latestVc.FullName "bin\Hostx64\x64" }
            if (Test-Path $vcBin) {
                $env:PATH = "$vcBin;$env:PATH"
                Write-Host "Added VC tools: $vcBin"
            }
        }
    }
}

Write-Host "`n=== Initializing MTEngineSDL submodules ===" -ForegroundColor Cyan
Push-Location $mtDir
git submodule update --init --recursive
Pop-Location

if ($Clean) {
    Write-Host "`n=== Cleaning build artifacts ===" -ForegroundColor Yellow

    # Clean MSBuild projects
    Write-Host "Cleaning MTEngineSDL..."
    & $msbuild "$mtDir\platform\Windows\MTEngineSDL.sln" `
        /t:Clean /p:Configuration=$Configuration /p:Platform=$Platform `
        @toolsetArgs /v:minimal /nologo 2>$null

    Write-Host "Cleaning RetroDebugger..."
    & $msbuild "$c64dDir\platform\Windows\c64d.sln" `
        /t:Clean /p:Configuration=$Configuration /p:Platform=$Platform `
        @toolsetArgs /v:minimal /nologo 2>$null

    # Clean dependency build directories
    $depBuildDirs = @(
        (Join-Path $mtDir 'other\lib\llama.cpp\build-windows-cpu'),
        (Join-Path $mtDir 'other\lib\llama.cpp\build-windows-cuda'),
        (Join-Path $mtDir 'other\lib\ftxui\build-windows-x64'),
        (Join-Path $mtDir 'other\lib\ftxui\build-windows-ARM64'),
        (Join-Path $mtDir 'other\lib\mbedtls\build-windows')
    )
    foreach ($dir in $depBuildDirs) {
        if (Test-Path $dir) {
            Write-Host "Removing $dir"
            Remove-Item -Recurse -Force $dir
        }
    }

    # Clean built dependency libs
    $depLibsDir = Join-Path $mtDir "platform\Windows\libs\$Platform\$Configuration"
    if (Test-Path $depLibsDir) {
        $builtLibs = @('llama_cpp.lib', 'ftxui.lib', 'mbedtls_bundle.lib', 'mbedtls_bundle.stamp')
        foreach ($lib in $builtLibs) {
            $libPath = Join-Path $depLibsDir $lib
            if (Test-Path $libPath) {
                Write-Host "Removing $libPath"
                Remove-Item -Force $libPath
            }
        }
    }

    # Clean output bin directory
    $binDir = "$c64dDir\platform\Windows\bin\$Platform\$Configuration"
    if (Test-Path $binDir) {
        Write-Host "Removing $binDir"
        Remove-Item -Recurse -Force $binDir
    }

    Write-Host "Clean complete." -ForegroundColor Green
    exit 0
}

if (-not $SkipDeps) {
    Write-Host "`n=== Building dependencies ===" -ForegroundColor Cyan
    & "$mtDir\platform\Windows\build-deps.ps1" -Platform $Platform -Configuration $Configuration -Compiler $Compiler -SkipCuda:$SkipCuda
}

# Build uSockets (ClangCL's lld-link cannot read MSVC /GL bitcode objects,
# so we disable WholeProgramOptimization when using Clang)
$uSocketsDir = Join-Path (Split-Path -Parent $c64dDir) 'uSockets'
$uSocketsSln = Join-Path $uSocketsDir 'uSockets.sln'
if (Test-Path $uSocketsSln) {
    Write-Host "`n=== Building uSockets ($Platform $Configuration $Compiler) ===" -ForegroundColor Cyan
    $uSocketsArgs = @()
    if ($Compiler -eq 'Clang') {
        $uSocketsArgs = @('/p:WholeProgramOptimization=false')
    }
    & $msbuild $uSocketsSln `
        /p:Configuration=$Configuration /p:Platform=$Platform `
        @toolsetArgs @uSocketsArgs `
        /m /v:minimal /nologo
    if ($LASTEXITCODE -ne 0) { Write-Error "uSockets build failed"; exit 1 }

    # Copy rebuilt uSockets.lib to MTEngineSDL libs directory
    $uSocketsLib = Join-Path $uSocketsDir "$Platform\$Configuration\uSockets.lib"
    $mtLibsDir = Join-Path $mtDir "platform\Windows\libs\$Platform\$Configuration"
    if ((Test-Path $uSocketsLib) -and (Test-Path $mtLibsDir)) {
        Copy-Item $uSocketsLib $mtLibsDir -Force
        Write-Host "Copied uSockets.lib to $mtLibsDir"
    }
}

Write-Host "`n=== Building MTEngineSDL ($Platform $Configuration $Compiler) ===" -ForegroundColor Cyan
& $msbuild "$mtDir\platform\Windows\MTEngineSDL.sln" `
    /t:MTEngineSDL `
    /p:Configuration=$Configuration /p:Platform=$Platform `
    @toolsetArgs `
    /m /v:minimal /nologo
if ($LASTEXITCODE -ne 0) { Write-Error "MTEngineSDL build failed"; exit 1 }

Write-Host "`n=== Building RetroDebugger ($Platform $Configuration $Compiler) ===" -ForegroundColor Cyan
& $msbuild "$c64dDir\platform\Windows\c64d.sln" `
    /p:Configuration=$Configuration /p:Platform=$Platform `
    @toolsetArgs `
    /m /v:minimal /nologo
if ($LASTEXITCODE -ne 0) { Write-Error "RetroDebugger build failed"; exit 1 }

$outDir = "$c64dDir\platform\Windows\bin\$Platform\$Configuration"

if ($Platform -eq 'x64' -and -not $SkipCuda -and $env:CUDA_PATH) {
    Write-Host "`n=== Building CUDA plugin (always MSVC) ===" -ForegroundColor Cyan
    & $msbuild "$mtDir\platform\Windows\MTEngineSDL.sln" `
        /t:mt_llama_cuda_backend `
        /p:Configuration=$Configuration /p:Platform=$Platform `
        /p:PlatformToolset=v143 `
        /m /v:minimal /nologo
    if ($LASTEXITCODE -eq 0) {
        $cudaBin = "$mtDir\platform\Windows\bin\$Platform\$Configuration"
        $cudaDll = Join-Path $cudaBin "mt_llama_cuda_backend.dll"
        if (Test-Path $cudaDll) {
            Copy-Item $cudaDll $outDir -Force
            Write-Host "Copied CUDA plugin to output"
        }
        $cudaPath = $env:CUDA_PATH
        foreach ($pattern in @('cudart64_*.dll','cublas64_*.dll','cublasLt64_*.dll')) {
            $dlls = Get-ChildItem "$cudaPath\bin\$pattern" -ErrorAction SilentlyContinue
            foreach ($dll in $dlls) {
                Copy-Item $dll.FullName $outDir -Force
                Write-Host "Copied $($dll.Name)"
            }
        }
    } else {
        Write-Warning "CUDA plugin build failed (non-fatal)"
    }
} elseif ($Platform -eq 'x64' -and -not $env:CUDA_PATH) {
    Write-Host "CUDA toolkit not found - skipping CUDA plugin" -ForegroundColor Yellow
}

$exe = Join-Path $outDir "Retro Debugger.exe"
if (-not (Test-Path $exe)) {
    $exe = Join-Path $outDir "retrodebugger.exe"
}
if (-not (Test-Path $exe)) {
    $exe = Join-Path $outDir "c64d.exe"
}
if (Test-Path $exe) {
    Write-Host "`n=== Build successful ===" -ForegroundColor Green
    Write-Host "Output: $outDir"
} else {
    Write-Error "Build completed but executable not found at $outDir"
    exit 1
}
