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
    [string]$CoreDeployKeyPath,

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
    [switch]$SkipMediaVerify,

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
$CLIENT_REPO_URL = "git@github.com:structura-factor/structura-clients-$Client.git"
# Client repos are SEPARATE per client (structura-clients-<client>) so each client's
# deploy key grants access to ITS OWN repo only - never to other clients' data.
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
# SSH with password helper (Windows doesn't have sshpass)
# ============================================================================

# ---------------------------------------------------------------------------
# UWAGA: usunieto martwy kod Invoke-SshWithPassword / Install-SshKeyOnVm.
# Zaden z nich nie byl wywolywany (Install-SshKeyOnVm: 0 wywolan), a oba
# zawieraly haslo w plaintext ([string]$Password = "structura") i wymagaly
# SSH_ASKPASS. Klucz deploy jest instalowany poprawnie przez post-install
# script VBoxManage unattended install (patrz Invoke-VMCreation).
# ---------------------------------------------------------------------------

# ============================================================================
# Utility functions
# ============================================================================

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

# ============================================================================
# Public key extraction (bezpieczne dla Windows)
# ============================================================================

# Zwraca klucz publiczny z klucza prywatnego albo $null.
#
# DLACZEGO NIE PROSTO `ssh-keygen -y` W SKRYPCIE:
#   1) Na Windows ssh-keygen odrzuca klucz, ktorego ACL jest "zbyt otwarty":
#        @@@@@ WARNING: UNPROTECTED PRIVATE KEY FILE! @@@@@
#      i konczy sie kodem 255. Klucze z SMB/OneDrive/pendrive tak wlasnie
#      wygladaja.
#   2) ssh-keygen pisze ostrzezenia na stderr, a przy $ErrorActionPreference='Stop'
#      PowerShell 5.1 zamienia stderr polecenia natywnego na RemoteException
#      i PRZERYWA cala instalacje (dokladnie ten blad: "System.Management.Automation.RemoteException").
#
# Dlatego: lokalna kopia z zawezonym ACL, uruchomienie z EAP=Continue
# i sprawdzenie wyniku zamiast wyjatku.
function Get-SshPublicKey {
    param([string]$PrivateKeyPath)

    if (-not $PrivateKeyPath -or -not (Test-Path -LiteralPath $PrivateKeyPath)) { return $null }

    $tmpKey = Join-Path $env:TEMP ("structura_pub_{0}" -f ([guid]::NewGuid().ToString('N')))
    try {
        Copy-Item -LiteralPath $PrivateKeyPath -Destination $tmpKey -Force

        # Zawez ACL do biezacego uzytkownika - bez tego ssh-keygen odmawia.
        try {
            $acl = Get-Acl $tmpKey
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "$env:USERDOMAIN\$env:USERNAME", "FullControl", "Allow")
            $acl.AddAccessRule($rule)
            Set-Acl $tmpKey $acl
        } catch {
            Write-Log "Get-SshPublicKey: nie udalo sie zawezic ACL ($_)" -Level "WARN"
        }

        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & ssh-keygen -y -f $tmpKey 2>&1
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP

        if ($rc -ne 0) {
            Write-Log "Get-SshPublicKey: ssh-keygen exit $rc ($out)" -Level "WARN"
            return $null
        }

        $pub = ($out | Where-Object { $_ -match '^(ssh-|ecdsa-)' } | Select-Object -First 1)
        if (-not $pub) { return $null }
        return $pub.Trim()
    } catch {
        Write-Log "Get-SshPublicKey: $_" -Level "WARN"
        return $null
    } finally {
        Remove-Item -LiteralPath $tmpKey -Force -ErrorAction SilentlyContinue
    }
}

