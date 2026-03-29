#Requires -Version 5
# OpenClacky Windows Installation Script
# Usage: powershell -c "irm https://oss.1024code.com/clacky-ai/openclacky/main/scripts/install.ps1 | iex"
#
# WSL2 is preferred. If virtualisation is unavailable (e.g. running inside a VM),
# the script automatically falls back to WSL1.
# If WSL is not installed at all, the script enables it and asks you to reboot.
# After rebooting, run the same command again to complete installation.
#
# Development: .\install.ps1 -Local
#   Uses install_simple.sh from the same directory as this script instead of CDN.

param(
    [switch]$Local
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CLACKY_CDN_BASE_URL   = "https://oss.1024code.com"
$INSTALL_PS1_COMMAND   = "powershell -c `"irm $CLACKY_CDN_BASE_URL/clacky-ai/openclacky/main/scripts/install.ps1 | iex`""
$INSTALL_SCRIPT_URL    = "$CLACKY_CDN_BASE_URL/clacky-ai/openclacky/main/scripts/install_simple.sh"
$UBUNTU_WSL_AMD64_URL        = "$CLACKY_CDN_BASE_URL/ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz"
$UBUNTU_WSL_AMD64_SHA256_URL = "$CLACKY_CDN_BASE_URL/ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz.sha256"
$UBUNTU_WSL_ARM64_URL        = "$CLACKY_CDN_BASE_URL/ubuntu-jammy-wsl-arm64-ubuntu22.04lts.rootfs.tar.gz"
$UBUNTU_WSL_ARM64_SHA256_URL = "$CLACKY_CDN_BASE_URL/ubuntu-jammy-wsl-arm64-ubuntu22.04lts.rootfs.tar.gz.sha256"
$WSL_UPDATE_URL        = "$CLACKY_CDN_BASE_URL/wsl_update_x64.msi"      # Windows 10
$WSL_UPDATE_URL_WIN11  = "$CLACKY_CDN_BASE_URL/wsl.2.6.3.0.x64.msi"    # Windows 11
$UBUNTU_WSL_DIR        = "$env:SystemDrive\WSL\Ubuntu"

# ===========================================================================
# Shared Helpers
# ===========================================================================

function Write-Info    { param($msg) Write-Host "  [i] $msg" -ForegroundColor Cyan }
function Write-Success { param($msg) Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Warn    { param($msg) Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Write-Fail    { param($msg) Write-Host "  [x] $msg" -ForegroundColor Red }
function Write-Step    { param($msg) Write-Host "`n==> $msg" -ForegroundColor Blue }

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Robust file download: try curl first (shows progress), fall back to
# Invoke-WebRequest. Returns $true on success, $false on failure.
function Invoke-Download {
    param([string]$Url, [string]$OutFile)
    $ok = $false
    try {
        curl.exe -L --fail --progress-bar $Url -o $OutFile
        $ok = ($LASTEXITCODE -eq 0)
    } catch {}
    if (-not $ok) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
            $ok = $true
        } catch { $ok = $false }
    }
    return $ok
}

# Verify SHA256 of a local file against a remote .sha256 file.
# Returns $true on match, or if the checksum file cannot be fetched (non-fatal).
function Test-Sha256 {
    param([string]$FilePath, [string]$Sha256Url)
    $sha256File = "$env:TEMP\download.sha256"
    try {
        if (-not (Invoke-Download -Url $Sha256Url -OutFile $sha256File)) {
            Write-Warn "Could not download checksum file — skipping verification."
            return $true
        }
        $expectedLine = (Get-Content $sha256File -Raw).Trim()
        $expected     = ($expectedLine -split '\s+')[0].ToLower()
        $actual       = (Get-FileHash -Algorithm SHA256 -Path $FilePath).Hash.ToLower()
        if ($actual -ne $expected) {
            Write-Fail "Checksum mismatch!"
            Write-Fail "  Expected : $expected"
            Write-Fail "  Got      : $actual"
            return $false
        }
        Write-Success "Checksum OK."
        return $true
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $sha256File
    }
}

# Use cmd.exe to avoid PS5 NativeCommandError and UTF-16LE mojibake on stderr.
# exit 1 = WSL feature not enabled; exit 0 = WSL is functional.
# Timeout 10s to avoid hanging when WSL is partially initialised.
function Invoke-WslListExitCode {
    $p = Start-Process -FilePath "wsl.exe" -ArgumentList "--list" `
        -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\wsl_out.txt" `
        -RedirectStandardError "$env:TEMP\wsl_err.txt"
    $finished = $p.WaitForExit(10000)   # 10 seconds
    if (-not $finished) {
        $p.Kill()
        Write-Info "WSL --list timed out (WSL not ready)."
        return 1
    }
    return $p.ExitCode
}

