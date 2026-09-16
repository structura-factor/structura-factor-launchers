# ============================================================================
#  Install-STRUCTURA-FACTOR.ps1
#  Jeden plik - wszystko w jednym. Pobiera bootstrap, szuka klucza, stawia VM.
#  Uruchom jako Administrator.
# ============================================================================

[CmdletBinding()]
param(
    [string]$MediaCachePath,
    [int]$VM_RAM = 4096,
    [int]$VM_CPU = 2,
    [int]$VM_DISK = 40960,
    [switch]$EnableLUKS,
    [string]$LUKSPassword,
    [switch]$Quiet,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'

# --- Stale ---
$CLIENT = "sawaryn"
$LAUNCHER_REPO = "structura-factor/structura-factor-launchers"
$GITHUB_RAW = "https://raw.githubusercontent.com"
$BOOTSTRAP_URL = "$GITHUB_RAW/$LAUNCHER_REPO/main/bootstrap.ps1"
$BASE_DIR = "C:\STRUCTURA"
$KEYS_DIR = "$BASE_DIR\klucze"
$MEDIA_DIR = "$BASE_DIR\media"
$LOGS_DIR = "$BASE_DIR\logs"
$LOG_FILE = "$LOGS_DIR\setup.log"
$UBUNTU_ISO_NAME = "ubuntu-24.04.1-server-amd64.iso"
$VBOX_INSTALLER_NAME = "VirtualBox-7.1.4-Win.exe"

# --- Logowanie ---
function W-Log([string]$Msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if (Test-Path $LOGS_DIR) { Add-Content -Path $LOG_FILE -Value "[$ts] $Msg" }
}

# --- Banner ---
Write-Host ""
Write-Host "+============================================================+" -ForegroundColor Cyan
Write-Host "|       STRUCTURA FACTOR - Instalator v1.2                   |" -ForegroundColor Cyan
Write-Host "|       Personal Assistant prawniczy                          |" -ForegroundColor Cyan
Write-Host "|                                                             |" -ForegroundColor Cyan
Write-Host "|  Klient: Sawaryn i Partnerzy                                |" -ForegroundColor White
Write-Host "|  Folder: C:\STRUCTURA                                        |" -ForegroundColor White
Write-Host "+============================================================+" -ForegroundColor Cyan
Write-Host ""

# --- Struktura folderow ---
Write-Host "  > Tworzenie struktury folderow..." -ForegroundColor Cyan
@($BASE_DIR, $KEYS_DIR, $MEDIA_DIR, $LOGS_DIR) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}
Write-Host "  v Struktura gotowa: $BASE_DIR" -ForegroundColor Green
Write-Host "    $KEYS_DIR   (wklej tu deploy key)" -ForegroundColor DarkGray
Write-Host "    $MEDIA_DIR  (pobrane ISO + VBox)" -ForegroundColor DarkGray
Write-Host "    $LOGS_DIR   (logi)" -ForegroundColor DarkGray
Write-Host ""

W-Log "=== Install v1.2 started ==="
W-Log "VM_RAM=$VM_RAM VM_CPU=$VM_CPU VM_DISK=$VM_DISK LUKS=$EnableLUKS"

# --- Deploy key ---
Write-Host "  > Szukanie deploy key w klucze\..." -ForegroundColor Cyan
$deployKeyPath = $null
$keyFiles = Get-ChildItem -Path $KEYS_DIR -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -notmatch '\.pub$' -and $_.Name -notmatch '\.txt$' -and $_.Name -notmatch '\.md$'
}
if ($keyFiles) {
    $deployKeyPath = $keyFiles[0].FullName
    Write-Host "  v Deploy key: klucze\$($keyFiles[0].Name)" -ForegroundColor Green
} else {
    Write-Host "  ! Nie znaleziono deploy key w $KEYS_DIR\" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Wklej plik klucza prywatnego SSH do:" -ForegroundColor Yellow
    Write-Host "    $KEYS_DIR\" -ForegroundColor White
    Write-Host ""
    Write-Host "  Klucz to plik bez rozszerzenia (.pub to klucz publiczny)." -ForegroundColor DarkGray
    Write-Host "  Nastepnie uruchom skrypt ponownie." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
W-Log "DeployKey: $deployKeyPath"

# --- Admin check ---
Write-Host "  > Sprawdzanie uprawnien administratora..." -ForegroundColor Cyan
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "  x Wymagane uprawnienia administratora." -ForegroundColor Red
    Write-Host "  Kliknij prawym na PowerShell -> Uruchom jako administrator" -ForegroundColor Yellow
    exit 1
}
Write-Host "  v Admin: tak" -ForegroundColor Green
W-Log "Admin: OK"