# Klucz publiczny z pliku .pub (jesli istnieje obok klucza prywatnego).
# Prostsze i pewne - nie wymaga ssh-keygen.
function Get-SshPublicKeyFromPubFile {
    param([string]$PrivateKeyPath)
    if (-not $PrivateKeyPath) { return $null }
    foreach ($cand in @("$PrivateKeyPath.pub", ([System.IO.Path]::ChangeExtension($PrivateKeyPath, '.pub')))) {
        if ($cand -and (Test-Path -LiteralPath $cand)) {
            $line = Get-Content -LiteralPath $cand -TotalCount 1 -ErrorAction SilentlyContinue
            if ($line -match '^(ssh-|ecdsa-)') { return $line.Trim() }
        }
    }
    return $null
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

# ============================================================================
# SSH/SCP helpers (bezpieczne dla PowerShell 5.1)
# ============================================================================

# Uruchamia ssh/scp i ZWRACA wynik jako tekst, nigdy nie rzucajac wyjatkiem.
#
# DLACZEGO: przy $ErrorActionPreference='Stop' PowerShell 5.1 zamienia
# dowolny zapis na stderr polecenia natywnego na RemoteException i przerywa
# skrypt. ssh wypisuje na stderr rzeczy NIEBEDACE bledami, np.:
#   Warning: Permanently added '[127.0.0.1]:2222' (ED25519) to the list of known hosts.
# To wywalalo ETAP 4 ("Docker check via SSH failed after 3 attempts") mimo
# ze polaczenie bylo w porzadku. Ten sam mechanizm zabil wczesniej ssh-keygen.
function Invoke-Ssh {
    param(
        [string[]]$SshArgs,
        [int]$TimeoutSec = 0
    )
    # -o LogLevel=ERROR tlumi "Warning: Permanently added ... to the list of
    # known hosts" U ZRODLA. Bez tego warning leci na stderr, a PowerShell 5.1
    # opakowuje go w NativeCommandError i (mimo try/catch) wciska do wyniku,
    # przez co weryfikacje typu "$out -match 'Docker version'" nie dzialaja.
    $argsWithLog = @('-o', 'LogLevel=ERROR') + $SshArgs

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & ssh @argsWithLog 2>&1
        $rc = $LASTEXITCODE
        # Odfiltruj resztki NativeCommandError / warningow z tekstu wyniku
        $clean = @($out | Where-Object {
            $_.ToString() -notmatch '^(ssh\.exe|scp\.exe)\s*:'
        } | ForEach-Object { $_.ToString() })
        return @{ Output = (($clean | Out-String).Trim()); ExitCode = $rc; Raw = ($out | Out-String).Trim() }
    } catch {
        return @{ Output = ''; ExitCode = 255; Raw = "$_" }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

function Invoke-Scp {
    param([string[]]$ScpArgs)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & scp @(@('-o', 'LogLevel=ERROR') + $ScpArgs) 2>&1
        return @{ Output = ($out | Out-String).Trim(); ExitCode = $LASTEXITCODE }
    } catch {
        return @{ Output = "$_"; ExitCode = 255 }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# Uruchamia WIELOLINIJKOWY skrypt bash na VM bez problemow z cytowaniem.
#
# DLACZEGO NIE przekazywac skryptu jako argumentu do ssh:
#   PowerShell 5.1 przy wywolaniu polecenia natywnego ZDEJMUJE cudzyslowy
#   z argumentow. Wielolinijkowy skrypt typu
#       echo "deb [arch=$(dpkg --print-architecture)] ..." | sudo tee ...
#   dociera do bash w gosciu bez cudzyslowow i SIE ROZSYPIJE. Skutek:
#   instalacja Dockera konczyla sie "docker: command not found".
#
# ROZWIAZANIE: zapisz skrypt do pliku (LF), scp na VM, uruchom przez bash.
# Zero argumentow ze znakami specjalnymi - nic nie moze sie zepsuc.
function Invoke-SshScript {
    param(
        [string]$Script,
        [string]$Label = 'script',
        [string]$sshTarget = "structura@$sshHost",
        [int]$SshPort = 2222,
        [string]$RemotePath
    )
    if (-not $RemotePath) { $RemotePath = "/tmp/structura-$Label.sh" }

    $localPath = Join-Path $env:TEMP ("structura-$Label-{0}.sh" -f ([guid]::NewGuid().ToString('N')))
    try {
        # LF wymuszone - skrypt z CRLF lamie sie na shebang
        $text = ($Script -replace "`r`n", "`n")
        [System.IO.File]::WriteAllText($localPath, $text, [System.Text.UTF8Encoding]::new($false))

        $cp = Invoke-Scp -ScpArgs (@("-P", "$SshPort", "-o", "StrictHostKeyChecking=no", $localPath, "${sshTarget}:$RemotePath"))
        if ($cp.ExitCode -ne 0) {
            return @{ Output = "scp nie powiodl sie: $($cp.Output)"; ExitCode = $cp.ExitCode }
        }

        # ------------------------------------------------------------------
        # URUCHOMIENIE NA VM - KRYTYCZNE: HOME musi wskazywac na uzytkownika
        #
        # UWAGA: bylo tu 'sudo bash $RemotePath'. Problem: 'sudo' ustawia
        # HOME=/root, wiec WSZYSTKO, co instalator robil wzgledem $HOME,
        # ladowalo w /root zamiast /home/structura:
        #   /root/.local/bin/hermes          (binarka)
        #   /root/.local/share/uv/tools/     (pakiet Hermesa)
        #   /root/.hermes/{config.yaml,skills,SOUL.md,hindsight/}
        #
        # Skutek: hermes.service dziala jako User=structura, ktory NIE MA
        # tych plikow -> ExecStart=/root/.local/bin/hermes -> status=203/EXEC
        # -> usluga nie wstaje, instalacja przerwana w ETAPIE 7.
        #
        # Sprawdzone na VM: 'sudo bash -c "echo $HOME"' -> /root
        #                   'sudo -u structura bash -c "echo $HOME"' -> /home/structura
        #
        # ROZWIAZANIE: uruchamiamy jako uzytkownik (bez sudo), a skrypty
        # ktore potrzebuja roota uzywaja 'sudo' WEWNATRZ siebie (15 z 25
        # here-stringow robi to explicite). To bezpieczniejsze i zgodne
        # z tym, jak Hermes pozniej dziala.
        #
        # Fallback na 'sudo bash' zostawiony dla skryptow, ktore naprawde
        # potrzebuja roota od poczatku (np. instalacja pakietow) - one
        # i tak nie polegaja na $HOME.
        # ------------------------------------------------------------------
        $r = Invoke-Ssh -SshArgs (@("-p", "$SshPort", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL", $sshTarget, "bash $RemotePath 2>&1 || sudo bash $RemotePath"))
        return @{ Output = $r.Output; ExitCode = $r.ExitCode }
    } finally {
        Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
    }
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
        # Host sprawdzany jako parametr (wczesniej literal - linter slusznie ostrzegal)
        $probeHost = if ($env:STRUCTURA_PROBE_HOST) { $env:STRUCTURA_PROBE_HOST } else { "github.com" }
        $testConn = Test-NetConnection -ComputerName $probeHost -Port 443 -WarningAction SilentlyContinue
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
                Write-Check "Ubuntu ISO: SHA256 nie zgadza sie z versions.txt" -Warn
                Write-Host "    Plik:     $oneDriveIso" -ForegroundColor Yellow
                if ($expected) {
                    Write-Host "    Oczekiwany: $expected" -ForegroundColor DarkGray
                    Write-Host "    Znaleziony: $sha" -ForegroundColor DarkGray
                }
                Write-Host "    To normalne gdy masz inna (np. starsza) wersje Ubuntu -" -ForegroundColor White
                Write-Host "    instalator dziala z kazda 24.04.x LTS." -ForegroundColor White
                Write-Host ""
                if ($SkipMediaVerify) {
                    Write-Host "    -SkipMediaVerify: uzywam znalezionego pliku." -ForegroundColor Green
                    Copy-Item $oneDriveIso $isoPath -Force
                    $isoExists = $true
                } else {
                    $useIt = Read-Host "    Uzyc tego pliku zamiast pobierac 3 GB? (t/n)"
                    if ($useIt -match '^[tTyY]') {
                        Copy-Item $oneDriveIso $isoPath -Force
                        $isoExists = $true
                        Write-Check "Ubuntu ISO: uzywam pliku uzytkownika"
                    } else {
                        Write-Host "    Pobieram oficjalna wersje z internetu..." -ForegroundColor Yellow
                    }
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
            } else {
                # Inna wersja VBox niz w versions.txt to normalne (VirtualBox wydaje
                # poprawki czesto). Kazda 7.1.x dziala - nie zmuszaj do pobierania.
                Write-Check "VirtualBox: inna wersja niz w versions.txt" -Warn
                Write-Host "    Plik: $oneDriveVbox" -ForegroundColor Yellow
                if ($SkipMediaVerify) {
                    Write-Host "    -SkipMediaVerify: uzywam znalezionego pliku." -ForegroundColor Green
                    Copy-Item $oneDriveVbox $vboxPath -Force
                    $vboxExists = $true
                } else {
                    $useIt = Read-Host "    Uzyc tego pliku? (t/n)"
                    if ($useIt -match '^[tTyY]') {
                        Copy-Item $oneDriveVbox $vboxPath -Force
                        $vboxExists = $true
                        Write-Check "VirtualBox: uzywam pliku uzytkownika"
                    }
                }
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

            # Install VirtualBox Extension Pack (for VRDE/Remote Desktop preview)
            $extpackUrl = "https://download.virtualbox.org/virtualbox/7.1.16/Oracle_VirtualBox_Extension_Pack-7.1.16-172425.vbox-extpack"
            $extpackPath = "$mediaDir\Oracle_VirtualBox_Extension_Pack-7.1.16.vbox-extpack"
            if (-not (Test-Path $extpackPath)) {
                Write-Host "  Downloading Extension Pack (~22MB)..." -ForegroundColor White
                Invoke-WebRequest -Uri $extpackUrl -OutFile $extpackPath -UseBasicParsing -TimeoutSec 120
            }
            # Check if already installed
            $extpackInstalled = (& $vbox list extpacks 2>$null | Select-String "Oracle VM VirtualBox Extension Pack")
            if (-not $extpackInstalled) {
                Write-Host "  Installing Extension Pack..." -ForegroundColor White
                $prevEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                & $vbox extpack install --replace $extpackPath 2>&1 | Out-Null
                $ErrorActionPreference = $prevEAP
                Write-Check "Extension Pack installed (VRDE ready)"
            } else {
                Write-Check "Extension Pack already installed"
            }

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
        [hashtable]$Media
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
                    & $vbox startvm $VM_NAME --type headless 2>&1 | Out-Null
                    
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
        & $vbox modifyvm $VM_NAME --memory $VM_RAM --cpus $VM_CPU --nic1 nat --boot1 dvd --boot2 disk 2>&1 | Out-Null
        & $vbox modifyvm $VM_NAME --uart1 0x3F8 4 --uartmode1 file "$LOG_DIR\vm-console.log" 2>&1 | Out-Null
        # NAT port forwarding: host:2222 -> guest:22 (SSH), host:8080 -> guest:80
        # UWAGA: NIE forwardujemy host:8443->guest:443. HTTPS dla NPM wystawia
        # sie na host:8080->guest:80 (NPM sam terminuje TLS), wiec dodatkowy
        # forwarding nie jest potrzebny i moglby kolidowac z innymi uslugami.
        # NAT: host:2222 -> guest:22. sshd w gosciu slucha na 22 (domyslne) -
        # NIE przestawiamy go, bo handshake SSH w ETAPIE 3 odbywa sie zanim
        # ETAP 8 cokolwiek zmieni. Port 22 nie jest widoczny z sieci: VM ma NAT
        # i tylko 2222 jest forwardowane z hosta.
        # UWAGA: UFW musi zezwalac na 22 (a nie na 2222) - patrz ETAP 8.
        & $vbox modifyvm $VM_NAME --natpf1 "ssh,tcp,,2222,,22" 2>&1 | Out-Null

        # HTTP: NAJPIERW port 80 (jesli wolny), dopiero potem 8080.
        #
        # DLACZEGO TO KRYTYCZNE: nazwy .local laduja w pliku hosts klienta
        # wskazujac na 127.0.0.1 (patrz Install-HostsEntries). Przegladarka
        # przy http://homepage.local uderza na PORT 80. Gdy NAT wystawia NPM
        # tylko na 8080, nazwa .local nie otwiera sie ("nie mozna polaczyc"):
        #   127.0.0.1:80  -> nic nie slucha  (bylo tak na CiemPincie)
        #   127.0.0.1:8080 -> NPM (dziala, ale bez portu w adresie nie trafisz)
        #
        # Sprawdzone na CiemPincie: 192.168.40.8:80 = ZAMKNIETY, :8080 = otwarty.
        #
        # Wybor portu: 80 gdy wolny (nazwy dzialaja bez portu w adresie),
        # w przeciwnym razie 8080 + ostrzezenie (konflikt z IIS/Skype itp.).
        $hostPort = 8080
        $port80Taken = $false
        try {
            $conn80 = Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue
            if ($conn80) { $port80Taken = $true }
        } catch {
            # PS 5.1 bez modulu NetTCPIP - sprawdz przez netstat
            $ns = (netstat -ano 2>$null | Select-String ":80\s+.*LISTENING")
            if ($ns) { $port80Taken = $true }
        }

        if ($port80Taken) {
            Write-Check "Port 80 na tym komputerze jest zajety - uzywam 8080" -Warn
            Write-Log "NAT http: port 80 zajety, forwarding na 8080"
        } else {
            $hostPort = 80
            Write-Log "NAT http: port 80 wolny, forwarding na 80 (nazwy .local dzialaja bez portu)"
        }

        # 127.0.0.1 (nie 0.0.0.0): uslugi klienta NIE maja byc widoczne w LAN.
        # Wczesniej pusty hostip = 0.0.0.0, wiec kazdy w sieci mogl wejsc na
        # n8n/homepage VM-ki klienta pod :8080.
        & $vbox modifyvm $VM_NAME --natpf1 "http,tcp,127.0.0.1,$hostPort,,80" 2>&1 | Out-Null
        $global:StructuraHostPort = $hostPort
        # Enable VRDE if Extension Pack is installed (for RDP preview)
        $extpackReady = (& $vbox list extpacks 2>$null | Select-String "Oracle VM VirtualBox Extension Pack")
        if ($extpackReady) {
            # VRDE tylko na localhost + uwierzytelnianie. '--vrde-auth-type null'
            # wystawialo konsole VM bez logowania dla calej sieci LAN (dane klienta!).
            # Podglad: mstsc /v:localhost:5000 (port nie widoczny z zewnatrz).
            # Skladnia wg manuala VirtualBox 7.x: --vrde-address= / --vrde-auth-type=
            # (formy bez myslnika --vrdeaddress NIE sa udokumentowane w 7.x).
            # Fallback: jesli nowsza skladnia zawiedzie, probujemy form starszych.
            & $vbox modifyvm $VM_NAME --vrde=on --vrde-port=5000 --vrde-address=127.0.0.1 --vrde-auth-type=guest 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Log "VRDE (nowa skladnia) exit $LASTEXITCODE - probuje formy alternatywnej"
                & $vbox modifyvm $VM_NAME --vrde on --vrdeport 5000 --vrdeaddress 127.0.0.1 --vrdeauthtype guest 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "VRDE niedostepne (exit $LASTEXITCODE) - instalacja bez podgladu" -Level "WARN"
                    Write-Host "    VRDE niedostepne - instalacja kontynuuje bez podgladu (headless)" -ForegroundColor Yellow
                }
            }
        }
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
        # Get the public key from the deploy key for SSH key auth
        # (najpierw plik .pub - pewny i szybki; potem ssh-keygen z zawezonym ACL)
        $pubKey = Get-SshPublicKeyFromPubFile -PrivateKeyPath $DeployKeyPath
        if (-not $pubKey) {
            $pubKey = Get-SshPublicKey -PrivateKeyPath $DeployKeyPath
        }
        if (-not $pubKey) {
            # Twarda porazka zamiast ostrzezenia - bez klucza caly deployment i tak
            # sie zatrzyma (nie da sie sklonowac prywatnych repo), a diagnostyka
            # "po fakcie" jest droga. Lepiej przerwac TERAZ, przed 15 min instalacji.
            Write-Log "Nie udalo sie wyznaczyc klucza publicznego z $DeployKeyPath" -Level "ERROR"
            Write-Check "Nie moge odczytac klucza publicznego z: $DeployKeyPath" -Fail
            Write-Host "    Oczekiwany plik .pub obok klucza prywatnego, np.:" -ForegroundColor Yellow
            Write-Host "      $DeployKeyPath.pub" -ForegroundColor DarkGray
            Write-Host "    Albo poprawny klucz prywatny (bez .pub), z ktorego da sie go wyliczyc." -ForegroundColor Yellow
            throw "Brak klucza publicznego - przerwano przed utworzeniem VM"
        }
        Write-Log "Klucz publiczny klienta: $($pubKey.Substring(0, [Math]::Min(50, $pubKey.Length)))..."

        # ====================================================================
        # KLUCZ SSH - wlasciwy mechanizm
        # ====================================================================
        # Przyczyna realnej awarii (potwierdzona bugiem Ubuntu #2090834):
        #   VirtualBox wstawia uzytkownika do autoinstall -> "user-data.users",
        #   a NIE do "identity". Subiquity tworzy takiego uzytkownika dopiero
        #   przy PIERWSZYM BOOTCIE (cloud-init). Skrypt z --post-install-template
        #   jest natomiast wykonywany w late-commands, czyli PRZED tym bootem.
        #   Skutek: "chown structura:structura" -> "invalid user" -> exit 1
        #   -> curtin in-target zwraca blad -> instalacja sie NIE konczy,
        #   brak restartu, konsola zostaje w live installerze ("login incorrect").
        #
        # ROZWIAZANIE: nadpisujemy szablon user-data przez --script-template
        # i wstawiamy klucz w "ssh_authorized_keys" uzytkownika. Cloud-init
        # zaklada konto i klucz przy pierwszym starcie - wtedy user juz istnieje.

        # Wygeneruj wlasny szablon (stock VirtualBox + ssh_authorized_keys)
        $keyForYaml = if ($pubKey) { $pubKey } else { "" }
        $scriptTemplatePath = "$LOG_DIR\ubuntu-user-data-template"
        $tmpl = @'
#cloud-config
autoinstall:
  version: 1
  apt:
    fallback: offline-install
  locale: @@VBOX_INSERT_LOCALE@@
  keyboard:
    layout: us
  shutdown: SHUTDOWN_MODE
  storage:
    layout:
      name: direct
    swap:
      size: 0
@@VBOX_COND_HAS_PROXY@@
  proxy: @@VBOX_INSERT_PROXY@@
@@VBOX_COND_END@@
  identity:
    hostname: '@@VBOX_INSERT_HOSTNAME_WITHOUT_DOMAIN@@'
    username: '@@VBOX_INSERT_USER_LOGIN@@'
    realname: '@@VBOX_INSERT_USER_FULL_NAME@@'
    password: '@@VBOX_INSERT_USER_PASSWORD_SHACRYPT512@@'
  # Pakiety - stock szablon VirtualBox ich NIE ma, a bez openssh-server
  # nie da sie wejsc na VM po instalacji (sshd nie istnieje -> NAT zwraca
  # "Connection reset"). git/curl potrzebne pozniej w ETAPIE 5-6.
  packages:
    - openssh-server
    - curl
    - git
    - ca-certificates
    - make
  # openssh-server + klucz publiczny; haslo zostaje jako awaryjne wejscie
  # (allow-pw: true), bo przy pierwszym wdrozeniu czesto trzeba sie dostac
  # na VM nawet gdy klucz nie zadziala.
  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
      - __SSH_PUBKEY__
  # UWAGA: NIE definiujemy tu drugi raz tego samego usera przez "users:".
  # Dokumentacja Ubuntu: "identity and user-data/users sections are not being
  # merged" - podwojna definicja 'structura' jest ryzykiem (konflikt), a nie
  # zabezpieczeniem. Klucz wgrywa sekcja ssh.authorized-keys powyzej.
  user-data:
    timezone: @@VBOX_INSERT_TIME_ZONE_UX@@
    ntp:
      enabled: true
    # ====================================================================
    # SUDO BEZ HASLA - KRYTYCZNE dla automatycznej instalacji.
    # ====================================================================
    # Uzytkownik z sekcji "identity" dostaje sudo Z HASLEM. Instalator
    # wysyla komendy przez SSH (sudo apt-get update, sudo docker ...),
    # a nikt nie podaje hasla na stdin -> sudo CZEKA na haslo -> komenda
    # wisi -> "set -e" przerywa -> Docker sie nie instaluje
    # ("docker: command not found").
    #
    # runcmd z cloud-init wykonuje sie PO utworzeniu konta, wiec mozemy
    # bezpiecznie nadac NOPASSWD (w late-commands konto jeszcze nie istnieje).
    runcmd:
      - install -d -m 0755 /etc/sudoers.d
      - printf '%s\n' "@@VBOX_INSERT_USER_LOGIN@@ ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/010-structura-nopasswd
      - chmod 0440 /etc/sudoers.d/010-structura-nopasswd
      - visudo -cf /etc/sudoers.d/010-structura-nopasswd
  late-commands:
    - cp /cdrom/vboxpostinstall.sh /target/root/vboxpostinstall.sh
    - chmod +x /target/root/vboxpostinstall.sh
    - curtin in-target --target=/target -- /bin/bash /root/vboxpostinstall.sh --direct
'@
        $tmpl = $tmpl.Replace('__SSH_PUBKEY__', $keyForYaml).Replace('SHUTDOWN_MODE', 'reboot')
        [System.IO.File]::WriteAllText($scriptTemplatePath, ($tmpl -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
        Write-Log "script-template (user-data) zapisany: $scriptTemplatePath"

        # --- Skrypt post-install ---
        # UWAGA: NIE wolno tu uzywac chown/useradd na 'structura' - konto
        # nie istnieje w late-commands (patrz komentarz wyzej). Klucz SSH
        # wgrywa cloud-init przez ssh_authorized_keys.
        # Plik MUSI byc z LF (shebang "#!/bin/bash<CR>" lamie sie w kernelu).
        $postInstallScript = "$LOG_DIR\post-install.sh"
        $shText = @'
#!/bin/bash
# Struktura FACTOR - kroki po instalacji (late-commands).
# Uruchamiane PRZED pierwszym restartem - konto uzytkownika jeszcze NIE istnieje,
# dlatego ZADNYCH chown/useradd tutaj. Klucz SSH wgrywa cloud-init.
TARGET=/
if [ "${1:-}" = "--direct" ]; then TARGET=/; else TARGET=/target; fi
echo "post-install: start (target=$TARGET)"
echo "post-install: authorized_keys wgrywa cloud-init przy pierwszym starcie"
'@
        $shText = ($shText -replace "`r`n", "`n")
        [System.IO.File]::WriteAllText($postInstallScript, $shText, [System.Text.UTF8Encoding]::new($false))

        Write-Log "post-install-template: $postInstallScript"
        Write-Log "script-template: $scriptTemplatePath"

        $unattendedArgs = @(
            "unattended", "install", $VM_NAME,
            "--iso=$isoFilePath",
            "--user=structura",
            "--password=structura",
            "--full-user-name=STRUCTURA",
            "--time-zone=Europe/Warsaw",
            "--hostname=structura.local",
            # user-data z ssh_authorized_keys - klucz wgrywa cloud-init
            # przy pierwszym starcie (po utworzeniu konta). Patrz komentarz wyzej.
            "--script-template=$scriptTemplatePath",
            "--post-install-template=$postInstallScript"
        )
        & $vbox @unattendedArgs 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        $unattendedExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        Write-Log "Unattended install exit code: $unattendedExit"
        
        if ($unattendedExit -ne 0) {
            Write-Host "    VBoxManage unattended install failed (exit $unattendedExit)" -ForegroundColor Yellow
            # VM might be locked from failed attempt - poweroff and wait
            $isVmRunning = (& $vbox showvminfo $VM_NAME --machinereadable 2>$null | Select-String 'VMState="running"')
            if ($isVmRunning) {
                & $vbox controlvm $VM_NAME poweroff 2>&1 | Out-Null
                Start-Sleep -Seconds 5
            }
            Write-Host "    Trying minimal args..." -ForegroundColor Yellow
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & $vbox unattended install $VM_NAME --iso="$isoFilePath" --user=structura --password=structura --time-zone=Europe/Warsaw --hostname=structura.local --start-vm=gui 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
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
            & $vbox startvm $VM_NAME --type headless 2>&1 | Out-Null
        }

        # If Extension Pack is installed, enable VRDE and open Remote Desktop preview
        $extpackReady = (& $vbox list extpacks 2>$null | Select-String "Oracle VM VirtualBox Extension Pack")
        if ($extpackReady -and -not $Quiet) {
            Start-Sleep -Seconds 3
            Start-Process mstsc -ArgumentList "/v:localhost:5000" -ErrorAction SilentlyContinue
            Write-Host "  Podglad VM: Remote Desktop (localhost:5000) - okno mozna zamknac w dowolnym momencie." -ForegroundColor DarkGray
        }


# VM runs headless - SSH via NAT port forwarding (localhost:2222)
    }

    return Get-VmIpAndSsh -Vbox $vbox
}

function Get-VmIpAndSsh {
    param([string]$Vbox)

    $sshHost = "127.0.0.1"
    $sshPort = 2222

    # Wait for a REAL SSH handshake. A plain TCP check on 2222 is a false positive:
    # NAT port forwarding accepts the connection on the host before sshd exists.
    Write-Host "  Czekam na koniec instalacji Ubuntu (realny handshake SSH)..." -ForegroundColor White
    Write-Host "  (Ubuntu installation takes 5-15 minutes, please be patient)" -ForegroundColor DarkGray
    Write-Host ""

    # CZEKAMY WYLACZNIE NA UDANE UWIERZYTELNIENIE KLUCZEM (SSH_OK).
    #
    # UWAGA: NIE wolno traktowac "Permission denied" jako sygnalu gotowosci.
    # sshd LIVE INSTALATORA odpowiada tak samo (konto jeszcze nie istnieje),
    # wiec przerwanie petli na "Permission denied" konczy sie przejsciem dalej
    # w trakcie instalacji - dokladnie tak powstawal blad "SSH key auth failed",
    # gdy na konsoli wciaz lecialo "installing kernel".
    #
    # Klucz (ssh_authorized_keys z --script-template) jest wgrywany przez
    # cloud-init dopiero na ZAINSTALOWANYM systemie, po pierwszym starcie.
    # Wiec: sukces klucza == instalacja zakonczona i system wstal.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $ubuntuUp = $false
    $sshReady = $false
    $probeKey = "$env:USERPROFILE\.ssh\id_ed25519"
    $sawDenied = $false
    $maxIter = 90          # 90 x 30s = 45 min
    for ($i = 0; $i -lt $maxIter; $i++) {
        $probe = ssh -v -p $sshPort -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=8 -o BatchMode=yes -i $probeKey $sshHost "echo SSH_OK" 2>&1
        if ($probe -match 'SSH_OK') {
            $ErrorActionPreference = $prevEAP
            Write-Host ""
            Write-Check "SSH gotowe (klucz dziala) - ${sshHost}:${sshPort}"
            $sshReady = $true
            break
        }
        if ($probe -match 'Permission denied') {
            # To NORMALNE w trakcie instalacji - nie przerywamy, tylko raportujemy.
            if (-not $sawDenied) {
                $sawDenied = $true
                $ubuntuUp = $true
                Write-Host ""
                Write-Host "  ! sshd odpowiada, ale klucz jeszcze nieaktywny (instalacja w toku)" -ForegroundColor DarkGray
                Write-Host "    Czekam az cloud-init utworzy konto i wgra klucz..." -ForegroundColor DarkGray
            }
        }

        # Szybkie wyjscie: jesli maszyna sie wylaczyla/stoi, nie ma na co czekac
        $vmState = (& $Vbox showvminfo $VM_NAME --machinereadable 2>$null | Select-String 'VMState=')
        $stateStr = if ($vmState) { $vmState -replace 'VMState=|"','' } else { 'unknown' }
        $min = [math]::Floor($i * 30 / 60)
        $phase = if ($sawDenied) { 'sshd jest, czekam na klucz' } else { 'start instalatora' }
        Write-Host "  [${min}min] VM: $stateStr - $phase..." -ForegroundColor DarkGray
        if ($stateStr -eq 'poweroff' -or $stateStr -eq 'aborted') {
            Write-Check "VM zatrzymala sie nieoczekiwanie (stan: $stateStr)" -Fail
            $ErrorActionPreference = $prevEAP
            return @{ VmExists = $true; VmIp = $null }
        }
        Start-Sleep -Seconds 30
    }
    $ErrorActionPreference = $prevEAP

    if (-not $sshReady) {
        Write-Check "SSH kluczem nie zadzialal po $([math]::Floor($maxIter*30/60)) min" -Warn
        if ($sawDenied) {
            Write-Host "    sshd odpowiadal, ale klucz nigdy nie stal sie aktywny." -ForegroundColor Yellow
            Write-Host "    Sprawdz w VM: sudo cat /var/log/vboxpostinstall.log oraz" -ForegroundColor DarkGray
            Write-Host "                  sudo cloud-init status --long" -ForegroundColor DarkGray
        }
        return @{ VmExists = $true; VmIp = $null }
    }

    # Klucz JEST juz aktywny (SSH_OK powyzej) - wgrywa go cloud-init przez
    # ssh.authorized-keys z szablonu autoinstall. Wiec NIE ma po co wstrzykiwac
    # klawiatury do konsoli VM.
    #
    # USUNIETO (Fala 1n): martwy blok keyboardputstring, ktory wykonywal sie
    # MIJAJAC sprawdzenie sshReady - stad na konsoli widac bylo
    # "Installing SSH key via VM console..." i sudo czekajace na haslo
    # dlugo PO tym, jak SSH juz dzialalo. Wstrzykiwanie klawiatury nie dziala
    # w trybie headless i nie jest juz do niczego potrzebne.
    Write-Host ""
    Write-Check "Klucz SSH aktywny - pomijam wstrzykiwanie klawiatury (niepotrzebne)"
    return @{ VmExists = $true; VmIp = $sshHost }
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
    $sshPort = 2222

    # Guard: check if Docker already installed
    Write-Host "  Checking Docker on VM..." -ForegroundColor White
    $dockerCheck = Invoke-WithRetry -Action {
        $r = Invoke-Ssh -SshArgs (@("-p","$sshPort","-o","StrictHostKeyChecking=no","-o","ConnectTimeout=10","-o","UserKnownHostsFile=NUL",$sshTarget,"docker --version"))
        return $r.Output
    } -Description "Docker check via SSH" -MaxRetries 3

    if ($dockerCheck -match 'Docker version') {
        Write-Check "Docker already installed: $($dockerCheck.Trim())"
        $composeCheck = (Invoke-Ssh -SshArgs (@("-p","$sshPort","-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL",$sshTarget,"docker compose version"))).Output
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
        # make: NIE ma go w Ubuntu 24.04 live-server (sprawdzone na manifescie ISO:
        # 707 pakietow, zero dopasowan '^make'/'build-essential'; docker-ce go nie
        # ciagnie - Depends to containerd.io/iptables/libseccomp2/libc6/libsystemd0).
        # Bez make caly ETAP 6/7/8 pada: "make: command not found" - a instalator
        # raportowal to tylko jako WARN, wiec szedl dalej i pokazywal falszywe sukcesy.
        sudo apt-get install -y ca-certificates curl gnupg lsb-release make
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
        # make jest KRYTYCZNE: ETAP 6/7/8 wolaja 'make secrets-check', 'make deploy',
        # 'make npm-setup', 'make init-hindsight'. Bez niego instalacja nie ma prawa
        # dojsc do konca - lepiej zatrzymac sie tu z jasnym komunikatem.
        if command -v make >/dev/null 2>&1; then
            echo "MAKE_OK `$(make --version | head -1)"
        else
            echo "MAKE_MISSING"
            exit 1
        fi
"@

    $installResult = Invoke-WithRetry -Action {
        $r = Invoke-SshScript -Script $installCmd -Label "docker-install" -sshTarget $sshTarget -SshPort $sshPort
        return $r.Output
    } -Description "Docker install via SSH" -MaxRetries 3

    if ($PSBoundParameters.ContainsKey("Verbose")) {
        Write-Host $installResult -ForegroundColor DarkGray
    }

    # Verify
    $verifyResult = (Invoke-Ssh -SshArgs (@("-p","$sshPort","-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL",$sshTarget,"docker --version && docker compose version && (command -v make >/dev/null && echo MAKE_OK || echo MAKE_MISSING)"))).Output
    if ($verifyResult -match 'MAKE_MISSING') {
        # Brak make = twarda BLOKADA. ETAP 6/7/8 sa zbudowane na 'make ...' i bez
        # niego instalator wczesniej szedl dalej, pokazujac falszywe sukcesy
        # ('v NPM configured', 'v Hindsight banks initialized').
        Write-Check "make NIE zainstalowany - ETAP 6/7/8 niemozliwe" -Fail
        Write-Host "    Output: $verifyResult" -ForegroundColor Red
        return $false
    }
    if ($verifyResult -match 'Docker version' -and $verifyResult -match 'Docker Compose version' -and $verifyResult -match 'MAKE_OK') {
        Write-Check "Docker installed and verified"
        Write-Check "Docker Compose installed and verified"
        Write-Check "make dostepny (wymagany przez ETAPY 6/7/8)"

        # ------------------------------------------------------------------
        # Guest Additions (vboxsf) - instalowane TU, nie dopiero w ETAPIE 8.
        #
        # DLACZEGO: vboxsf to modul jadra potrzebny do montowania folderu
        # wspoldzielonego (Windows <-> VM). Wczesniej instalowal go dopiero
        # Install-SharedFolder w ETAPIE 8, wiec:
        #   - gdy ETAP 7 przerwal instalacje, GA nie bylo WCALE
        #     (sprawdzone na VM: brak /opt/VBoxGuestAdditions-*, brak vboxsf)
        #   - folder wymiany dla n8n musi istniec ZANIM wystartuja kontenery
        #     (ETAP 6 montuje go do n8n jako /exchange)
        #
        # vboxsf dziala w ramach tej samej galezi VBox 7.x - repo Ubuntu daje
        # virtualbox-guest-utils 7.0.x, host ma 7.1.x i modul sie laduje.
        # ------------------------------------------------------------------
        Write-Host "  Sprawdzanie Guest Additions (vboxsf dla folderu wspoldzielonego)..." -ForegroundColor White
        $gaSetup = @"
            if lsmod | grep -q vboxsf; then
                echo "GA_ALREADY"
            else
                sudo apt-get update -qq 2>/dev/null || true
                sudo apt-get install -y virtualbox-guest-utils 2>/dev/null || true
                sudo modprobe vboxsf 2>/dev/null || true
                if lsmod | grep -q vboxsf; then echo "GA_INSTALLED_OK"; else echo "GA_INSTALL_FAILED"; fi
            fi
"@
        $gaSetupResult = (Invoke-SshScript -Script $gaSetup -Label "ga-setup" -sshTarget $sshTarget -SshPort $sshPort).Output
        if ($gaSetupResult -match 'GA_INSTALL_FAILED') {
            Write-Check "Guest Additions: instalacja nieudana - folder wspoldzielony moze nie dzialac" -Warn
            Write-Log "GA install failed in Docker setup stage: $gaSetupResult"
        } else {
            Write-Check "Guest Additions gotowe (vboxsf dostepny)"
        }

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
    $sshPort = 2222

    # Guard: check if repos already cloned
    # UWAGA: wczesniej byla tu DRUGA, slabsza sciezka aktualizacji:
    #   git pull --ff-only 2>/dev/null
    # Blad zjadal 2>/dev/null, wynik nie byl sprawdzany, a gdy repo juz
    # istnialo (typowe przy powtornym uruchomieniu) ta galaz PRZESKAKIWALA
    # blok klonowania z sync_repo. Skutek: VM zostawala na STARYM kodzie
    # (np. Makefile wymagajacy usunietej zmiennej), instalator pracowal
    # na nieaktualnym core i padal bez sladu dlaczego.
    #
    # Teraz: JEDNA sciezka. Zawsze sync_repo - klonuje gdy brak,
    # fetch + reset --hard gdy istnieje. Zero cichych bledow.
    Write-Host "  Syncing repos to /opt/structura/repos/..." -ForegroundColor White

        # Transfer deploy key(s) to VM for git clone authentication.
        # UWAGA: GitHub NIE pozwala uzyc tego samego deploy keya w dwoch repo
        # ("key is already in use"), wiec core i client maja OSOBNE klucze.
        # Dlatego na VM konfigurujemy aliasy SSH (github-core / github-client),
        # a URL-e klonowania uzywaja tych aliasow zamiast github.com.
        $haveClientKey = $DeployKeyPath -and (Test-Path $DeployKeyPath)
        $haveCoreKey = $CoreDeployKeyPath -and (Test-Path $CoreDeployKeyPath)

        if ($haveClientKey -or $haveCoreKey) {
            Write-Host "  Transferring deploy key(s) to VM..." -ForegroundColor DarkGray
            $keySetupCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh`n"
            $keySetupCmd += "ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null || true`n"
            $sshCfg = ""

            if ($haveClientKey) {
                $null = Invoke-Scp -ScpArgs (@("-P","$sshPort","-o","StrictHostKeyChecking=no",$DeployKeyPath,"${sshTarget}:/tmp/k_client"))
                $keySetupCmd += "cp /tmp/k_client ~/.ssh/id_client && chmod 600 ~/.ssh/id_client && rm -f /tmp/k_client`n"
                $sshCfg += "Host github-client`n    HostName github.com`n    User git`n    IdentityFile ~/.ssh/id_client`n    IdentitiesOnly yes`n    StrictHostKeyChecking no`n"
            }
            if ($haveCoreKey) {
                $null = Invoke-Scp -ScpArgs (@("-P","$sshPort","-o","StrictHostKeyChecking=no",$CoreDeployKeyPath,"${sshTarget}:/tmp/k_core"))
                $keySetupCmd += "cp /tmp/k_core ~/.ssh/id_core && chmod 600 ~/.ssh/id_core && rm -f /tmp/k_core`n"
                $sshCfg += "Host github-core`n    HostName github.com`n    User git`n    IdentityFile ~/.ssh/id_core`n    IdentitiesOnly yes`n    StrictHostKeyChecking no`n"
            }

            # Nadpisz ~/.ssh/config - powtarzalne, bez duplikatow przy re-runie
            $cfgLines = ($sshCfg -split "`n" | ForEach-Object { "echo '$_' >> ~/.ssh/config" }) -join " && "
            $keySetupCmd += "rm -f ~/.ssh/config && $cfgLines`n"
            # Fallback: jesli podano tylko jeden klucz, ustaw go tez jako domyslny
            if ($haveClientKey -and -not $haveCoreKey) { $keySetupCmd += "cp ~/.ssh/id_client ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519`n" }
            if ($haveCoreKey -and -not $haveClientKey) { $keySetupCmd += "cp ~/.ssh/id_core ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519`n" }
            $keySetupCmd += "echo KEY_SETUP_DONE"

            $keySetupResult = (Invoke-SshScript -Script $keySetupCmd -Label "keys" -sshTarget $sshTarget -SshPort $sshPort).Output
            if ($keySetupResult -match 'KEY_SETUP_DONE') {
                Write-Log "Deploy key(s) transferred to VM (client=$haveClientKey core=$haveCoreKey)"
            } else {
                Write-Check "Deploy key transfer: sprawdz log" -Warn
            }
        }

        # Host w URL zalezy od tego, ktore klucze mamy (aliasy github-core / github-client)
        $coreUrl = $CORE_REPO_URL
        $clientUrl = $CLIENT_REPO_URL
        if ($haveCoreKey -and $haveClientKey) {
            $coreUrl   = $CORE_REPO_URL   -replace 'github\.com:', 'github-core:'
            $clientUrl = $CLIENT_REPO_URL -replace 'github\.com:', 'github-client:'
        }

        $cloneCmd = @"
            # NOTE: clone as 'structura' WITHOUT sudo - 'sudo' resets HOME to /root,
            # so the deploy key staged in /home/structura/.ssh would be ignored and the
            # private clone would fail with 'Permission denied (publickey)'.
            sudo mkdir -p /opt/structura/repos
            sudo chown -R structura:structura /opt/structura
            cd /opt/structura/repos

            # Idempotentnie: klonuj ALBO zaktualizuj istniejace repo.
            # Powod: nieudany przebieg zostawia sklonowane repo. Drugie
            # 'git clone' konczy sie bledem "destination path already exists",
            # a poniewaz brak tu 'set -e' -> skrypt leci dalej z NIEAKTUALNYM
            # kodem i raportuje sukces. Poprawki w core (np. Makefile) nigdy
            # nie docieraly na VM.
            sync_repo() {
                local url="`$1" dir="`$2"
                if [ -d "`$dir/.git" ]; then
                    echo "REPO_UPDATE `$dir"
                    git -C "`$dir" fetch --depth 1 origin main                         && git -C "`$dir" reset --hard origin/main                         || { echo "REPO_FAIL `$dir"; return 1; }
                else
                    echo "REPO_CLONE `$dir"
                    git clone --depth 1 "`$url" "`$dir" \
                        || { echo "REPO_FAIL `$dir"; return 1; }
                fi
            }

            sync_repo "$coreUrl" "structura-core" || exit 1
            sync_repo "$clientUrl" "structura-clients-$Client" || exit 1
            echo "CLONE_DONE"
"@
        $cloneResult = Invoke-WithRetry -Action {
            return (Invoke-SshScript -Script $cloneCmd -Label "clone" -sshTarget $sshTarget -SshPort $sshPort).Output
        } -Description "Git clone repos" -MaxRetries 3

        # Sprawdz znacznik zamiast bezwarunkowego sukcesu. Bylo: Write-Check
        # "Repos cloned" zawsze, nawet gdy git clone zwrocil blad (np.
        # "destination path already exists") -> instalator lecial dalej
        # z NIEZAKTUALNYM kodem na VM i raportowal sukces.
        if ($cloneResult -notmatch 'CLONE_DONE') {
            Write-Check "Klonowanie repo NIE powiodlo sie" -Fail
            Write-Log "clone: brak CLONE_DONE. Output: $cloneResult"
            return $false
        }
        if ($cloneResult -match 'REPO_UPDATE') {
            Write-Check "Repozytoria zaktualizowane (fetch + reset do origin/main)"
        } else {
            Write-Check "Repos cloned"
        }
        # (sprawdzenie CLONE_DONE z return $false jest wyzej - wystarczy)

    # Create appdata directory structure
    Write-Host "  Creating appdata structure..." -ForegroundColor White

    $mkdirCmd = @"
        sudo mkdir -p /opt/structura/appdata/postgresql/{data,pgdump}
        sudo mkdir -p /opt/structura/appdata/hermes/{memories,skills,session}
        sudo mkdir -p /opt/structura/appdata/n8n/config
        sudo mkdir -p /opt/structura/appdata/npm/{data,letsencrypt}
        sudo mkdir -p /opt/structura/appdata/portainer
        sudo mkdir -p /opt/structura/appdata/duplicati
        sudo mkdir -p /opt/structura/appdata/homepage/icons
        sudo mkdir -p /opt/structura/appdata/searxng
        sudo mkdir -p /opt/structura/ai-workspace/{STRUCTURA,Sprawy,_trash}
        sudo mkdir -p /opt/structura/backups/{appdata,ai-workspace,pgdump,pgdata,config}
        # Katalog konfiguracji krytycznej dla backupu (.env + certyfikaty TLS).
        # Bez .env backup bazy jest bezuzyteczny - nie ma czym sie zalogowac.
        sudo mkdir -p /opt/structura/config
        sudo chmod 750 /opt/structura/appdata

        # ====================================================================
        # PGDATA: przygotowanie PRZED startem kontenera (KRYTYCZNE)
        # ====================================================================
        # pgdata to BIND-MOUNT do appdata/postgresql/data (nie named volume),
        # wiec 'docker compose down -v' ani 'docker volume rm' NIE czyszcza
        # tego katalogu. Nieudana instalacja zostawia w nim resztki, a wtedy
        # entrypoint postgresa przerywa z:
        #   initdb: error: directory "/var/lib/postgresql/data" exists but
        #           is not empty
        # i baza NIGDY WIECEJ NIE WSTANIE.
        #
        # UWAGA na kolejnosc: NIE da sie tego naprawic w init.sh, bo skrypty
        # z /docker-entrypoint-initdb.d uruchamiaja sie DOPIERO PO initdb.
        # Zabezpieczenie MUSI byc tutaj - przed 'docker compose up'.
        #
        # Bezpieczenstwo: czyscimy TYLKO gdy brak PG_VERSION (czyli katalog
        # nie jest zainicjowana baza). Prawdziwe dane sa nietykalne.
        PGDATA_DIR="/opt/structura/appdata/postgresql/data"
        if [ -d "`$PGDATA_DIR" ] && [ -n "`$(ls -A "`$PGDATA_DIR" 2>/dev/null)" ]; then
            if [ -f "`$PGDATA_DIR/PG_VERSION" ]; then
                echo "pgdata: OK - istnieje zainicjowana baza (PG_VERSION), zachowuje"
            else
                echo "pgdata: UWAGA - katalog niepusty, ale bez PG_VERSION (resztki):"
                echo "pgdata:   `$(ls -A "`$PGDATA_DIR" 2>/dev/null | head -5 | tr '\n' ' ')"
                echo "pgdata:   usuwam resztki, zeby initdb mogl wystartowac"
                sudo rm -rf "`$PGDATA_DIR"
                sudo mkdir -p "`$PGDATA_DIR"
                echo "pgdata: wyczyszczone"
            fi
        else
            echo "pgdata: pusty - initdb zainicjalizuje baze"
        fi

        # Wlasciciel PGDATA musi byc postgres (uid 999 w obrazie pgvector).
        # Bez tego entrypoint robi chown i (przy nieoczekiwanym uid) konczy bledem.
        sudo chown -R 999:999 "`$PGDATA_DIR"
        sudo chmod 700 "`$PGDATA_DIR"

        sudo chown -R 1000:1000 /opt/structura/appdata
        echo "appdata structure created"
"@

    $mkdirResult = (Invoke-SshScript -Script $mkdirCmd -Label "mkdir" -sshTarget $sshTarget -SshPort $sshPort).Output
    Write-Check "appdata structure created"

    # Copy config files from repos to appdata
    Write-Host "  Copying config files to appdata..." -ForegroundColor White

    $copyCmd = @"
        # Hindsight config
        if [ -f /opt/structura/repos/structura-core/postgresql/init.sql ]; then
            sudo cp /opt/structura/repos/structura-core/postgresql/init.sql /opt/structura/appdata/postgresql/
            sudo cp /opt/structura/repos/structura-core/postgresql/postgresql.conf /opt/structura/appdata/postgresql/
            sudo cp /opt/structura/repos/structura-core/postgresql/pg_hba.conf /opt/structura/appdata/postgresql/
        fi
        # SearXNG config
        if [ -f /opt/structura/repos/structura-core/searxng/settings.yml ]; then
            sudo cp /opt/structura/repos/structura-core/searxng/settings.yml /opt/structura/appdata/searxng/
        fi
        # pgdump script
        if [ -f /opt/structura/repos/structura-core/postgresql/pgdump.sh ]; then
            sudo cp /opt/structura/repos/structura-core/postgresql/pgdump.sh /opt/structura/appdata/postgresql/pgdump/
            sudo chmod +x /opt/structura/appdata/postgresql/pgdump/pgdump.sh
        fi
        echo "config files copied"
"@

    $null = Invoke-SshScript -Script $copyCmd -Label "copycfg" -sshTarget $sshTarget -SshPort $sshPort
    Write-Check "Config files copied to appdata"

    return $true
}

# ============================================================================
# Container deployment
# ============================================================================

function Invoke-ContainerDeployment {
    param([string]$VmIp)

    $sshTarget = "structura@$VmIp"
    $sshPort = 2222

    # Prepare .env from client template
    Write-Host "  Preparing .env from client template..." -ForegroundColor White

    $envCmd = @"
        CLIENT_DIR="/opt/structura/repos/structura-clients-$Client"
        CORE_DIR="/opt/structura/repos/structura-core"

        if [ -f "`$CLIENT_DIR/.env.example" ]; then
            sudo cp "`$CLIENT_DIR/.env.example" "`$CORE_DIR/.env"
            echo "env: from client template"
        else
            echo "env: WARN - client .env.example not found, using core template"
            sudo cp "`$CORE_DIR/.env.example" "`$CORE_DIR/.env"
        fi

        # Wlascicielem musi byc structura - 'make' uruchamia sie jako ten uzytkownik
        # i bez tego nie odczyta .env (root:600 => Permission denied).
        sudo chown structura:structura "`$CORE_DIR/.env"

        # --- Kopia .env do katalogu objetego backupem ---
        # .env lezy w repos/ (poza appdata), wiec NIE byl w zadnym jobie
        # Duplicati. A zawiera wszystkie hasla - bez niego odtworzenie bazy
        # z dumpu jest niemozliwe. Kopiujemy do /opt/structura/config/,
        # ktore jest montowane do Duplicati jako /source/config.
        sudo cp "`$CORE_DIR/.env" /opt/structura/config/.env
        sudo chmod 600 /opt/structura/config/.env
        sudo chown root:root /opt/structura/config/.env
        echo "CONFIG_ENV_BACKED_UP"
        chmod 600 "`$CORE_DIR/.env"

        # Wygeneruj LOKALNE sekrety (Postgres, n8n, NPM, Duplicati, Portainer, SearXNG, SMB).
        # Bez tego make secrets-check odrzuca placeholdery i deploy nie startuje.
        if [ -x "`$CORE_DIR/scripts/generate-secrets.sh" ]; then
            ( cd "`$CORE_DIR" && ./scripts/generate-secrets.sh .env )
        else
            echo "env: WARN - generate-secrets.sh not found"
        fi

        # Sekrety zewnetrzne (Anthropic/Telegram/MS365) NIE sa wymagane na tym etapie -
        # klient wybiera providera LLM przy pierwszej konfiguracji Hermesa.
        echo "ENV_READY"
"@
    $envResult = (Invoke-SshScript -Script $envCmd -Label "env" -sshTarget $sshTarget -SshPort $sshPort).Output
    if ($envResult -match 'ENV_READY') {
        Write-Check ".env utworzony, sekrety lokalne wygenerowane (chmod 600)"
    } else {
        Write-Check ".env setup problem - sprawdz log" -Warn
    }
    if ($PSBoundParameters.ContainsKey("Verbose")) { Write-Host $envResult -ForegroundColor DarkGray }

    # Deploy: make deploy
    Write-Host "  Running make deploy..." -ForegroundColor White

    $deployCmd = @"
        cd /opt/structura/repos/structura-core
        export CLIENT_DIR="/opt/structura/repos/structura-clients-$Client"
        export CLIENT="$Client"
        # 'usermod -aG docker' nie dziala w juz otwartej sesji SSH - nowe czlonkostwo
        # grupy jest czytane przy logowaniu. 'sg docker -c' przelacza grupe w tej sesji.
        if ! command -v make >/dev/null 2>&1; then
            echo "MAKE_MISSING - nie moge uruchomic 'make deploy'"
            exit 1
        fi
        sg docker -c "make secrets-check && make deploy CLIENT=$Client"
        RC=`$?
        if [ `$RC -eq 0 ]; then echo "DEPLOY_DONE"; else echo "DEPLOY_FAILED rc=`$RC"; fi
"@

    $deployResult = Invoke-WithRetry -Action {
        return (Invoke-SshScript -Script $deployCmd -Label "deploy" -sshTarget $sshTarget -SshPort $sshPort).Output
    } -Description "make deploy" -MaxRetries 3

    if ($PSBoundParameters.ContainsKey("Verbose")) {
        Write-Host $deployResult -ForegroundColor DarkGray
    }

    if ($deployResult -match 'DEPLOY_DONE') {
        Write-Check "Containers deployed"
    } elseif ($deployResult -match 'MAKE_MISSING') {
        # Brak make = BLOKADA, nie ostrzezenie. Wczesniej instalator szedl dalej
        # i raportowal 'v NPM configured' oraz 'v Hindsight banks initialized',
        # mimo ze nie wykonalo sie nic. Koniec z falszywymi sukcesami.
        Write-Check "BLOKADA: brak 'make' na VM - ETAP 6/7/8 niemozliwe" -Fail
        Write-Log "make deploy: MAKE_MISSING. Log: $deployResult"
        return $false
    } else {
        Write-Check "Deployment FAILED" -Fail
        Write-Log "make deploy nie zwrocil DEPLOY_DONE. Output: $deployResult"

        # --- DIAGNOSTYKA ---
        # Bylo: komunikat bez tresci -> trzeba bylo zgadywac, a kazdy obieg
        # kosztuje ~15 min (VM + instalacja Ubuntu). Zbierz fakty z VM.
        Write-Host ""
        Write-Host "  --- DIAGNOSTYKA ---" -ForegroundColor Yellow

        # 1. Ostatnie linie outputu make deploy (gdzie stanelo?)
        if ($deployResult) {
            $tail = ($deployResult -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 20) -join "`n"
            Write-Host "  [make deploy - ostatnie linie]:" -ForegroundColor Gray
            $tail -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Write-Log "DEPLOY diag (tail): $tail"
        }

        # 2. Stan kontenerow + logi nie-zdrowych
        $diagCmd = @"
            cd /opt/structura/repos/structura-core
            echo "=== docker compose ps -a ==="
            sg docker -c "docker compose -f docker-compose.yaml ps -a" 2>&1 | head -25
            echo ""
            echo "=== stan kontenerow ==="
            for c in postgresql hindsight n8n npm searxng duplicati portainer homepage; do
                st=`$(sg docker -c "docker inspect --format={{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}no-hc{{end}} `$c" 2>/dev/null)
                echo "  `$c: `$st"
            done
            echo ""
            echo "=== logi nie-zdrowych (ostatnie 15 linii) ==="
            for c in postgresql hindsight n8n npm searxng duplicati portainer homepage; do
                st=`$(sg docker -c "docker inspect --format={{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}} `$c" 2>/dev/null)
                if [ "`$st" != "healthy" ]; then
                    echo "--- `$c (`$st) ---"
                    sg docker -c "docker logs --tail 15 `$c" 2>&1 | sed "s/^/    /"
                fi
            done
            echo ""
            echo "=== .env sanity (bez wartosci sekretow) ==="
            grep -cE "^[A-Z_]+=" .env | sed "s/^/  linii w .env: /"
            grep -E "^(N8N_DB_PASSWORD|HINDSIGHT_PASSWORD|SMB_PASSWORD)=" .env | sed "s/=.*/=<ustawione>/"
            echo "DIAG_DONE"
"@
        $diag = (Invoke-SshScript -Script $diagCmd -Label "deploy-diag" -sshTarget $sshTarget -SshPort $sshPort).Output
        if ($diag) {
            Write-Host ""
            $diag -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
            Write-Log "DEPLOY diag (stan+logi): $diag"
        }
        Write-Host ""
        Write-Host "  Pelny log: C:\structura\setup.log" -ForegroundColor Yellow
        Write-Host "  ----------------------------------------" -ForegroundColor Yellow
        return $false
    }

    # NPM setup
    # UWAGA: setup-npm.sh jest uruchamiany jako skrypt bash przez Invoke-SshScript
    # (nie przez 'make'), bo Makefile nie eksportuje .env, a setup-npm.sh sam go
    # teraz wczytuje. Dodatkowo przekazujemy znacznik sukcesu, zeby NIE raportowac
    # 'v NPM configured' bez pokrycia (bylo: bezwarunkowy Write-Check).
    Write-Host "  Running NPM setup..." -ForegroundColor White
    $npmCmd = @"
        cd /opt/structura/repos/structura-core
        if bash npm/setup-npm.sh; then
            echo "NPM_SETUP_OK"
        else
            echo "NPM_SETUP_FAILED"
        fi
"@
    $npmResult = (Invoke-SshScript -Script $npmCmd -Label "npm-setup" -sshTarget $sshTarget -SshPort $sshPort).Output
    if ($PSBoundParameters.ContainsKey("Verbose")) { Write-Host $npmResult -ForegroundColor DarkGray }
    if ($npmResult -match 'NPM_SETUP_OK') {
        Write-Check "NPM proxy hosts configured (7 hosts)"

        # Certyfikaty TLS tez sa krytyczne: bez nich odtworzone domeny
        # .local nie maja HTTPS. NPM trzyma je w wolumenie letsencrypt_data,
        # ktory mapuje na /opt/structura/appdata/npm/letsencrypt.
        $certCmd = @"
            if [ -d /opt/structura/appdata/npm/letsencrypt ] && [ -n "`$(ls -A /opt/structura/appdata/npm/letsencrypt 2>/dev/null)" ]; then
                sudo rm -rf /opt/structura/config/letsencrypt
                sudo cp -r /opt/structura/appdata/npm/letsencrypt /opt/structura/config/letsencrypt
                echo "CONFIG_CERTS_BACKED_UP"
            else
                echo "CONFIG_CERTS_EMPTY (NPM nie wystawil jeszcze certyfikatow)"
            fi
"@
        $certResult = (Invoke-SshScript -Script $certCmd -Label "certs" -sshTarget $sshTarget -SshPort $sshPort).Output
        if ($certResult -match 'CONFIG_CERTS_BACKED_UP') {
            Write-Check "Certyfikaty TLS skopiowane do backupu (/opt/structura/config)"
        } else {
            Write-Check "Certyfikaty TLS: jeszcze nie ma (NPM wystawi przy pierwszym uzyciu HTTPS)" -Warn
        }
    } else {
        Write-Check "NPM setup NIE powiodl sie - sprawdz log" -Warn
        Write-Log "setup-npm.sh: NPM_SETUP_FAILED. Output: $npmResult"
    }

    # Health check polling
    Write-Host ""
    Write-Host "  Waiting for containers to be healthy..." -ForegroundColor White
    Write-Host ""

    $services = @{
        # 8 kontenerow. Hermes NIE jest tu - dziala natywnie na VM (systemd),
        # a Telegram odszedl z zakresu instalacji.
        "postgresql" = @{ Status = "waiting"; Timeout = 30; CheckCmd = "pg_isready" }
        "hindsight"  = @{ Status = "waiting"; Timeout = 90; CheckCmd = "curl -sf http://127.0.0.1:8888/health" }
        "searxng"    = @{ Status = "waiting"; Timeout = 15; CheckCmd = "curl -sf http://127.0.0.1:8080/healthz" }
        "n8n"        = @{ Status = "waiting"; Timeout = 30; CheckCmd = "curl -sf http://127.0.0.1:5678/healthz" }
        "npm"        = @{ Status = "waiting"; Timeout = 15; CheckCmd = "curl -sf http://127.0.0.1:81/api" }
        "homepage"   = @{ Status = "waiting"; Timeout = 15; CheckCmd = "curl -sf http://127.0.0.1:3000/" }
        "duplicati"  = @{ Status = "waiting"; Timeout = 15; CheckCmd = "curl -sf http://127.0.0.1:8200/" }
        "portainer"  = @{ Status = "waiting"; Timeout = 15; CheckCmd = "true" }  # obraz scratch: brak shella, healthcheck niemozliwy - patrz petla nizej
    }

    # Poll health on VM
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline) {
        $allHealthy = $true
        $healthResults = (Invoke-Ssh -SshArgs (@("-p","$sshPort","-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=NUL",$sshTarget,"docker compose -f /opt/structura/repos/structura-core/docker-compose.yaml ps --format json"))).Output

        foreach ($svc in $services.Keys) {
            $info = $services[$svc]
            if ($info.Status -eq 'healthy') { continue }

            # Check container health
            # UWAGA: NIE uzywamy "docker inspect --format='{{...}}'" jako argumentu
            # ssh - PowerShell 5.1 zdejmuje apostrofy, bash robi brace expansion
            # na {{...}} i komenda sie rozsypuje -> "notfound" -> wieczne "starting"
            # (dokladnie ten sam mechanizm, ktory psul instalacje Dockera).
            # Invoke-SshScript wysyla skrypt PLIKIEM, wiec cytowanie jest bezpieczne.
            # W podwojnym cudzyslowie PS klamry NIE wymagaja escapowania.
            $inspectScript = "docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-hc{{end}}|{{.State.Status}}' $svc 2>/dev/null || echo notfound"
            $checkResult = (Invoke-SshScript -Script $inspectScript -Label "health" -sshTarget $sshTarget -SshPort $sshPort).Output
            $checkResult = $checkResult.Trim()

            # Format: "<health>|<runstate>", np. "healthy|running", "no-hc|running"
            $hStat, $rStat = $checkResult -split '\|', 2
            if (-not $rStat) { $rStat = $checkResult }  # fallback dla 'notfound'

            if ($hStat -eq 'healthy') {
                $info.Status = 'healthy'
            } elseif ($hStat -eq 'no-hc' -and $rStat -eq 'running') {
                # Usluga BEZ healthchecka, ale dziala (np. portainer - obraz
                # scratch, healthcheck niemozliwy: brak /bin/sh).
                # Wczesniej taka usluga czekala 300s i raportowala porazke.
                $info.Status = 'healthy'
            } elseif ($hStat -eq 'unhealthy') {
                $info.Status = 'unhealthy'
                $allHealthy = $false
            } elseif ($rStat -eq 'exited' -or $rStat -eq 'restarting' -or $rStat -eq 'dead') {
                # Kontener padl - to realna porazka, nie 'jeszcze startuje'.
                $info.Status = 'unhealthy'
                $allHealthy = $false
            } else {
                $info.Status = 'starting'
                $allHealthy = $false
            }
        }

        if (-not $Quiet) {
            # Odswiezanie tabeli statusu BEZ rozjezdzania sie linii.
            # Poprzednio bylo `r + newline*N, co przy kazdym obrocie dopisywalo
            # kolejny blok i statusy siekle sie jedno pod drugim.
            # Teraz mierzymy wiersz, na ktorym zaczelismy tabele i wracamy
            # kursorem na te sama pozycje - tablica jest stabilna w miejscu.
            if ($script:healthTableTop -eq $null) {
                $script:healthTableTop = [Console]::CursorTop
            }
            try {
                [Console]::SetCursorPosition(0, $script:healthTableTop)
            } catch {
                # Brak konsoli interaktywnej (przekierowanie) - bez pozycjonowania
            }
            # UWAGA: modulo MUSI byc przed rzutowaniem na [int].
            # (Get-Date).Ticks ~ 6.4e14 przekracza zakres Int32 (2.1e9),
            # wiec "[int](Ticks/...) % Count" rzucalo:
            #   Cannot convert value "63925606501,6067" to type "System.Int32"
            # i przerywalo instalacje tuz po starcie kontenerow.
            # Dzielenie 10000000 + modulo najpierw, rzutowanie na koncu.
            $spinnerIdx = [int]((((Get-Date).Ticks / 10000000) % $BRAILLE_SPINNER.Count))
            foreach ($svc in $services.Keys) {
                $info = $services[$svc]
                $svcPadded = $svc.PadRight(12)
                $frame = $BRAILLE_SPINNER[$spinnerIdx % $BRAILLE_SPINNER.Count]
                $elapsedStr = Format-Elapsed -Seconds $elapsed
                # Kazda linia dopelniona do stalej szerokosci - nadpisuje
                # ewentualne resztki dluzszego tekstu z poprzedniej iteracji.
                switch ($info.Status) {
                    'healthy'   { $line = "  $svcPadded [v] healthy ($elapsedStr)" }
                    'unhealthy' { $line = "  $svcPadded [x] unhealthy ($elapsedStr)" }
                    'starting'  { $line = "  $svcPadded [$frame] starting... ($elapsedStr)" }
                    default     { $line = "  $svcPadded [ ] waiting..." }
                }
                Write-Host ($line.PadRight(60))
            }
            # Dopisz tyle linii, ile ma tabela, zeby kolejne odswiezenie
            # mialo dokad wrocic kursorem.
            Write-Host (" " * 60)
        }

        if ($allHealthy) { break }
        Start-Sleep -Seconds 2
    }

    Write-Host ""
    $script:healthTableTop = $null
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
    $sshPort = 2222

    # Init Hindsight banks
    Write-Host "  Initializing Hindsight banks..." -ForegroundColor White

    # UWAGA: 'set -e' jest KRYTYCZNE. Bez niego 'echo HINDSIGHT_INIT_DONE'
    # wykonywalo sie TAKZE po nieudanym make, wiec warunek ponizej byl zawsze
    # prawdziwy i instalator raportowal "v Hindsight banks initialized (2 banks)"
    # mimo ze nie powstal ani jeden bank.
    $initCmd = @"
        set -e
        CLIENT_DIR="/opt/structura/repos/structura-clients-$Client"
        if [ ! -f "`$CLIENT_DIR/init-hindsight.sh" ]; then
            echo "INIT_HINDSIGHT_MISSING"
            exit 1
        fi
        # Hermes jest NATYWNY (nie w kontenerze), wiec init-hindsight.sh
        # musi dzialac z HOSTA - API Hindsight jest wystawione na localhost:8888.
        # Uruchamiamy skrypt bezposrednio (bez 'make', ktore wymagaloby repo).
        chmod +x "`$CLIENT_DIR/init-hindsight.sh"
        # UWAGA: 127.0.0.1, NIE 'localhost'. Compose binduje port hindsight
        # jako "127.0.0.1:8888:8888" (tylko IPv4), a 'localhost' rozwiazuje
        # sie najpierw na ::1 -> "Connection refused". Ten sam blad zatrzymal
        # healthcheck n8n (fala 6e); tutaj objaw bylby gorszy - bank pamieci
        # nigdy nie powstalby i ETAP 7 raportowalby porazke inicjalizacji.
        HINDSIGHT_URL="http://127.0.0.1:8888" bash "`$CLIENT_DIR/init-hindsight.sh"
        # Weryfikacja REALNA - liczymy banki przez API, nie przez komunikat.
        BANK_COUNT=`$(curl -sf http://127.0.0.1:8888/v1/default/banks 2>/dev/null | grep -o '"bank_id"' | wc -l)
        if [ "`$BANK_COUNT" -ge 1 ]; then
            echo "HINDSIGHT_INIT_DONE banks=`$BANK_COUNT"
        else
            echo "HINDSIGHT_NO_BANKS"
            exit 1
        fi
"@

    $initResult = Invoke-WithRetry -Action {
        return (Invoke-SshScript -Script $initCmd -Label "hindsight" -sshTarget $sshTarget -SshPort $sshPort).Output
    } -Description "init-hindsight" -MaxRetries 3

    if ($PSBoundParameters.ContainsKey("Verbose")) { Write-Host $initResult -ForegroundColor DarkGray }

    if ($initResult -match 'HINDSIGHT_INIT_DONE') {
        # Liczba bankow pochodzi z REALNEGO zapytania do API Hindsight,
        # a nie ze stalej w komunikacie (bylo: na sztywno "(2 banks)").
        $bankInfo = if ($initResult -match 'banks=(\d+)') { "$($Matches[1]) bank(i)" } else { "banki utworzone" }
        Write-Check "Hindsight: $bankInfo"
    } elseif ($initResult -match 'MAKE_MISSING') {
        Write-Check "BLOKADA: brak 'make' - init-hindsight niemozliwy" -Fail
        return $false
    } elseif ($initResult -match 'HINDSIGHT_NO_BANKS') {
        Write-Check "Hindsight: zadnego banku nie utworzono - sprawdz log" -Fail
        Write-Log "init-hindsight: HINDSIGHT_NO_BANKS. Output: $initResult"
        return $false
    } else {
        Write-Check "Hindsight init FAILED - sprawdz log" -Fail
        Write-Log "init-hindsight nie zwrocil HINDSIGHT_INIT_DONE. Output: $initResult"
        return $false
    }

    return $true
}

# ============================================================================
# Hermes natywnie na VM (bez kontenera) - instalacja + usluga systemd
# ============================================================================

function Install-NativeHermes {
    param(
        [string]$VmIp,
        [string]$Client
    )

    Write-Host "  Instalowanie Hermesa natywnie na VM (bez kontenera)..." -ForegroundColor White

    $sshTarget = "structura@$VmIp"
    $sshPort = 2222

    # ------------------------------------------------------------------
    # 1. Instalacja hermes-agent z PyPI
    #    uv jest szybszy i daje izolowane srodowisko (bez smieci systemowych).
    #    Fallback: python3 -m venv + pip (gdyby uv nie bylo dostepne).
    # ------------------------------------------------------------------
    $installCmd = @"
        set -e

        # Python + narzedzia
        sudo apt-get install -y python3 python3-venv python3-pip curl git 2>/dev/null

        # uv (szybki instalator) - jesli sie nie uda, uzywamy venv+pip
        if ! command -v uv >/dev/null 2>&1; then
            curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null || true
            export PATH="`$HOME/.local/bin:`$PATH"
        fi

        HERMES_HOME="`$HOME/.hermes"
        mkdir -p "`$HERMES_HOME"

        if command -v uv >/dev/null 2>&1; then
            echo "Instaluje przez uv..."
            uv tool install hermes-agent 2>&1 | tail -3 || {
                echo "uv nieudane - fallback na venv"
                python3 -m venv "`$HERMES_HOME/venv"
                "`$HERMES_HOME/venv/bin/pip" install --upgrade pip -q
                "`$HERMES_HOME/venv/bin/pip" install hermes-agent -q
            }
        else
            echo "Instaluje przez venv+pip..."
            python3 -m venv "`$HERMES_HOME/venv"
            "`$HERMES_HOME/venv/bin/pip" install --upgrade pip -q
            "`$HERMES_HOME/venv/bin/pip" install hermes-agent -q
        fi

        # Ustal sciezke binarki hermes
        HERMES_BIN=""
        if [ -x "`$HOME/.local/bin/hermes" ]; then
            HERMES_BIN="`$HOME/.local/bin/hermes"
        elif [ -x "`$HOME/.local/share/uv/tools/hermes-agent/bin/hermes" ]; then
            HERMES_BIN="`$HOME/.local/share/uv/tools/hermes-agent/bin/hermes"
        elif [ -x "`$HERMES_HOME/venv/bin/hermes" ]; then
            HERMES_BIN="`$HERMES_HOME/venv/bin/hermes"
        fi

        if [ -z "`$HERMES_BIN" ]; then
            echo "HERMES_BIN_NOT_FOUND"
            exit 1
        fi
        echo "HERMES_BIN=`$HERMES_BIN"
        "`$HERMES_BIN" --version 2>&1 | head -2
        echo "HERMES_INSTALLED"
"@
    $installResult = (Invoke-SshScript -Script $installCmd -Label "hermes-install" -sshTarget $sshTarget -SshPort $sshPort).Output

    if ($PSBoundParameters.ContainsKey("Verbose")) { Write-Host $installResult -ForegroundColor DarkGray }

    if ($installResult -notmatch 'HERMES_INSTALLED') {
        Write-Check "Hermes: instalacja natywna NIE powiodla sie" -Fail
        Write-Log "Install-NativeHermes failed. Output: $installResult"
        return $false
    }
    Write-Check "Hermes zainstalowany natywnie (PyPI)"

    # ------------------------------------------------------------------
    # 2. Konfiguracja klienta -> ~/.hermes
    #    Hermes natywny czyta z ~/.hermes/. Kopiujemy config, SOUL.md, skille.
    # ------------------------------------------------------------------
    $configCmd = @"
        set -e
        CLIENT_DIR="/opt/structura/repos/structura-clients-$Client"
        HERMES_HOME="`$HOME/.hermes"
        mkdir -p "`$HERMES_HOME"

        # config.yaml klienta (model, providery, tierowanie)
        if [ -f "`$CLIENT_DIR/hermes-config.yaml" ]; then
            cp "`$CLIENT_DIR/hermes-config.yaml" "`$HERMES_HOME/config.yaml"
        fi

        # ------------------------------------------------------------------
        # ~/.hermes/.env - zmienne SRODOWISKOWE dla Hermesa
        #
        # UWAGA: czesc konfiguracji Hermes czyta ze SRODOWISKA, nie z YAML.
        # Przyklad: plugin web/searxng uzywa SEARXNG_URL (env), a sekcja
        # 'searxng:' w config.yaml jest IGNOROWANA (sprawdzone w kodzie:
        # plugins/web/searxng/provider.py -> KEY_ENV = "SEARXNG_URL").
        # Bez tego pliku 'web.search_backend: searxng' z config.yaml nie ma
        # dokad sie podlaczyc i wyszukiwarka nie dziala.
        # ------------------------------------------------------------------
        if [ ! -f "`$HERMES_HOME/.env" ]; then
            touch "`$HERMES_HOME/.env"
            chmod 600 "`$HERMES_HOME/.env"
        fi

        # SEARXNG_URL: kontener searxng wystawia port na 127.0.0.1:8080 w tej VM.
        if ! grep -q '^SEARXNG_URL=' "`$HERMES_HOME/.env" 2>/dev/null; then
            echo 'SEARXNG_URL=http://127.0.0.1:8080' >> "`$HERMES_HOME/.env"
            echo "env: SEARXNG_URL ustawiony"
        else
            echo "env: SEARXNG_URL juz ustawiony"
        fi

        # N8N: adres instancji (skille moga go uzywac)
        if ! grep -q '^N8N_URL=' "`$HERMES_HOME/.env" 2>/dev/null; then
            echo 'N8N_URL=http://127.0.0.1:5678' >> "`$HERMES_HOME/.env"
        fi

        # ------------------------------------------------------------------
        # Haslo sudo/VM - AWARYJNE, dla Hermesa (gdyby kiedys wyskoczylo).
        #
        # UWAGA: sudo dziala BEZ HASLA (cloud-init ustawia
        #   /etc/sudoers.d/010-structura-nopasswd: structura ALL=(ALL) NOPASSWD:ALL)
        # wiec to haslo NIE jest potrzebne do normalnej pracy. Zapisujemy je
        # jako awaryjne - np. gdy ktos wylaczy NOPASSWD albo Hermes bedzie
        # potrzebowal hasla przy operacji na konsoli VM.
        #
        # To haslo logowania do VM (ustawiane przez VBoxManage --password),
        # NIE do GitHub ani do zadnej uslugi zewnetrznej.
        #
        # Plik ma chmod 600, wlasciciel structura - tylko Hermes go widzi.
        #
        # ZMIENNE: SUDO_PASSWORD + VM_USER/VM_PASSWORD (aliasy, zeby model
        # nie musial zgadywac nazwy).
        # ------------------------------------------------------------------
        if ! grep -q '^SUDO_PASSWORD=' "`$HERMES_HOME/.env" 2>/dev/null; then
            {
                echo ''
                echo '# Hasla awaryjne VM (sudo dziala normalnie BEZ hasla - patrz sudoers.d)'
                echo 'SUDO_PASSWORD=structura'
                echo 'VM_USER=structura'
                echo 'VM_PASSWORD=structura'
            } >> "`$HERMES_HOME/.env"
            echo "env: SUDO_PASSWORD ustawiony (awaryjny)"
        fi

        echo "hermes env: `$(grep -c '=' "`$HERMES_HOME/.env" 2>/dev/null || echo 0) zmiennych"

        # SOUL.md - osobowosc "prawnicza"
        if [ -f "`$CLIENT_DIR/SOUL.md" ]; then
            cp "`$CLIENT_DIR/SOUL.md" "`$HERMES_HOME/SOUL.md"
        fi

        # Reguly pamieci (wytyczne dla modelu)
        if [ -f "`$CLIENT_DIR/hindsight-rules.yaml" ]; then
            cp "`$CLIENT_DIR/hindsight-rules.yaml" "`$HERMES_HOME/hindsight-rules.yaml"
        fi

        # --- Konfiguracja pluginu pamieci (KRYTYCZNE) ---
        # Plugin czyta $HERMES_HOME/hindsight/config.json (NIE config.yaml).
        # Zawiera: tryb polaczenia, bank, auto_retain/auto_recall, tryby recall.
        # Bez tego: bank "hermes" zamiast "Kontekst_Sprawy", tryb "cloud"
        # zamiast "local_external" (Hermes szukalby Hindsight Cloud).
        if [ -f "`$CLIENT_DIR/hindsight/config.json" ]; then
            mkdir -p "`$HERMES_HOME/hindsight"
            cp "`$CLIENT_DIR/hindsight/config.json" "`$HERMES_HOME/hindsight/config.json"
            chmod 600 "`$HERMES_HOME/hindsight/config.json"
            echo "HINDSIGHT_CONFIG_INSTALLED"
        else
            echo "HINDSIGHT_CONFIG_MISSING"
        fi

        # --- Skille: dwa zrodla (core = wspolne, klient = custom) ---
        mkdir -p "`$HERMES_HOME/skills"
        CORE_DIR="/opt/structura/repos/structura-core"

        # 1) Wspolne skille z core (generyczne, utrzymywane w jednym miejscu)
        CORE_SKILLS=0
        if [ -d "`$CORE_DIR/skills" ]; then
            cp -r "`$CORE_DIR/skills/." "`$HERMES_HOME/skills/" 2>/dev/null || true
            CORE_SKILLS=`$(ls -1 "`$CORE_DIR/skills" 2>/dev/null | wc -l)
            echo "CORE_SKILLS count=`$CORE_SKILLS"
        else
            echo "CORE_SKILLS_MISSING"
        fi

        # 2) Skille klienta (custom). Kopiowane PO core -> moga nadpisac wspolne.
        CLIENT_SKILLS=0
        if [ -d "`$CLIENT_DIR/skills" ]; then
            cp -r "`$CLIENT_DIR/skills/." "`$HERMES_HOME/skills/" 2>/dev/null || true
            CLIENT_SKILLS=`$(ls -1 "`$CLIENT_DIR/skills" 2>/dev/null | wc -l)
            echo "CLIENT_SKILLS count=`$CLIENT_SKILLS"
        else
            echo "CLIENT_SKILLS_MISSING"
        fi

        # Lacznie w ~/.hermes/skills
        SKILL_COUNT=`$(ls -1 "`$HERMES_HOME/skills" 2>/dev/null | wc -l)
        echo "SKILLS_INSTALLED count=`$SKILL_COUNT"

        # Motyw dashboardu (Aether - ciemnoszare tlo czatu)
        if [ -d "`$CLIENT_DIR/dashboard-themes" ]; then
            mkdir -p "`$HERMES_HOME/dashboard-themes"
            cp -r "`$CLIENT_DIR/dashboard-themes/." "`$HERMES_HOME/dashboard-themes/" 2>/dev/null || true
            THEME_NAME=`$(ls -1 "`$HERMES_HOME/dashboard-themes" 2>/dev/null | head -1 | sed 's/\.yaml`$//')
            echo "THEME_INSTALLED name=`$THEME_NAME"
        fi

        echo "CONFIG_DONE"
"@
    $configResult = (Invoke-SshScript -Script $configCmd -Label "hermes-config" -sshTarget $sshTarget -SshPort $sshPort).Output
    if ($PSBoundParameters.ContainsKey("Verbose")) { Write-Host $configResult -ForegroundColor DarkGray }

    if ($configResult -match 'CONFIG_DONE') {
        Write-Check "Konfiguracja klienta wgrana do ~/.hermes"
    } else {
        Write-Check "Konfiguracja klienta: sprawdz log" -Warn
    }

    $themeMatch = [regex]::Match($configResult, 'THEME_INSTALLED name=([\w\-]+)')
    if ($themeMatch.Success) {
        $themeName = $themeMatch.Groups[1].Value
        Write-Check "Motyw dashboardu: $themeName"
    } else {
        Write-Check "Motyw dashboardu: nie znaleziono (sprawdz repo klienta)" -Warn
    }

    # Skille: osobno wspolne (core) i custom (klient)
    $coreSkills = [regex]::Match($configResult, 'CORE_SKILLS count=(\d+)')
    $clientSkills = [regex]::Match($configResult, 'CLIENT_SKILLS count=(\d+)')
    $totalSkills = [regex]::Match($configResult, 'SKILLS_INSTALLED count=(\d+)')

    if ($coreSkills.Success -and $clientSkills.Success) {
        $c = [int]$coreSkills.Groups[1].Value
        $k = [int]$clientSkills.Groups[1].Value
        $t = if ($totalSkills.Success) { $totalSkills.Groups[1].Value } else { "$($c + $k)" }
        Write-Check "Skille: $t (wspolne z core: $c, custom klienta: $k)"
    } elseif ($configResult -match 'CORE_SKILLS_MISSING') {
        Write-Check "Skille: BRAK katalogu skills/ w core" -Warn
    } else {
        Write-Check "Skille: sprawdz log" -Warn
    }

    # Konfiguracja pamieci - bez niej pamiec nie dziala od pierwszego slowa
    if ($configResult -match 'HINDSIGHT_CONFIG_INSTALLED') {
        Write-Check "Pamiec: konfiguracja Hindsight wgrana (~/.hermes/hindsight/config.json)"
    } else {
        Write-Check "Pamiec: BRAK hindsight/config.json - pamiec nie zapisze sie automatycznie" -Fail
        Write-Log "Install-NativeHermes: HINDSIGHT_CONFIG_MISSING (brak w repo klienta)"
        return $false
    }

    # ------------------------------------------------------------------
    # 3. Usluga systemd - Hermes startuje z VM (VM startuje z Windowsem)
    # ------------------------------------------------------------------
    $serviceCmd = @"
        set -e

        # Znajdz binarke (ta sama logika co przy instalacji)
        HERMES_BIN=""
        for cand in "`$HOME/.local/bin/hermes" "`$HOME/.local/share/uv/tools/hermes-agent/bin/hermes" "`$HOME/.hermes/venv/bin/hermes"; do
            if [ -x "`$cand" ]; then HERMES_BIN="`$cand"; break; fi
        done
        if [ -z "`$HERMES_BIN" ]; then echo "HERMES_BIN_NOT_FOUND"; exit 1; fi

        # Serwer DASHBOARDU (UI w przegladarce + /health).
        # UWAGA: 'hermes serve' to backend headless BEZ UI i BEZ /health -
        # klient potrzebuje dashboardu, ktory wystawia UI i endpoint /health.
        # Port 9119 = domyslny port dashboardu (zgodny z NPM dashboard.local).
        # --skip-build: nie buduje UI od nowa (dist jest w pakiecie), dzieki
        # czemu start jest szybki i nie wymaga npm na VM.
        sudo tee /etc/systemd/system/hermes.service > /dev/null << HERMESEOF
[Unit]
Description=Hermes Agent dashboard
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=structura
WorkingDirectory=/opt/structura
Environment=HOME=/home/structura
# ---------------------------------------------------------------------------
# BIND: 127.0.0.1, NIE 0.0.0.0 (KRYTYCZNE)
#
# UWAGA: bylo tu --host 0.0.0.0 "zeby kontener NPM mogl dosiegnac dashboard
# przez host.docker.internal". To NIE dziala i jest niebezpieczne:
#
# Hermes od czerwca 2026 (hardening hermes-0day) ODRZUCA start przy
# publicznym bindzie bez skonfigurowanego providera auth. Dokladny komunikat
# z hermes_cli/web_server.py:1080:
#
#   "Refusing to bind dashboard to 0.0.0.0 - <gate_reason>, but no auth
#    providers are registered."
#   -> SystemExit, usluga nie wstaje
#
# Dodatkowo --insecure jest NO-OP (nie omija juz bramki auth). Opcja pomocy:
#   "a public bind always requires an auth provider (password or OAuth).
#    Bind 127.0.0.1 + tunnel to keep it local."
#
# DLACZEGO 127.0.0.1 JEST WYSTARCZAJACE:
#   - NPM (nasz reverse proxy) dziala na HOSCIE VM w sieci Docker. Aby
#     dosiegnac usluge na 127.0.0.1 hoscie, uzywa network_mode: host lub
#     extra_hosts: host.docker.internal:host-gateway (patrz docker-compose).
#   - Dashboard jest dodatkowo dostepny przez NPM (proxy host dashboard.local).
#   - Bezpieczniej: nie wystawiamy UI na wszystkie interfejsy bez auth.
#
# Jesli kiedys potrzebny bedzie publiczny bind: skonfiguruj
# dashboard.basic_auth w ~/.hermes/config.yaml (username + password_hash).
# --- Fala 16: bind 0.0.0.0 + basic_auth (dashboard.local przez NPM) ---
# 127.0.0.1 -> kontener NPM NIE dosiegnie loopbacka hosta -> 502
# 172.17.0.1 -> dosiegnie, ale Hermes odrzuca Host: dashboard.local
#               ("Invalid Host header")
# 0.0.0.0 -> akceptuje dowolny Host; ochrone daje basic_auth
#            (Hermes: "no unauthenticated public-dashboard option").
HERMES_PY="`$HOME/.local/share/uv/tools/hermes-agent/bin/python3"
[ -x "`$HERMES_PY" ] || HERMES_PY="`$HERMES_BIN"
DASH_USER="asystent"
DASH_PASS_PLAIN="`$(`$HERMES_PY -c 'import secrets; print(secrets.token_urlsafe(12))')"
DASH_HASH="`$(`$HERMES_PY -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('`$DASH_PASS_PLAIN'))" 2>/dev/null)"
DASH_SECRET="`$(`$HERMES_PY -c 'import secrets; print(secrets.token_hex(32))')"
if [ -z "`$DASH_HASH" ]; then echo "DASHBOARD_HASH_FAILED"; exit 1; fi

sudo mkdir -p /etc/systemd/system/hermes.service.d
sudo tee /etc/systemd/system/hermes.service.d/10-bind.conf > /dev/null << DROPINEOF
[Service]
Environment=HERMES_DASHBOARD_BASIC_AUTH_USERNAME=`$DASH_USER
Environment=HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=`$DASH_HASH
Environment=HERMES_DASHBOARD_BASIC_AUTH_SECRET=`$DASH_SECRET
ExecStart=
ExecStart=`$HERMES_BIN dashboard --host 0.0.0.0 --port 9119 --no-open --skip-build
DROPINEOF

# Haslo do .env - klient je odczyta, zeby sie zalogowac do dashboardu.
if ! grep -q '^DASHBOARD_ADMIN_PASSWORD=' "`$HERMES_HOME/.env" 2>/dev/null; then
    {
        echo ''
        echo '# Login do dashboardu Hermesa (http://dashboard.local)'
        echo "DASHBOARD_ADMIN_USER=`$DASH_USER"
        echo "DASHBOARD_ADMIN_PASSWORD=`$DASH_PASS_PLAIN"
    } >> "`$HERMES_HOME/.env"
fi
echo "dashboard: basic_auth user=`$DASH_USER (bind 0.0.0.0)"
sudo systemctl daemon-reload
Restart=on-failure
RestartSec=10
StandardOutput=append:/opt/structura/appdata/hermes/hermes.log
StandardError=append:/opt/structura/appdata/hermes/hermes.log

[Install]
WantedBy=multi-user.target
HERMESEOF

        sudo mkdir -p /opt/structura/appdata/hermes
        sudo chown -R structura:structura /opt/structura/appdata/hermes

        sudo systemctl daemon-reload
        sudo systemctl enable hermes 2>/dev/null || true
        sudo systemctl restart hermes

        # ------------------------------------------------------------------
        # CZEKANIE na start dashboardu.
        #
        # UWAGA: bylo tu 'sleep 5' i sprawdzenie 'systemctl is-active'.
        # Hermes dashboard startuje dluzej (ladowanie FastAPI/uvicorn, skille,
        # konfiguracja) - 5 sekund to za malo, wiec instalator raportowal
        # "Usluga hermes.service NIE wystartowala" mimo poprawnego startu.
        #
        # Teraz: petla do 90s, sprawdzajaca REALNE HTTP /health (a nie tylko
        # is-active - proces moze zyc, a jeszcze nie sluchac na porcie).
        # ------------------------------------------------------------------
        HERMES_ACTIVE=0
        for i in `$(seq 1 30); do
            if curl -sf http://127.0.0.1:9119/health >/dev/null 2>&1; then
                echo "HERMES_ACTIVE (po `$((i*3))s, /health OK)"
                HERMES_ACTIVE=1
                break
            fi
            # Proces padl? Nie ma sensu czekac dalej.
            if ! systemctl is-active --quiet hermes; then
                echo "HERMES_PROCESS_DEAD (po `$((i*3))s)"
                break
            fi
            sleep 3
        done

        if [ "`$HERMES_ACTIVE" -eq 0 ]; then
            # Ostatnia szansa: UI odpowiada bez /health (starsze wersje)
            if curl -sf http://127.0.0.1:9119/ >/dev/null 2>&1; then
                echo "HERMES_ACTIVE_UI_ONLY"
                HERMES_ACTIVE=1
            fi
        fi

        if [ "`$HERMES_ACTIVE" -eq 0 ]; then
            echo "HERMES_INACTIVE"
            echo "--- diagnostyka ---"
            systemctl status hermes --no-pager 2>&1 | head -12
            echo "--- log ---"
            tail -20 /opt/structura/appdata/hermes/hermes.log 2>&1
        fi
"@
    $serviceResult = (Invoke-SshScript -Script $serviceCmd -Label "hermes-service" -sshTarget $sshTarget -SshPort $sshPort).Output
    if ($PSBoundParameters.ContainsKey("Verbose")) { Write-Host $serviceResult -ForegroundColor DarkGray }

    if ($serviceResult -match 'HERMES_ACTIVE') {
        Write-Check "Usluga hermes.service aktywna (start z VM)"
    } else {
        Write-Check "Usluga hermes.service NIE wystartowala" -Fail
        Write-Log "hermes.service failed. Output: $serviceResult"
        return $false
    }

    # Hermes musi moc zarzadzac kontenerami - dodaj do grupy docker
    $grpCmd = @"
        sudo usermod -aG docker structura 2>/dev/null || true
        if id structura | grep -q docker; then echo "DOCKER_GRP_OK"; else echo "DOCKER_GRP_MISSING"; fi
"@
    $grpResult = (Invoke-SshScript -Script $grpCmd -Label "hermes-dockergrp" -sshTarget $sshTarget -SshPort $sshPort).Output
    if ($grpResult -match 'DOCKER_GRP_OK') {
        Write-Check "Hermes ma dostep do Dockera (grupa docker)"
    }

    return $true
}

# ============================================================================
# Autostart VM z Windowsem (wymog: klient restartuje PC -> wszystko dziala)
# ============================================================================

function Install-VmAutostart {
    param([string]$VmName)

    Write-Host "  Konfigurowanie autostartu VM z Windowsem..." -ForegroundColor White

    # VBoxManage startvm --type headless uruchamia VM bez okna (w tle).
    # Zadanie w Harmonogramie zadan:
    #   - Trigger: przy starcie systemu (ONSTART)
    #   - Kontekst: SYSTEM (dziala bez logowania uzytkownika!)
    #   - Delay: 30 s, zeby VirtualBox zdazyl wystartowac swoje uslugi
    #
    # UWAGA: zadanie musi dzialac jako SYSTEM, a nie "przy logowaniu" - klient
    # moze zostawic komputer wlaczony bez zalogowania sesji, a asystent ma
    # dzialac w tle.
    $vbox = Get-VBoxManage
    if (-not $vbox) {
        Write-Check "Autostart VM: VBoxManage nie znaleziony" -Warn
        return $false
    }

    $vboxDir = Split-Path $vbox -Parent

    # VBoxSVC/VBoxSDS musza byc uruchomione zanim ruszy VM. VirtualBox
    # rejestruje wlasne uslugi przy instalacji, ale dla pewnosci dajemy delay.
    $taskName = "STRUCTURA-VM-Autostart"
    $scriptCmd = "`"$vboxDir\VBoxManage.exe`" startvm `"$VmName`" --type headless"

    # Usun poprzednie zadanie (idempotencja przy re-runie)
    $null = & schtasks /Delete /TN $taskName /F 2>&1

    # Trigger ONSTART + SYSTEM (bez logowania) + 30 s opoznienia
    $createOut = & schtasks /Create /TN $taskName /TR $scriptCmd /SC ONSTART /RU SYSTEM /RL HIGHEST /DELAY 0000:30 /F 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Check "Autostart VM: nie udalo sie utworzyc zadania ($createOut)" -Warn
        return $false
    }

    Write-Check "Autostart VM: zadanie '$taskName' (start systemu, 30 s, bez logowania)"
    Write-Log "Autostart VM: schtasks /Create /TN $taskName /SC ONSTART /RU SYSTEM /DELAY 0000:30"

    # Dodatkowo: VBoxManage setproperty + autostart VBox wlasnym mechanizmem
    # (dziala gdy VM ma wlaczony autostart w VirtualBox Manager).
    $null = & $vbox modifyvm $VmName --autostart-enabled on --autostart-delay 30 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Check "Autostart VM: VirtualBox autostart-enabled on (delay 30s)"
    }

    return $true
}

# ============================================================================
# Wspoldzielony folder ai_workspace (Windows <-> VM), TRWALY
# ============================================================================

function Install-SharedFolder {
    param(
        [string]$VmName,
        [string]$VmIp
    )

    Write-Host "  Konfigurowanie wspoldzielonego folderu ai_workspace..." -ForegroundColor White

    # ------------------------------------------------------------------------
    # WYBOR METODY: VirtualBox Shared Folders (vboxsf), NIE SMB.
    #
    # Dlaczego NIE SMB:
    #   VM ma --nic1 nat, wiec Windows NIE OSIAGA VM na porcie 445.
    #   Instalator raportowal "\127.0.0.1i-workspace" - ale 127.0.0.1 w tym
    #   kontekscie to WINDOWS, nie VM. Udzial SMB w VM byl z hosta nieosiagalny.
    #
    # Dlaczego vboxsf:
    #   - dziala BEZ sieci (nie potrzebuje NIC ani portu 445)
    #   - jest TRWALY: folder zyje na dysku Windows, montuje sie przy starcie VM
    #   - brak dodatkowego hasla do zarzadzania
    #   - VBoxManage sharedfolder add --automount montuje go automatycznie
    #
    # Wymaga: Guest Additions w gosciu (vboxsf kernel module).
    # ------------------------------------------------------------------------

    $vbox = Get-VBoxManage
    if (-not $vbox) { return $false }

    # Folder po stronie Windows - w profilu uzytkownika, zeby byl naturalny
    # i latwy do znalezienia w Eksploratorze.
    $hostFolder = Join-Path $env:USERPROFILE "STRUCTURA-PLiki"
    if (-not (Test-Path $hostFolder)) {
        $null = New-Item -ItemType Directory -Path $hostFolder -Force
    }

    # Podfolder na dokumenty spraw (klient pracuje na plikach)
    $sprawyFolder = Join-Path $hostFolder "Sprawy"
    if (-not (Test-Path $sprawyFolder)) {
        Write-Log "SharedFolder: tworze $sprawyFolder"
        $null = New-Item -ItemType Directory -Path $sprawyFolder -Force
    }

    # Rejestracja udzialu w VirtualBox z automount
    # --automount: montuje sie automatycznie przy starcie VM
    #       (bez tego trzeba recznie 'mount -t vboxsf' po kazdym restarcie)
    # ------------------------------------------------------------------
    # KRYTYCZNE: 'sharedfolder add' dziala TYLKO przy WYLACZONEJ VM.
    # Przy dzialajacej polecenie milczaco zawodzi (i zwraca 0), a montaz
    # nigdy nie powstaje. Sprawdzone na zywej VM: VBoxControl raportowal
    # "No Shared Folders available", a katalog byl zwyklym ext4 zamiast
    # vboxsf - czyli VM i Windows NIE dzielily plikow wcale.
    #
    # Dlatego: rozgalezienie po stanie VM.
    #   dziala -> 'controlvm sharedfolder add' (bez restartu VM)
    #   stoi   -> 'modifyvm --sharedfolder add'
    # ------------------------------------------------------------------
    $vmRunning = (& $vbox list runningvms 2>&1 | Out-String) -match [regex]::Escape("`"$VmName`"")

    if ($vmRunning) {
        # Usun stara rejestracje (jesli jest), potem dodaj na zywo.
        $null = & $vbox controlvm $VmName sharedfolder remove "ai-workspace" 2>&1
        $addOut = & $vbox controlvm $VmName sharedfolder add "ai-workspace" `
            --hostpath "$hostFolder" --automount --auto-mount-point "/opt/structura/ai-workspace" 2>&1
        $regMode = "controlvm (VM dziala)"
    } else {
        $null = & $vbox modifyvm $VmName --sharedfolder remove "ai-workspace" 2>&1
        $addOut = & $vbox modifyvm $VmName --sharedfolder add "ai-workspace" `
            --hostpath "$hostFolder" --automount --auto-mount-point "/opt/structura/ai-workspace" 2>&1
        $regMode = "modifyvm (VM zatrzymana)"
    }

    # WERYFIKACJA: samo $LASTEXITCODE nie wystarcza (patrz wyzej) - pytamy
    # VirtualBox, czy udzial NAPRAWDE jest zarejestrowany.
    Start-Sleep -Seconds 2
    $listOut = & $vbox sharedfolder list $VmName 2>&1 | Out-String
    if ($listOut -notmatch 'ai-workspace') {
        Write-Check "Folder wspoldzielony: rejestracja NIEUDANA ($regMode)" -Warn
        Write-Log "SharedFolder not registered. add: $addOut"
        Write-Host "      Recznie: VBoxManage controlvm $VmName sharedfolder add ai-workspace --hostpath `"$hostFolder`" --automount --auto-mount-point /opt/structura/ai-workspace" -ForegroundColor Yellow
        return $false
    }
    Write-Log "SharedFolder zarejestrowany przez $regMode"

    Write-Check "Folder wspoldzielony: $hostFolder -> VM:/opt/structura/ai-workspace (automount)"

    # Upewnij sie ze Guest Additions sa zainstalowane w gosciu (vboxsf)
    $sshTarget = "structura@$VmIp"
    $sshPort = 2222
    $gaCheck = @"
        if lsmod | grep -q vboxsf || [ -d /opt/VBoxGuestAdditions-* ]; then
            echo "GA_OK"
        else
            echo "GA_MISSING"
        fi
"@
    $gaResult = (Invoke-SshScript -Script $gaCheck -Label "ga-check" -sshTarget $sshTarget -SshPort $sshPort).Output

    if ($gaResult -match 'GA_MISSING') {
        # UWAGA: GA powinny byc zainstalowane w ETAPIE 4 (Invoke-DockerSetup).
        # Ten blok jest zabezpieczeniem dla re-instalacji / starszych VM-na.
        # Bez Guest Additions vboxsf nie zadziala. Instalujemy z repo Ubuntu
        # (virtualbox-guest-utils dostarcza vboxsf dla VBox 7.x).
        Write-Host "    Guest Additions brak - instaluje virtualbox-guest-utils..." -ForegroundColor DarkGray
        $gaInstall = @"
            sudo apt-get install -y virtualbox-guest-utils virtualbox-guest-dkms 2>/dev/null ||             sudo apt-get install -y virtualbox-guest-utils 2>/dev/null
            sudo modprobe vboxsf 2>/dev/null || true
            if lsmod | grep -q vboxsf; then echo "GA_INSTALLED"; else echo "GA_FAILED"; fi
"@
        $gaInst = (Invoke-SshScript -Script $gaInstall -Label "ga-install" -sshTarget $sshTarget -SshPort $sshPort).Output
        if ($gaInst -match 'GA_INSTALLED') {
            Write-Check "Guest Additions zainstalowane (vboxsf dostepny)"
        } else {
            Write-Check "Guest Additions: instalacja nieudana - folder moze nie dzialac po restarcie" -Warn
            Write-Log "GuestAdditions install failed: $gaInst"
        }
    } else {
        Write-Check "Guest Additions obecne (vboxsf)"
    }

    # Wpis w /etc/fstab jako zabezpieczenie (automount VBox bywa zawodny
    # przy pierwszym starcie po wlaczeniu udzialu - fstab gwarantuje montowanie)
    $fstabCmd = @"
        if ! grep -q 'ai-workspace' /etc/fstab 2>/dev/null; then
            echo 'ai-workspace /opt/structura/ai-workspace vboxsf defaults,nofail,uid=1000,gid=1000,umask=002 0 0' | sudo tee -a /etc/fstab > /dev/null
            echo "FSTAB_ADDED"
        else
            echo "FSTAB_EXISTS"
        fi
        # Utworz punkt montowania i zamontuj teraz
        sudo mkdir -p /opt/structura/ai-workspace
        sudo mount -a 2>/dev/null || true
        if mountpoint -q /opt/structura/ai-workspace 2>/dev/null; then echo "MOUNTED"; else echo "NOT_MOUNTED"; fi

        # Podkatalog wymiany dla n8n (klient wrzuca plik -> workflow czyta ->
        # zapisuje wynik). Montowany do kontenera jako /exchange.
        # Uprawnienia: n8n dziala jako uid 1000, a vboxsf montuje z uid/gid
        # z fstab (uid=1000,gid=1000) - dlatego ten katalog MUSI byc zapisywalny
        # dla uid 1000, inaczej workflow nie zapisze wyniku.
        if mountpoint -q /opt/structura/ai-workspace 2>/dev/null; then
            mkdir -p /opt/structura/ai-workspace/n8n/{input,output,processed} 2>/dev/null || true
            chmod -R 775 /opt/structura/ai-workspace/n8n 2>/dev/null || true
            echo "EXCHANGE_READY"
        fi
"@
    $fstabResult = (Invoke-SshScript -Script $fstabCmd -Label "sharedfolder" -sshTarget $sshTarget -SshPort $sshPort).Output

    if ($fstabResult -match 'MOUNTED') {
        Write-Check "Folder wspoldzielony zamontowany: /opt/structura/ai-workspace"
    } else {
        Write-Check "Folder wspoldzielony: zamontuje sie przy nastepnym starcie VM (nofail w fstab)" -Warn
        Write-Log "SharedFolder mount state: $fstabResult"
    }

    return $true
}

# ============================================================================
# Post-setup: backup, SMB, UFW, fail2ban, dashboard theme
# ============================================================================

function Invoke-PostSetup {
    param([string]$VmIp)

    $sshTarget = "structura@$VmIp"
    $sshPort = 2222

    # --- Duplicati backup: definicje + sprawdzenie kontenera ---
    # Jobow NIE da sie utworzyc automatycznie (Duplicati API v2 nie ma stabilnego
    # endpointu tworzenia). Wczesniejszy Write-Check "4 jobs scheduled" byl FALSZYWY -
    # nie konfigurowal niczego. Teraz: sprawdzamy ze Duplicati dziala i podajemy
    # uzytkownikowi gotowy plik + instrukcje.
    Write-Host "  Sprawdzanie Duplicati (backup konfiguruje uzytkownik recznie)..." -ForegroundColor White
    $duplicatiCmd = @"
        if docker ps --format '{{.Names}}' | grep -q '^structura-duplicati$'; then
            echo "DUPLICATI_UP"
        else
            echo "DUPLICATI_DOWN"
        fi
        ls /opt/structura/repos/structura-core/duplicati/pgdump.json 2>/dev/null && echo "JOBS_FILE_OK"
"@
    $duplicatiResult = (Invoke-SshScript -Script $duplicatiCmd -Label "duplicati" -sshTarget $sshTarget -SshPort $sshPort).Output
    if ($duplicatiResult -match 'DUPLICATI_UP') {
        $manualBackup = $true
        Write-Host "    Duplicati dziala." -ForegroundColor Green
        Write-Host "    KONFIGURACJA RECZNA (jednorazowo, ~5 min):" -ForegroundColor Yellow
        Write-Host "      1. ssh -L 8200:localhost:8200 structura@$VmIp -p 2222" -ForegroundColor Yellow
        Write-Host "      2. Otworz http://localhost:8200 (haslo: DUPLICATI_PASSWORD z .env)" -ForegroundColor Yellow
        Write-Host "      3. Add backup -> Import from file -> duplicati/*.json (4 joby)" -ForegroundColor Yellow
    } else {
        Write-Host "    WARN: kontener Duplicati nie dziala - sprawdz 'docker compose ps'" -ForegroundColor Yellow
    }

    # --- PostgreSQL pg_dump cron ---
    Write-Host "  Configuring PostgreSQL pg_dump cron (01:45 daily)..." -ForegroundColor White
    $cronCmd = @"
        # Add pg_dump cron job
        # Cron uruchamia sie w minimalnym srodowisku (bez grupy docker w kontekscie
        # i z ubogim PATH), wiec 'docker exec' padalby na 'permission denied'.
        # 'sg docker -c' przelacza grupe; PATH podany jawnie.
        CRON_LINE="45 1 * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin sg docker -c 'docker exec postgresql /pgdump/pgdump.sh >> /opt/structura/appdata/postgresql/pgdump/cron.log 2>&1'"
        (crontab -l 2>/dev/null | grep -v "pgdump.sh"; echo "`$CRON_LINE") | crontab -
        # Weryfikacja: cron wymaga grupy docker, inaczej 'docker exec' padnie po cichu.
        if crontab -l 2>/dev/null | grep -q "pgdump.sh"; then echo "CRON_OK"; else echo "CRON_MISSING"; fi
        if id structura 2>/dev/null | grep -q docker; then echo "DOCKER_GRP_OK"; else echo "DOCKER_GRP_MISSING"; fi
"@
    $cronResult = (Invoke-SshScript -Script $cronCmd -Label "cron" -sshTarget $sshTarget -SshPort $sshPort).Output
    if ($cronResult -match 'CRON_OK' -and $cronResult -match 'DOCKER_GRP_OK') {
        Write-Check "pg_dump cron (01:45 daily) zainstalowany i zweryfikowany"
    } elseif ($cronResult -match 'DOCKER_GRP_MISSING') {
        Write-Check "cron OK, ale brak grupy docker - pgdump padnie (wymaga re-loginu)" -Warn
    } else {
        Write-Check "cron pg_dump NIE zainstalowany" -Warn
    }

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
        # Haslo SMB z .env (SMB_PASSWORD, wygenerowane losowo przez generate-secrets.sh).
        # Wczesniej smbpasswd dostawalo haslo 'structura' = takie samo jak konto VM,
        # do udzialu z dokumentami spraw (slabe i przewidywalne).
        # UWAGA: to here-string @"..."@ - PowerShell interpoluje $, dlatego KAZDA
        # zmienna bashowa MUSI byc poprzedzona backtickiem (`$VAR / `$(...)).
        # Bez tego PS podstawia wlasne (puste) zmienne, a `$(...)` WYKONUJE jako
        # polecenie PowerShell - haslo SMB nigdy nie trafialo do smbpasswd.
        ENV_FILE="/opt/structura/repos/structura-core/.env"
        SMB_PW="`$(grep -m1 '^SMB_PASSWORD=' "`$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
        if [ -z "`$SMB_PW" ]; then
            echo "SMB_PW_MISSING"
        else
            # samba wymaga dodatkowej roli systemowej dla uzytkownika SMB
            sudo smbpasswd -a structura -s <<< "`$SMB_PW"$'\n'"`$SMB_PW" 2>/dev/null || true
            sudo smbpasswd -e structura 2>/dev/null || true
        fi
        sudo systemctl enable smbd 2>/dev/null
        sudo systemctl restart smbd 2>/dev/null
        sleep 2
        if systemctl is-active --quiet smbd; then echo "SMB_UP"; else echo "SMB_DOWN"; fi
"@
    $smbResult = (Invoke-SshScript -Script $smbCmd -Label "smb" -sshTarget $sshTarget -SshPort $sshPort).Output
    if ($smbResult -match 'SMB_UP') {
        # UWAGA: to sprawdza TYLKO, czy demon smbd zyje - NIE czy udzial jest
        # osiagalny. Przy --nic1 nat Windows nie widzi portu 445, wiec ten
        # udzial jest uzyteczny wylacznie wewnatrz VM. Dla wymiany plikow
        # Windows <-> VM uzywamy VirtualBox Shared Folders (patrz
        # Install-SharedFolder). Komunikat pozostawiony dla wewnetrznych
        # potrzeb (np. przyszly dostep z sieci LAN po zmianie NIC na bridged).
        Write-Check "SMB (wewnatrz VM): smbd aktywny, udzial /opt/structura/ai-workspace"
    } elseif ($smbResult -match 'SMB_PW_MISSING') {
        Write-Check "SMB: brak SMB_PASSWORD w .env - uruchom scripts/generate-secrets.sh" -Warn
    } else {
        Write-Check "SMB nie wystartowal - sprawdz 'systemctl status smbd'" -Warn
    }

    # --- UFW firewall ---
    Write-Host "  Configuring UFW firewall..." -ForegroundColor White
    $ufwCmd = @"
        set -e

        # Wykryj REALNY port sshd - nie zakladamy go z gory.
        # Bylo: UFW zezwalal na 2222, a sshd sluchal na 22 (NAT: host 2222 -> guest 22).
        # Po 'default deny incoming' port 22 byl blokowany, wiec SSH przez NAT
        # przestawal dzialac w polowie instalacji. Sled w logu klienta:
        # "kex_exchange_identification: read: Connection reset" przy motywie.
        SSHD_PORT=`$(sudo sshd -T 2>/dev/null | awk '/^port /{print `$2; exit}')
        SSHD_PORT=`${SSHD_PORT:-22}

        sudo ufw --force reset
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        # Reguly dodajemy PRZED 'enable' - w momencie przelaczenia dostep dziala.
        sudo ufw allow "`$SSHD_PORT/tcp" comment 'SSH (realny port sshd)'
        sudo ufw allow 80/tcp comment 'HTTP'
        sudo ufw allow 443/tcp comment 'HTTPS'
        # 445 = SMB. NAT nie forwarduje tego portu (patrz --natpf1), wiec regula
        # ma sens tylko przy dostepie z sieci LAN (hostonly/bridged).
        sudo ufw allow from 192.168.0.0/16 to any port 445 proto tcp comment 'SMB LAN only'
        sudo ufw --force enable

        if sudo ufw status | grep -q "Status: active"; then echo "UFW_ACTIVE"; else echo "UFW_INACTIVE"; fi
        # Weryfikacja ze UFW zezwala na port, na ktorym sshd REALNIE slucha
        if sudo ufw status | grep -qE "(^| )`$SSHD_PORT/tcp"; then echo "UFW_SSH_OK port=`$SSHD_PORT"; else echo "UFW_SSH_MISSING"; fi
        # Sanity check: czy SSH nie zostalo odciete wlasnym firewallem
        if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/`$SSHD_PORT" 2>/dev/null; then echo "SSH_LOCAL_OK"; else echo "SSH_LOCAL_BLOCKED"; fi
"@
    $ufwResult = (Invoke-SshScript -Script $ufwCmd -Label "ufw" -sshTarget $sshTarget -SshPort $sshPort).Output
    if ($ufwResult -match 'SSH_LOCAL_BLOCKED') {
        # Najgorszy scenariusz: wlasny firewall odcial SSH. Kolejne kroki padna.
        Write-Check "KRYTYCZNE: UFW zablokowal SSH - dalsze kroki beda padac" -Fail
        Write-Log "UFW: SSH_LOCAL_BLOCKED. Output: $ufwResult"
        return $false
    }
    if ($ufwResult -match 'UFW_SSH_MISSING') {
        Write-Check "UFW NIE zezwala na realny port sshd" -Warn
    }
    if ($ufwResult -match 'UFW_ACTIVE') {
        $sshPortInfo = if ($ufwResult -match 'port=(\d+)') { $Matches[1] } else { '22' }
        Write-Check "UFW aktywny: deny incoming, allow $sshPortInfo(SSH)/80/443/445(LAN)"
    } else {
        Write-Check "UFW NIE aktywny - sprawdz 'sudo ufw status'" -Warn
    }

    # --- fail2ban ---
    Write-Host "  Installing fail2ban..." -ForegroundColor White
    $f2bCmd = @"
        sudo apt-get install -y fail2ban 2>/dev/null || exit 1

        # ---- jail.d/structura.conf ----
        # UWAGA: NIE /etc/fail2ban/jail-local.conf - fail2ban czyta jail.conf
        # oraz jail.d/*.conf. Plik 'jail-local.conf' byl IGNOROWANY, dlatego
        # jail nie byl wczytywany (log klienta: "fail2ban NIE aktywny").
        sudo mkdir -p /etc/fail2ban/jail.d
        sudo tee /etc/fail2ban/jail.d/structura.conf > /dev/null << 'F2BEOF'
[DEFAULT]
# KRYTYCZNE: bez ignoreip fail2ban banuje WLASNY host. Instalator i tak
# wykonuje dziesiatki polaczen SSH (health checki), a maxretry=3 wystarczy,
# zeby zablokowac 127.0.0.1 i przerwac instalacje w polowie.
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
# Port zgodny z REALNYM nasluchem sshd w gosciu (22).
# NAT mapuje host:2222 -> guest:22, ale sshd slucha na 22.
port = 22
filter = sshd
# Ubuntu 24.04 uzywa rsyslog, wiec auth.log istnieje. Gdyby go nie bylo,
# backend=systemd dziala jako fallback.
backend = auto
logpath = /var/log/auth.log
F2BEOF

        # Usun stary, ignorowany plik jesli zostal z poprzednich wersji
        sudo rm -f /etc/fail2ban/jail-local.conf 2>/dev/null || true

        sudo systemctl enable fail2ban 2>/dev/null || true
        sudo systemctl restart fail2ban
        sleep 5

        if systemctl is-active --quiet fail2ban; then echo "F2B_ACTIVE"; else echo "F2B_INACTIVE"; fi
        # Weryfikacja ze jail sshd jest REALNIE wczytany (nie tylko demon zyje)
        if sudo fail2ban-client status sshd >/dev/null 2>&1; then echo "F2B_JAIL_OK"; else echo "F2B_JAIL_MISSING"; fi
"@
    $f2bResult = (Invoke-SshScript -Script $f2bCmd -Label "fail2ban" -sshTarget $sshTarget -SshPort $sshPort).Output
    if ($f2bResult -match 'F2B_ACTIVE' -and $f2bResult -match 'F2B_JAIL_OK') {
        Write-Check "fail2ban aktywny: jail sshd (port 22, ban 3 proby/1h, ignoreip 127.0.0.1)"
    } elseif ($f2bResult -match 'F2B_JAIL_MISSING') {
        Write-Check "fail2ban dziala, ale jail sshd NIE wczytany - sprawdz /etc/fail2ban/jail.d/" -Warn
    } else {
        Write-Check "fail2ban NIE aktywny - sprawdz 'systemctl status fail2ban'" -Warn
    }

    # --- Dashboard theme (Aether Sawaryn) ---
    Write-Host "  Installing dashboard theme (Aether Sawaryn)..." -ForegroundColor White

    $themeCmd = @"
        # Hermes jest NATYWNY - motyw trafia do ~/.hermes, nie do kontenera.
        CLIENT_DIR="/opt/structura/repos/structura-clients-$Client"
        HERMES_HOME="`$HOME/.hermes"
        THEME_NAME="aether-$Client"
        THEME_FILE="`$CLIENT_DIR/dashboard-themes/`$THEME_NAME.yaml"

        if [ ! -f "`$THEME_FILE" ]; then
            echo "Theme file not found: `$THEME_FILE"
            exit 0
        fi

        mkdir -p "`$HERMES_HOME/dashboard-themes"
        cp "`$THEME_FILE" "`$HERMES_HOME/dashboard-themes/`$THEME_NAME.yaml"

        # Aktywacja motywu. Hermes domyslnie czyta ~/.hermes/config.yaml.
        HERMES_BIN=""
        for cand in "`$HOME/.local/bin/hermes" "`$HOME/.local/share/uv/tools/hermes-agent/bin/hermes" "`$HERMES_HOME/venv/bin/hermes"; do
            if [ -x "`$cand" ]; then HERMES_BIN="`$cand"; break; fi
        done

        if [ -n "`$HERMES_BIN" ]; then
            "`$HERMES_BIN" config set dashboard.theme "`$THEME_NAME" 2>/dev/null || {
                # Fallback: dopisz do config.yaml recznie
                if ! grep -q 'dashboard:' "`$HERMES_HOME/config.yaml" 2>/dev/null; then
                    printf '
dashboard:
  theme: %s
' "`$THEME_NAME" >> "`$HERMES_HOME/config.yaml"
                fi
            }
        fi
        echo "THEME_INSTALLED"

        # --- GH#38238: terminalBackground/terminalForeground sa WYCINANE
        # przez backend-normalizer, wiec samo YAML nie wystarcza. Bez patchera
        # tlo czatu zostaje CZARNE zamiast ciemnoszarego (#2A2A2E).
        PATCHER_FILE="`$CLIENT_DIR/patches/gh38238-patcher.py"
        if [ -f "`$PATCHER_FILE" ]; then
            # Patchujemy zainstalowany pakiet Hermesa (nie kontener).
            # UWAGA 1: pakiet na PyPI nazywa sie 'hermes_cli' (dystrybucja
            #          'hermes-agent'). 'import hermes' NIE ISTNIEJE.
            # UWAGA 2: pakiet nalezy do root -> patcher MUSI isc przez sudo,
            #          inaczej PermissionError.
            #
            # UWAGA 3 (KRYTYCZNE): Hermes jest instalowany przez 'uv tool install',
            # ktore tworzy IZOLOWANE srodowisko w ~/.local/share/uv/tools/.
            # Systemowy python3 NIE MA tam hermes_cli w sys.path, wiec
            #   python3 -c 'import hermes_cli'
            # zwracalo pustke -> PKG_DIR pusty -> patch NIE byl aplikowany,
            # a tlo czatu zostawalo CZARNE zamiast ciemnoszarego (#2A2A2E).
            #
            # UWAGA 4 (sprawdzone na zywej VM): $HERMES_BIN to SYMLINK
            #   ~/.local/bin/hermes -> ~/.local/share/uv/tools/hermes-agent/bin/hermes
            # wiec 'dirname $HERMES_BIN' daje ~/.local/bin, gdzie NIE MA pythona.
            # Trzeba rozwiazac symlink: 'readlink -f'.
            # Dowod (VM): ~/.local/bin/hermes -> uv/tools/.../bin/hermes (symlink)
            #             ~/.local/bin/ zawiera TYLKO binarki, zero pythona
            #             uv/tools/hermes-agent/bin/python3 istnieje i WIDZI hermes_cli
            HERMES_PY=""
            HERMES_REAL=`$(readlink -f "`$HERMES_BIN" 2>/dev/null || echo "`$HERMES_BIN")
            if [ -n "`$HERMES_REAL" ]; then
                CAND=`$(dirname "`$HERMES_REAL")/python3
                [ -x "`$CAND" ] && HERMES_PY="`$CAND"
                if [ -z "`$HERMES_PY" ]; then
                    CAND=`$(dirname "`$HERMES_REAL")/python
                    [ -x "`$CAND" ] && HERMES_PY="`$CAND"
                fi
            fi
            # Fallback: znane lokalizacje uv tool (gdyby readlink zawiodl)
            if [ -z "`$HERMES_PY" ]; then
                for CAND in "`$HOME/.local/share/uv/tools/hermes-agent/bin/python3" \
                            "`$HOME/.local/share/uv/tools/hermes-agent/bin/python"; do
                    if [ -x "`$CAND" ] && "`$CAND" -c 'import hermes_cli' 2>/dev/null; then
                        HERMES_PY="`$CAND"; break
                    fi
                done
            fi
            # Fallback: venv Hermesa, potem systemowy python3
            if [ -z "`$HERMES_PY" ] && [ -x "`$HERMES_HOME/venv/bin/python3" ]; then
                HERMES_PY="`$HERMES_HOME/venv/bin/python3"
            fi
            if [ -z "`$HERMES_PY" ]; then
                HERMES_PY="`$(command -v python3)"
            fi
            echo "GH38238 patch: python=`$HERMES_PY"

            PATCH_APPLIED=0
            PKG_DIR=`$("`$HERMES_PY" -c 'import hermes_cli,os;print(os.path.dirname(hermes_cli.__file__))' 2>/dev/null || true)
            if [ -n "`$PKG_DIR" ]; then
                sudo "`$HERMES_PY" "`$PATCHER_FILE" --package-dir "`$PKG_DIR" 2>&1 | tail -3
                if sudo "`$HERMES_PY" "`$PATCHER_FILE" --package-dir "`$PKG_DIR" >/dev/null 2>&1; then
                    PATCH_APPLIED=1
                fi
            fi
            if [ "`$PATCH_APPLIED" -eq 1 ]; then
                echo "GH38238_PATCHED"
            else
                echo "GH38238_PATCH_FAILED"
            fi
        else
            echo "Patcher file not found: `$PATCHER_FILE"
        fi

        # Restart uslugi, zeby motyw i patch zadzialaly od razu
        sudo systemctl restart hermes 2>/dev/null || true
        sleep 3
        if systemctl is-active --quiet hermes; then echo "HERMES_RESTARTED"; fi
"@

    $themeResult = (Invoke-SshScript -Script $themeCmd -Label "theme" -sshTarget $sshTarget -SshPort $sshPort).Output
    if ($PSBoundParameters.ContainsKey("Verbose")) { Write-Host $themeResult -ForegroundColor DarkGray }

    if ($themeResult -match 'THEME_INSTALLED') {
        Write-Check "Dashboard theme: Aether Sawaryn installed"
    } else {
        Write-Check "Dashboard theme: $themeResult" -Warn
    }

    if ($themeResult -match 'GH#38238_PATCHED') {
        Write-Check "GH#38238 patch: tlo czatu ciemnoszare (#2A2A2E) - dziala od razu"
    } elseif ($themeResult -match 'GH38238_PATCH_FAILED') {
        Write-Check "GH#38238 patch: nie zastosowano - tlo czatu moze byc czarne" -Warn
        Write-Log "gh38238 patcher failed on native Hermes"
    } else {
        Write-Check "GH#38238 patch: BRAK patchera w repo klienta" -Warn
    }

    # --- Folder wspoldzielony Windows <-> VM (TRWALY) ---
    # Wymog: klient pracuje na plikach spraw, a folder ma przezyc restart.
    # Metoda: VirtualBox Shared Folders (vboxsf), NIE SMB - VM ma --nic1 nat,
    # wiec Windows NIE osiaga VM na porcie 445 (Samba byla dla hosta
    # niewidoczna, a instalator raportowal "\127.0.0.1\ai-workspace",
    # czyli Windows SAM - nie VM).
    $null = Install-SharedFolder -VmName $VM_NAME -VmIp $VmIp

    # --- Autostart VM z Windowsem ---
    # Wymog: klient restartuje komputer -> wszystko dziala samo w tle,
    # bez logowania. Zadanie w Harmonogramie: ONSTART + SYSTEM + delay 30 s.
    $null = Install-VmAutostart -VmName $VM_NAME

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

    # Add 127.0.0.1 (VM via NAT) to SSH config for key-based auth
    $vmConfigEntry = @"
Host 127.0.0.1
    HostName 127.0.0.1
    User structura
    Port 2222
    IdentityFile $keyDest
    StrictHostKeyChecking no
    UserKnownHostsFile NUL
"@
    if ($existingConfig -notmatch 'Host 127.0.0.1') {
        Add-Content -Path $configPath -Value $vmConfigEntry
        Write-Check "SSH config: 127.0.0.1:2222 configured"
    }
}

# ============================================================================
# LUKS encryption
# ============================================================================

function Invoke-LUKS {
    param([string]$VmIp)

    if (-not $EnableLUKS) { return }

    # ========================================================================
    # LUKS NIE JEST ZAIMPLEMENTOWANY (swiadoma decyzja, nie przeoczenie).
    #
    # Poprzednia wersja probowala 'cryptsetup luksFormat /dev/sda5', ale VM
    # z autoinstall (storage.layout.name = direct) ma JEDNA partycje root -
    # /dev/sda5 nie istnieje. Funkcja nie mogla zadzialac, a mimo to
    # raportowala "LUKS setup: check VM console" -Warn, co czytalo sie jako
    # "szyfrowanie wlaczone". Dla kancelarii z tajemnica zawodowa to powazne
    # wprowadzenie w blad.
    #
    # Realna implementacja wymaga: osobnego dysku/wolumenu w autoinstall
    # storage.layout + cryptsetup w late-commands (przed montowaniem /opt),
    # plus obsluga odblokowywania przy starcie (dropbear/clevis). To osobny
    # zakres prac - NIE jest zrobione i NIE udajemy, ze jest.
    # ========================================================================
    Write-Host "  Szyfrowanie dysku (LUKS)..." -ForegroundColor White
    Write-Check "LUKS: NIEZREALIZOWANE - dysk VM nie jest szyfrowany" -Fail
    Write-Host "    Parametr -EnableLUKS jest przyjmowany, ale NIE wykonuje szyfrowania." -ForegroundColor Yellow
    Write-Host "    Powod: VM ma jedna partycje root (autoinstall storage.layout=direct)," -ForegroundColor Yellow
    Write-Host "    a realne LUKS wymaga osobnego wolumenu + obslugi odblokowania przy starcie." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "    KOMPENSACJA (do wdrozenia przez klienta):" -ForegroundColor Yellow
    Write-Host "      - BitLocker na dysku hosta Windows (chroni plik .vdi)" -ForegroundColor Yellow
    Write-Host "      - Duplicati: backup szyfrowany AES (--encryption-module=aes)" -ForegroundColor Yellow
    Write-Host "      - Fizyczna kontrola dostepu do stacji" -ForegroundColor Yellow
    Write-Log "LUKS: -EnableLUKS uzyty, ale szyfrowanie NIE jest zaimplementowane (patrz komentarz w setup.ps1)"

    return $false
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
    $hostFolder = Join-Path $env:USERPROFILE "STRUCTURA-PLiki"

    # ========================================================================
    # Podsumowanie dla KLIENTA (nie dla informatyka).
    # Cel: prawnik ma wiedziec (1) co dostal, (2) gdzie kliknac, (3) co robic
    # dalej. Zero zargonu, zero "SSH", zero "localhost".
    #
    # Dashboard: NPM tworzy osobne hosty (homepage.local, n8n.local, ...).
    # Te nazwy trzeba wpisac do pliku hosts Windows, inaczej przegladarka ich
    # nie zna. Dlatego instalator DODAJE je do hosts i mowi o tym wprost.
    # ========================================================================

    Write-Host ""
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
    Write-Host "   GOTOWE - ASYSTENT DZIALA" -ForegroundColor Cyan
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "   Co zostalo zainstalowane" -ForegroundColor White
    Write-Host "   ------------------------" -ForegroundColor DarkGray
    Write-Host "     Maszyna wirtualna z systemem Ubuntu" -ForegroundColor Gray
    Write-Host "       $VM_NAME  (${ramGB} GB pamieci, $VM_CPU rdzenie, ${diskGB} GB dysku)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "     Osiem uslug gotowych do pracy:" -ForegroundColor Gray
    Write-Host "       - Asystent AI (rozmowa po polsku, zna przepisy)" -ForegroundColor DarkGray
    Write-Host "       - Pamiec kancelarii (baza wiedzy i kontekst spraw)" -ForegroundColor DarkGray
    Write-Host "       - Wyszukiwarka prawna (ISAP, orzeczenia)" -ForegroundColor DarkGray
    Write-Host "       - Automatyzacje (przeplywy dokumentow)" -ForegroundColor DarkGray
    Write-Host "       - Kopie zapasowe (codziennie w nocy)" -ForegroundColor DarkGray
    Write-Host "       - Panel zarzadzania" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "   Jak zaczac" -ForegroundColor White
    Write-Host "   ----------" -ForegroundColor DarkGray
    Write-Host "     1. Otworz panel z wszystkimi aplikacjami:" -ForegroundColor Gray
    Write-Host ""
    Write-Host "          http://homepage.local" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "        (link otworzy sie automatycznie za chwile)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "     2. Twoje pliki sa w folderze:" -ForegroundColor Gray
    Write-Host "          $hostFolder" -ForegroundColor Cyan
    Write-Host "        To ten sam folder widziany przez asystenta - wrzucasz" -ForegroundColor DarkGray
    Write-Host "        dokument, asystent go widzi. Bez kopiowania." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "     3. Asystent startuje automatycznie z Windowsem." -ForegroundColor Gray
    Write-Host "        Nic nie trzeba uruchamiac - dziala w tle." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "     4. Dostep z telefonu (opcjonalnie):" -ForegroundColor Gray
    Write-Host "        Skonfiguruj bota Telegram - patrz instrukcja obok." -ForegroundColor DarkGray
    Write-Host "        Bez tego asystent dziala tylko na tym komputerze." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "   Wazne informacje" -ForegroundColor White
    Write-Host "   ----------------" -ForegroundColor DarkGray
    Write-Host "     Hasla dostepowe sa w pliku .env na maszynie wirtualnej." -ForegroundColor DarkGray
    Write-Host "     Zapisz je w sejfie - nie sa odtwarzalne po utracie." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "     Szyfrowanie dysku: NIE JEST WLACZONE." -ForegroundColor Yellow
    Write-Host "     Zalecane: wlacz BitLocker na tym komputerze - chroni" -ForegroundColor Yellow
    Write-Host "     rowniez dane asystenta." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "     Kopie zapasowe wymagaja jednorazowej konfiguracji" -ForegroundColor Yellow
    Write-Host "     (okolo 5 minut) - szczegoly w instrukcji." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   Plik dziennika instalacji" -ForegroundColor White
    Write-Host "   -------------------------" -ForegroundColor DarkGray
    Write-Host "     $LOG_FILE" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
    Write-Host "   STRUCTURA  -  Ex fundamentis, intelligentia" -ForegroundColor DarkGray
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
    Write-Host ""

    # --- Otworz dashboard w przegladarce ---
    # Wymog Prem: klient dostaje link, ktory otwiera gotowy dashboard.
    Write-Host "  Otwieram panel z aplikacjami w przegladarce..." -ForegroundColor White
    try {
        Start-Process "http://homepage.local" -ErrorAction Stop
        Write-Host "  v Panel otwarty" -ForegroundColor Green
    } catch {
        Write-Host "  ! Nie udalo sie otworzyc automatycznie." -ForegroundColor Yellow
        Write-Host "    Otworz recznie: http://homepage.local" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ============================================================================
# Wpisy w pliku hosts (Windows) - zeby nazwy .local dzialaly w przegladarce
# ============================================================================

function Install-HostsEntries {
    param([string]$VmIp)

    # NPM tworzy osobne HOSTY (nie sciezki), a Windows nie zna domen .local.
    # Bez wpisu w hosts przegladarka nie otworzy http://homepage.local.
    #
    # KLUCZOWE: wpis wskazuje 127.0.0.1, a przegladarka przy http://homepage.local
    # uderza na PORT 80. Dlatego NAT MUSI wystawiac NPM na hoscie na porcie 80
    # (patrz Invoke-VMCreation: port 80 gdy wolny, inaczej 8080 jako fallback).
    # Gdy NAT wystawia tylko 8080, nazwy .local NIE otwieraja sie bez portu
    # w adresie ("nie mozna polaczyc") - tak bylo na CiemPincie.
    # Jesli port 80 byl zajety, klient musi wpisywac adres z :8080.
    Write-Host "  Konfigurowanie nazw aplikacji w systemie..." -ForegroundColor White
    if ($global:StructuraHostPort -and $global:StructuraHostPort -ne 80) {
        Write-Check "Port 80 zajety - otwieraj aplikacje z ':8080' w adresie (np. http://homepage.local:8080)" -Warn
    }

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $marker = "# STRUCTURA AI - aplikacje asystenta"

    $domains = @(
        "homepage.local",
        "dashboard.local",
        "hindsight.local",
        "n8n.local",
        "portainer.local",
        "duplicati.local",
        "search.local"
    )

    try {
        $existing = Get-Content $hostsPath -ErrorAction Stop
    } catch {
        Write-Check "Nie moge odczytac pliku hosts: $_" -Warn
        return $false
    }

    # Usun stare wpisy STRUCTURA (idempotencja przy re-runie)
    $cleaned = $existing | Where-Object { $_ -notmatch [regex]::Escape($marker) -and $_ -notmatch '\.local\s' }
    $newLines = @($cleaned) + @("") + @($marker)

    # WAZNE: NPM slucha na porcie 80 WEWNATRZ VM, ktory NAT wystawia na
    # host:8080. Nazwy .local kierujemy wiec na 127.0.0.1, ale przegladarka
    # domyslnie uderza na port 80. Dlatego dodatkowo przekierowujemy
    # lokalnie: patrz proxy w NPM + regula portu. Najprosciej: wpis w hosts
    # + odsylacz na port 8080 w samej nazwie linku dashboardu.
    foreach ($d in $domains) {
        $newLines += "127.0.0.1`t$d"
    }

    try {
        Set-Content -Path $hostsPath -Value $newLines -Force -ErrorAction Stop
        Write-Check "Nazwy aplikacji dodane do pliku hosts ($($domains.Count) domen)"
        Write-Log "hosts: dodano $($domains -join ', ') -> 127.0.0.1"
    } catch {
        Write-Check "Nie moge zapisac pliku hosts (wymaga uprawnien administratora)" -Warn
        Write-Log "hosts write failed: $_"
        return $false
    }

    # Port: NAT przekierowuje host:80 (lub :8080 gdy 80 zajety) BEZPOSREDNIO do
    # gosciowi:80, wiec zadne dodatkowe przekierowanie nie jest potrzebne.
    #
    # UWAGA: byl tu netsh portproxy 127.0.0.1:80 -> 127.0.0.1:8080. Usuniete,
    # bo:
    #   1) Konflikt o port 80 - NAT (127.0.0.1:80 -> guest:80) i portproxy
    #      (sluchajacy na 127.0.0.1:80) nie moga dzialac jednoczesnie;
    #      jeden z nich nie zbindowal sie, co tlumaczy zamkniety port 80.
    #   2) Zbedna zaleznosc od uslugi iphlpsvc (IP Helper) - bez niej
    #      portproxy milczy, a objaw jest identyczny ("nie mozna polaczyc").
    #   3) Dwa przejscia (80 -> 8080 -> NAT -> guest) tam, gdzie wystarczy
    #      jedno (80 -> NAT -> guest).
    # Gdy port 80 na hoscie jest zajety, NAT uzywa 8080 i uzytkownik wpisuje
    # ':8080' w adresie - ostrzezenie jest w komunikatach wyzej.
    Write-Check "Aplikacje pod adresami .local (np. http://homepage.local)"

    return $true
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

    # UWAGA: brak ubuntu-unattend.xml. Instalacja idzie INLINE szablonem
    # VBoxManage --script-template (patrz Invoke-VMCreation), bo stock szablon
    # VirtualBox ma bug launchpad #2090834 (late-commands przed utworzeniem
    # uzytkownika) - klucz SSH wgrywa cloud-init przez ssh_authorized_keys.
    $vmResult = Invoke-VMCreation -Media $media
    $vmIp = $vmResult.VmIp

    if (-not $vmIp) {
        throw "VM nie udostepnila dzialajacego SSH - instalacja nie dobiegla konca. Sprawdz C:\structura\setup.log i konsole VM (VirtualBox Manager -> Show)."
    }

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

    # --- ETAP 7/8: Hermes natywnie + Hindsight + konfiguracja klienta ---
    Write-Etap -Number 7 -Name "Hermes (natywnie) + Hindsight + config klienta"
    # Hermes NATYWNIE (bez kontenera) - zarzadza kontenerami i nie dlawi sie
    # w izolacji. Instalowany z PyPI + usluga systemd (start z VM).
    $hermesOk = Install-NativeHermes -VmIp $vmIp -Client $Client
    if (-not $hermesOk) { throw "Hermes natywny: instalacja nie powiodla sie." }
    $hindsightOk = Invoke-HindsightAndConfig -VmIp $vmIp
    # UWAGA: funkcja zwracala $false przy bledzie, ale wynik NIE byl sprawdzany -
    # instalator szedl dalej do ETAPU 8 i konczyl sie komunikatem sukcesu.
    # Teraz brak bankow Hindsight jest blokada (bez pamieci dlugoterminowej
    # asystent nie spelnia zalozen produktu).
    if (-not $hindsightOk) { throw "Hindsight init failed - banki pamieci nie powstan." }

    # --- ETAP 8/8: Post-setup ---
    Write-Etap -Number 8 -Name "Post-setup (Duplicati, pg_dump cron, SMB, UFW, fail2ban, health, dashboard theme)"

    # LUKS - NIEZREALIZOWANE. Jesli ktos podal -EnableLUKS, mowi o tym glosno,
    # ale nie przerywa instalacji (funkcja jest opcjonalna, a system dziala
    # bez szyfrowania dysku - pod warunkiem, ze klient zna to ograniczenie).
    if ($EnableLUKS) {
        $luksOk = Invoke-LUKS -VmIp $vmIp
        if (-not $luksOk) {
            Write-Host "  Kontynuuje instalacje BEZ szyfrowania dysku." -ForegroundColor Yellow
        }
    }

    $postOk = Invoke-PostSetup -VmIp $vmIp
    # UWAGA: bylo tu przypisanie bez sprawdzenia - instalator konczyl sie
    # komunikatem "Setup completed successfully" i exit 0 NAWET gdy ETAP 8
    # zwrocil $false (np. UFW/fail2ban/motyw/dashboard nie wstaly).
    # Klient dostawal "sukces" z niedzialajacym firewall albo brakiem motywu.
    # Ten sam wzorzec falszywego sukcesu, ktory tepimy od fali 2.
    if (-not $postOk) {
        Write-Host ""
        Write-Check "ETAP 8 (post-setup) NIE zakonczyl sie sukcesem" -Warn
        Write-Log "PostSetup zwrocil `$false - instalacja NIE jest pelna" -Level "WARN"
        Write-Host "  Stack kontenerow DZIALA, ale czesc krokow post-setup wymaga uwagi:" -ForegroundColor Yellow
        Write-Host "    - UFW / fail2ban (firewall)" -ForegroundColor DarkGray
        Write-Host "    - motyw dashboardu" -ForegroundColor DarkGray
        Write-Host "    - wpisy w /etc/hosts" -ForegroundColor DarkGray
        Write-Host "  Szczegoly: $LOG_FILE" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Instalacja konczy sie z ostrzezeniem - sprawdz powyzsze punkty." -ForegroundColor Yellow
        Write-Host ""
    }

    # Nazwy aplikacji w pliku hosts + przekierowanie portu, zeby
    # http://homepage.local dzialalo bez podawania portu.
    $null = Install-HostsEntries -VmIp $vmIp

    # Final summary (podsumowanie dla klienta + otwarcie dashboardu)
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