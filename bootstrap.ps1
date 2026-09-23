# bootstrap.ps1 - Uniwersalny bootstrap PowerShell dla STRUCTURA FACTOR
# Pobiera i uruchamia launcher na podstawie bootstrap.yaml z client repo.
#
# Usage:
#   .\bootstrap.ps1 -Client sawaryn -DeployKeyPath C:\path\to\deploy_key
#   .\bootstrap.ps1 -Client sawaryn -MediaPath "C:\Users\premek\OneDrive\STRUCTURA\media\"

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Client,

    [Parameter(Mandatory = $false)]
    [string]$InstallPath = "C:\STRUCTURA",

    [Parameter(Mandatory = $false)]
    [string]$DeployKeyPath,

    [Parameter(Mandatory = $false)]
    [string]$CoreDeployKeyPath,

    [Parameter(Mandatory = $false)]
    [string]$MediaPath,

    [Parameter(Mandatory = $false)]
    [switch]$SkipMediaVerify,

    [Parameter(Mandatory = $false)]
    [string]$LauncherRepo = "structura-factor/structura-factor-launchers@3b8bc68315eef47624d06377c7fe20166a14f00d",
    # Jawny wybor launchera (nadpisuje 'launcher' z bootstrap.yaml).
    # Uzycie: .\bootstrap.ps1 -Client sawaryn -Launcher factor-vm-win11
    # Przydatne przy testach bez specyfikacji klienta.
    [string]$Launcher = "",

    [Parameter(Mandatory = $false)]
    [string]$ClientRepo = "structura-factor/structura-clients-sawaryn",

    [Parameter(Mandatory = $false)]
    [int]$VM_RAM,

    [Parameter(Mandatory = $false)]
    [int]$VM_CPU,

    [Parameter(Mandatory = $false)]
    [int]$VM_DISK,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
    # -Verbose provided by CmdletBinding automatically
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Constants
# ============================================================================

$STRUCTURA_LOG_DIR = "C:\structura"
$STRUCTURA_LOG_FILE = "$STRUCTURA_LOG_DIR\setup.log"
$GITHUB_RAW_BASE = "https://cdn.jsdelivr.net/gh"
$DOWNLOAD_TIMEOUT_SEC = 30
$MAX_RETRIES = 3

# ============================================================================
# Logging
# ============================================================================

function Write-StructuraLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    if (-not (Test-Path $STRUCTURA_LOG_DIR)) {
        New-Item -ItemType Directory -Path $STRUCTURA_LOG_DIR -Force | Out-Null
    }
    # Log rotation >10MB
    if (Test-Path $STRUCTURA_LOG_FILE) {
        $size = (Get-Item $STRUCTURA_LOG_FILE).Length
        if ($size -gt 10MB) {
            $rotated = "$STRUCTURA_LOG_FILE.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Move-Item $STRUCTURA_LOG_FILE $rotated -Force
        }
    }
    Add-Content -Path $STRUCTURA_LOG_FILE -Value $line
    if (-not $Quiet) {
        switch ($Level) {
            "ERROR" { Write-Host $line -ForegroundColor Red }
            "WARN"  { Write-Host $line -ForegroundColor Yellow }
            default { Write-Host $line -ForegroundColor Cyan }
        }
    }
}

# ============================================================================
# Bootstrap YAML validation
# ============================================================================

function Test-BootstrapYaml {
    param([string]$YamlContent)

    $requiredFields = @('client', 'launcher', 'repos.core', 'repos.client')
    $errors = @()

    # Simple YAML field extraction (no module dependency)
    foreach ($field in $requiredFields) {
        $parts = $field.Split('.')
        $found = $false

        if ($parts.Count -eq 1) {
            if ($YamlContent -match "(?m)^$($parts[0])\s*:\s*(.+)$") {
                $found = $true
            }
        } elseif ($parts.Count -eq 2) {
            if ($YamlContent -match "(?m)^$($parts[0])\s*:" -and $YamlContent -match "(?m)^\s+$($parts[1])\s*:\s*(.+)$") {
                $found = $true
            }
        }

        if (-not $found) {
            $errors += "Missing required field: $field"
        }
    }

    return $errors
}

# ============================================================================
# Download with retry and rollback
# ============================================================================

