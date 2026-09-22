# STRUCTURA FACTOR — Launchers

Publiczne repozytorium **mechaniki instalacyjnej** dla STRUCTURA AI.

## Zasada: launcher nie wie nic o kliencie

To repo zawiera **tylko mechanizm**. Nie ma tu konfiguracji żadnego klienta —
wszystko, co specyficzne, klient trzyma we własnym repo (`structura-clients-*`).

Dzięki temu ten sam launcher obsłuży kolejnych klientów bez zmian, a nowy
target instalacji (np. Ubuntu bez VM) to **nowy katalog + wpis w manifeście**,
bez dotykania istniejącego kodu.

## Zawartość

```
structura-factor-launchers/
├── README.md                  # Ten plik
├── launchers.yaml             # MANIFEST dostępnych launcherów
├── Test-STRUCTURA-FACTOR.ps1  # Entry point dla klienta (pobiera wszystko)
├── Install-STRUCTURA-FACTOR.ps1  # Instalator interaktywny
├── bootstrap.ps1              # Pobiera bootstrap.yaml klienta i odpala launcher
├── bootstrap.sh               # Wariant Linux (stub)
└── factor-vm-win11/           # Launcher: Ubuntu w VirtualBox na Windows
    ├── README.md
    ├── setup.ps1              # Główny skrypt instalacyjny
    ├── setup.bat              # Wrapper (nieużywany — jsDelivr blokuje .bat)
    ├── ubuntu-unattend.xml    # Pozostałość — instalacja idzie szablonem cloud-init
    └── media/versions.txt     # SHA256 dla dużych plików
```

## Jak działa wybór launchera

Kolejność decyzyjna (pierwsze trafienie wygrywa):

1. **Parametr `-Launcher`** — jawny wybór, np. przy testach bez klienta
2. **`launcher:` w `bootstrap.yaml`** klienta — normalny tryb produkcyjny
3. **Manifest `launchers.yaml`** — interaktywna lista, gdy nic nie wskazano

```powershell
# Klient ma bootstrap.yaml -> launcher wybrany automatycznie
.\bootstrap.ps1 -Client sawaryn -DeployKeyPath C:\path\to\deploy_key

# Test bez klienta -> wybór z listy
.\bootstrap.ps1 -Launcher factor-vm-win11

# Jawnie (nadpisuje wszystko)
.\bootstrap.ps1 -Client sawaryn -Launcher factor-vm-win11
```

## Dodanie nowego launchera

1. Utwórz katalog `<nazwa>/` z `setup.ps1` (lub `setup.sh`)
2. Dopisz wpis w `launchers.yaml`
3. Gotowe — `bootstrap.ps1` sam go znajdzie i zaoferuje

Komentarze w manifeście (`#`) są pomijane przy parsowaniu, więc warianty
planowane można trzymać zakomentowane — jak `factor-bare-ubuntu`
w `launchers.yaml`.

## Architektura instalacji (launcher `factor-vm-win11`)

```
Windows (host) → VirtualBox VM → Ubuntu 24.04 Server
                                    ├── Hermes Agent (NATYWNIE, systemd) :9119
                                    └── Docker: 8 kontenerów
                                        ├── npm          (reverse proxy)
                                        ├── postgresql   (PostgreSQL 16 + pgvector)
                                        ├── hindsight    (API pamięci)
                                        ├── searxng      (prywatna wyszukiwarka)
                                        ├── n8n          (automatyzacje)
                                        ├── duplicati    (kopie zapasowe)
                                        ├── portainer    (zarządzanie)
                                        └── homepage     (dashboard klienta)
```

**Hermes działa natywnie na VM, nie w kontenerze** — dzięki temu zarządza
kontenerami bezpośrednio i nie jest ograniczony izolacją.

## Bezpieczeństwo

- To repo jest **publiczne** — zero sekretów w kodzie
- Deploy keys idą do `~/.ssh/` (NIGDY do repo)
- Wszystkie hasła klienta w `.env` z `chmod 600`
- Skrypty są idempotentne (guard clauses na każdym kroku)

## Powiązane repozytoria

| Repo | Zawartość |
|------|-----------|
| `structura-core` (private) | Stack Docker, Makefile, **wspólne skille**, mechanika usług |
| `structura-clients-<nazwa>` (private) | **Tylko** custom klienta: SOUL, konfiguracja, brandingu, skille własne |

Podział skilli: generyczne (pdf, n8n, excalidraw) żyją w `core/skills/` —
utrzymywane raz dla wszystkich klientów. Custom (microsoft-365, prawny-*)
w repo klienta. Instalator łączy oba; klient może nadpisać wspólny skill.

## Licencja

MIT — dla użytku wewnętrznego kancelarii Sawaryn i Partnerzy oraz przyszłych
klientów STRUCTURA AI.