# Returns $true if a distro named exactly "Ubuntu" is registered.
# wsl --list outputs UTF-16LE; switch OutputEncoding to decode correctly.
function Test-UbuntuInstalled {
    $prev = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    try {
        $out = (wsl.exe --list --quiet 2>$null) -join "`n"
    } finally {
        [Console]::OutputEncoding = $prev
    }
    # Whole-line match to avoid false positives from Ubuntu-22.04, Ubuntu-24.04, etc.
    return ($out -match '(?im)^Ubuntu\s*$')
}

# Returns 'arm64' or 'amd64'
function Get-CpuArch {
    $arch = (Get-CimInstance Win32_Processor).Architecture
    # 12 = ARM64
    if ($arch -eq 12) { return "arm64" }
    return "amd64"
}

function Prompt-Reboot {
    Write-Host ""
    Write-Warn "Please restart your computer."
    Write-Warn "After restarting, run the same command again:"
    Write-Host "  $INSTALL_PS1_COMMAND" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 0
}

# Download Ubuntu rootfs, verify checksum, import into WSL.
# $WslVersion: 1 or 2
function Install-UbuntuRootfs {
    param([int]$WslVersion)

    $cpuArch = Get-CpuArch
    Write-Info "CPU architecture: $cpuArch"

    if ($cpuArch -eq "arm64") {
        $wslUrl    = $UBUNTU_WSL_ARM64_URL
        $sha256Url = $UBUNTU_WSL_ARM64_SHA256_URL
    } else {
        $wslUrl    = $UBUNTU_WSL_AMD64_URL
        $sha256Url = $UBUNTU_WSL_AMD64_SHA256_URL
    }

    $tarPath    = "$env:TEMP\ubuntu-wsl-$cpuArch.tar.gz"
    $installDir = $UBUNTU_WSL_DIR

    # Disk space check (~2 GB needed: 350 MB download + ~1.5 GB imported)
    $drive     = Split-Path -Qualifier $installDir
    $freeBytes = (Get-PSDrive ($drive.TrimEnd(':'))).Free
    if ($freeBytes -lt 2GB) {
        Write-Fail "Not enough disk space on $drive."
        Write-Fail "  Available : $([math]::Round($freeBytes / 1GB, 1)) GB"
        Write-Fail "  Required  : ~2 GB"
        exit 1
    }

    # Check if a valid cached tarball exists (skip download if checksum passes)
    $needDownload = $true
    if (Test-Path $tarPath) {
        Write-Info "Found cached Ubuntu rootfs, verifying checksum..."
        if (Test-Sha256 -FilePath $tarPath -Sha256Url $sha256Url) {
            Write-Success "Cache valid — skipping download."
            $needDownload = $false
        } else {
            Write-Warn "Cache corrupted — re-downloading..."
            Remove-Item -Force $tarPath
        }
    }

    try {
        if ($needDownload) {
            Write-Step "Downloading Ubuntu rootfs (~350 MB)..."
            if (-not (Invoke-Download -Url $wslUrl -OutFile $tarPath)) {
                Write-Fail "Failed to download Ubuntu rootfs. Check your network and try again."
                exit 1
            }
            Write-Success "Download complete."

            Write-Step "Verifying checksum..."
            if (-not (Test-Sha256 -FilePath $tarPath -Sha256Url $sha256Url)) {
                Write-Fail "The downloaded file is corrupted. Please try again."
                exit 1
            }
        }

        Write-Step "Importing Ubuntu into WSL$WslVersion (this may take a minute)..."
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        wsl.exe --import Ubuntu $installDir $tarPath --version $WslVersion
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "wsl --import failed (exit $LASTEXITCODE)."
            Write-Fail "Try removing $installDir and running the script again."
            exit 1
        }
        Write-Success "Ubuntu (WSL$WslVersion) imported successfully."
    } finally {
        # Keep the tarball as cache for future runs (e.g. after reboot)
        # Only clean up if import succeeded — leave it for retry otherwise
        if (Test-Path $tarPath) {
            Write-Info "Keeping Ubuntu rootfs cache at $tarPath for future use."
        }
    }
}