function Invoke-SafeDownload {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$TimeoutSec = $DOWNLOAD_TIMEOUT_SEC,
        [int]$MaxRetries = $MAX_RETRIES
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Write-StructuraLog "Downloading $Url (attempt $attempt/$MaxRetries)..."

            $partialDest = "$Destination.partial"

            # Clean up any previous partial download
            if (Test-Path $partialDest) {
                Remove-Item $partialDest -Force
            }

            Invoke-WebRequest -Uri $Url -OutFile $partialDest -TimeoutSec $TimeoutSec -UseBasicParsing

            # Verify file is not empty
            $fileSize = (Get-Item $partialDest).Length
            if ($fileSize -eq 0) {
                throw "Downloaded file is empty (0 bytes)"
            }

            # Move partial to final
            Move-Item $partialDest $Destination -Force
            Write-StructuraLog "Download complete: $Destination ($fileSize bytes)"

            return $true
        }
        catch {
            Write-StructuraLog "Download attempt $attempt failed: $_" -Level "WARN"

            # Rollback: remove partial download
            $partialDest = "$Destination.partial"
            if (Test-Path $partialDest) {
                Remove-Item $partialDest -Force
            }

            if ($attempt -lt $MaxRetries) {
                $backoff = [math]::Pow(2, $attempt)
                Write-StructuraLog "Retrying in $backoff seconds..."
                Start-Sleep -Seconds $backoff
            }
        }
    }

    Write-StructuraLog "All $MaxRetries download attempts failed for $Url" -Level "ERROR"
    return $false
}

# ============================================================================
# SHA256 verification
# ============================================================================

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $hash = Get-FileHash -Path $Path -Algorithm SHA256
    return $hash.Hash.ToLower()
}

# ============================================================================
# Main
# ============================================================================

Write-StructuraLog "=== STRUCTURA FACTOR - Bootstrap ==="
Write-StructuraLog "Client: $Client"
Write-StructuraLog "Launcher repo: $LauncherRepo"
Write-StructuraLog "Client repo: $ClientRepo"
if ($DeployKeyPath) { Write-StructuraLog "Deploy key: $DeployKeyPath" }
if ($MediaPath) { Write-StructuraLog "Media path: $MediaPath" }

# Step 1: Fetch bootstrap.yaml from client repo via git (private repo)
Write-StructuraLog "Fetching bootstrap.yaml from $ClientRepo (private, via git)..."

$tempClone = "$InstallPath\temp\bootstrap-clone"
$tempParent = Split-Path $tempClone -Parent
if (-not (Test-Path $tempParent)) { New-Item -ItemType Directory -Path $tempParent -Force | Out-Null }
if (Test-Path $tempClone) { Remove-Item $tempClone -Recurse -Force }
$gitUrl = "git@github.com:$ClientRepo.git"

# Setup SSH for git with deploy key
if ($DeployKeyPath) {
    # SSH on Windows (Git for Windows) strips backslashes from -i path
    # Convert to forward slashes
    $sshKeyPath = $DeployKeyPath -replace '\\', '/'
    $env:GIT_SSH_COMMAND = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -i $sshKeyPath -o IdentitiesOnly=yes"
} else {
    Write-StructuraLog "No deploy key provided - git clone may fail for private repos" -Level "WARN"
}

# Temporarily relax error preference - git writes to stderr which triggers Stop
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

Write-StructuraLog "Cloning $gitUrl (shallow)..."
$cloneOutput = & git clone --depth 1 $gitUrl $tempClone 2>&1
$cloneExit = $LASTEXITCODE

$ErrorActionPreference = $prevEAP

if ($cloneExit -ne 0) {
    Write-StructuraLog "git clone failed (exit $cloneExit): $cloneOutput" -Level "ERROR"
    Write-Host ""
    Write-Host "  Nie udalo sie sklonowac repo: $ClientRepo" -ForegroundColor Yellow
    Write-Host "  Sprawdz czy deploy key jest poprawny." -ForegroundColor Yellow
    Write-Host "  Klucz: $DeployKeyPath" -ForegroundColor DarkGray
    Write-Host "  Blad: $cloneOutput" -ForegroundColor DarkGray
    exit 1
}

Write-StructuraLog "git clone successful"

