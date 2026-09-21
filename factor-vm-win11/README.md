# factor-vm-win11/README.md - Instrukcja launcher VM Windows 11

# STRUCTURA FACTOR - VM Win11 Launcher

Launcher tworzy pelne srodowisko STRUCTURA AI na Windows 11:
- Maszyna wirtualna VirtualBox z Ubuntu 24.04 Server
- Docker Compose stack (9 kontenerow)
- Hindsight (PostgreSQL) z 2 bankami pamieci (Kontekst_Sprawy + Wiedza_Osobista)
- Hermes Agent z konfiguracja kliencka
- NPM, SearXNG, n8n, Duplicati, Portainer, Homepage, Telegram bot

## Wymagania

| Wymaganie | Minimum | Zalecane |
|-----------|---------|----------|
| Windows | 10 (22H2) | 11 (22H2+) |
| RAM | 16 GB | 32 GB |
| Disk free | 50 GB | 100 GB |
| VirtualBox | 7.0 | 7.1+ |
| Internet | Wymagany | Stabilny 10+ Mbps |
| Admin rights | Wymagane | - |

## Szybki start

### Opcja A: Przez bootstrap.ps1 (zalecane)

```powershell
# Pobierz bootstrap.ps1 z repo
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/structura-factor/structura-factor-launchers/main/bootstrap.ps1" -OutFile "bootstrap.ps1"

# Uruchom
.\bootstrap.ps1 -Client sawaryn -DeployKeyPath C:\path\to\deploy_key
```

### Opcja B: Bezposrednio setup.bat

```powershell
# Sklonuj repo lub pobierz factor-vm-win11/ folder
cd factor-vm-win11
.\setup.bat
```

### Opcja C: setup.ps1 z parametrami

```powershell
.\setup.ps1 -Client sawaryn -DeployKeyPath C:\path\to\deploy_key -VM_RAM 8192 -VM_CPU 4 -VM_DISK 80
```

## Parametry setup.ps1

| Parametr | Domylny | Opis |
|----------|---------|------|
| `-Client` | (wymagany) | Nazwa klienta (np. `sawaryn`) |
| `-DeployKeyPath` | (brak) | Sciezka do deploy key SSH (kopiowany do `~/.ssh/`) |
| `-VM_RAM` | 4096 | RAM VM w MB |
| `-VM_CPU` | 2 | Liczba vCPU |
| `-VM_DISK` | 40960 | Rozmiar dysku VM w MB |
| `-EnableLUKS` | $false | Wlacz LUKS encryption na VM |
| `-LUKSPassword` | (brak) | Haslo LUKS (lub z .env LUKS_PASSPHRASE) |
| `-MediaPath` | (brak) | Sciezka do folderu z mediami (OneDrive caching) |
| `-Quiet` | $false | Tryb cichy (tylko banner + bledy + podsumowanie) |
| `-Verbose` | $false | Tryb verbose (pelne outputy komend) |

## Media caching (OneDrive)

### First-user workflow (pierwszy klient)

1. Uruchom `setup.ps1` bez `-MediaPath` (lub z nieistniejacym folderem)
2. Skrypt pobiera Ubuntu ISO (~2.5GB) i VirtualBox installer (~100MB) z internetu
3. Po instalacji, skrypt zapisuje pliki w folderze OneDrive (jesli wskazany)
4. Pliki sa automatycznie synchronizowane przez OneDrive

### Kolejni klienci

```powershell
.\setup.ps1 -Client nowyklient -MediaPath "C:\Users\premek\OneDrive\STRUCTURA\media\"
```

Pliki sa pobierane z lokalnego OneDrive (migusiem, oszczednosc ~10-15 min).

### Wymagane pliki w MediaPath

```
media/
  ubuntu-24.04.1-server-amd64.iso    # ~2.5GB
  VirtualBox-7.1.4-Win.exe            # ~100MB
  versions.txt                        # SHA256 checksums (w repo)
```

SHA256 plikow musi pasowac do `versions.txt` w tym repo.

### UNC paths

MediaPath moze byc rowniez sciezka UNC (`\\server\share\STRUCTURA\media\`) lub dowolny path lokalny.

## Etapy instalacji (8 etapow)

| Etap | Nazwa | Czas est. |
|------|-------|-----------|
| 1/8 | Pre-flight checks | <30s |
| 2/8 | Media sourcing (ISO + VBox) | 5-15 min (download) lub <30s (OneDrive) |
| 3/8 | VM creation + Ubuntu install | 5-10 min |
| 4/8 | Docker setup | 2-5 min |
| 5/8 | Repo clone + appdata structure | 1-2 min |
| 6/8 | Container deployment | 3-5 min |
| 7/8 | Hindsight + client config | 1-2 min |
| 8/8 | Post-setup (backup, SMB, UFW, theme) | 1-2 min |

## Struktura na VM (po instalacji)

```
/opt/structura/
  appdata/                    # Wszystkie dane Docker (backup target)
    hindsight/{pgdata,pgdump}/ # PostgreSQL
    hermes/                    # Hermes config + memories + skills
    n8n/                       # n8n workflows
    npm/{data,letsencrypt}/   # NPM proxy + TLS
    portainer/                 # Portainer config
    duplicati/                 # Duplicati config
    homepage/{icons}/         # Homepage dashboard
    searxng/                   # SearXNG settings
    telegram/                  # Telegram bot config
  repos/
    structura-core/                # Docker compose stack
    structura-clients-sawaryn/     # Konfiguracja kliencka (repo PER KLIENT)
  ai-workspace/                # SMB share (wymiana plikow)
  backups/                     # Duplicati backup destination
```

## Bezpieczenstwo

- Wszystkie porty na `127.0.0.1` (jedyny dostep z zewnatrz przez NPM 80/443)
- `.env` z `chmod 600` (sekrety NIGDY w skryptach)
- Deploy keys w `~/.ssh/` (NIGDY w .env)
- UFW firewall: deny incoming, allow 2222/tcp, 80/tcp, 443/tcp, 445/tcp (LAN only)
- fail2ban (ban po 3 nieudanych SSH, 1h)
- Opcjonalny LUKS encryption (`-EnableLUKS`)
- `security_opt: no-new-privileges` na kazdym kontenerze
- PostgreSQL scram-sha-256 auth

## Troubleshooting

### VirtualBox not found

```
[1/8] Pre-flight checks
  x VirtualBox 7.0+ not found
    Action: Download from https://www.virtualbox.org/wiki/Downloads
```

Sprobuj: `setup.ps1 -MediaPath C:\path\to\media\` (auto-installs VBox from MediaPath).

### SHA256 mismatch

```
[2/8] Media sourcing
  x Ubuntu ISO SHA256 mismatch
    Expected: a4acf510...  Got: 8b3e0c1a...
    Action: Fallback to internet download
```

Plik w MediaPath jest uszkodzony. Usun i uruchom bez `-MediaPath` (pobierze z internetu).

### VM creation failed

```
[3/8] VM creation
  x VirtualBox VM creation failed: VT-x not enabled
    Action: Enable virtualization in BIOS
```

Wlacz virtualizacje w BIOS/UEFI (Intel VT-x / AMD-V).

### Log

Wszystkie logi sa w: `C:\structura\setup.log` (append, rotation >10MB).