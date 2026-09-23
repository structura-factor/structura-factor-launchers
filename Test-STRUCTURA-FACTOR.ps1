<#
    Test-STRUCTURA-FACTOR.ps1
    STRUCTURA FACTOR - instalacja na czystej maszynie klienta.

    CO ROBI:
      1. zaklada C:\STRUCTURA (klucze / media / logs)
      2. znajduje klucze deploy (core + client) - lokalnie albo pyta o folder
      3. pobiera instalator z GitHuba (staly pin) i uruchamia go
      4. instalator pyta o sciezke, moc VM i folder mediow

    JAK URUCHOMIC (PowerShell jako Administrator):
      powershell -ExecutionPolicy Bypass -File ".\Test-STRUCTURA-FACTOR.ps1"

    KLUCZE:
      Poloz pliki kluczy obok tego skryptu, w podfolderze "klucze\",
      albo wskaz ich folder parametrem -KeysPath.
      Nazwa pliku z "core" = klucz do repo structura-core, pozostale = klient.
      Jesli kluczy nie znajdzie, skrypt zapyta o folder.

      .\Test-STRUCTURA-FACTOR.ps1 -KeysPath "D:\od_premka\klucze"
#>

[CmdletBinding()]
param(
    # Folder z plikami kluczy (opcjonalnie - skrypt szuka tez sam)
    [string]$KeysPath,

    # Folder z pobranym Ubuntu ISO + VirtualBox (opcjonalnie - instalator zapyta)
    [string]$MediaCachePath
)

$ErrorActionPreference = 'Stop'

$BASE_DIR = "C:\STRUCTURA"
$KEYS_DIR = "$BASE_DIR\klucze"
$MEDIA_DIR = "$BASE_DIR\media"
$LOGS_DIR = "$BASE_DIR\logs"

# Staly pin instalatora - test powtarzalny.
# lancuch: Test -> Install @5527cc0 -> bootstrap @e45edad -> setup.ps1 @c231b77
$INSTALL_URL = "https://cdn.jsdelivr.net/gh/structura-factor/structura-factor-launchers@c39ba8ec350dfbd25cf55b57c2cca6d04502440d/Install-STRUCTURA-FACTOR.ps1"

Write-Host ""
Write-Host "+============================================================+" -ForegroundColor Cyan
Write-Host "|  STRUCTURA FACTOR - INSTALACJA                              |" -ForegroundColor Cyan
Write-Host "|  Sawaryn i Partnerzy - Kancelaria Prawna                    |" -ForegroundColor Cyan
Write-Host "+============================================================+" -ForegroundColor Cyan
Write-Host ""

# --- Uprawnienia administratora ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "  x Wymagane uprawnienia administratora." -ForegroundColor Red
    Write-Host "    Kliknij prawym na PowerShell -> 'Uruchom jako administrator'." -ForegroundColor Yellow
    exit 1
}
Write-Host "  v Administrator: tak" -ForegroundColor Green

# --- Struktura folderow ---
Write-Host "  > Tworzenie struktury folderow..." -ForegroundColor Cyan
@($BASE_DIR, $KEYS_DIR, $MEDIA_DIR, $LOGS_DIR) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}
Write-Host "  v Struktura gotowa: $BASE_DIR" -ForegroundColor Green

# --- Szukanie kluczy deploy ---
# Skrypt NIE zaklada zadnej konkretnej lokalizacji sieciowej - klient moze
# dostac klucze na pendrivie, w mailu, albo skopiowac obok skryptu.
Write-Host "  > Szukanie kluczy deploy (core + client)..." -ForegroundColor Cyan

$searchDirs = @()
if ($KeysPath) { $searchDirs += $KeysPath }
if ($PSScriptRoot) { $searchDirs += (Join-Path $PSScriptRoot 'klucze'); $searchDirs += $PSScriptRoot }
$searchDirs += (Join-Path (Get-Location) 'klucze')
$searchDirs += (Join-Path $env:USERPROFILE 'Downloads')
$searchDirs += (Join-Path $env:USERPROFILE 'Desktop')
$searchDirs += $KEYS_DIR

function Find-KeyFiles {
    param([string[]]$Dirs)
    $found = @()
    foreach ($d in $Dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        $files = Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notmatch '\.pub$' -and $_.Name -notmatch '\.txt$' -and $_.Name -notmatch '\.md$' }
        foreach ($f in $files) {
            # plik musi wygladac na klucz prywatny
            try {
                $head = Get-Content -LiteralPath $f.FullName -TotalCount 2 -ErrorAction Stop
            } catch { continue }
            if ($head -match 'BEGIN OPENSSH PRIVATE KEY' -or $head -match 'BEGIN PRIVATE KEY') {
                $found += $f
            }
        }
    }
    return $found
}

