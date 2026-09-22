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
$BOOTSTRAP_URL = "https://cdn.jsdelivr.net/gh/structura-factor/structura-factor-launchers@eda4fa522bd4d9b09138ad1ca8ade3d19ca1a881/bootstrap.ps1"
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
# GitHub nie pozwala uzyc jednego deploy keya w dwoch repo, wiec instalka
# potrzebuje DWOCH kluczy: klienta (structura-clients-<client>) i core.
# Rozpoznajemy je po nazwie pliku; reszta idzie jako klucz klienta.
$coreDeployKeyPath = $null
if ($keyFiles) {
    # Wybor deterministyczny (Get-ChildItem sortuje alfabetycznie, wiec samo
    # "First 1" bralo stary plik 'deploy_key' zamiast 'deploy_key_client').
    $coreFile = $keyFiles | Where-Object { $_.Name -match 'core' } | Select-Object -First 1
    $clientFile = $keyFiles | Where-Object { $_.Name -match 'client' } | Select-Object -First 1
    if (-not $clientFile) {
        $clientFile = $keyFiles | Where-Object { $_.Name -notmatch 'core' -and $_.Name -ne 'deploy_key' } | Select-Object -First 1
    }
    if (-not $clientFile) {
        $clientFile = $keyFiles | Where-Object { $_.Name -notmatch 'core' } | Select-Object -First 1
    }
    if ($coreFile) {
        $coreDeployKeyPath = $coreFile.FullName
        Write-Host "  v Klucz core: klucze\$($coreFile.Name)" -ForegroundColor Green
    }
    $deployKeyPath = if ($clientFile) { $clientFile.FullName } else { $keyFiles[0].FullName }
    Write-Host "  v Klucz klienta: klucze\$(Split-Path $deployKeyPath -Leaf)" -ForegroundColor Green
    if (-not $coreFile) {
        Write-Host "  ! Brak klucza 'core' w $KEYS_DIR - klon structura-core padnie." -ForegroundColor Yellow
        Write-Host "    Skopiuj deploy_key_core (deploy key z repo structura-core)." -ForegroundColor Yellow
    }
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

# Ten sam test dla klucza core (jesli podany)
if ($coreDeployKeyPath) {
    $coreRaw = Get-Content $coreDeployKeyPath -Raw
    if ($coreRaw -match 'BEGIN OPENSSH PRIVATE KEY' -or $coreRaw -match 'BEGIN PRIVATE KEY') {
        Write-Host "  v Klucz core: zweryfikowany" -ForegroundColor Green
    } else {
        Write-Host "  x Klucz core nie jest kluczem prywatnym SSH: $coreDeployKeyPath" -ForegroundColor Red
        exit 1
    }
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

# --- VM power selection ---
Write-Host ""
Write-Host "  === Konfiguracja VM ===" -ForegroundColor Cyan
Write-Host "  Wybierz moc maszyny wirtualnej:" -ForegroundColor White
Write-Host "    1. Standard (4GB RAM, 2 vCPU) - dluzsza instalacja, mniej zasobow" -ForegroundColor DarkGray
Write-Host "    2. Boost (8GB RAM, 6 vCPU) - szybsza instalacja, wiecej zasobow" -ForegroundColor DarkGray
Write-Host ""
$vmPower = Read-Host "  Wybierz (1/2, domyslnie 1)"
if ($vmPower -eq "2") {
    $VM_RAM = 8192
    $VM_CPU = 6
    Write-Host "  v Boost: 8GB RAM, 6 vCPU" -ForegroundColor Green
} else {
    Write-Host "  v Standard: 4GB RAM, 2 vCPU" -ForegroundColor Green
}
Write-Host ""

# --- Media ---
# Filmy instalacyjne sa duze (~3.2 GB razem). Przy wdrozeniu u kilku osob
# w tej samej firmie nie ma sensu pobierac ich za kazdym razem - wystarczy
# jeden folder zsynchronizowany (OneDrive / SMB / pendrive) i wszyscy go wskaza.
Write-Host ""
Write-Host "  === Media instalacyjne ===" -ForegroundColor Cyan
Write-Host "  Potrzeba: Ubuntu 24.04 ISO (~3.1 GB) + VirtualBox (~119 MB)" -ForegroundColor White
Write-Host "  Mozesz wskazac folder z juz pobranymi plikami (OneDrive/SMB/pendrive)," -ForegroundColor DarkGray
Write-Host "  wtedy instalator je skopiuje zamiast pobierac z internetu." -ForegroundColor DarkGray
Write-Host ""

$localIso  = "$MEDIA_DIR\$UBUNTU_ISO_NAME"
$localVbox = "$MEDIA_DIR\$VBOX_INSTALLER_NAME"

# Znajdz plik po wzorcu (klient moze miec inna wersje niz oczekiwana)
function Find-MediaFile {
    param([string]$Dir, [string]$Pattern)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $null }
    return Get-ChildItem -LiteralPath $Dir -File -Filter $Pattern -ErrorAction SilentlyContinue |
           Sort-Object Length -Descending | Select-Object -First 1
}

$isoSrc  = $null
$vboxSrc = $null

# 1) lokalny C:\STRUCTURA\media (z poprzedniej instalacji)
if (-not $isoSrc)  { $isoSrc  = Find-MediaFile -Dir $MEDIA_DIR -Pattern 'ubuntu-*.iso' }
if (-not $vboxSrc) { $vboxSrc = Find-MediaFile -Dir $MEDIA_DIR -Pattern 'VirtualBox-*.exe' }

# 2) -MediaCachePath z parametru
if ($MediaCachePath) {
    if (-not $isoSrc)  { $isoSrc  = Find-MediaFile -Dir $MediaCachePath -Pattern 'ubuntu-*.iso' }
    if (-not $vboxSrc) { $vboxSrc = Find-MediaFile -Dir $MediaCachePath -Pattern 'VirtualBox-*.exe' }
}

# 3) ZAPYTAJ uzytkownika (zawsze gdy brakuje choc jednego pliku)
if (-not $isoSrc -or -not $vboxSrc) {
    Write-Host "  Media nie znalezione lokalnie." -ForegroundColor Yellow
    if ($isoSrc)  { Write-Host "    (ISO juz jest: $($isoSrc.Name))" -ForegroundColor DarkGray }
    if ($vboxSrc) { Write-Host "    (VirtualBox juz jest: $($vboxSrc.Name))" -ForegroundColor DarkGray }
    Write-Host ""
    Write-Host "  Masz folder z pobranymi plikami? Podaj sciezke." -ForegroundColor White
    Write-Host "  (np. C:\Users\ktos\OneDrive\STRUCTURA\media albo \\serwer\udzial\media)" -ForegroundColor DarkGray
    Write-Host "  Enter = pomin i pobierz z internetu" -ForegroundColor DarkGray
    Write-Host ""

    $tries = 0
    while ((-not $isoSrc -or -not $vboxSrc) -and $tries -lt 3) {
        $userInput = Read-Host "  Folder z mediami (lub Enter)"
        if (-not $userInput -or $userInput.Trim() -eq "") { break }
        $cand = $userInput.Trim().Trim('"').Trim("'")
        $tries++

        if (-not (Test-Path -LiteralPath $cand)) {
            Write-Host "    x Folder nie istnieje: $cand" -ForegroundColor Red
            continue
        }

        $isoFound  = Find-MediaFile -Dir $cand -Pattern 'ubuntu-*.iso'
        $vboxFound = Find-MediaFile -Dir $cand -Pattern 'VirtualBox-*.exe'

        if ($isoFound)  { $isoSrc  = $isoFound;  Write-Host "    v ISO: $($isoFound.Name)" -ForegroundColor Green }
        else            { Write-Host "    ! Brak pliku ubuntu-*.iso w tym folderze" -ForegroundColor Yellow }
        if ($vboxFound) { $vboxSrc = $vboxFound; Write-Host "    v VirtualBox: $($vboxFound.Name)" -ForegroundColor Green }
        else            { Write-Host "    ! Brak pliku VirtualBox-*.exe w tym folderze" -ForegroundColor Yellow }

        if ((-not $isoSrc -or -not $vboxSrc) -and $tries -lt 3) {
            Write-Host "    Sprobuj inny folder (Enter aby pominac)." -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

# Skopiuj znalezione pliki pod nazwy, ktorych oczekuje setup.ps1.
# UWAGA: nazwa pliku ma znaczenie - setup.ps1 szuka DOKLADNIE
# $UBUNTU_ISO_NAME / $VBOX_INSTALLER_NAME, dlatego kopiujemy (nie linkujemy).
if ($isoSrc) {
    if ($isoSrc.FullName -ne $localIso) {
        Write-Host "  > Kopiowanie ISO ($([math]::Round($isoSrc.Length/1GB,2)) GB)..." -ForegroundColor Cyan
        Copy-Item $isoSrc.FullName $localIso -Force
    }
    Write-Host "  v ISO gotowe: $UBUNTU_ISO_NAME" -ForegroundColor Green
}
if ($vboxSrc) {
    if ($vboxSrc.FullName -ne $localVbox) {
        Write-Host "  > Kopiowanie VirtualBox..." -ForegroundColor Cyan
        Copy-Item $vboxSrc.FullName $localVbox -Force
    }
    Write-Host "  v VirtualBox gotowy: $VBOX_INSTALLER_NAME" -ForegroundColor Green
}

# Jesli uzytkownik wskazal folder z WLASNYMI plikami, nie ma sensu wymagac
# zgodnosci SHA256 z versions.txt - jego wersja Ubuntu/VBox jest w porzadku.
if ($isoSrc -or $vboxSrc) { $SkipMediaVerify = $true }

$mediaCacheOut = $null   # folder, do ktorego zapiszemy pobrane pliki (jesli trzeba pobierac)
if (-not $isoSrc -or -not $vboxSrc) {
    Write-Host "  ! Brakujace pliki zostana pobrane z internetu (~15 min)." -ForegroundColor Yellow
    if ($MediaCachePath) {
        $mediaCacheOut = $MediaCachePath
        if (-not (Test-Path $MediaCachePath)) { New-Item -ItemType Directory -Path $MediaCachePath -Force | Out-Null }
    } else {
        $cacheAnswer = Read-Host "  Zapisac pobrane pliki do wspoldzielonego folderu? (sciezka lub Enter)"
        if ($cacheAnswer -and $cacheAnswer.Trim() -ne "") {
            $mediaCacheOut = $cacheAnswer.Trim().Trim('"').Trim("'")
            if (-not (Test-Path $mediaCacheOut)) { New-Item -ItemType Directory -Path $mediaCacheOut -Force | Out-Null }
        }
    }
    if ($mediaCacheOut) { Write-Host "  v Cache dla pobranych: $mediaCacheOut" -ForegroundColor Green }
}

$MediaCachePath = $mediaCacheOut
$hasLocal = (Test-Path $localIso) -and (Test-Path $localVbox)
W-Log "Media: iso=$($isoSrc.FullName) vbox=$($vboxSrc.FullName) local=$hasLocal"
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
if ($coreDeployKeyPath) { $ba += @("-CoreDeployKeyPath", "'$coreDeployKeyPath'") }
if ($SkipMediaVerify) { $ba += "-SkipMediaVerify" }
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