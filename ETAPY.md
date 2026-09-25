# ETAPY INSTALACJI — status zamknięcia

**Zasada nadrzędna:** etap ZAMKNIĘTY = nie dotykamy. Zmiana w zamkniętym etapie
wymaga jego ponownej weryfikacji (dowód niżej), albo jest zabroniona.

Historia pokazała dlaczego: przez tydzień cofaliśmy się z 8/8 działających
etapów na 5, bo każda naprawa "przy okazji" psuła coś zamkniętego wcześniej.
Fala 36 dodała blok `ensure` przed instalacją Dockera → regresja w ETAPIE 4
(blokada dpkg). Nikt tego nie zauważył, bo ETAP 4 był "już zrobiony".

---

## STATUS

| # | Etap | Status | Dowód | Data |
|---|------|--------|-------|------|
| 1 | Pre-flight (RAM, dysk, VBox, internet) | **ZAMKNIĘTY** | log: wszystkie checki `v`, blokada przy <8GB | 2026-09-23 |
| 2 | Media sourcing (ISO + VBox) | **ZAMKNIĘTY** | log: `OneDrive (SHA256 OK)` + pobieranie z sieci HTTP 200 | 2026-09-23 |
| 3 | VM creation + Ubuntu unattended | **ZAMKNIĘTY** | VM: `Ubuntu 24.04.5 LTS`, kernel 6.8.0-142, SSH kluczem | 2026-09-23 |
| 4 | Docker + make + Guest Additions + swap | **ZAMKNIĘTY** | VM: `docker 29.8.1`, `compose v5.5.1`, `GNU Make 4.3`, `vboxsf=2`, `swap 2047MB` | 2026-09-23 |
| 5 | Repo clone + klucze + appdata | **ZAMKNIĘTY** | VM: oba repo, `.env`, `git@github-core` i `-client` → `authenticated` | 2026-09-23 |
| 6 | Containers (make deploy + health) | **OTWARTY** | — | — |
| 7 | Hermes natywnie + usługa systemd | **OTWARTY** | — | — |
| 8 | Hosts + NAT + folder współdzielony | **OTWARTY** | — | — |

---

## DOWODY — jak sprawdzić samemu

Wszystko weryfikowalne przez SSH na VM (`-p 2222 structura@<ip>`).
Nie wierzymy logom instalatora — sprawdzamy stan VM, bo to on jest prawdą.

### ETAP 1-2 (Windows, bez VM)

```
Etap 1: log instalatora, linie "v Windows", "v Admin", "v RAM", "v Disk",
        "v VirtualBox", "v Internet", "v Media source"
Etap 2: log: "v Ubuntu ISO: ... (SHA256 OK)" / "v VirtualBox: ... (SHA256 OK)"
```

### ETAP 3 — maszyna wirtualna i system

```bash
ssh -i <klucz> -p 2222 structura@<vm-ip>
  lsb_release -d           # -> Ubuntu 24.04.5 LTS
  uname -r                 # -> 6.8.0-142-generic
```

### ETAP 4 — Docker, make, Guest Additions, swap

```bash
  docker --version                    # -> Docker version 29.8.1
  docker compose version              # -> Docker Compose version v5.5.1
  make --version | head -1            # -> GNU Make 4.3
  lsmod | grep -c vboxsf              # -> 2   (0 = Guest Additions BRAK)
  free -m | awk '/Swap/{print $2}'    # -> 2047  (0 = swap BRAK)
  sudo systemctl is-active docker     # -> active
  groups | grep -c docker             # -> 1
```

**Uwaga:** `vboxsf=0` i `swap=0` mimo komunikatu `v Guest Additions gotowe`
w logu to był prawdziwy błąd (Fala 39 — fałszywy sukces). Dlatego etap 4
weryfikujemy przez SSH, nie przez log.

### ETAP 5 — repozytoria i klucze