# --- RAM ---
Write-Host "  > Sprawdzanie RAM..." -ForegroundColor Cyan
$totalRAM = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($totalRAM -lt 16) {
    Write-Host "  x Zbyt malo RAM: $totalRAM GB (min. 16 GB)" -ForegroundColor Red
    exit 1
}
Write-Host "  v RAM: $totalRAM GB" -ForegroundColor Green
W-Log "RAM: $totalRAM GB"

# --- Dysk ---
Write-Host "  > Sprawdzanie wolnego miejsca na C:..." -ForegroundColor Cyan
$freeGB = [math]::Round((Get-PSDrive -Name C).Free / 1GB)
$needGB = [math]::Round($VM_DISK / 1024) + 10
if ($freeGB -lt $needGB) {
    Write-Host "  ! Wolne miejsce: $freeGB GB (zalecane $needGB GB)" -ForegroundColor Yellow
} else {
    Write-Host "  v Wolne miejsce: $freeGB GB" -ForegroundColor Green
}
W-Log "Disk free: $freeGB GB"

# --- Internet ---
Write-Host "  > Sprawdzanie internetu..." -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri "https://github.com" -TimeoutSec 10 -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null
    Write-Host "  v Internet: tak" -ForegroundColor Green
} catch {
    Write-Host "  x Brak internetu. Wymagany dostep do GitHub." -ForegroundColor Red
    exit 1
}
W-Log "Internet: OK"

# --- LUKS ---
if ($EnableLUKS -and -not $LUKSPassword) {
    Write-Host "  x LUKS wlaczony ale brak hasla. Uzyj -LUKSPassword." -ForegroundColor Red
    exit 1
}

# --- Media ---
Write-Host ""
Write-Host "  === Media instalacyjne ===" -ForegroundColor Cyan
Write-Host "  Potrzeba: Ubuntu 24.04 ISO (~2.5 GB) + VirtualBox 7.1.4 (~100 MB)" -ForegroundColor White
Write-Host ""

$localIso = "$MEDIA_DIR\$UBUNTU_ISO_NAME"
$localVbox = "$MEDIA_DIR\$VBOX_INSTALLER_NAME"
$hasLocal = (Test-Path $localIso) -and (Test-Path $localVbox)
$hasCache = $false
if ($MediaCachePath -and (Test-Path $MediaCachePath)) {
    $hasCache = (Test-Path "$MediaCachePath\$UBUNTU_ISO_NAME") -and (Test-Path "$MediaCachePath\$VBOX_INSTALLER_NAME")
}

if ($hasLocal) {
    Write-Host "  v Media znalezione lokalnie: $MEDIA_DIR" -ForegroundColor Green
} elseif ($hasCache) {
    Write-Host "  v Media znalezione w cache: $MediaCachePath" -ForegroundColor Green
    Write-Host "  > Kopiowanie do lokalnego folderu..." -ForegroundColor Cyan
    Copy-Item "$MediaCachePath\$UBUNTU_ISO_NAME" $localIso -Force
    Copy-Item "$MediaCachePath\$VBOX_INSTALLER_NAME" $localVbox -Force
    Write-Host "  v Skopiowane" -ForegroundColor Green
} else {
    Write-Host "  ! Media nie znalezione - pobieranie z internetu (~15 min)" -ForegroundColor Yellow
    Write-Host ""
    if (-not $MediaCachePath) {
        Write-Host "  Gdzie zapisac pobrane pliki dla kolejnych instalacji?" -ForegroundColor Yellow
        Write-Host "  Wskaz folder OneDrive/SMB - inni zainstaluja szybciej." -ForegroundColor White
        Write-Host "  Enter = tylko lokalnie w $MEDIA_DIR" -ForegroundColor DarkGray
        Write-Host ""
        $userInput = Read-Host "  Sciezka cache (lub Enter)"
        if ($userInput -and $userInput.Trim() -ne "") {
            $MediaCachePath = $userInput.Trim().Trim('"').Trim("'")
        }
    }
    if ($MediaCachePath) {
        if (-not (Test-Path $MediaCachePath)) {
            New-Item -ItemType Directory -Path $MediaCachePath -Force | Out-Null
        }
        Write-Host "  v Cache: $MediaCachePath" -ForegroundColor Green
    } else {
        Write-Host "  Tylko lokalnie: $MEDIA_DIR" -ForegroundColor DarkGray
    }
}
W-Log "MediaCache=$MediaCachePath Local=$hasLocal Cache=$hasCache"
Write-Host ""

