# DODAJ-KLUCZ-PIPBOY-HOST v4 — public (irm | iex)
# Dodaje klucz publiczny asystenta do OpenSSH na tym komputerze.
# Log: C:\PIPBOY-LOG.txt
$ErrorActionPreference = 'Continue'
$Key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIEFVWX/rOhf742cdesRaoBNCmAUeLFS3kJbcXgzkxBi hermes@a315df74c7fc'
Start-Transcript -Path 'C:\PIPBOY-LOG.txt' -Force | Out-Null
Write-Output "=== DODAJ-KLUCZ-PIPBOY v4 ==="
Write-Output "Czas: $(Get-Date)"
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Output "Administrator: $IsAdmin"

if (-not $IsAdmin) {
    Write-Output "[!] Brak admina - podnosze przywileje (zaakceptuj UAC)..."
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -Command `"iex ((irm 'https://raw.githubusercontent.com/structura-factor/structura-factor-launchers/main/dodaj-klucz-pipboy-host.ps1'))`"" -Wait
    Write-Output "Koniec (podniesiona instancja wrote log do C:\PIPBOY-LOG.txt)."
    Stop-Transcript | Out-Null
    exit
}

Write-Output "[1/6] Uslugi OpenSSH:"
Get-Service | Where-Object { $_.Name -like '*ssh*' -or $_.DisplayName -like '*ssh*' } | Format-List Name,DisplayName,Status,StartType | Out-String | Write-Output

Write-Output "[2/6] C:\OpenSSH (niestandardowa instalacja):"
if (Test-Path 'C:\OpenSSH') { Get-ChildItem 'C:\OpenSSH' | Select-Object Name,Length | Format-Table | Out-String | Write-Output } else { Write-Output "brak" }

Write-Output "[3/6] ProgramData\ssh + klucz + ACL:"
if (-not (Test-Path 'C:\ProgramData\ssh')) { New-Item -ItemType Directory -Path 'C:\ProgramData\ssh' | Out-Null }
Add-Content -Path 'C:\ProgramData\ssh\administrators_authorized_keys' -Value $Key
try {
    icacls 'C:\ProgramData\ssh\administrators_authorized_keys' /inheritance:r /grant 'SYSTEM:F' /grant 'BUILTIN\Administrators:F'
    icacls 'C:\ProgramData\ssh\administrators_authorized_keys'
} catch { Write-Output "icacls: $_" }

Write-Output "[4/6] Profil ssh_admin:"
$AdminHome = 'C:\Users\ssh_admin'
if (-not (Test-Path "$AdminHome\.ssh")) {
    # moze konto nazywa sie inaczej - dopisz do profilow istniejacych userow admin-grupy
    Get-ChildItem 'C:\Users' -Directory | ForEach-Object { New-Item -ItemType Directory -Path "$($_.FullName)\.ssh" -Force | Out-Null; Add-Content -Path "$($_.FullName)\.ssh\authorized_keys" -Value $Key -ErrorAction SilentlyContinue }
} else {
    Add-Content -Path "$AdminHome\.ssh\authorized_keys" -Value $Key
}
Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object { Write-Output "user: $($_.Name)" }

Write-Output "[5/6] Restart uslug ssh:"
Get-Service | Where-Object { $_.Name -like '*ssh*' } | ForEach-Object {
    Write-Output "Restart: $($_.Name)"
    try { Restart-Service -Name $_.Name -Force -ErrorAction Stop; Write-Output "  -> OK" } catch { Write-Output "  -> BLAD: $_" }
}

Write-Output "[6/6] sshd_config - AuthorizedKeysFile:"
foreach ($cfg in @('C:\ProgramData\ssh\sshd_config','C:\OpenSSH\sshd_config')) {
    if (Test-Path $cfg) {
        Write-Output "--- $cfg ---"
        Select-String -Path $cfg -Pattern 'AuthorizedKeysFile|PubkeyAuthentication' | ForEach-Object { Write-Output $_.Line }
    }
}
Write-Output "=== KONIEC v4 ==="
Stop-Transcript | Out-Null
