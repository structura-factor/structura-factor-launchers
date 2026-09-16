# ============================================================================
#  Install-STRUCTURA-FACTOR.ps1
#  Skrypt wdrozeniowy STRUCTURA FACTOR - Personal Assistant prawniczy
#
#  Klient: Sawaryn i Partnerzy - Kancelaria Prawna
#  Wersja: 1.1
#
#  Wszystko instaluje sie w jednym folderze na dysku C:
#    C:\STRUCTURA\
#      Install-STRUCTURA-FACTOR.ps1   <- ten skrypt
#      klucze\                         <- wklej tu deploy key
#      media\                          <- pobrane ISO + VBox installer
#      logs\                           <- logi instalacji
#
#  Skrypt:
#    1. Tworzy strukture folderow
#    2. Weryfikuje deploy key, admin, RAM, dysk, internet
#    3. Zarzadza mediami (pobierz z internetu ALBO uzyj z folderu)
#    4. Pyta gdzie zapisac pobrane media (dla kolejnych instalacji)
#    5. Pobiera bootstrap.ps1 z GitHub i uruchamia instalacje VM
#
#  Uzycie:
#    .\Install-STRUCTURA-FACTOR.ps1
#    .\Install-STRUCTURA-FACTOR.ps1 -MediaCachePath "C:\Users\premek\OneDrive\STRUCTURA\media\"
#    .\Install-STRUCTURA-FACTOR.ps1 -VM_RAM 8192 -VM_CPU 4 -VM_DISK 80
#
#  Parametry:
#    -MediaCachePath  [opcjonalny] Gdzie zapisac pobrane media (ISO, VBox).
#                                 Default: C:\STRUCTURA\media\
#                                 Wskaz folder OneDrive/network - przyspieszy
#                                 kolejne instalacje u innych osob.
#    -VM_RAM          [opcjonalny] RAM VM w MB (domyslnie: 4096)
#    -VM_CPU          [opcjonalny] Liczba vCPU (domyslnie: 2)
#    -VM_DISK         [opcjonalny] Rozmiar dysku VM w MB (domyslnie: 40960)
#    -EnableLUKS      [opcjonalny] Wlacza LUKS encryption (GDPR/RODO)
#    -LUKSPassword    [opcjonalny] Haslo LUKS (wymagane jesli -EnableLUKS)
#    -Quiet           [opcjonalny] Tryb cichy
#    -Verbose         [opcjonalny] Tryb verbose
#
#  Log: C:\STRUCTURA\logs\setup.log
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$MediaCachePath,

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
    [switch]$Quiet,

    [Parameter(Mandatory = $false)]
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Stale
# ============================================================================

$CLIENT = "sawaryn"
$LAUNCHER_REPO = "structura-factor/structura-factor-launchers"
$GITHUB_RAW = "https://raw.githubusercontent.com"
$BOOTSTRAP_URL = "$GITHUB_RAW/$LAUNCHER_REPO/main/bootstrap.ps1"

# Glowny folder instalacyjny - wszystko w jednym miejscu
$BASE_DIR = "C:\STRUCTURA"
$KEYS_DIR = "$BASE_DIR\klucze"
$MEDIA_DIR = "$BASE_DIR\media"
$LOGS_DIR = "$BASE_DIR\logs"
$LOG_FILE = "$LOGS_DIR\setup.log"

# Pliki media (nazwy musza sie zgadzac z versions.txt w repo)
$UBUNTU_ISO_NAME = "ubuntu-24.04.1-server-amd64.iso"
$VBOX_INSTALLER_NAME = "VirtualBox-7.1.4-Win.exe"

# Kolory ANSI
$CYAN = "`e[36m"
$GREEN = "`e[32m"
$RED = "`e[31m"
$YELLOW = "`e[33m"
$WHITE = "`e[37m"
$RESET = "`e[0m"
$DIM = "`e[2m"

# ============================================================================
# Funkcje pomocnicze
# ============================================================================

function Write-Step {
    param([string]$Message)
    if (-not $Quiet) { Write-Host "  ${CYAN}>${RESET} $Message" -ForegroundColor Cyan }
}