# --- Pobieranie bootstrap.ps1 ---
Write-Host "  > Pobieranie bootstrap.ps1 z GitHub..." -ForegroundColor Cyan
$bp = "$BASE_DIR\bootstrap.ps1"
$bpp = "$bp.partial"
if (Test-Path $bpp) { Remove-Item $bpp -Force }
try {
    Invoke-WebRequest -Uri $BOOTSTRAP_URL -OutFile $bpp -TimeoutSec 30 -UseBasicParsing
    $sz = (Get-Item $bpp).Length
    if ($sz -eq 0) { throw "empty" }
    Move-Item $bpp $bp -Force
    Write-Host "  v bootstrap.ps1 pobrany ($sz bytes)" -ForegroundColor Green
    W-Log "bootstrap.ps1: $sz bytes"
} catch {
    if (Test-Path $bpp) { Remove-Item $bpp -Force }
    Write-Host "  x Blad pobierania bootstrap.ps1: $_" -ForegroundColor Red
    exit 1
}

# --- Uruchomienie ---
Write-Host ""
Write-Host "  === Rozpoczecie instalacji STRUCTURA FACTOR ===" -ForegroundColor Cyan
Write-Host "  Klient:  $CLIENT" -ForegroundColor White
Write-Host "  Folder:  $BASE_DIR" -ForegroundColor White
Write-Host "  VM:      ${VM_RAM}MB RAM, $VM_CPU vCPU, $([math]::Round($VM_DISK/1024))GB" -ForegroundColor White
Write-Host "  Media:   $MEDIA_DIR" -ForegroundColor White
if ($MediaCachePath) { Write-Host "  Cache:   $MediaCachePath" -ForegroundColor White }
if ($EnableLUKS) { Write-Host "  LUKS:    wlaczony" -ForegroundColor White }
Write-Host ""

$ba = @("-Client", $CLIENT, "-DeployKeyPath", $deployKeyPath, "-MediaPath", $MEDIA_DIR)
if ($VM_RAM -ne 4096) { $ba += @("-VM_RAM", $VM_RAM) }
if ($VM_CPU -ne 2) { $ba += @("-VM_CPU", $VM_CPU) }
if ($VM_DISK -ne 40960) { $ba += @("-VM_DISK", $VM_DISK) }
if ($EnableLUKS) { $ba += @("-EnableLUKS", "-LUKSPassword", $LUKSPassword) }
if ($Quiet) { $ba += "-Quiet" }
if ($Verbose) { $ba += "-Verbose" }

W-Log "bootstrap args: $($ba -join ' ')"
Unblock-File -Path $bp -ErrorAction SilentlyContinue

$ec = 0
try {
    & $bp @ba
    $ec = $LASTEXITCODE
} catch {
    Write-Host "  x bootstrap.ps1 blad: $_" -ForegroundColor Red
    $ec = 1
}

# --- Zapisz media do cache po instalacji ---
if ($ec -eq 0 -and $MediaCachePath -and (Test-Path $MediaCachePath)) {
    $ci = "$MediaCachePath\$UBUNTU_ISO_NAME"
    $cv = "$MediaCachePath\$VBOX_INSTALLER_NAME"
    if ((Test-Path $localIso) -and -not (Test-Path $ci)) {
        Write-Host ""
        Write-Host "  > Kopiowanie media do cache..." -ForegroundColor Cyan
        Copy-Item $localIso $ci -Force
        Copy-Item $localVbox $cv -Force
        Write-Host "  v Media zapisane w cache: $MediaCachePath" -ForegroundColor Green
        W-Log "Media cached to: $MediaCachePath"
    }
}

# --- Podsumowanie ---
Write-Host ""
if ($ec -eq 0) {
    W-Log "=== Installation SUCCESS ==="
    Write-Host "  === INSTALACJA ZAKONCZONA ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Wszystko w: $BASE_DIR" -ForegroundColor White
    Write-Host "    Klucze:  $KEYS_DIR" -ForegroundColor DarkGray
    Write-Host "    Media:   $MEDIA_DIR" -ForegroundColor DarkGray
    Write-Host "    Logi:    $LOG_FILE" -ForegroundColor DarkGray
    if ($MediaCachePath) { Write-Host "    Cache:   $MediaCachePath" -ForegroundColor DarkGray }
} else {
    W-Log "=== Installation FAILED ($ec) ==="
    Write-Host "  === INSTALACJA NIEUDANA ===" -ForegroundColor Red
    Write-Host "  Log: $LOG_FILE" -ForegroundColor White
}
Write-Host ""
exit $ec