$bootstrapYamlPath = "$tempClone\bootstrap.yaml"
if (-not (Test-Path $bootstrapYamlPath)) {
    Write-StructuraLog "bootstrap.yaml not found in repo root" -Level "ERROR"
    Write-Host "  Plik bootstrap.yaml nie znaleziony w repo: $ClientRepo" -ForegroundColor Yellow
    exit 1
}

Write-StructuraLog "bootstrap.yaml found: $bootstrapYamlPath"
Remove-Item env:\GIT_SSH_COMMAND -ErrorAction SilentlyContinue

# Step 2: Validate bootstrap.yaml schema
$bootstrapYaml = Get-Content $bootstrapYamlPath -Raw
Write-StructuraLog "Validating bootstrap.yaml schema..."
$validationErrors = Test-BootstrapYaml -YamlContent $bootstrapYaml

if ($validationErrors.Count -gt 0) {
    Write-StructuraLog "bootstrap.yaml validation failed:" -Level "ERROR"
    foreach ($err in $validationErrors) {
        Write-StructuraLog "  $err" -Level "ERROR"
    }
    exit 1
}

Write-StructuraLog "bootstrap.yaml schema valid."

# Step 3: Ustal launcher
# Kolejnosc: parametr -Launcher > pole 'launcher' w bootstrap.yaml > manifest
$launcherName = $null

# 3a. Jawny parametr ma najwyzszy priorytet
if ($Launcher) {
    $launcherName = $Launcher.Trim()
    Write-StructuraLog "Launcher z parametru -Launcher: $launcherName"
}

# 3b. Pole 'launcher' z bootstrap.yaml klienta
if (-not $launcherName -and $bootstrapYaml) {
    if ($bootstrapYaml -match "(?m)^launcher\s*:\s*(.+)$") {
        $launcherName = $Matches[1].Trim().Trim('"').Trim("'")
        Write-StructuraLog "Launcher z bootstrap.yaml: $launcherName"
    }
}

# 3c. Brak wskazania -> manifest launchers.yaml + wybor interaktywny
if (-not $launcherName) {
    Write-StructuraLog "Brak 'launcher' w bootstrap.yaml - czytam manifest launchers.yaml"

    $manifestUrl = "$GITHUB_RAW_BASE/$LauncherRepo/launchers.yaml"
    $manifestPath = [System.IO.Path]::GetTempFileName()
    $manifestOk = Invoke-SafeDownload -Url $manifestUrl -Destination $manifestPath -TimeoutSec $DOWNLOAD_TIMEOUT_SEC

    if ($manifestOk) {
        $manifestContent = Get-Content -Path $manifestPath -Raw -ErrorAction SilentlyContinue
        # Parsuj liste: "- name: <nazwa>" oraz "  label: <opis>"
        $entries = @()
        $lines = $manifestContent -split "`n"
        $current = $null
        foreach ($line in $lines) {
            if ($line -match '^\s*-\s*name:\s*(.+)$') {
                if ($current) { $entries += $current }
                $current = @{ Name = $Matches[1].Trim().Trim('"'); Label = "" }
            } elseif ($current -and $line -match '^\s+label:\s*(.+)$') {
                $current.Label = $Matches[1].Trim().Trim('"')
            }
        }
        if ($current) { $entries += $current }

        if ($entries.Count -gt 0) {
            Write-Host ""
            Write-Host "  Dostepne launchery:" -ForegroundColor White
            for ($i = 0; $i -lt $entries.Count; $i++) {
                Write-Host ("    {0}. {1} - {2}" -f ($i + 1), $entries[$i].Name, $entries[$i].Label) -ForegroundColor Gray
            }
            Write-Host ""
            $choice = Read-Host "  Wybierz launcher (numer, domyslnie 1)"
            $idx = 0
            if ($choice -match '^\d+$') {
                $idx = [int]$choice - 1
                if ($idx -lt 0 -or $idx -ge $entries.Count) { $idx = 0 }
            }
            $launcherName = $entries[$idx].Name
            Write-StructuraLog "Launcher wybrany z manifestu: $launcherName"
        } else {
            Write-StructuraLog "Manifest launchers.yaml jest pusty lub nieczytelny" -Level "ERROR"
        }
    } else {
        Write-StructuraLog "Nie udalo sie pobrac launchers.yaml z $LauncherRepo" -Level "ERROR"
    }
}