function Write-OK {
    param([string]$Message)
    Write-Host "  ${GREEN}v${RESET} $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  ${YELLOW}!${RESET} $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "  ${RED}x${RESET} $Message" -ForegroundColor Red
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    if (Test-Path $LOGS_DIR) {
        Add-Content -Path $LOG_FILE -Value $line
    }
}

function Write-Banner {
    $width = 64
    $top = "+$("=" * ($width - 2))+"
    $bot = "+$("=" * ($width - 2))+"
    Write-Host ""
    Write-Host $top -ForegroundColor Cyan
    $title = "STRUCTURA FACTOR - Instalator"
    $centerTitle = $title.PadLeft([math]::Floor(($width - 2 + $title.Length) / 2)).PadRight($width - 2)
    Write-Host "|$centerTitle|" -ForegroundColor Cyan
    $subtitle = "Personal Assistant prawniczy"
    $centerSub = $subtitle.PadLeft([math]::Floor(($width - 2 + $subtitle.Length) / 2)).PadRight($width - 2)
    Write-Host "|$centerSub|" -ForegroundColor Cyan
    $emptyLine = " " * ($width - 2)
    Write-Host "|$emptyLine|" -ForegroundColor Cyan
    $clientLine = "  Klient: Sawaryn i Partnerzy".PadRight($width - 2)
    Write-Host "|$clientLine|" -ForegroundColor White
    $dirLine = "  Folder: $BASE_DIR".PadRight($width - 2)
    Write-Host "|$dirLine|" -ForegroundColor White
    Write-Host $bot -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================================
# Tworzenie struktury folderow
# ============================================================================

Write-Banner

Write-Step "Tworzenie struktury folderow: $BASE_DIR"
$dirs = @($BASE_DIR, $KEYS_DIR, $MEDIA_DIR, $LOGS_DIR)
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}
Write-OK "Struktura folderow gotowa"
Write-Host ""
Write-Host "  Struktura:" -ForegroundColor White
Write-Host "    $BASE_DIR\" -ForegroundColor DarkGray
Write-Host "      Install-STRUCTURA-FACTOR.ps1   (ten skrypt)" -ForegroundColor DarkGray
Write-Host "      klucze\                         (wklej tu deploy key)" -ForegroundColor DarkGray
Write-Host "      media\                          (pobrane ISO + VBox)" -ForegroundColor DarkGray
Write-Host "      logs\                           (logi instalacji)" -ForegroundColor DarkGray
Write-Host ""

Write-Log "=== Install-STRUCTURA-FACTOR.ps1 v1.1 started ==="
Write-Log "Base dir: $BASE_DIR"
Write-Log "VM_RAM: $VM_RAM, VM_CPU: $VM_CPU, VM_DISK: $VM_DISK, EnableLUKS: $EnableLUKS"

# ============================================================================
# Krok 0: Deploy key - szukaj w klucze\ lub zapytaj
# ============================================================================

Write-Step "Szukanie deploy key w $KEYS_DIR\..."
$deployKeyPath = $null

# Szukaj pliku klucza w folderze klucze\
$keyFiles = Get-ChildItem -Path $KEYS_DIR -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -notmatch '\.pub$' -and $_.Name -notmatch '\.txt$' -and $_.Name -notmatch '\.md$'
}

if ($keyFiles) {
    # Bier pierwszy klucz prywatny znaleziony
    $deployKeyPath = $keyFiles[0].FullName
    $keyName = $keyFiles[0].Name
    Write-OK "Deploy key znaleziony: klucze\$keyName"
} else {
    Write-Warn "Nie znaleziono deploy key w $KEYS_DIR\"
    Write-Host ""
    Write-Host "  Wklej plik klucza prywatnego SSH do folderu:" -ForegroundColor Yellow
    Write-Host "    $KEYS_DIR\" -ForegroundColor White
    Write-Host ""
    Write-Host "  Klucz to plik bez rozszerzenia (lub z rozszerzeniem innym niz .pub)" -ForegroundColor DarkGray
    Write-Host "  Nastepnie uruchom skrypt ponownie." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# Weryfikuj zawartosc klucza
$keyContent = Get-Content $deployKeyPath -Raw
if ($keyContent -notmatch 'BEGIN OPENSSH PRIVATE KEY' -and $keyContent -notmatch 'BEGIN PRIVATE KEY') {
    Write-Warn "Plik nie wyglada na klucz prywatny SSH. Kontynuje, ale clone moze sie nie udac."
} else {
    Write-OK "Klucz prywatny SSH: zweryfikowany"
}
Write-Log "Deploy key: $deployKeyPath"

# ============================================================================
# Krok 1: Uprawnienia administratora
# ============================================================================

Write-Step "Sprawdzanie uprawnien administratora..."
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "Wymagane uprawnienia administratora."
    Write-Host ""
    Write-Host "  Kliknij prawym na PowerShell -> Uruchom jako administrator" -ForegroundColor Yellow
    Write-Host "  i uruchom skrypt ponownie z folderu $BASE_DIR" -ForegroundColor White
    Write-Host ""
    exit 1
}
Write-OK "Uprawnienia administratora: tak"
Write-Log "Admin rights: OK"