# Install OpenClacky inside the Ubuntu WSL distro.
function Run-InstallInWsl {
    Write-Step "Installing OpenClacky inside WSL..."

    if ($Local) {
        # Convert Windows path to WSL path (e.g. C:\foo\bar -> /mnt/c/foo/bar)
        $scriptDir = Split-Path -Parent $MyInvocation.PSCommandPath
        $localScript = Join-Path $scriptDir "install_simple.sh"
        if (-not (Test-Path $localScript)) {
            Write-Fail "Local mode: install_simple.sh not found at $localScript"
            exit 1
        }
        $wslPath = ($localScript -replace '\', '/') -replace '^([A-Za-z]):', { '/mnt/' + $args[0].Groups[1].Value.ToLower() }
        Write-Info "Local mode: using $wslPath"
        wsl.exe -d Ubuntu -u root -- bash $wslPath
    } else {
        wsl.exe -d Ubuntu -u root -- bash -c "cd ~ && curl -fsSL $INSTALL_SCRIPT_URL | bash"
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Installation failed inside WSL (exit $LASTEXITCODE)."
        Write-Fail "You can retry manually:"
        Write-Host "  wsl -d Ubuntu -u root -- bash -c `"curl -fsSL $INSTALL_SCRIPT_URL | bash`"" -ForegroundColor Yellow
        exit 1
    }
}

function Show-PostInstall {
    param([int]$WslVersion)
    Write-Host ""
    Write-Success "OpenClacky installed successfully (WSL$WslVersion)."
    Write-Host ""
    Write-Info "To use OpenClacky, first enter WSL:"
    Write-Host "   wsl" -ForegroundColor Green
    Write-Host ""
    Write-Info "Then run OpenClacky:"
    Write-Host "   openclacky" -ForegroundColor Green
    Write-Host ""
    Write-Info "Or start the Web UI:"
    Write-Host "   openclacky server" -ForegroundColor Green
    Write-Host "   Then open http://localhost:7070 in your browser"
    Write-Host ""
}

# ===========================================================================
# Registry helpers  (HKCU:\Software\OpenClacky\Install)
# ===========================================================================
$REG_ROOT = "HKCU:\Software\OpenClacky\Install"

function Get-InstallReg {
    param([string]$Name, $Default = $null)
    try {
        $val = (Get-ItemProperty -Path $REG_ROOT -Name $Name -ErrorAction Stop).$Name
        return $val
    } catch {
        return $Default
    }
}

function Set-InstallReg {
    param([string]$Name, $Value)
    if (-not (Test-Path $REG_ROOT)) {
        New-Item -Path $REG_ROOT -Force | Out-Null
    }
    Set-ItemProperty -Path $REG_ROOT -Name $Name -Value $Value
}

function Remove-InstallReg {
    param([string]$Name)
    try {
        Remove-ItemProperty -Path $REG_ROOT -Name $Name -ErrorAction Stop
    } catch {}
}

# ===========================================================================
# WSL2 Path — preferred, requires hardware virtualisation
# ===========================================================================

# Returns $true if WSL2 is actually usable by doing a real probe import.
# A 512-byte zero-filled tar (valid EOF block) is used as minimal rootfs.
# Probe import succeeds   → WSL2 usable
# Probe import fails (HCS_E_HYPERV_NOT_INSTALLED etc.) → WSL1 only
function Test-VirtualisationSupported {
    # Probe WSL2 with a minimal tar (512 zero bytes = valid tar EOF block)
    # Called only after WSL feature is confirmed enabled (Main already checked).
    Write-Info "Probing WSL2 availability..."
    $probeTar = "$env:TEMP\wsl_probe.tar"
    $probeDir = "$env:TEMP\wsl_probe"
    $ok = $false
    try {
        $bytes = New-Object byte[] 512
        [System.IO.File]::WriteAllBytes($probeTar, $bytes)
        New-Item -ItemType Directory -Force -Path $probeDir | Out-Null

        Write-Info "[probe] Running: wsl --import WslProbe $probeDir $probeTar --version 2"
        wsl.exe --import WslProbe $probeDir $probeTar --version 2 2>$null | Out-Null
        $importExit = $LASTEXITCODE
        Write-Info "[probe] wsl --import exit code: $importExit"
        $ok = ($importExit -eq 0)
        if ($ok) {
            wsl.exe --unregister WslProbe 2>$null | Out-Null
            Write-Info "[probe] WslProbe unregistered."
        }
    } catch {
        Write-Info "[probe] Exception caught: $_"
        $ok = $false
    } finally {
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $probeDir
        Remove-Item -Force -ErrorAction SilentlyContinue $probeTar
    }

    Write-Info "[probe] Final result: ok=$ok"
    if ($ok) {
        Write-Info "WSL2 probe passed — using WSL2."
    } else {
        Write-Info "WSL2 probe failed (Hyper-V not available) — falling back to WSL1."
    }
    return $ok
}

# Download and install the WSL2 kernel MSI from our CDN.
function Install-WslKernel {
    $build = [System.Environment]::OSVersion.Version.Build
    if ($build -lt 19041) {
        Write-Fail "Windows 10 build 19041 or later is required for WSL2."
        Write-Fail "Please upgrade to Windows 10 (May 2020 Update) or Windows 11."
        exit 1
    }

    # Win11 (build >= 22000) needs the new full WSL2 package; legacy MSI fails on Win11.
    $url     = if ($build -ge 22000) { $WSL_UPDATE_URL_WIN11 } else { $WSL_UPDATE_URL }
    $msiPath = "$env:TEMP\wsl_update.msi"

    Write-Step "Downloading WSL2 kernel update..."
    if (-not (Invoke-Download -Url $url -OutFile $msiPath)) {
        Write-Fail "Failed to download WSL2 kernel update. Check your network and try again."
        exit 1
    }
    Write-Info "Installing WSL2 kernel..."
    Start-Process msiexec -Wait -ArgumentList "/i", $msiPath, "/quiet", "/norestart"
    Write-Success "WSL2 kernel installed."
    Remove-Item -Force -ErrorAction SilentlyContinue $msiPath
}

# Enable WSL + VirtualMachinePlatform features, install kernel MSI, then reboot.
function Enable-Wsl2Features {
    Write-Step "Enabling WSL2 components (requires admin)..."
    dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    Write-Success "WSL2 components enabled."
    Install-WslKernel
    Set-InstallReg -Name "WslFeaturesEnabled" -Value 1
    Prompt-Reboot
}

# Full WSL2 install path. Called only after WSL feature is confirmed enabled
# and WSL2 probe has passed.
function Install-WithWsl2 {
    Write-Step "WSL2 mode selected."
    if (Test-UbuntuInstalled) {
        Write-Info "Ubuntu (WSL) already installed — skipping import."
    } else {
        wsl.exe --set-default-version 2 2>$null
        Install-UbuntuRootfs -WslVersion 2
    }
}

# ===========================================================================
# WSL1 Path — fallback when virtualisation is unavailable (e.g. inside a VM)
# ===========================================================================

# Full WSL1 install path. Called only after WSL feature is confirmed enabled
# and WSL2 probe has failed (Hyper-V not available).
function Install-WithWsl1 {
    Write-Step "WSL1 mode selected (virtualisation unavailable)."
    Write-Warn "WSL2 is preferred but not available in this environment."
    Write-Warn "Falling back to WSL1 — OpenClacky will still work normally."
    if (Test-UbuntuInstalled) {
        Write-Info "Ubuntu (WSL) already installed — skipping import."
    } else {
        Install-UbuntuRootfs -WslVersion 1
    }
}

# ===========================================================================
# Main
# ===========================================================================
Write-Host ""
Write-Host "OpenClacky Installation Script (Windows)" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-IsAdmin)) {
    Write-Fail "Please re-run this script as Administrator:"
    Write-Host ""
    Write-Host "  Right-click PowerShell -> 'Run as administrator', then:" -ForegroundColor Yellow
    Write-Host "  $INSTALL_PS1_COMMAND" -ForegroundColor Yellow
    exit 1
}

# Step 1: Ensure WSL feature is enabled (same for WSL1 and WSL2)
Write-Step "Checking WSL status..."
$wslCode = Invoke-WslListExitCode
Write-Info "WSL check result: exit code $wslCode"

if ($wslCode -eq 1) {
    if ((Get-InstallReg -Name "WslFeaturesEnabled" -Default 0) -eq 1) {
        Remove-InstallReg -Name "WslFeaturesEnabled"
        Write-Warn "WSL features were enabled last boot but WSL is still not ready."
        Write-Warn "Please reboot manually and retry."
        exit 1
    } else {
        # Enable WSL feature (WSL2 components) and reboot — version will be decided after reboot
        Enable-Wsl2Features
        # Always exits (prompts reboot)
    }
}

# WSL feature is enabled — clean up flag
Remove-InstallReg -Name "WslFeaturesEnabled"

# Step 2: Probe whether WSL2 actually works
$virt = Test-VirtualisationSupported
Write-Info "[main] Test-VirtualisationSupported returned: $virt"
if ($virt) {
    Install-WithWsl2
    $wslVersion = 2
} else {
    Install-WithWsl1
    $wslVersion = 1
}

Write-Success "WSL is ready."
Run-InstallInWsl
Set-InstallReg -Name "WslVersion" -Value $wslVersion
Show-PostInstall -WslVersion $wslVersion
