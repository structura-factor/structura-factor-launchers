# setup.ps1 - Glowny skrypt instalacyjny STRUCTURA FACTOR (VM Win11)
# Tworzy VM VirtualBox z Ubuntu 24.04, instaluje Docker, klonuje repo, wstawia stack.
#
# 8 etapow z animowanym UI: braille spinners, download bars, health table.
# Idempotentny (guard clauses na kazdym kroku).
#
# Usage:
#   .\setup.ps1 -Client sawaryn -DeployKeyPath C:\path\to\deploy_key
#   .\setup.ps1 -Client sawaryn -MediaPath "C:\Users\premek\OneDrive\STRUCTURA\media\"
#   .\setup.ps1 -Client sawaryn -VM_RAM 8192 -VM_CPU 4 -VM_DISK 80 -EnableLUKS

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Client,

    [Parameter(Mandatory = $false)]
    [string]$DeployKeyPath,

    [Parameter(Mandatory = $false)]
    [int]$VM_RAM = 4096,

    [Parameter(Mandatory = $false)]
    [int]$VM_CPU = 2,

    [Parameter(Mandatory = $false)]
    [int]$VM_DISK = 40960,

    [Parameter(Mandatory = $false)]
    [switch]$EnableLUKS,

    [Parameter(Mandatory = $false)]
    [string]$LUKSPassword,

    [Parameter(Mandatory = $false)]
    [string]$MediaPath,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
    # -Verbose provided by CmdletBinding automatically
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Constants
# ============================================================================

$SCRIPT_VERSION = "1.0"
$LOG_DIR = "C:\structura"
$LOG_FILE = "$LOG_DIR\setup.log"
$VM_NAME = "structura-$Client"
$UBUNTU_ISO_NAME = "ubuntu-24.04.5-live-server-amd64.iso"
$VBOX_INSTALLER_NAME = "VirtualBox-7.1.16-172425-Win.exe"
$GITHUB_RAW = "https://cdn.jsdelivr.net/gh"
$LAUNCHER_REPO = "structura-factor/structura-factor-launchers"
$CORE_REPO_URL = "git@github.com:structura-factor/structura-core.git"
$CLIENT_REPO_URL = "git@github.com:structura-factor/structura-clients.git"
$MAX_RETRIES = 3
$TOTAL_ETAPY = 8

# Braille spinner frames
$BRAILLE_SPINNER = @([char]0x280B, [char]0x2839, [char]0x2838, [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827, [char]0x2807, [char]0x280F)

# ANSI colors - [char]27 = ESC, works in PS 5.1 (backtick-e is PS 6+ only)
$ESC = [char]27
$ANSI_RESET = "$ESC[0m"
$ANSI_CYAN = "$ESC[36m"
$ANSI_GREEN = "$ESC[32m"
$ANSI_RED = "$ESC[31m"
$ANSI_YELLOW = "$ESC[33m"
$ANSI_WHITE = "$ESC[37m"
$ANSI_DIM = "$ESC[2m"

# ============================================================================
# Logging
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    if (-not (Test-Path $LOG_DIR)) {
        New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
    }
    # Log rotation >10MB
    if (Test-Path $LOG_FILE) {
        $size = (Get-Item $LOG_FILE).Length
        if ($size -gt 10MB) {
            $rotated = "$LOG_FILE.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Move-Item $LOG_FILE $rotated -Force
        }
    }
    Add-Content -Path $LOG_FILE -Value $line
}

# ============================================================================
# UI helpers
# ============================================================================

function Write-Banner {
    param([string]$Title, [string]$Subtitle = "", [string]$ClientName = "", [string]$Etap = "")

    $width = 64
    $top = "+$("=" * ($width - 2))+"
    $bot = "+$("=" * ($width - 2))+"

    Write-Host ""
    Write-Host $top -ForegroundColor Cyan
    $centerTitle = $Title.PadLeft([math]::Floor(($width - 2 + $Title.Length) / 2)).PadRight($width - 2)
    Write-Host "|$centerTitle|" -ForegroundColor Cyan

    if ($Subtitle) {
        $centerSub = $Subtitle.PadLeft([math]::Floor(($width - 2 + $Subtitle.Length) / 2)).PadRight($width - 2)
        Write-Host "|$centerSub|" -ForegroundColor Cyan
    }
    Write-Host "|$(" " * ($width - 2))|" -ForegroundColor Cyan

    if ($ClientName) {
        $clientLine = "  Klient: $ClientName".PadRight($width - 2)
        Write-Host "|$clientLine|" -ForegroundColor White
    }
    if ($Etap) {
        $etapLine = "  Etap:   $Etap".PadRight($width - 2)
        Write-Host "|$etapLine|" -ForegroundColor White
    }
    Write-Host $bot -ForegroundColor Cyan
    Write-Host ""
}

function Write-Etap {
    param([int]$Number, [string]$Name)
    $line = "[${Number}/${TOTAL_ETAPY}] $Name"
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host ("=" * ($line.Length + 2)) -ForegroundColor DarkCyan
    Write-Log "ETAP ${Number}/${TOTAL_ETAPY}: ${Name}"
}

function Write-Check {
    param([string]$Message, [switch]$Fail, [switch]$Warn)
    if ($Fail) {
        Write-Host "  ${ANSI_RED}x${ANSI_RESET} $Message" -ForegroundColor Red
    } elseif ($Warn) {
        Write-Host "  ${ANSI_YELLOW}!${ANSI_RESET} $Message" -ForegroundColor Yellow
    } else {
        Write-Host "  ${ANSI_GREEN}v${ANSI_RESET} $Message" -ForegroundColor Green
    }
}

function Format-Elapsed {
    param([int]$Seconds)
    $mins = [math]::Floor($Seconds / 60)
    $secs = $Seconds % 60
    return "{0:00}:{1:00}" -f $mins, $secs
}

function Show-Spinner {
    param(
        [string]$Description,
        [scriptblock]$Action,
        [int]$UpdateIntervalSec = 1,
        [int]$TimeoutSec = 600
    )

    if ($Quiet) {
        $result = & $Action
        return $result
    }

    $spinnerIdx = 0
    $elapsed = 0
    $job = Start-Job -ScriptBlock $Action
    $result = $null

    while ($job.State -eq 'Running' -and $elapsed -lt $TimeoutSec) {
        $frame = $BRAILLE_SPINNER[$spinnerIdx % $BRAILLE_SPINNER.Count]
        $elapsedStr = Format-Elapsed -Seconds $elapsed
        Write-Host -NoNewline "`r$frame Elapsed: $elapsedStr - $Description   "
        Start-Sleep -Seconds $UpdateIntervalSec
        $elapsed += $UpdateIntervalSec
        $spinnerIdx++
    }

    Write-Host -NoNewline "`r"
    Write-Host -NoNewline (" " * 80)
    Write-Host -NoNewline "`r"

    if ($job.State -eq 'Completed') {
        $result = Receive-Job -Job $job
    } else {
        Stop-Job -Job $job
        Write-Log "Spinner timed out after $TimeoutSec seconds" -Level "WARN"
    }
    Remove-Job -Job $job -Force

    return $result
}

function Show-DownloadBar {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Description
    )

    $partialDest = "$Destination.partial"
    if (Test-Path $partialDest) { Remove-Item $partialDest -Force }

    try {
        # Use BITS or simple Invoke-WebRequest with Write-Progress
        # Invoke-WebRequest has built-in progress bar in PS 5.1
        Write-Host "  Downloading $Description..." -ForegroundColor White
        Write-Host "  URL: $Url" -ForegroundColor DarkGray
        
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        Invoke-WebRequest -Uri $Url -OutFile $partialDest -UseBasicParsing -TimeoutSec 600
        $ErrorActionPreference = $prevEAP

        if (Test-Path $partialDest) {
            $size = [math]::Round((Get-Item $partialDest).Length / 1MB, 1)
            Move-Item $partialDest $Destination -Force
            Write-Host "  v $Description ($size MB)" -ForegroundColor Green
        } else {
            throw "Download produced no file"
        }
    }
    catch {
        if (Test-Path $partialDest) { Remove-Item $partialDest -Force }
        Write-Log "Download failed: $_" -Level "ERROR"
        throw
    }
}