# ============================================================================
# Krok 2: RAM
# ============================================================================

Write-Step "Sprawdzanie pamieci RAM..."
$totalRAM = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($totalRAM -lt 16) {
    Write-Err "Zbyt malo RAM: ${totalRAM} GB (wymagane min. 16 GB, zalecane 32 GB)"
    exit 1
}
Write-OK "RAM: ${totalRAM} GB"
Write-Log "RAM: ${totalRAM} GB"

# ============================================================================
# Krok 3: Miejsce na dysku
# ============================================================================

Write-Step "Sprawdzanie wolnego miejsca na dysku C:..."
$systemDrive = (Get-PSDrive -Name C)
$freeDiskGB = [math]::Round($systemDrive.Free / 1GB)
$diskNeededGB = [math]::Round($VM_DISK / 1024) + 10
if ($freeDiskGB -lt $diskNeededGB) {
    Write-Warn "Wolne miejsce: ${freeDiskGB} GB (zalecane min. ${diskNeededGB} GB)"
} else {
    Write-OK "Wolne miejsce: ${freeDiskGB} GB"
}
Write-Log "Free disk C: ${freeDiskGB} GB"

# ============================================================================
# Krok 4: Internet
# ============================================================================

Write-Step "Sprawdzanie polaczenia internetowego..."
try {
    $resp = Invoke-WebRequest -Uri "https://github.com" -TimeoutSec 10 -UseBasicParsing -ErrorAction SilentlyContinue
    Write-OK "Polaczenie internetowe: tak"
} catch {
    Write-Err "Brak polaczenia internetowego. Instalacja wymaga dostepu do GitHub."
    exit 1
}
Write-Log "Internet: OK"

# ============================================================================
# Krok 5: LUKS password check
# ============================================================================

if ($EnableLUKS -and -not $LUKSPassword) {
    Write-Err "LUKS wlaczony, ale brak hasla. Uzyj -LUKSPassword lub usun -EnableLUKS."
    exit 1
}

# ============================================================================
# Krok 6: Zarzadzanie mediami - gdzie pobrac / gdzie zapisac
# ============================================================================

Write-Host ""
Write-Host "  ${CYAN}=== Media instalacyjne ===${RESET}" -ForegroundColor Cyan
Write-Host "  Pliki potrzebne do instalacji:" -ForegroundColor White
Write-Host "    - Ubuntu 24.04 Server ISO (~2.5 GB)" -ForegroundColor DarkGray
Write-Host "    - VirtualBox 7.1.4 Installer (~100 MB)" -ForegroundColor DarkGray
Write-Host ""

# Sprawdz czy media juz sa w lokalnym folderze media\
$localIsoPath = "$MEDIA_DIR\$UBUNTU_ISO_NAME"
$localVboxPath = "$MEDIA_DIR\$VBOX_INSTALLER_NAME"
$hasLocalMedia = (Test-Path $localIsoPath) -and (Test-Path $localVboxPath)

# Sprawdz czy MediaCachePath ma media
$hasCacheMedia = $false
$cacheIsoPath = $null
$cacheVboxPath = $null
if ($MediaCachePath -and (Test-Path $MediaCachePath)) {
    $cacheIsoPath = "$MediaCachePath\$UBUNTU_ISO_NAME"
    $cacheVboxPath = "$MediaCachePath\$VBOX_INSTALLER_NAME"
    $hasCacheMedia = (Test-Path $cacheIsoPath) -and (Test-Path $cacheVboxPath)
}