if (-not $launcherName) {
    Write-StructuraLog "Nie ustalono launchera. Podaj -Launcher albo dodaj 'launcher' do bootstrap.yaml klienta." -Level "ERROR"
    Write-Host ""
    Write-Host "  Przyklad: .\bootstrap.ps1 -Client sawaryn -Launcher factor-vm-win11" -ForegroundColor Yellow
    exit 1
}

Write-StructuraLog "Launcher: $launcherName"

# Step 4: setup.bat is skipped - jsDelivr CDN blocks .bat files (HTTP 403)
# setup.ps1 is used directly by bootstrap, no .bat wrapper needed
$setupBatPath = $null
Write-StructuraLog "setup.bat skipped (jsDelivr blocks .bat files) - using setup.ps1 directly"

# Step 5: Fetch setup.ps1 from launcher repo
$setupPs1Url = "$GITHUB_RAW_BASE/$LauncherRepo/$launcherName/setup.ps1"
$setupPs1Path = [System.IO.Path]::GetTempFileName()
$downloaded = Invoke-SafeDownload -Url $setupPs1Url -Destination $setupPs1Path -TimeoutSec $DOWNLOAD_TIMEOUT_SEC

if (-not $downloaded) {
    Write-StructuraLog "Failed to fetch setup.ps1 from launcher." -Level "ERROR"
    exit 1
}

# Step 6: Prepare local launcher directory
# UWAGA: ubuntu-unattend.xml NIE jest pobierany. Plik byl martwy - setup.ps1
# przyjmowal go jako parametr -UnattendPath, ale NIGDY nie uzywal: buduje
# wlasny inline szablon przez VBoxManage --script-template (z ssh_authorized_keys,
# bo stock szablon VBox ma bug launchpad #2090834 - late-commands przed userem).
$launcherDir = "$STRUCTURA_LOG_DIR\launcher\$launcherName"
if (-not (Test-Path $launcherDir)) {
    New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
}

if ($setupBatPath) { Copy-Item $setupBatPath "$launcherDir\setup.bat" -Force }
Copy-Item $setupPs1Path "$launcherDir\setup.ps1" -Force

Write-StructuraLog "Launcher files staged in $launcherDir"

# Step 8: Build setup.ps1 arguments
$setupArgs = @("-Client", $Client)
if ($DeployKeyPath) { $setupArgs += @("-DeployKeyPath", $DeployKeyPath) }
if ($CoreDeployKeyPath) { $setupArgs += @("-CoreDeployKeyPath", $CoreDeployKeyPath) }
if ($MediaPath) { $setupArgs += @("-MediaPath", $MediaPath) }
if ($SkipMediaVerify) { $setupArgs += "-SkipMediaVerify" }
if ($VM_RAM) { $setupArgs += @("-VM_RAM", $VM_RAM) }
if ($VM_CPU) { $setupArgs += @("-VM_CPU", $VM_CPU) }
if ($VM_DISK) { $setupArgs += @("-VM_DISK", $VM_DISK) }
if ($Quiet) { $setupArgs += "-Quiet" }
if ($PSBoundParameters.ContainsKey("Verbose")) { $setupArgs += "-Verbose" }

# Step 9: Execute launcher
Write-StructuraLog "Executing launcher: $launcherName/setup.ps1"
Write-StructuraLog "Arguments: $($setupArgs -join ' ')"

# Build command string - more reliable than splatting when loaded via Invoke-Expression
$setupCmd = "& '$launcherDir\setup.ps1'"
foreach ($arg in $setupArgs) {
    if ($arg -match '^-') {
        $setupCmd += " $arg"
    } else {
        $setupCmd += " '$arg'"
    }
}
Write-StructuraLog "Setup command: $setupCmd"

try {
    Invoke-Expression $setupCmd
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq $null) { $exitCode = 0 }
}
catch {
    Write-StructuraLog "setup.ps1 error: $_" -Level "ERROR"
    $exitCode = 1
}

if ($exitCode -ne 0) {
    Write-StructuraLog "Launcher exited with code $exitCode" -Level "ERROR"
    exit $exitCode
}

Write-StructuraLog "=== Bootstrap complete ==="

# Cleanup temp files
Remove-Item $tempClone -Recurse -Force -ErrorAction SilentlyContinue
if ($setupBatPath) { Remove-Item $setupBatPath -Force -ErrorAction SilentlyContinue }
Remove-Item $setupPs1Path -Force -ErrorAction SilentlyContinue