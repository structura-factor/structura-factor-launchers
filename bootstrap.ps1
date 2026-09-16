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
    [string]$DeployKeyPath,

    [Parameter(Mandatory = $false)]
    [string]$MediaPath,

    [Parameter(Mandatory = $false)]
    [string]$LauncherRepo = "ciemek/structura-factor-launchers",

    [Parameter(Mandatory = $false)]
    [string]$ClientRepo = "ciemek/structura-clients",

    [Parameter(Mandatory = $false)]
    [switch]$Quiet,

    [Parameter(Mandatory = $false)]
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Constants
# ============================================================================

$STRUCTURA_LOG_DIR = "C:\structura"
$STRUCTURA_LOG_FILE = "$STRUCTURA_LOG_DIR\setup.log"
$GITHUB_RAW_BASE = "https://raw.githubusercontent.com"
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

# Step 1: Fetch bootstrap.yaml from client repo
Write-StructuraLog "Fetching bootstrap.yaml from $ClientRepo/$Client/..."
$bootstrapUrl = "$GITHUB_RAW_BASE/$ClientRepo/main/$Client/bootstrap.yaml"

$bootstrapYamlPath = [System.IO.Path]::GetTempFileName()
$downloaded = Invoke-SafeDownload -Url $bootstrapUrl -Destination $bootstrapYamlPath -TimeoutSec $DOWNLOAD_TIMEOUT_SEC

if (-not $downloaded) {
    Write-StructuraLog "Failed to fetch bootstrap.yaml. Check client repo and network." -Level "ERROR"
    Write-Host ""
    Write-Host "  Potrzebujesz dostepu do repo: $ClientRepo" -ForegroundColor Yellow
    Write-Host "  Sprawdz czy deploy key ma uprawnienia do: $ClientRepo" -ForegroundColor Yellow
    exit 1
}

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

# Step 3: Extract launcher name from bootstrap.yaml
$launcherName = $null
if ($bootstrapYaml -match "(?m)^launcher\s*:\s*(.+)$") {
    $launcherName = $Matches[1].Trim().Trim('"').Trim("'")
}

if (-not $launcherName) {
    Write-StructuraLog "Could not extract 'launcher' field from bootstrap.yaml" -Level "ERROR"
    exit 1
}

Write-StructuraLog "Launcher: $launcherName"

# Step 4: Fetch setup.bat from launcher repo
$setupBatUrl = "$GITHUB_RAW_BASE/$LauncherRepo/main/$launcherName/setup.bat"
$setupBatPath = [System.IO.Path]::GetTempFileName()
$downloaded = Invoke-SafeDownload -Url $setupBatUrl -Destination $setupBatPath -TimeoutSec $DOWNLOAD_TIMEOUT_SEC

if (-not $downloaded) {
    Write-StructuraLog "Failed to fetch setup.bat from launcher." -Level "ERROR"
    exit 1
}

# Step 5: Fetch setup.ps1 from launcher repo
$setupPs1Url = "$GITHUB_RAW_BASE/$LauncherRepo/main/$launcherName/setup.ps1"
$setupPs1Path = [System.IO.Path]::GetTempFileName()
$downloaded = Invoke-SafeDownload -Url $setupPs1Url -Destination $setupPs1Path -TimeoutSec $DOWNLOAD_TIMEOUT_SEC

if (-not $downloaded) {
    Write-StructuraLog "Failed to fetch setup.ps1 from launcher." -Level "ERROR"
    exit 1
}

# Step 6: Fetch ubuntu-unattend.xml from launcher repo
$unattendUrl = "$GITHUB_RAW_BASE/$LauncherRepo/main/$launcherName/ubuntu-unattend.xml"
$unattendPath = [System.IO.Path]::GetTempFileName()
$downloaded = Invoke-SafeDownload -Url $unattendUrl -Destination $unattendPath -TimeoutSec $DOWNLOAD_TIMEOUT_SEC

if (-not $downloaded) {
    Write-StructuraLog "Failed to fetch ubuntu-unattend.xml from launcher." -Level "WARN"
    # Non-fatal - setup.ps1 may have its own handling
}

# Step 7: Prepare local launcher directory
$launcherDir = "$STRUCTURA_LOG_DIR\launcher\$launcherName"
if (-not (Test-Path $launcherDir)) {
    New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
}

Copy-Item $setupBatPath "$launcherDir\setup.bat" -Force
Copy-Item $setupPs1Path "$launcherDir\setup.ps1" -Force
if (Test-Path $unattendPath) {
    Copy-Item $unattendPath "$launcherDir\ubuntu-unattend.xml" -Force
}

Write-StructuraLog "Launcher files staged in $launcherDir"

# Step 8: Build setup.ps1 arguments
$setupArgs = @("-Client", $Client)
if ($DeployKeyPath) { $setupArgs += @("-DeployKeyPath", $DeployKeyPath) }
if ($MediaPath) { $setupArgs += @("-MediaPath", $MediaPath) }
if ($Quiet) { $setupArgs += "-Quiet" }
if ($Verbose) { $setupArgs += "-Verbose" }

# Step 9: Execute launcher
Write-StructuraLog "Executing launcher: $launcherName/setup.ps1"
Write-StructuraLog "Arguments: $($setupArgs -join ' ')"

Push-Location $launcherDir
try {
    & ".\setup.ps1" @setupArgs
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}

if ($exitCode -ne 0) {
    Write-StructuraLog "Launcher exited with code $exitCode" -Level "ERROR"
    exit $exitCode
}

Write-StructuraLog "=== Bootstrap complete ==="

# Cleanup temp files
Remove-Item $bootstrapYamlPath -Force -ErrorAction SilentlyContinue
Remove-Item $setupBatPath -Force -ErrorAction SilentlyContinue
Remove-Item $setupPs1Path -Force -ErrorAction SilentlyContinue
Remove-Item $unattendPath -Force -ErrorAction SilentlyContinue