if ($hasLocalMedia) {
    Write-OK "Media znalezione w lokalnym folderze: $MEDIA_DIR\"
    Write-Host "    Pliki beda uzyte bez pobierania." -ForegroundColor DarkGray
} elseif ($hasCacheMedia) {
    Write-OK "Media znalezione w cache: $MediaCachePath\"
    Write-Step "Kopiowanie media do folderu lokalnego..."
    Copy-Item $cacheIsoPath $localIsoPath -Force
    Copy-Item $cacheVboxPath $localVboxPath -Force
    Write-OK "Media skopiowane do $MEDIA_DIR\"
} else {
    # Nie ma media - trzeba pobrac. Zapytaj gdzie zapisac dla przyszlych instalacji
    Write-Warn "Media nie znalezione. Pliki zostana pobrane z internetu (~15 min)."
    Write-Host ""

    if (-not $MediaCachePath) {
        Write-Host "  Gdzie zapisac pobrane pliki dla kolejnych instalacji?" -ForegroundColor Yellow
        Write-Host "  Wskaz folder sieciowy (OneDrive, SMB) - inni skorzystaja i zainstaluja szybciej." -ForegroundColor White
        Write-Host "  Nacisnij Enter aby zapisac tylko lokalnie w $MEDIA_DIR\" -ForegroundColor DarkGray
        Write-Host ""
        $userInput = Read-Host "  Sciezka cache (np. C:\Users\premek\OneDrive\STRUCTURA\media\)"

        if ($userInput -and $userInput.Trim() -ne "") {
            $MediaCachePath = $userInput.Trim()
            # Usun otaczajace cudzyslowy jesli sa
            $MediaCachePath = $MediaCachePath.Trim('"').Trim("'")
        }
    }

    if ($MediaCachePath) {
        if (-not (Test-Path $MediaCachePath)) {
            Write-Step "Tworzenie folderu cache: $MediaCachePath"
            New-Item -ItemType Directory -Path $MediaCachePath -Force | Out-Null
        }
        Write-OK "Cache media: $MediaCachePath"
        Write-Host "    Pobrane pliki zostana zapisane takze tutaj dla innych instalacji." -ForegroundColor DarkGray
    } else {
        Write-Host "  Pliki zostana zapisane tylko lokalnie w $MEDIA_DIR\" -ForegroundColor DarkGray
    }
}
Write-Log "MediaCachePath: $MediaCachePath"
Write-Log "HasLocalMedia: $hasLocalMedia, HasCacheMedia: $hasCacheMedia"
Write-Host ""

# ============================================================================
# Krok 7: Pobieranie bootstrap.ps1
# ============================================================================

Write-Step "Pobieranie bootstrap.ps1 z GitHub..."
Write-Host "    URL: $BOOTSTRAP_URL" -ForegroundColor DarkGray

$bootstrapPath = "$BASE_DIR\bootstrap.ps1"
$bootstrapPartial = "$bootstrapPath.partial"

if (Test-Path $bootstrapPartial) { Remove-Item $bootstrapPartial -Force }

try {
    Invoke-WebRequest -Uri $BOOTSTRAP_URL -OutFile $bootstrapPartial -TimeoutSec 30 -UseBasicParsing
    $fileSize = (Get-Item $bootstrapPartial).Length
    if ($fileSize -eq 0) { throw "Downloaded file is empty" }
    Move-Item $bootstrapPartial $bootstrapPath -Force
    Write-OK "bootstrap.ps1 pobrany ($fileSize bytes)"
    Write-Log "bootstrap.ps1 downloaded ($fileSize bytes)"
} catch {
    if (Test-Path $bootstrapPartial) { Remove-Item $bootstrapPartial -Force }
    Write-Err "Nie udalo sie pobrac bootstrap.ps1: $_"
    exit 1
}

# ============================================================================
# Krok 8: Przygotowanie argumentow i uruchomienie
# ============================================================================

Write-Host ""
Write-Host "  ${CYAN}=== Rozpoczecie instalacji STRUCTURA FACTOR ===${RESET}" -ForegroundColor Cyan
Write-Host "  Klient:    $CLIENT" -ForegroundColor White
Write-Host "  Folder:    $BASE_DIR" -ForegroundColor White
Write-Host "  VM:        ${VM_RAM}MB RAM, $VM_CPU vCPU, $([math]::Round($VM_DISK/1024))GB dysk" -ForegroundColor White
Write-Host "  Media:     $MEDIA_DIR" -ForegroundColor White
if ($MediaCachePath) { Write-Host "  Cache:     $MediaCachePath" -ForegroundColor White }
if ($EnableLUKS) { Write-Host "  LUKS:      wlaczony" -ForegroundColor White }
Write-Host ""