# Kopia klucza do C:\STRUCTURA\klucze (bez BOM, LF) - instalator szuka tam
function Copy-KeyToStore {
    param($File, [string]$DestName)
    $dest = Join-Path $KEYS_DIR $DestName
    $bytes = [System.IO.File]::ReadAllBytes($File.FullName)
    # normalizuj CRLF -> LF (klucz SSH z CRLF lamie sie przy uzyciu)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($dest, $text, [System.Text.UTF8Encoding]::new($false))

    # Skopiuj tez .pub jesli jest - instalator uzywa go do wgrania klucza
    # do authorized_keys na VM (pewniejsze niz wywolywanie ssh-keygen,
    # ktory na Windows odrzuca klucze z szerokim ACL).
    foreach ($pubCand in @("$($File.FullName).pub")) {
        if (Test-Path -LiteralPath $pubCand) {
            $pubText = ([System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($pubCand))) -replace "`r`n", "`n"
            [System.IO.File]::WriteAllText("$dest.pub", $pubText, [System.Text.UTF8Encoding]::new($false))
            break
        }
    }
    return $dest
}

$keyFiles = Find-KeyFiles -Dirs $searchDirs

if (-not $keyFiles -or $keyFiles.Count -eq 0) {
    Write-Host "  ! Nie znaleziono kluczy deploy w typowych miejscach." -ForegroundColor Yellow
    Write-Host "    Sprawdzone: $($searchDirs -join ' | ')" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    Podaj folder, w ktorym sa pliki kluczy (albo Enter aby przerwac):" -ForegroundColor White
    $ans = Read-Host "    Sciezka"
    if (-not $ans -or $ans.Trim() -eq "") {
        Write-Host "  x Bez kluczy nie da sie sklonowac prywatnych repozytoriow." -ForegroundColor Red
        exit 1
    }
    $ans = $ans.Trim().Trim('"').Trim("'")
    $keyFiles = Find-KeyFiles -Dirs @($ans)
    if (-not $keyFiles -or $keyFiles.Count -eq 0) {
        Write-Host "  x W tym folderze tez nie ma kluczy prywatnych SSH." -ForegroundColor Red
        Write-Host "    Potrzebne pliki zaczynaja sie od '-----BEGIN OPENSSH PRIVATE KEY-----'" -ForegroundColor Yellow
        exit 1
    }
}

# Rozpoznanie: plik z 'core' = klucz do structura-core, reszta = klient
$coreFile = $keyFiles | Where-Object { $_.Name -match 'core' } | Select-Object -First 1
$clientFile = $keyFiles | Where-Object { $_.Name -notmatch 'core' } | Select-Object -First 1

if (-not $clientFile -and $keyFiles.Count -eq 1) { $clientFile = $keyFiles[0] }

if (-not $clientFile) {
    Write-Host "  x Nie znaleziono klucza KLIENTA (pliku bez 'core' w nazwie)." -ForegroundColor Red
    Write-Host "    Znalezione pliki: $($keyFiles.Name -join ', ')" -ForegroundColor DarkGray
    exit 1
}

$clientDest = Copy-KeyToStore -File $clientFile -DestName 'deploy_key_client'
Write-Host "  v Klucz klienta: $clientDest" -ForegroundColor Green

if ($coreFile) {
    $coreDest = Copy-KeyToStore -File $coreFile -DestName 'deploy_key_core'
    Write-Host "  v Klucz core:    $coreDest" -ForegroundColor Green
} else {
    Write-Host "  x Brak klucza CORE (pliku z 'core' w nazwie)." -ForegroundColor Red
    Write-Host "    Bez niego klon structura-core padnie i instalacja sie zatrzyma." -ForegroundColor Yellow
    Write-Host "    Znalezione pliki: $($keyFiles.Name -join ', ')" -ForegroundColor DarkGray
    Write-Host "    Popros o drugi plik klucza i uruchom skrypt ponownie." -ForegroundColor Yellow
    exit 1
}

# --- Internet ---
Write-Host "  > Sprawdzanie internetu..." -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri "https://github.com" -TimeoutSec 10 -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null
    Write-Host "  v Internet: OK" -ForegroundColor Green
} catch {
    Write-Host "  x Brak internetu - instalator wymaga dostepu do GitHub." -ForegroundColor Red
    exit 1
}

# --- Pobranie instalatora (staly pin) ---
$INSTALL_LOCAL = "$BASE_DIR\Install-STRUCTURA-FACTOR.ps1"
Write-Host "  > Pobieranie instalatora..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $INSTALL_URL -OutFile $INSTALL_LOCAL -TimeoutSec 60 -UseBasicParsing
Unblock-File -Path $INSTALL_LOCAL -ErrorAction SilentlyContinue
$sz = (Get-Item $INSTALL_LOCAL).Length
if ($sz -lt 10000 -or -not (Select-String -Path $INSTALL_LOCAL -Pattern 'STRUCTURA FACTOR' -Quiet)) {
    Write-Host "  x Pobrany plik nie wyglada na instalator ($sz B). Sprawdz internet/CDN." -ForegroundColor Red
    exit 1
}
Write-Host "  v Instalator pobrany ($sz B)" -ForegroundColor Green

# --- Uruchomienie instalatora ---
$installArgs = @()
if ($MediaCachePath) {
    $installArgs += @("-MediaCachePath", $MediaCachePath)
}

Write-Host ""
Write-Host "  === URUCHAMIENIE INSTALATORA ===" -ForegroundColor Cyan
Write-Host "  Klucze sa w $KEYS_DIR - instalator znajdzie je automatycznie." -ForegroundColor White
Write-Host ""

& $INSTALL_LOCAL @installArgs
