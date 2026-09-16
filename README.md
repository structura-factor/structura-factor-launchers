# STRUCTURA FACTOR - Launchers

Publiczne repozytorium launcherow instalacyjnych dla STRUCTURA AI - Personal Assistant prawniczy.

## Zawartosc

```
structura-factor-launchers/
├── README.md                          # Ten plik
├── bootstrap.ps1                      # Uniwersalny bootstrap (Windows PowerShell)
├── bootstrap.sh                        # Uniwersalny bootstrap (Linux/Mac, stub)
└── factor-vm-win11/                    # Launcher VM Windows 11
    ├── README.md                       # Instrukcja launcher Win11
    ├── setup.bat                       # Wrapper batch wywolujacy setup.ps1
    ├── setup.ps1                       # Glowny skrypt instalacyjny (PowerShell)
    ├── ubuntu-unattend.xml             # Cloud-init konfiguracja Ubuntu 24.04
    └── media/
        └── versions.txt                # SHA256 checksums dla duzych plikow
```

## Szybki start

### Windows 11 (klient kancelarii)

1. Pobierz i uruchom `bootstrap.ps1`:

```powershell
# Opcja A: Z deploy key
.\bootstrap.ps1 -Client sawaryn -DeployKeyPath C:\path\to\deploy_key

# Opcja B: Z media caching (OneDrive - dla drugiego+ klienta)
.\bootstrap.ps1 -Client sawaryn -MediaPath "C:\Users\premek\OneDrive\STRUCTURA\media\"
```

2. Albo uruchom bezposrednio setup.ps1:

```powershell
.\factor-vm-win11\setup.bat
```

### Media caching (OneDrive)

Pierwszy klient pobiera Ubuntu ISO (~2.5GB) i VirtualBox installer (~100MB) z internetu.
Pliki sa zapisywane w wspoldzielonym folderze OneDrive (`STRUCTURA\media\`).

Kolejni klienci uruchamiaja `setup.ps1 -MediaPath "C:\Users\<user>\OneDrive\STRUCTURA\media\"`
i pliki leca z lokalnego OneDrive (oszczednosc ~10-15 min).

Szczegoly w `factor-vm-win11/README.md`.

## Bezpieczenstwo

- To repo jest **publiczne** - zero sekretow w kodzie
- Wszystkie parametry klienckie (API keys, hasla) ida do `.env` z `chmod 600`
- Deploy keys ida do `~/.ssh/` (NIGDY w .env)
- Skrypty sa idempotentne (guard clauses na kazdym kroku)

## Architektura

```
Windows 11 (host) → VirtualBox VM → Ubuntu 24.04 Server → Docker Compose → 9 kontenerow
                                                                    ├── npm (Nginx Proxy Manager)
                                                                    ├── hindsight (PostgreSQL)
                                                                    ├── hermes (Hermes Agent)
                                                                    ├── searxng (SearXNG)
                                                                    ├── n8n (n8n workflows)
                                                                    ├── duplicati (backup)
                                                                    ├── portainer (Docker management)
                                                                    ├── homepage (dashboard)
                                                                    └── telegram-bot
```

## Powiazane repozytoria

- `ciemek/structura-core` (private) - bazowy stack Docker Compose
- `ciemek/structura-clients` (private) - konfiguracja per-klientowa (np. `sawaryn/`)

## Licencja

MIT - dla uzytku wewnetrznego kancelarii Sawaryn i Partnerzy oraz przyszlych klientow STRUCTURA AI.