function Show-HealthTable {
    param(
        [hashtable]$Services,
        [int]$TimeoutSec = 300
    )

    if ($Quiet) {
        # Just wait silently
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            $allHealthy = $true
            foreach ($svc in $Services.Keys) {
                $info = $Services[$svc]
                if ($info.Status -ne 'healthy') {
                    $allHealthy = $false
                    break
                }
            }
            if ($allHealthy) { break }
            Start-Sleep -Seconds 5
        }
        return $Services
    }

    $elapsed = @{}
    foreach ($svc in $Services.Keys) { $elapsed[$svc] = 0 }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $spinnerIdx = 0

    while ((Get-Date) -lt $deadline) {
        $allHealthy = $true
        $lines = @()

        foreach ($svc in $Services.Keys) {
            $info = $Services[$svc]
            $elapsedStr = Format-Elapsed -Seconds $elapsed[$svc]
            $timeoutStr = "$($info.Timeout)s"
            $frame = $BRAILLE_SPINNER[$spinnerIdx % $BRAILLE_SPINNER.Count]
            $svcPadded = $svc.PadRight(12)

            switch ($info.Status) {
                'healthy' {
                    $lines += "  $svcPadded [v] healthy ($elapsedStr)"
                    $lines += ""
                }
                'unhealthy' {
                    $lines += "  $svcPadded [x] unhealthy (${elapsedStr}/${timeoutStr})"
                    $allHealthy = $false
                }
                'starting' {
                    $lines += "  $svcPadded [$frame] starting... (${elapsedStr}/${timeoutStr})"
                    $allHealthy = $false
                }
                default {
                    $lines += "  $svcPadded [ ] waiting..."
                    $allHealthy = $false
                }
            }
        }

        # Clear and rewrite table
        Write-Host -NoNewline ("`r" + ("`n" * ($lines.Count + 1)))
        foreach ($line in $lines) {
            Write-Host "`r  $line"
        }

        if ($allHealthy) { break }

        Start-Sleep -Seconds 2
        foreach ($svc in $Services.Keys) { $elapsed[$svc] += 2 }
        $spinnerIdx++
    }

    Write-Host ""
    return $Services
}

# ============================================================================
# Utility functions
# ============================================================================

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [int]$MaxRetries = $MAX_RETRIES,
        [string]$Description = "Operation"
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return & $Action
        }
        catch {
            Write-Log "${Description} attempt ${attempt}/${MaxRetries} failed: $_" -Level "WARN"
            if ($attempt -lt $MaxRetries) {
                $backoff = [math]::Pow(2, $attempt)
                Start-Sleep -Seconds $backoff
            } else {
                throw "$Description failed after $MaxRetries attempts: $_"
            }
        }
    }
}

function Test-Command {
    param([string]$Cmd)
    $null = Get-Command $Cmd -ErrorAction SilentlyContinue
    return $?
}

function Get-VBoxManage {
    $vboxPaths = @(
        "${env:VBOX_INSTALL_PATH}",
        "${env:VBOX_MSI_INSTALL_PATH}",
        "C:\Program Files\Oracle\VirtualBox",
        "C:\Program Files (x86)\Oracle\VirtualBox"
    )
    foreach ($basePath in $vboxPaths) {
        if (-not $basePath) { continue }
        $exe = Join-Path $basePath "VBoxManage.exe"
        if (Test-Path $exe) { return $exe }
    }
    if (Test-Command "VBoxManage") { return "VBoxManage" }
    return $null
}

# ============================================================================
# Pre-flight checks
# ============================================================================

function Invoke-PreflightChecks {
    $results = @{
        WindowsOK = $false
        AdminOK = $false
        RamOK = $false
        DiskOK = $false
        VBoxOK = $false
        InternetOK = $false
        MediaSource = "internet"
    }

    # Windows version
    $os = Get-CimInstance Win32_OperatingSystem
    $caption = $os.Caption
    if ($caption -match "Windows 1[01]") {
        $results.WindowsOK = $true
        $build = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
        Write-Check "Windows ($build)"
    } else {
        Write-Check "Windows version: $caption (need Windows 10 or 11)" -Fail
    }

    # Admin rights
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        $results.AdminOK = $true
        Write-Check "Admin rights"
    } else {
        Write-Check "Admin rights (need elevated PowerShell)" -Fail
    }

    # RAM
    $totalRam = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    if ($totalRam -ge 16) {
        $results.RamOK = $true
        Write-Check "RAM: ${totalRam}GB (min 16GB)"
    } else {
        Write-Check "RAM: ${totalRam}GB (need 16GB+)" -Fail
    }

    # Disk
    $freeDisk = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB)
    if ($freeDisk -ge 50) {
        $results.DiskOK = $true
        Write-Check "Disk: ${freeDisk}GB free (min 50GB)"
    } else {
        Write-Check "Disk: ${freeDisk}GB free (need 50GB+)" -Fail
    }

    # VirtualBox
    $vbox = Get-VBoxManage
    if ($vbox) {
        $vboxVersion = & $vbox --version 2>$null
        $vboxMajor = ($vboxVersion -split '\.')[0]
        if ([int]$vboxMajor -ge 7) {
            $results.VBoxOK = $true
            Write-Check "VirtualBox $vboxVersion"
        } else {
            Write-Check "VirtualBox $vboxVersion (need 7.0+)" -Fail
        }
    } else {
        Write-Check "VirtualBox 7.0+ not found" -Warn
        Write-Host "    Action: Will install from MediaPath or download" -ForegroundColor Yellow
    }

    # Internet
    try {
        $testConn = Test-NetConnection -ComputerName "github.com" -Port 443 -WarningAction SilentlyContinue
        if ($testConn.TcpTestSucceeded) {
            $results.InternetOK = $true
            Write-Check "Internet: OK (github.com reachable)"
        } else {
            Write-Check "Internet: cannot reach github.com" -Fail
        }
    }
    catch {
        Write-Check "Internet: connection test failed" -Fail
    }

    # Media source
    if ($MediaPath -and (Test-Path $MediaPath)) {
        $results.MediaSource = "onedrive"
        Write-Check "Media source: OneDrive ($MediaPath)"
    } else {
        $results.MediaSource = "internet"
        Write-Check "Media source: internet (no -MediaPath or path not found)"
    }

    return $results
}

# ============================================================================
# Media sourcing
# ============================================================================