```bash
  test -d /opt/structura/repos/structura-core && echo core:OK
  test -d /opt/structura/repos/structura-clients-sawaryn && echo client:OK
  test -f /opt/structura/repos/structura-core/.env && echo env:OK
  ssh -T git@github-core     # -> "Hi structura-factor/structura-core! ... authenticated"
  ssh -T git@github-client   # -> "Hi structura-factor/structura-clients-sawaryn! ... authenticated"
```

Dodatkowo: sekrety wygenerowane (`N8N_ENCRYPTION_KEY`, `DUPLICATI_PASSWORD`,
`NPM_ADMIN_PASSWORD`, `SEARXNG_SECRET_KEY`, `PORTAINER_ADMIN_PASSWORD`,
`N8N_RUNNERS_AUTH_TOKEN`, `SMB_PASSWORD`).

### ETAP 6 — kontenery

```bash
  docker ps --format '{{.Names}}: {{.Status}}'
  # oczekiwane 8: n8n, n8n-runners, postgresql, searxng, npm, duplicati,
  #               portainer, homepage  — wszystkie "healthy"
```

### ETAP 7 — Hermes jako usługa

```bash
  systemctl is-active hermes
  systemctl status hermes --no-pager | head -5
  ls -la ~/.local/bin/hermes
  # UWAGA: usluga dziala jako User=structura. Pliki musza byc w /home/structura,
  # nie w /root (blad 203/EXEC).
```

### ETAP 8 — dostep z Windows

```
Windows: sprawdz wpisy w C:\Windows\System32\drivers\etc\hosts
         (homepage.local, n8n.local, dashboard.local, ...)
         oraz regule NAT: VBoxManage showvminfo <vm> | findstr natpf
Przegladarka: http://homepage.local -> panel
```

---

## PROTOKÓŁ PRACY (obowiązujący)

### Przed zmianą czegokolwiek

1. Sprawdź, którego etapu dotyka zmiana. Jeśli **zamkniętego** — STOP,
   najpierw zaplanuj jego ponowną weryfikację.
2. Uruchom `git log -p -S "<zmieniany fragment>"` — może już raz to naprawiano.
3. Sprawdź komentarze `UWAGA (naprawiony blad)` obok — pole było już zepsute.

### Po zmianie dotykającej zamkniętego etapu

Nie zamykaj zadania, dopóki nie przejdziesz ponownie **kroków weryfikacji
z sekcji DOWODY** dla tego etapu, na żywej VM.

### Kolejność zmian

Zmiana w etapie N może zepsuć etap N+1 swoim **istnieniem** (nie treścią).
Dowód: Fala 36 dodała krok w etapie 4 → Docker przestał się instalować,
bo krok zabrał blokadę dpkg. Zawsze pytaj: *co się zmienia w KOLEJNOŚCI
i ŚRODOWISKU, w którym działa reszta?*

### Testowanie bez reinstalacji

Mając SSH do VM można odtworzyć dowolny etap ręcznie, bez kasowania maszyny:
skrypty zostają w `/tmp/structura-*.sh` po nieudanym runie. Uruchomienie ich
ręcznie pokazuje, czy problem jest w **treści** skryptu, czy w **wywołaniu**.

---

## HISTORIA REGRESJI

| Fala | Co dodano | Co zepsuło | Etap |
|------|-----------|------------|------|
| 30 | pg18 zamiast pg16 | postgres nie wstawał (PGDATA) | 6 |
| 36 | blok `ensure` przed Dockerem | blokada dpkg → `docker: command not found` | 4 |
| 36 | `Invoke-Scp` przez `Start-Process` | `$null ExitCode` → fałszywa porażka scp | 4 |
| 37 | profil Mini | wymusił 3GB, ujawnił brak swapu | 4 |
| 38 | czekanie na dpkg | (naprawa 36) | 4 |
| 39 | `MAKE_OK` jako warunek | (naprawa fałszywego sukcesu z 36) | 4 |

**Wniosek:** 4 z 5 regresji dotyczyły ETAPU 4. Etapy 1-3 i 5 ani razu nie
zostały zepsute. To znaczy: tam praca jest skończona i nie ma po co wracać.