# Bootstrap przyjmuje -MediaPath (skad czytac media) i -DeployKeyPath
$bootstrapArgs = @(
    "-Client", $CLIENT,
    "-DeployKeyPath", $deployKeyPath,
    "-MediaPath", $MEDIA_DIR
)

if ($VM_RAM -ne 4096) { $bootstrapArgs += @("-VM_RAM", $VM_RAM) }
if ($VM_CPU -ne 2) { $bootstrapArgs += @("-VM_CPU", $VM_CPU) }
if ($VM_DISK -ne 40960) { $bootstrapArgs += @("-VM_DISK", $VM_DISK) }
if ($EnableLUKS) {
    $bootstrapArgs += "-EnableLUKS"
    $bootstrapArgs += @("-LUKSPassword", $LUKSPassword)
}
if ($Quiet) { $bootstrapArgs += "-Quiet" }
if ($Verbose) { $bootstrapArgs += "-Verbose" }

Write-Log "Executing bootstrap.ps1 with args: $($bootstrapArgs -join ' ')"

# Unblock pobranego skryptu
Unblock-File -Path $bootstrapPath -ErrorAction SilentlyContinue

# Uruchom bootstrap
$exitCode = 0
try {
    & $bootstrapPath @bootstrapArgs
    $exitCode = $LASTEXITCODE
} catch {
    Write-Err "bootstrap.ps1 nie wykonal sie: $_"
    $exitCode = 1
}

# ============================================================================
# Krok 9: Po instalacji - zapisz media do cache dla innych
# ============================================================================

if ($exitCode -eq 0 -and $MediaCachePath -and (Test-Path $MediaCachePath)) {
    # Skopiuj pobrane media do cache (jesli jeszcze ich tam nie ma)
    $cacheIsoPath = "$MediaCachePath\$UBUNTU_ISO_NAME"
    $cacheVboxPath = "$MediaCachePath\$VBOX_INSTALLER_NAME"

    if ((Test-Path $localIsoPath) -and -not (Test-Path $cacheIsoPath)) {
        Write-Host ""
        Write-Step "Kopiowanie media do cache dla kolejnych instalacji..."
        Copy-Item $localIsoPath $cacheIsoPath -Force
        Copy-Item $localVboxPath $cacheVboxPath -Force
        Write-OK "Media zapisane w cache: $MediaCachePath"
        Write-Host "  Inne osoby moga wskazac ten folder przez -MediaCachePath" -ForegroundColor DarkGray
        Write-Log "Media cached to: $MediaCachePath"
    }
}

# ============================================================================
# Krok 10: Podsumowanie
# ============================================================================

Write-Host ""
if ($exitCode -eq 0) {
    Write-Log "=== Installation completed successfully ==="
    Write-Host "  ${GREEN}=== INSTALACJA ZAKONCZONA ===${RESET}" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Wszystko jest w: $BASE_DIR" -ForegroundColor White
    Write-Host "    Skrypt:      $BASE_DIR\Install-STRUCTURA-FACTOR.ps1" -ForegroundColor DarkGray
    Write-Host "    Klucze:      $KEYS_DIR\" -ForegroundColor DarkGray
    Write-Host "    Media:       $MEDIA_DIR\" -ForegroundColor DarkGray
    Write-Host "    Logi:        $LOG_FILE" -ForegroundColor DarkGray
    if ($MediaCachePath) {
        Write-Host "    Cache media: $MediaCachePath (dla innych instalacji)" -ForegroundColor DarkGray
    }
} else {
    Write-Log "=== Installation FAILED (exit code $exitCode) ==="
    Write-Host "  ${RED}=== INSTALACJA NIEUDANA ===${RESET}" -ForegroundColor Red
    Write-Host "  Log: $LOG_FILE" -ForegroundColor White
    Write-Host "  Sprawdz log dla szczegolow." -ForegroundColor White
}
Write-Host ""

exit $exitCode