# ============================================================================
#  Install-STRUCTURA-FACTOR.ps1
#  Jeden plik - wszystko w jednym. Pobiera bootstrap, szuka klucza, stawia VM.
#  Uruchom jako Administrator.
# ============================================================================

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\STRUCTURA",

    [string]$MediaCachePath,
    [int]$VM_RAM = 4096,
    [int]$VM_CPU = 2,
    [int]$VM_DISK = 40960,
    [switch]$EnableLUKS,
    [string]$LUKSPassword,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# --- Stale ---
$CLIENT = "sawaryn"
$LAUNCHER_REPO = "structura-factor/structura-factor-launchers"
$BOOTSTRAP_URL = "https://cdn.jsdelivr.net/gh/structura-factor/structura-factor-launchers@b6237094087ac3e79584fc3d85eeb3e99eb4cf21/bootstrap.ps1"
$BASE_DIR = $InstallPath
$KEYS_DIR = "$BASE_DIR\klucze"
$MEDIA_DIR = "$BASE_DIR\media"
$LOGS_DIR = "$BASE_DIR\logs"
$LOG_FILE = "$LOGS_DIR\setup.log"
$UBUNTU_ISO_NAME = "ubuntu-24.04.5-live-server-amd64.iso"
$VBOX_INSTALLER_NAME = "VirtualBox-7.1.16-172425-Win.exe"

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
Write-Host "|  Folder: $InstallPath                                        |" -ForegroundColor White
Write-Host "+============================================================+" -ForegroundColor Cyan
Write-Host ""

# --- Pytanie o sciezke instalacyjna ---
if (-not $InstallPath -or $InstallPath -eq "C:\STRUCTURA") {
    Write-Host "  Domyslny folder instalacyjny: C:\STRUCTURA" -ForegroundColor White
    Write-Host "  Nacisnij Enter aby zaakceptowac, lub wpisz inna sciezke (np. D:\STRUCTURA)" -ForegroundColor DarkGray
    Write-Host ""
    $pathInput = Read-Host "  Sciezka instalacyjna (lub Enter)"
    if ($pathInput -and $pathInput.Trim() -ne "") {
        $InstallPath = $pathInput.Trim().Trim('"').Trim("'")
    }
}

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

# --- Admin check: zanim zapyta o klucz ---
Write-Host "  > Sprawdzanie uprawnien administratora..." -ForegroundColor Cyan
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "  x Wymagane uprawnienia administratora." -ForegroundColor Red
    Write-Host "  Kliknij prawym na PowerShell -> Uruchom jako administrator" -ForegroundColor Yellow
    exit 1
}
Write-Host "  v Admin: tak" -ForegroundColor Green
W-Log "Admin: OK"

# --- Deploy key: zapytaj zanim cokolwiek pobierze ---
Write-Host ""
Write-Host "  === Klucz deploy SSH ===" -ForegroundColor Cyan
Write-Host "  Do instalacji potrzebny jest klucz prywatny SSH (deploy key)." -ForegroundColor White
Write-Host "  Plik klucza zostal przekazany osobno (email, pendrive, itp.)." -ForegroundColor White
Write-Host ""
Write-Host "  Opcje:" -ForegroundColor White
Write-Host "    1. Wskaz sciezke do pliku klucza (np. C:\Users\ja\Desktop\deploy_key)" -ForegroundColor DarkGray
Write-Host "    2. Wklej klucz do folderu $KEYS_DIR i nacisnij Enter" -ForegroundColor DarkGray
Write-Host "    3. Wklej zawartosc klucza tutaj (skrypt zapisze go automatycznie)" -ForegroundColor DarkGray
Write-Host ""
$deployKeyPath = $null