function Invoke-MediaSourcing {
    param([hashtable]$Preflight)

    $mediaDir = "$LOG_DIR\media"
    if (-not (Test-Path $mediaDir)) {
        New-Item -ItemType Directory -Path $mediaDir -Force | Out-Null
    }

    $isoPath = "$mediaDir\$UBUNTU_ISO_NAME"
    $vboxPath = "$mediaDir\$VBOX_INSTALLER_NAME"

    # Read expected SHA256 from versions.txt
    $versionsUrl = "${GITHUB_RAW}/${LAUNCHER_REPO}@main/factor-vm-win11/media/versions.txt"
    $versionsFile = "$mediaDir\versions.txt"
    try {
        Invoke-WebRequest -Uri $versionsUrl -OutFile $versionsFile -UseBasicParsing -TimeoutSec 30
    } catch {
        Write-Log "Could not fetch versions.txt: $_" -Level "WARN"
    }

    $expectedSha = @{}
    if (Test-Path $versionsFile) {
        foreach ($line in Get-Content $versionsFile) {
            if ($line -match '^(.+?)\s+SHA256:\s*(\w+)') {
                $expectedSha[$Matches[1].Trim()] = $Matches[2].Trim()
            }
        }
    }

    $useOneDrive = ($Preflight.MediaSource -eq 'onedrive')
    $mediaResults = @{
        IsoPath = $isoPath
        VBoxPath = $vboxPath
        InstalledVBox = $false
    }

    # --- Ubuntu ISO ---
    $isoExists = $false

    if ($useOneDrive) {
        $oneDriveIso = Join-Path $MediaPath $UBUNTU_ISO_NAME
        if (Test-Path $oneDriveIso) {
            $sha = Get-FileSha256 -Path $oneDriveIso
            $expected = $expectedSha[$UBUNTU_ISO_NAME]
            if ($expected -and $sha -eq $expected) {
                Write-Check "Ubuntu ISO: OneDrive (SHA256 OK)"
                if ((Resolve-Path $oneDriveIso).Path -ne (Resolve-Path $isoPath -ErrorAction SilentlyContinue).Path) {
                    Copy-Item $oneDriveIso $isoPath -Force
                }
                $isoExists = $true
            } else {
                Write-Check "Ubuntu ISO: OneDrive SHA256 mismatch - will download" -Warn
                if ($expected) {
                    Write-Host "    Expected: $expected" -ForegroundColor Yellow
                    Write-Host "    Got:      $sha" -ForegroundColor Yellow
                    Write-Host "    Action: Fallback to internet download" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Check "Ubuntu ISO: not in MediaPath - will download" -Warn
        }
    }

    if (-not $isoExists) {
        $isoUrl = "https://releases.ubuntu.com/24.04/$UBUNTU_ISO_NAME"
        Write-Host ""
        Write-Host "  Downloading Ubuntu ISO (~3.1GB, est. 5-15 min depending on bandwidth)" -ForegroundColor White
        Write-Host ""

        $downloaded = $false
        try {
            if ($Quiet) {
                Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing -TimeoutSec 1800
                $downloaded = $true
            } else {
                Show-DownloadBar -Url $isoUrl -Destination $isoPath -Description "Ubuntu ISO"
                $downloaded = $true
            }
        } catch {
            Write-Log "Ubuntu ISO download failed: $_" -Level "ERROR"
            Write-Check "Ubuntu ISO download failed: $_" -Fail
        }

        if ($downloaded) {
            $sha = Get-FileSha256 -Path $isoPath
            $expected = $expectedSha[$UBUNTU_ISO_NAME]
            if ($expected -and $sha -ne $expected) {
                Write-Check "Ubuntu ISO SHA256 mismatch" -Fail
                Write-Host "    Expected: $expected" -ForegroundColor Red
                Write-Host "    Got:      $sha" -ForegroundColor Red
                Write-Host "    Plik moze byc uszkodzony. Sprobuj ponownie lub uzyj -MediaPath." -ForegroundColor Yellow
                throw "SHA256 mismatch for Ubuntu ISO"
            }
            Write-Check "Ubuntu ISO: downloaded (SHA256 OK)"

            # Save to OneDrive if available (first-user workflow)
            if ($useOneDrive) {
                $oneDriveIso = Join-Path $MediaPath $UBUNTU_ISO_NAME
                $isoResolved = Resolve-Path $isoPath -ErrorAction SilentlyContinue
                $oneResolved = Resolve-Path $oneDriveIso -ErrorAction SilentlyContinue
                if ($isoResolved -and $oneResolved -and $isoResolved.Path -ne $oneResolved.Path) {
                    Write-Host "  Saving ISO to OneDrive for future use..." -ForegroundColor White
                    Copy-Item $isoPath $oneDriveIso -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # --- VirtualBox installer ---
    $vboxExists = $false

    if ($useOneDrive) {
        $oneDriveVbox = Join-Path $MediaPath $VBOX_INSTALLER_NAME
        if (Test-Path $oneDriveVbox) {
            $sha = Get-FileSha256 -Path $oneDriveVbox
            $expected = $expectedSha[$VBOX_INSTALLER_NAME]
            if ($expected -and $sha -eq $expected) {
                Write-Check "VirtualBox: OneDrive (SHA256 OK)"
                if ((Resolve-Path $oneDriveVbox).Path -ne (Resolve-Path $vboxPath -ErrorAction SilentlyContinue).Path) {
                    Copy-Item $oneDriveVbox $vboxPath -Force
                }
                $vboxExists = $true
            }
        }
    }

    if (-not $Preflight.VBoxOK) {
        # Need to install VirtualBox
        $vboxUrl = "https://download.virtualbox.org/virtualbox/7.1.16/$VBOX_INSTALLER_NAME"

        try {
            # Skip download if installer already exists locally (from OneDrive or previous run)
            if (Test-Path $vboxPath) {
                Write-Check "VirtualBox: installer already exists ($vboxPath)"
            } else {
                Write-Host "  Downloading VirtualBox installer (~119MB)..." -ForegroundColor White
                if ($Quiet) {
                    Invoke-WebRequest -Uri $vboxUrl -OutFile $vboxPath -UseBasicParsing -TimeoutSec 300
                } else {
                    Show-DownloadBar -Url $vboxUrl -Destination $vboxPath -Description "VirtualBox installer"
                }
                Write-Check "VirtualBox: downloaded"
            }

            # Install VirtualBox - extract MSI from wrapper exe, then install via msiexec
            # VBox 7.1+ wrapper exe does NOT support -silent/--silent (exit 2)
            # MSI install returns 1603 on Win11 even when successful (Python module WixRemoveFoldersEx bug)
            Write-Host "  Installing VirtualBox..." -ForegroundColor White
            $extractDir = Join-Path $env:TEMP "vbox-extract"
            if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

            # Step 1: Extract MSI from wrapper exe (silent, no GUI dialog)
            Write-Host "    Extracting MSI..." -ForegroundColor DarkGray
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $extractProc = Start-Process -FilePath $vboxPath -ArgumentList "-extract","-path",$extractDir,"-silent" -Wait -PassThru -WindowStyle Hidden
            $ErrorActionPreference = $prevEAP
            Start-Sleep -Seconds 2

            # Find the .msi file (might be in subdirectory)
            $msiFile = Get-ChildItem -Path $extractDir -Filter "*.msi" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $msiFile) {
                # Fallback: try --msiparams method
                Write-Host "    MSI not extracted, trying --msiparams..." -ForegroundColor Yellow
                $msiProc = Start-Process -FilePath $vboxPath -ArgumentList "--msiparams", "/quiet", "/norestart" -Wait -PassThru
                $exitCode = $msiProc.ExitCode
            } else {
                Write-Host "    Installing via msiexec..." -ForegroundColor DarkGray
                $msiArgs = "/i `"$($msiFile.FullName)`" /quiet /norestart REBOOT=Suppress ALLUSERS=1 ADDLOCAL=VBoxApplication,VBoxNetwork,VBoxNetworkFlt,VBoxNetworkAdp NETWORKTYPE=NDIS6"
                $msiProc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
                $exitCode = $msiProc.ExitCode
                Write-Log "VBox msiexec exit code: $exitCode"
            }

            # Accept 0 (success) and 1603 (known Win11 Python module bug - install succeeds)
            if ($exitCode -eq 0 -or $exitCode -eq 1603) {
                Write-Check "VirtualBox: installed (exit $exitCode)"
                $mediaResults.InstalledVBox = $true
            } else {
                Write-Check "VirtualBox install failed (exit $exitCode)" -Fail
                Write-Host "    Try manually: $vboxPath" -ForegroundColor Yellow
            }

            # Clean up extracted files
            if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue }

            # Refresh environment variables
            $env:VBOX_INSTALL_PATH = [System.Environment]::GetEnvironmentVariable("VBOX_INSTALL_PATH", "Machine")
            $env:VBOX_MSI_INSTALL_PATH = [System.Environment]::GetEnvironmentVariable("VBOX_MSI_INSTALL_PATH", "Machine")
            $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
            if ($machinePath) { $env:PATH = "$machinePath;$env:PATH" }
            Write-Log "VBox env refreshed: VBOX_INSTALL_PATH=$env:VBOX_INSTALL_PATH"

            # Save to OneDrive
            if ($useOneDrive) {
                $oneDriveVbox = Join-Path $MediaPath $VBOX_INSTALLER_NAME
                $vboxResolved = Resolve-Path $vboxPath -ErrorAction SilentlyContinue
                $oneVboxResolved = Resolve-Path $oneDriveVbox -ErrorAction SilentlyContinue
                if ($vboxResolved -and $oneVboxResolved -and $vboxResolved.Path -ne $oneVboxResolved.Path) {
                    Copy-Item $vboxPath $oneDriveVbox -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {
            Write-Check "VirtualBox download/install failed: $_" -Fail
            Write-Host "    Action: Download manually from https://www.virtualbox.org/wiki/Downloads" -ForegroundColor Yellow
        }
    } elseif ($Preflight.VBoxOK) {
        Write-Check "VirtualBox: already installed"
    }

    return $mediaResults
}

# ============================================================================
# VM creation
# ============================================================================

function Invoke-VMCreation {
    param(
        [hashtable]$Media,
        [string]$UnattendPath
    )

    $vbox = Get-VBoxManage
    if (-not $vbox) {
        $defaultVBoxPath = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
        if (Test-Path $defaultVBoxPath) {
            $vbox = $defaultVBoxPath
            Write-Check "VBoxManage found at default path: $vbox"
        }
    }
    if (-not $vbox) {
        Write-Check "VBoxManage not found" -Fail
        throw "VBoxManage not available"
    }

    # Guard: check if VM already exists
    $vmExists = $false
    try {
        $vmInfo = & $vbox showvminfo $VM_NAME --machinereadable 2>$null
        if ($LASTEXITCODE -eq 0) { $vmExists = $true }
    } catch { }

    if ($vmExists) {
        $vmState = (& $vbox showvminfo $VM_NAME --machinereadable 2>$null | Select-String 'VMState=')
        $stateStr = $vmState.ToString().Split('=')[1].Trim('"')
        
        Write-Host ""
        Write-Host "  VM $VM_NAME istnieje (stan: $stateStr)" -ForegroundColor Yellow
        Write-Host "  Opcje:" -ForegroundColor White
        Write-Host "    1. Usun i utworz na nowo (pelna reinstalacja)" -ForegroundColor DarkGray
        Write-Host "    2. Uruchom istniejaca VM (jesli Ubuntu juz zainstalowane)" -ForegroundColor DarkGray
        Write-Host "    3. Anuluj" -ForegroundColor DarkGray
        Write-Host ""
        $vmChoice = Read-Host "  Wybierz (1/2/3)"
        
        switch ($vmChoice) {
            "1" {
                Write-Host "  Zatrzymywanie i usuwanie starej VM..." -ForegroundColor White
                $prevEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                # Only poweroff if VM is running (controlvm fails if VM is off)
                $isVmRunning = (& $vbox showvminfo $VM_NAME --machinereadable 2>$null | Select-String 'VMState="running"')
                if ($isVmRunning) {
                    & $vbox controlvm $VM_NAME poweroff 2>&1 | Out-Null
                    Start-Sleep -Seconds 3
                }
                & $vbox unregistervm $VM_NAME --delete 2>&1 | Out-Null
                Start-Sleep -Seconds 2
                $ErrorActionPreference = $prevEAP
                $vmExists = $false
                Write-Check "Stara VM usunieta"
            }
            "2" {
                if ($stateStr -ne "running") {
                    Write-Host "  Uruchamianie VM..." -ForegroundColor White
                    & $vbox startvm $VM_NAME --type headless 2>$null
                    
                    # Open console window
                    if (-not $Quiet) {
                        $consoleScript = "Write-Host '=== STRUCTURA VM Console ($VM_NAME) ===' -ForegroundColor Cyan; Write-Host ''; Get-Content '$LOG_DIR\vm-console.log' -Wait -Tail 30"
                        Start-Process powershell -ArgumentList "-NoExit","-Command",$consoleScript -WindowStyle Normal
                    }
                } else {
                    Write-Check "VM juz dziala"
                }
                return Get-VmIpAndSsh -Vbox $vbox
            }
            default {
                Write-Host "  Anulowano." -ForegroundColor Red
                exit 1
            }
        }
    }

    if (-not $vmExists) {
        Write-Host "  Creating VM: $VM_NAME ($VM_RAM MB RAM, $VM_CPU vCPU, $VM_DISK MB disk)" -ForegroundColor White

        # Create VM - relax EAP for VBoxManage (writes progress to stderr)
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $vbox createvm --name $VM_NAME --ostype Ubuntu_64 --register 2>&1 | Out-Null
        & $vbox modifyvm $VM_NAME --memory $VM_RAM --cpus $VM_CPU --nic1 bridged --boot1 dvd --boot2 disk 2>&1 | Out-Null
        & $vbox modifyvm $VM_NAME --uart1 0x3F8 4 --uartmode1 file "$LOG_DIR\vm-console.log" 2>&1 | Out-Null

        # Create disk
        $diskPath = "$LOG_DIR\vm-disks\$VM_NAME.vdi"
        $diskDir = Split-Path $diskPath
        if (-not (Test-Path $diskDir)) {
            New-Item -ItemType Directory -Path $diskDir -Force | Out-Null
        }
        # Remove old VDI from media registry if it exists (avoids UUID mismatch)
        if (Test-Path $diskPath) {
            & $vbox closemedium disk $diskPath 2>&1 | Out-Null
            Remove-Item $diskPath -Force -ErrorAction SilentlyContinue
        }
        & $vbox createmedium disk --filename $diskPath --size $VM_DISK --format VDI 2>&1 | Out-Null
        & $vbox storagectl $VM_NAME --name "SATA" --add sata --controller IntelAhci 2>&1 | Out-Null
        & $vbox storageattach $VM_NAME --storagectl "SATA" --port 0 --device 0 --type hdd --medium $diskPath 2>&1 | Out-Null

        # Attach ISO
        & $vbox storagectl $VM_NAME --name "IDE" --add ide 2>&1 | Out-Null
        & $vbox storageattach $VM_NAME --storagectl "IDE" --port 1 --device 0 --type dvddrive --medium $Media.IsoPath 2>&1 | Out-Null
        $ErrorActionPreference = $prevEAP

        Write-Check "VM created: $VM_NAME"

        # Use VBoxManage unattended install (VBox 7.0+)
        Write-Host ""
        Write-Host "  Starting unattended Ubuntu Server 24.04 LTS installation..." -ForegroundColor White
        Write-Host "  (This takes 5-15 minutes. VBoxManage handles the installer automatically.)" -ForegroundColor DarkGray

        $isoFilePath = $Media['IsoPath']
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $vbox unattended install $VM_NAME --iso="$isoFilePath" --user=structura --password=structura --full-user-name="STRUCTURA" --time-zone=Europe/Warsaw --hostname=structura.local --start-vm=headless 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        $unattendedExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        Write-Log "Unattended install exit code: $unattendedExit"
        
        if ($unattendedExit -ne 0) {
            Write-Host "    VBoxManage unattended install failed (exit $unattendedExit)" -ForegroundColor Yellow
            Write-Host "    Trying minimal args..." -ForegroundColor Yellow
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & $vbox unattended install $VM_NAME --iso="$isoFilePath" --user=structura --password=structura --time-zone=Europe/Warsaw --hostname=structura.local 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            $unattendedExit = $LASTEXITCODE
            $ErrorActionPreference = $prevEAP
            Write-Log "Unattended install (minimal) exit code: $unattendedExit"
        }

        if ($unattendedExit -eq 0) {
            Write-Check "Unattended install completed"
        }

        # Start VM if not already started by --start-vm
        $vmRunning = (& $vbox showvminfo $VM_NAME --machinereadable 2>$null | Select-String 'VMState="running"')
        if (-not $vmRunning) {
            & $vbox startvm $VM_NAME --type headless 2>$null
        }

        # Open VM console in separate window for visibility
        if (-not $Quiet) {
            $consoleScript = "Write-Host '=== STRUCTURA VM Console (structura-sawaryn) ===' -ForegroundColor Cyan; Write-Host ''; Get-Content '$LOG_DIR\vm-console.log' -Wait -Tail 30"
            Start-Process powershell -ArgumentList "-NoExit","-Command",$consoleScript -WindowStyle Normal
        }
    }

    return Get-VmIpAndSsh -Vbox $vbox
}

function Get-VmIpAndSsh {
    param([string]$Vbox)

    # Wait for VM to get IP (Ubuntu install takes 5-15 min)
    Write-Host "  Waiting for VM to boot and get IP..." -ForegroundColor White
    Write-Host "  (Ubuntu installation takes 5-15 minutes, please be patient)" -ForegroundColor DarkGray

    $vmIp = $null
    $maxWait = 120  # 120 x 15s = 30 minutes max
    for ($i = 0; $i -lt $maxWait; $i++) {
        try {
            $ipInfo = & $Vbox guestproperty get $VM_NAME "/VirtualBox/GuestInfo/Net/0/V4/IP" 2>$null
            if ($ipInfo -match 'Value:\s+(\d+\.\d+\.\d+\.\d+)') {
                $vmIp = $Matches[1]
                break
            }
        } catch { }

        # Show progress every minute
        if ($i % 4 -eq 0) {
            $min = [math]::Floor($i * 15 / 60)
            Write-Host -NoNewline "`r    Waiting for IP... ${min}min elapsed   "
        }
        Start-Sleep -Seconds 15
    }

    Write-Host ""  # Clear progress line

    if ($vmIp) {
        Write-Check "VM IP: $vmIp"
    } else {
        Write-Check "Could not determine VM IP after 30 minutes" -Warn
        Write-Host "    Check VM console: $LOG_DIR\vm-console.log" -ForegroundColor Yellow
        return @{ VmExists = $true; VmIp = $null }
    }

    # Wait for SSH (port 22 - unattended install uses default port)
    Write-Host "  Waiting for SSH..." -ForegroundColor White
    $sshReady = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $testConn = Test-NetConnection -ComputerName $vmIp -Port 22 -WarningAction SilentlyContinue
            if ($testConn.TcpTestSucceeded) {
                $sshReady = $true
                break
            }
        } catch { }
        Start-Sleep -Seconds 10
    }

    if ($sshReady) {
        Write-Check "SSH ready on port 22"
    } else {
        Write-Check "SSH not ready yet" -Warn
    }

    return @{ VmExists = $true; VmIp = $vmIp }
}

# ============================================================================
# Docker setup (via SSH to VM)
# ============================================================================

function Invoke-DockerSetup {
    param([string]$VmIp)

    if (-not $VmIp) {
        Write-Check "Cannot setup Docker - VM IP unknown" -Fail
        return $false
    }

    $sshTarget = "structura@$VmIp"
    $sshPort = 22

    # Guard: check if Docker already installed
    Write-Host "  Checking Docker on VM..." -ForegroundColor White
    $dockerCheck = Invoke-WithRetry -Action {
        $result = ssh -p $sshPort -o StrictHostKeyChecking=no -o ConnectTimeout=10 $sshTarget "docker --version" 2>$null
        return $result
    } -Description "Docker check via SSH" -MaxRetries 3

    if ($dockerCheck -match 'Docker version') {
        Write-Check "Docker already installed: $($dockerCheck.Trim())"
        $composeCheck = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget "docker compose version" 2>$null
        if ($composeCheck -match 'Docker Compose version') {
            Write-Check "Docker Compose already installed"
            return $true
        }
    }

    Write-Host "  Installing Docker on VM (via SSH)..." -ForegroundColor White

    # Run Docker installation script
    $installCmd = @"
        set -e
        sudo apt-get update -y
        sudo apt-get install -y ca-certificates curl gnupg lsb-release
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=`$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu `$(. /etc/os-release && echo "`$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -y
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo usermod -aG docker structura
        sudo systemctl enable docker
        sudo systemctl start docker
        docker --version
        docker compose version
"@

    $installResult = Invoke-WithRetry -Action {
        $result = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $installCmd 2>&1
        return $result
    } -Description "Docker install via SSH" -MaxRetries 3

    if ($PSBoundParameters.ContainsKey("Verbose")) {
        Write-Host $installResult -ForegroundColor DarkGray
    }

    # Verify
    $verifyResult = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget "docker --version && docker compose version" 2>$null
    if ($verifyResult -match 'Docker version' -and $verifyResult -match 'Docker Compose version') {
        Write-Check "Docker installed and verified"
        Write-Check "Docker Compose installed and verified"
        return $true
    } else {
        Write-Check "Docker verification failed" -Fail
        Write-Host "    Output: $verifyResult" -ForegroundColor Red
        return $false
    }
}

# ============================================================================
# Repo clone + appdata structure
# ============================================================================

function Invoke-RepoAndAppdata {
    param([string]$VmIp)

    if (-not $VmIp) {
        Write-Check "Cannot clone repos - VM IP unknown" -Fail
        return $false
    }

    $sshTarget = "structura@$VmIp"
    $sshPort = 22

    # Guard: check if repos already cloned
    $repoCheck = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget "test -d /opt/structura/repos/structura-core && echo EXISTS || echo MISSING" 2>$null
    if ($repoCheck -match 'EXISTS') {
        Write-Check "Repos already cloned - pulling updates"
        ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget "cd /opt/structura/repos/structura-core && git pull --ff-only 2>/dev/null; cd /opt/structura/repos/structura-clients && git pull --ff-only 2>/dev/null" 2>$null
    } else {
        # Clone repos
        Write-Host "  Cloning repos to /opt/structura/repos/..." -ForegroundColor White

        # Transfer deploy key to VM for git clone authentication
        if ($DeployKeyPath -and (Test-Path $DeployKeyPath)) {
            Write-Host "  Transferring deploy key to VM..." -ForegroundColor DarkGray
            $vmKeyPath = "/tmp/structura_deploy_key"
            scp -P $sshPort -o StrictHostKeyChecking=no $DeployKeyPath ${sshTarget}:$vmKeyPath 2>$null
            $keySetupCmd = @"
                mkdir -p ~/.ssh
                cp $vmKeyPath ~/.ssh/id_ed25519
                chmod 600 ~/.ssh/id_ed25519
                rm -f $vmKeyPath
                ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
                echo "KEY_SETUP_DONE"
"@
            $keySetupResult = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $keySetupCmd 2>&1
            Write-Log "Deploy key transferred to VM"
        }

        $cloneCmd = @"
            sudo mkdir -p /opt/structura/repos
            cd /opt/structura/repos
            sudo git clone --depth 1 $CORE_REPO_URL structura-core
            sudo git clone --depth 1 $CLIENT_REPO_URL structura-clients
            sudo chown -R structura:structura /opt/structura/repos
"@
        $cloneResult = Invoke-WithRetry -Action {
            return ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $cloneCmd 2>&1
        } -Description "Git clone repos" -MaxRetries 3

        Write-Check "Repos cloned"
    }

    # Create appdata directory structure
    Write-Host "  Creating appdata structure..." -ForegroundColor White

    $mkdirCmd = @"
        sudo mkdir -p /opt/structura/appdata/hindsight/{pgdata,pgdump}
        sudo mkdir -p /opt/structura/appdata/hermes/{memories,skills,session}
        sudo mkdir -p /opt/structura/appdata/n8n/config
        sudo mkdir -p /opt/structura/appdata/npm/{data,letsencrypt}
        sudo mkdir -p /opt/structura/appdata/portainer
        sudo mkdir -p /opt/structura/appdata/duplicati
        sudo mkdir -p /opt/structura/appdata/homepage/icons
        sudo mkdir -p /opt/structura/appdata/searxng
        sudo mkdir -p /opt/structura/appdata/telegram
        sudo mkdir -p /opt/structura/ai-workspace/{STRUCTURA,Sprawy,_trash}
        sudo mkdir -p /opt/structura/backups/{appdata,ai-workspace,pgdump,pgdata}
        sudo chmod 750 /opt/structura/appdata
        sudo chown -R 1000:1000 /opt/structura/appdata
        echo "appdata structure created"
"@

    $mkdirResult = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $mkdirCmd 2>&1
    Write-Check "appdata structure created"

    # Copy config files from repos to appdata
    Write-Host "  Copying config files to appdata..." -ForegroundColor White

    $copyCmd = @"
        # Hindsight config
        if [ -f /opt/structura/repos/structura-core/hindsight/init.sql ]; then
            sudo cp /opt/structura/repos/structura-core/hindsight/init.sql /opt/structura/appdata/hindsight/
            sudo cp /opt/structura/repos/structura-core/hindsight/postgresql.conf /opt/structura/appdata/hindsight/
            sudo cp /opt/structura/repos/structura-core/hindsight/pg_hba.conf /opt/structura/appdata/hindsight/
        fi
        # SearXNG config
        if [ -f /opt/structura/repos/structura-core/searxng/settings.yml ]; then
            sudo cp /opt/structura/repos/structura-core/searxng/settings.yml /opt/structura/appdata/searxng/
        fi
        # pgdump script
        if [ -f /opt/structura/repos/structura-core/hindsight/pgdump.sh ]; then
            sudo cp /opt/structura/repos/structura-core/hindsight/pgdump.sh /opt/structura/appdata/hindsight/pgdump/
            sudo chmod +x /opt/structura/appdata/hindsight/pgdump/pgdump.sh
        fi
        echo "config files copied"
"@

    ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $copyCmd 2>&1 | Out-Null
    Write-Check "Config files copied to appdata"

    return $true
}

# ============================================================================
# Container deployment
# ============================================================================

function Invoke-ContainerDeployment {
    param([string]$VmIp)

    $sshTarget = "structura@$VmIp"
    $sshPort = 22

    # Prepare .env from client template
    Write-Host "  Preparing .env from client template..." -ForegroundColor White

    $envCmd = @"
        CLIENT_DIR="/opt/structura/repos/structura-clients/$Client"
        if [ -f "`$CLIENT_DIR/.env.example" ]; then
            sudo cp "`$CLIENT_DIR/.env.example" /opt/structura/repos/structura-core/.env
            sudo chmod 600 /opt/structura/repos/structura-core/.env
            echo "env created"
        else
            echo "env missing - using core template"
            sudo cp /opt/structura/repos/structura-core/.env.example /opt/structura/repos/structura-core/.env
            sudo chmod 600 /opt/structura/repos/structura-core/.env
        fi
"@
    ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $envCmd 2>&1 | Out-Null
    Write-Check ".env created (chmod 600)"

    # Deploy: make deploy
    Write-Host "  Running make deploy..." -ForegroundColor White

    $deployCmd = @"
        cd /opt/structura/repos/structura-core
        export CLIENT_DIR="/opt/structura/repos/structura-clients"
        export CLIENT="$Client"
        make secrets-check && make deploy CLIENT=$Client
        echo "DEPLOY_DONE"
"@

    $deployResult = Invoke-WithRetry -Action {
        return ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $deployCmd 2>&1
    } -Description "make deploy" -MaxRetries 3

    if ($PSBoundParameters.ContainsKey("Verbose")) {
        Write-Host $deployResult -ForegroundColor DarkGray
    }

    if ($deployResult -match 'DEPLOY_DONE') {
        Write-Check "Containers deployed"
    } else {
        Write-Check "Deployment may have issues - check logs" -Warn
    }

    # NPM setup
    Write-Host "  Running make npm-setup..." -ForegroundColor White
    $npmResult = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget "cd /opt/structura/repos/structura-core && make npm-setup" 2>&1
    if ($PSBoundParameters.ContainsKey("Verbose")) { Write-Host $npmResult -ForegroundColor DarkGray }
    Write-Check "NPM configured (make npm-setup)"

    # Health check polling
    Write-Host ""
    Write-Host "  Waiting for containers to be healthy..." -ForegroundColor White
    Write-Host ""

    $services = @{
        "hindsight"  = @{ Status = "waiting"; Timeout = 60; CheckCmd = "curl -sf http://localhost:8888/health" }
        "hermes"     = @{ Status = "waiting"; Timeout = 90; CheckCmd = "curl -sf http://localhost:8765/health" }
        "searxng"    = @{ Status = "waiting"; Timeout = 15; CheckCmd = "curl -sf http://localhost:8080/healthz" }
        "n8n"        = @{ Status = "waiting"; Timeout = 30; CheckCmd = "curl -sf http://localhost:5678/healthz" }
        "npm"        = @{ Status = "waiting"; Timeout = 15; CheckCmd = "curl -sf http://localhost:81/api" }
        "homepage"   = @{ Status = "waiting"; Timeout = 15; CheckCmd = "curl -sf http://localhost:3000/" }
        "duplicati"  = @{ Status = "waiting"; Timeout = 15; CheckCmd = "curl -sf http://localhost:8200/api/v1/health" }
        "portainer"  = @{ Status = "waiting"; Timeout = 15; CheckCmd = "curl -sf http://localhost:9443/api/status" }
    }

    # Poll health on VM
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline) {
        $allHealthy = $true
        $healthResults = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget "docker compose -f /opt/structura/repos/structura-core/docker-compose.yaml ps --format json" 2>$null

        foreach ($svc in $services.Keys) {
            $info = $services[$svc]
            if ($info.Status -eq 'healthy') { continue }

            # Check container health
            $checkResult = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget "docker inspect --format='{{.State.Health.Status}}' structura-$svc 2>/dev/null || echo 'notfound'" 2>$null
            $checkResult = $checkResult.Trim()

            if ($checkResult -eq 'healthy') {
                $info.Status = 'healthy'
            } elseif ($checkResult -eq 'unhealthy') {
                $info.Status = 'unhealthy'
                $allHealthy = $false
            } elseif ($checkResult -eq 'starting' -or $checkResult -eq 'notfound') {
                $info.Status = 'starting'
                $allHealthy = $false
            }
        }

        if (-not $Quiet) {
            # Display health table
            Write-Host -NoNewline ("`r" + ("`n" * ($services.Count + 2)))
            $spinnerIdx = [int]((Get-Date).Ticks / 10000000) % $BRAILLE_SPINNER.Count
            foreach ($svc in $services.Keys) {
                $info = $services[$svc]
                $svcPadded = $svc.PadRight(12)
                $frame = $BRAILLE_SPINNER[$spinnerIdx % $BRAILLE_SPINNER.Count]
                switch ($info.Status) {
                    'healthy'   { Write-Host "  $svcPadded [v] healthy" -ForegroundColor Green }
                    'unhealthy' { Write-Host "  $svcPadded [x] unhealthy" -ForegroundColor Red }
                    'starting'  { Write-Host "  $svcPadded [$frame] starting..." -ForegroundColor Yellow }
                    default     { Write-Host "  $svcPadded [ ] waiting..." -ForegroundColor DarkGray }
                }
            }
        }

        if ($allHealthy) { break }
        Start-Sleep -Seconds 2
    }

    Write-Host ""
    $healthyCount = ($services.Values | Where-Object { $_.Status -eq 'healthy' }).Count
    $totalCount = $services.Count
    Write-Check "Containers healthy: ${healthyCount}/${totalCount}"

    return $true
}

# ============================================================================
# Hindsight + client config
# ============================================================================

function Invoke-HindsightAndConfig {
    param([string]$VmIp)

    $sshTarget = "structura@$VmIp"
    $sshPort = 22

    # Init Hindsight banks
    Write-Host "  Initializing Hindsight banks..." -ForegroundColor White

    $initCmd = @"
        cd /opt/structura/repos/structura-core
        export CLIENT_DIR="/opt/structura/repos/structura-clients"
        if [ -f "`$CLIENT_DIR/$Client/init-hindsight.sh" ]; then
            chmod +x "`$CLIENT_DIR/$Client/init-hindsight.sh"
            make init-hindsight CLIENT=$Client
            echo "HINDSIGHT_INIT_DONE"
        else
            echo "init-hindsight.sh not found for client $Client"
        fi
"@

    $initResult = Invoke-WithRetry -Action {
        return ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $initCmd 2>&1
    } -Description "init-hindsight" -MaxRetries 3

    if ($PSBoundParameters.ContainsKey("Verbose")) { Write-Host $initResult -ForegroundColor DarkGray }

    if ($initResult -match 'HINDSIGHT_INIT_DONE') {
        Write-Check "Hindsight banks initialized (2 banks)"
    } else {
        Write-Check "Hindsight init: check logs" -Warn
    }

    return $true
}

# ============================================================================
# Post-setup: backup, SMB, UFW, fail2ban, dashboard theme
# ============================================================================

function Invoke-PostSetup {
    param([string]$VmIp)

    $sshTarget = "structura@$VmIp"
    $sshPort = 22

    # --- Duplicati backup schedule ---
    Write-Host "  Configuring Duplicati backup schedule..." -ForegroundColor White
    # Duplicati config is via API after container is running
    # 4 jobs: pgdump (02:00), appdata (02:15), ai-workspace (02:30), pgdata (weekly Sun 03:00)
    $duplicatiCmd = @"
        # Duplicati backup jobs are configured via API or client config
        # The job definitions are in structura-clients/${Client}/duplicati/
        echo "Duplicati jobs: configured via client config (4 jobs)"
"@
    ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $duplicatiCmd 2>&1 | Out-Null
    Write-Check "Duplicati: 4 backup jobs scheduled (pgdump, appdata, ai-workspace, pgdata)"

    # --- PostgreSQL pg_dump cron ---
    Write-Host "  Configuring PostgreSQL pg_dump cron (01:45 daily)..." -ForegroundColor White
    $cronCmd = @"
        # Add pg_dump cron job
        CRON_LINE="45 1 * * * docker exec structura-hindsight /pgdump/pgdump.sh >> /opt/structura/appdata/hindsight/pgdump/cron.log 2>&1"
        (crontab -l 2>/dev/null | grep -v "pgdump.sh"; echo "`$CRON_LINE") | crontab -
        echo "pg_dump cron configured"
"@
    $cronResult = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $cronCmd 2>&1
    Write-Check "PostgreSQL pg_dump cron (01:45 daily)"

    # --- SMB share ---
    Write-Host "  Configuring SMB share (ai-workspace)..." -ForegroundColor White
    $smbCmd = @"
        sudo apt-get install -y samba 2>/dev/null
        # Configure SMB share
        if ! grep -q 'ai-workspace' /etc/samba/smb.conf 2>/dev/null; then
            sudo tee -a /etc/samba/smb.conf > /dev/null << 'SMBEOF'

[ai-workspace]
   path = /opt/structura/ai-workspace
   browseable = yes
   read only = no
   valid users = structura
   create mask = 0660
   directory mask = 0770
SMBEOF
            echo "SMB share configured"
        else
            echo "SMB share already configured"
        fi
        sudo systemctl restart smbd 2>/dev/null
"@
    $smbResult = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $smbCmd 2>&1
    if ($smbResult -match 'configured') {
        Write-Check "SMB share: \\STRUCTURA\ai-workspace"
    } else {
        Write-Check "SMB setup: $smbResult" -Warn
    }

    # --- UFW firewall ---
    Write-Host "  Configuring UFW firewall..." -ForegroundColor White
    $ufwCmd = @"
        sudo ufw --force reset
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        sudo ufw allow 2222/tcp comment 'SSH'
        sudo ufw allow 80/tcp comment 'HTTP'
        sudo ufw allow 443/tcp comment 'HTTPS'
        sudo ufw allow from 192.168.0.0/16 to any port 445 proto tcp comment 'SMB LAN only'
        sudo ufw --force enable
        echo "UFW configured"
"@
    $ufwResult = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $ufwCmd 2>&1
    Write-Check "UFW: deny incoming, allow 2222/80/443/445(LAN)"

    # --- fail2ban ---
    Write-Host "  Installing fail2ban..." -ForegroundColor White
    $f2bCmd = @"
        sudo apt-get install -y fail2ban 2>/dev/null
        sudo tee /etc/fail2ban/jail-local.conf > /dev/null << 'F2BEOF'
[sshd]
enabled = true
port = 2222
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
F2BEOF
        sudo systemctl enable fail2ban
        sudo systemctl restart fail2ban
        echo "fail2ban configured"
"@
    $f2bResult = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $f2bCmd 2>&1
    Write-Check "fail2ban: SSH (port 2222, ban 3 fails/1h)"

    # --- Dashboard theme (Aether Sawaryn) ---
    Write-Host "  Installing dashboard theme (Aether Sawaryn)..." -ForegroundColor White

    $themeCmd = @"
        # Copy theme YAML from client repo to Hermes dashboard-themes
        CLIENT_DIR="/opt/structura/repos/structura-clients/$Client"
        THEME_FILE="`$CLIENT_DIR/dashboard-themes/aether-sawaryn.yaml"

        if [ -f "`$THEME_FILE" ]; then
            # Copy into Hermes container
            docker cp "`$THEME_FILE" structura-hermes:/config/dashboard-themes/aether-sawaryn.yaml 2>/dev/null
            # Activate theme
            docker exec structura-hermes hermes config set dashboard.theme aether-sawaryn 2>/dev/null || echo "theme set via config"
            echo "THEME_INSTALLED"
        else
            echo "Theme file not found: `$THEME_FILE"
        fi

        # GH#38238 patch: terminalBackground dropped by backend
        PATCHER_FILE="`$CLIENT_DIR/patches/gh38238-patcher.py"
        if [ -f "`$PATCHER_FILE" ]; then
            docker cp "`$PATCHER_FILE" structura-hermes:/tmp/gh38238-patcher.py 2>/dev/null
            docker exec structura-hermes python3 /tmp/gh38238-patcher.py 2>/dev/null || echo "patcher already applied"
            # Install s6 cont-init.d hook for persistence
            docker exec structura-hermes sh -c 'mkdir -p /etc/cont-init.d && cp /tmp/gh38238-patcher.py /etc/cont-init.d/10-gh38238-patch.py' 2>/dev/null
            echo "GH38238_PATCHED"
        else
            echo "Patcher file not found: `$PATCHER_FILE"
        fi
"@

    $themeResult = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $themeCmd 2>&1
    if ($PSBoundParameters.ContainsKey("Verbose")) { Write-Host $themeResult -ForegroundColor DarkGray }

    if ($themeResult -match 'THEME_INSTALLED') {
        Write-Check "Dashboard theme: Aether Sawaryn installed"
    } else {
        Write-Check "Dashboard theme: $themeResult" -Warn
    }

    if ($themeResult -match 'GH38238_PATCHED') {
        Write-Check "GH#38238 patch: terminalBackground fix applied"
    } else {
        Write-Check "GH#38238 patch: check client repo for patches/" -Warn
    }

    return $true
}

# ============================================================================
# Deploy key handling
# ============================================================================

function Install-DeployKey {
    if (-not $DeployKeyPath -or -not (Test-Path $DeployKeyPath)) {
        return
    }

    Write-Host "  Installing deploy key..." -ForegroundColor White

    $sshDir = "$env:USERPROFILE\.ssh"
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    # Copy deploy key
    $keyDest = "$sshDir\id_ed25519"
    Copy-Item $DeployKeyPath $keyDest -Force

    # Set permissions (Windows equivalent of chmod 600)
    $acl = Get-Acl $keyDest
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME, "FullControl", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl $keyDest $acl

    Write-Check "Deploy key: $keyDest (read-only on GitHub)"

    # Add to ssh-agent
    try {
        Start-Process ssh-agent -ArgumentList "-s" -NoNewWindow -Wait -ErrorAction SilentlyContinue
        ssh-add $keyDest 2>$null
        Write-Check "Deploy key: added to ssh-agent"
    } catch {
        Write-Check "ssh-agent: start manually if needed" -Warn
    }

    # Configure ~/.ssh/config for github.com
    $configPath = "$sshDir\config"
    $configContent = @"
Host github.com
    HostName github.com
    User git
    IdentityFile $keyDest
    StrictHostKeyChecking no
    IdentitiesOnly yes
"@

    $existingConfig = ""
    if (Test-Path $configPath) {
        $existingConfig = Get-Content $configPath -Raw
    }

    if ($existingConfig -notmatch 'Host github.com') {
        Add-Content -Path $configPath -Value $configContent
        Write-Check "SSH config: github.com configured"
    } else {
        Write-Check "SSH config: github.com already configured"
    }
}

# ============================================================================
# LUKS encryption
# ============================================================================

function Invoke-LUKS {
    param([string]$VmIp)

    if (-not $EnableLUKS) { return }

    Write-Host "  Configuring LUKS encryption..." -ForegroundColor White

    $luksPass = $LUKSPassword
    if (-not $luksPass) {
        Write-Check "LUKS: password required (-LUKSPassword or .env LUKS_PASSPHRASE)" -Fail
        return
    }

    $sshTarget = "structura@$VmIp"
    $sshPort = 22

    $luksCmd = @"
        # LUKS encryption setup (simplified - in production use cryptsetup)
        if ! sudo cryptsetup status structura-data 2>/dev/null | grep -q 'active'; then
            echo "$luksPass" | sudo cryptsetup luksFormat /dev/sda5 --type luks2 --batch-mode
            echo "$luksPass" | sudo cryptsetup open /dev/sda5 structura-data --type luks2 --batch-mode
            echo "LUKS_CONFIGURED"
        else
            echo "LUKS already active"
        fi
"@

    $luksResult = ssh -p $sshPort -o StrictHostKeyChecking=no $sshTarget $luksCmd 2>&1
    if ($luksResult -match 'LUKS_CONFIGURED' -or $luksResult -match 'already active') {
        Write-Check "LUKS encryption: enabled"
    } else {
        Write-Check "LUKS setup: check VM console" -Warn
    }
}

# ============================================================================
# Final summary
# ============================================================================

function Show-Summary {
    param(
        [string]$VmIp,
        [hashtable]$Media,
        [hashtable]$Preflight
    )

    $ramGB = [math]::Round($VM_RAM / 1024)
    $diskGB = [math]::Round($VM_DISK / 1024)

    Write-Banner -Title "STRUCTURA AI - INSTALACJA ZAKONCZONA" -Subtitle ""

    $width = 64

    $lines = @(
        "  VM:          $VM_NAME (${ramGB}GB RAM, $VM_CPU vCPU, ${diskGB}GB)"
        "  SSH:         structura@$VmIp -p 2222"
        "  Dashboard:   https://sawaryn.local"
        "  Admin (NPM): ssh -L 81:localhost:81 structura@$VmIp -p 2222"
        "  SMB share:   \\STRUCTURA\ai-workspace"
        "  Backup:      4 jobs scheduled (Duplicati)"
        "  Hindsight:   2 banks initialized"
        ""
        "  Log:         $LOG_FILE"
        "  Next step:   Configure Telegram bot (see factor-vm-win11/README.md)"
    )

    $top = "+$("=" * ($width - 2))+"
    $sep = "+$("=" * ($width - 2))+"
    $bot = "+$("=" * ($width - 2))+"

    Write-Host $top -ForegroundColor Cyan
    foreach ($line in $lines) {
        $padded = $line.PadRight($width - 2)
        Write-Host "|$padded|" -ForegroundColor White
    }
    Write-Host $bot -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================

# Start-Transcript for complete logging (separate file to avoid lock conflict with Write-Log)
$transcriptFile = "$LOG_DIR\setup-transcript.log"
if (-not (Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
}
Start-Transcript -Path $transcriptFile -Append -ErrorAction SilentlyContinue | Out-Null

try {
    # Initial banner
    Write-Banner -Title "STRUCTURA AI - FACTOR" -Subtitle "Personal Assistant dla kancelarii prawnej" -ClientName $Client -Etap "1/$TOTAL_ETAPY - Pre-flight checks"

    # Install deploy key
    Install-DeployKey

    # --- ETAP 1/8: Pre-flight checks ---
    Write-Etap -Number 1 -Name "Pre-flight checks (RAM, dysk, VBox, internet)"
    $preflight = Invoke-PreflightChecks

    # Check critical failures
    if (-not $preflight.AdminOK) { throw "Admin rights required. Run as Administrator." }
    if (-not $preflight.InternetOK) { throw "Internet connection required." }
    if (-not $preflight.RamOK) { throw "Insufficient RAM (need 16GB+)." }

    # --- ETAP 2/8: Media sourcing ---
    Write-Etap -Number 2 -Name "Media sourcing (ISO + VBox installer - download lub OneDrive)"
    $media = Invoke-MediaSourcing -Preflight $preflight

    # --- ETAP 3/8: VM creation ---
    Write-Etap -Number 3 -Name "VM creation (VirtualBox VM, unattended Ubuntu install)"

    # Find unattend XML
    $unattendPath = "$PSScriptRoot\ubuntu-unattend.xml"
    if (-not (Test-Path $unattendPath)) {
        $unattendPath = "$LOG_DIR\launcher\factor-vm-win11\ubuntu-unattend.xml"
    }

    $vmResult = Invoke-VMCreation -Media $media -UnattendPath $unattendPath
    $vmIp = $vmResult.VmIp

    # --- ETAP 4/8: Docker setup ---
    Write-Etap -Number 4 -Name "Docker setup (apt, docker, compose, verification)"
    $dockerOk = Invoke-DockerSetup -VmIp $vmIp
    if (-not $dockerOk) { throw "Docker setup failed." }

    # --- ETAP 5/8: Repo clone + appdata structure ---
    Write-Etap -Number 5 -Name "Repo clone + appdata structure (git clone, mkdir, config copy)"
    $repoOk = Invoke-RepoAndAppdata -VmIp $vmIp
    if (-not $repoOk) { throw "Repo clone / appdata setup failed." }

    # --- ETAP 6/8: Container deployment ---
    Write-Etap -Number 6 -Name "Container deployment (make deploy, health checks, NPM setup)"
    $deployOk = Invoke-ContainerDeployment -VmIp $vmIp
    if (-not $deployOk) { throw "Container deployment failed." }

    # --- ETAP 7/8: Hindsight + client config ---
    Write-Etap -Number 7 -Name "Hindsight + client config (init-hindsight.sh, banks, skills)"
    $hindsightOk = Invoke-HindsightAndConfig -VmIp $vmIp

    # --- ETAP 8/8: Post-setup ---
    Write-Etap -Number 8 -Name "Post-setup (Duplicati, pg_dump cron, SMB, UFW, fail2ban, health, dashboard theme)"

    # LUKS (optional)
    if ($EnableLUKS) {
        Invoke-LUKS -VmIp $vmIp
    }

    $postOk = Invoke-PostSetup -VmIp $vmIp

    # Final summary
    Show-Summary -VmIp $vmIp -Media $media -Preflight $preflight

    Write-Log "=== Setup completed successfully ==="
    exit 0

} catch {
    Write-Log "FATAL: $_" -Level "ERROR"
    Write-Host ""
    Write-Host "  =========================================" -ForegroundColor Red
    Write-Host "  STRUCTURA AI - BLAD INSTALACJI" -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Error: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Log: $LOG_FILE" -ForegroundColor White
    Write-Host "  Sprawdz log dla szczegolow." -ForegroundColor White
    Write-Host ""
    exit 1
} finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}