# Najpierw sprawdz czy juz cos jest w klucze\
$keyFiles = Get-ChildItem -Path $KEYS_DIR -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -notmatch '\.pub$' -and $_.Name -notmatch '\.txt$' -and $_.Name -notmatch '\.md$'
}
if ($keyFiles) {
    $deployKeyPath = $keyFiles[0].FullName
    Write-Host "  v Znaleziono klucz w folderze: klucze\$($keyFiles[0].Name)" -ForegroundColor Green
} else {
    $keyChoice = Read-Host "  Wybierz opcje (1/2/3)"
    switch ($keyChoice) {
        "1" {
            $keyPathInput = Read-Host "  Sciezka do pliku klucza"
            if ($keyPathInput -and $keyPathInput.Trim() -ne "") {
                $keyPathInput = $keyPathInput.Trim().Trim('"').Trim("'")
                if (Test-Path $keyPathInput) {
                    $deployKeyPath = $keyPathInput
                    Write-Host "  v Klucz: $deployKeyPath" -ForegroundColor Green
                } else {
                    Write-Host "  x Plik nie istnieje: $keyPathInput" -ForegroundColor Red
                    exit 1
                }
            } else {
                Write-Host "  x Nie podano sciezki." -ForegroundColor Red
                exit 1
            }
        }
        "2" {
            Write-Host "  Wklej plik do $KEYS_DIR i nacisnij Enter..." -ForegroundColor Yellow
            Read-Host "  Gotowe? (Enter)"
            $keyFiles = Get-ChildItem -Path $KEYS_DIR -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -notmatch '\.pub$' -and $_.Name -notmatch '\.txt$' -and $_.Name -notmatch '\.md$'
            }
            if ($keyFiles) {
                $deployKeyPath = $keyFiles[0].FullName
                Write-Host "  v Klucz: klucze\$($keyFiles[0].Name)" -ForegroundColor Green
            } else {
                Write-Host "  x Nadal nie znaleziono klucza w $KEYS_DIR" -ForegroundColor Red
                exit 1
            }
        }
        "3" {
            Write-Host "  Wklej zawartosc klucza (rozpoczyna sie od -----BEGIN...):" -ForegroundColor Yellow
            Write-Host "  Zakoncz pusta linia i Enter:" -ForegroundColor DarkGray
            $keyLines = @()
            while ($true) {
                $line = Read-Host
                if ($line -eq "") { break }
                $keyLines += $line
            }
            if ($keyLines.Count -gt 0) {
                $keyContent = $keyLines -join "`n"
                $deployKeyPath = "$KEYS_DIR\deploy_key"
                $keyContent | Out-File -FilePath $deployKeyPath -Encoding ASCII -NoNewline
                Write-Host "  v Klucz zapisany: $deployKeyPath" -ForegroundColor Green
            } else {
                Write-Host "  x Pusty klucz." -ForegroundColor Red
                exit 1
            }
        }
        default {
            Write-Host "  x Niepoprawny wybor." -ForegroundColor Red
            exit 1
        }
    }
}

# Weryfikuj zawartosc klucza - zatrzymaj jesli to nie klucz prywatny
$keyRaw = Get-Content $deployKeyPath -Raw
if ($keyRaw -notmatch 'BEGIN OPENSSH PRIVATE KEY' -and $keyRaw -notmatch 'BEGIN PRIVATE KEY') {
    Write-Host "  x To nie jest klucz prywatny SSH." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Wklejony tekst zaczyna sie od 'ssh-ed25519' - to jest KLUCZ PUBLICZNY." -ForegroundColor Yellow
    Write-Host "  Potrzebny jest KLUCZ PRYWATNY - zaczyna sie od:" -ForegroundColor Yellow
    Write-Host "    -----BEGIN OPENSSH PRIVATE KEY-----" -ForegroundColor White
    Write-Host ""
    Write-Host "  Klucz prywatny to plik bez rozszerzenia .pub" -ForegroundColor DarkGray
    Write-Host "  Usun zly plik z $KEYS_DIR i uruchom skrypt ponownie." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "  v Klucz prywatny SSH: zweryfikowany" -ForegroundColor Green
}
W-Log "DeployKey: $deployKeyPath"

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
Write-Host "  > Sprawdzanie wolnego miejsca na dysku..." -ForegroundColor Cyan
$installDrive = $InstallPath.Substring(0,1)
    $freeGB = [math]::Round((Get-PSDrive -Name $installDrive).Free / 1GB)
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
Write-Host "  Potrzeba: Ubuntu 24.04 ISO (~3.1 GB) + VirtualBox 7.1.16 (~119 MB)" -ForegroundColor White
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
        # Re-check: does media exist in the cache path the user just entered?
        $cacheIso = "$MediaCachePath\$UBUNTU_ISO_NAME"
        $cacheVbox = "$MediaCachePath\$VBOX_INSTALLER_NAME"
        if ((Test-Path $cacheIso) -and (Test-Path $cacheVbox)) {
            Write-Host "  v Media znalezione w cache - kopiowanie do folderu lokalnego..." -ForegroundColor Green
            Copy-Item $cacheIso $localIso -Force
            Copy-Item $cacheVbox $localVbox -Force
            Write-Host "  v Skopiowane" -ForegroundColor Green
            $hasLocal = $true
        }
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

$ba = @("-Client", $CLIENT, "-DeployKeyPath", "'$deployKeyPath'", "-MediaPath", "'$MEDIA_DIR'", "-InstallPath", "'$BASE_DIR'")
if ($VM_RAM -ne 4096) { $ba += @("-VM_RAM", $VM_RAM) }
if ($VM_CPU -ne 2) { $ba += @("-VM_CPU", $VM_CPU) }
if ($VM_DISK -ne 40960) { $ba += @("-VM_DISK", $VM_DISK) }
if ($EnableLUKS) { $ba += @("-EnableLUKS", "-LUKSPassword", "'$LUKSPassword'") }
# Nie przekazuj -Quiet/-Verbose - konflikt z CmdletBinding w bootstrap.ps1

W-Log "bootstrap args: $($ba -join ' ')"
Unblock-File -Path $bp -ErrorAction SilentlyContinue

# Build command string and execute via iex - more reliable than splatting with & operator
$cmdStr = "& '$bp' " + ($ba -join ' ')
W-Log "Command: $cmdStr"

$ec = 0
try {
    Invoke-Expression $cmdStr
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