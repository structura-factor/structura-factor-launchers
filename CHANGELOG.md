# CHANGELOG — structura-factor-launchers

## Fala 44 (2026-11-17) — testy V1/base na czystej CiemPincie (Win11) + fixy

Kontekst: pełne testy instalatora V1 w profilu base od zera na czystym Win11 (CiemPinta
192.168.40.8), VirtualBox 7.1.16, VM Ubuntu Server 24.04.5, klucze i CDN jak u klienta.
Test-runer: `irm <Install@pin>` z `-Client base -OllamaApiKey -MediaCachePath`.
Dowody: C:\STRUCTURA\logs (setup.log, install-console.log) + /opt/data/factor-un/reports/.

### 44 — -OllamaApiKey transport (Install + bootstrap)
- Install: nowy parametr `[string]$OllamaApiKey` (przekazywany do bootstrapa; NIE blokuje instalacji gdy brak — ETAP 7 zostaje WARN),
  log redaguje wartość (`-OllamaApiKey '***'`).
- bootstrap: passthrough do setup.ps1 + redakcja w `Setup command` logu.
- Powód: runy testowe potrzebują klucza Ollama Cloud w ETAP 7 (Hermes na VM), wariant kliencki zostaje keyless.
- Piny: bootstrap@a0b7ca7, Install@0768fba.

### 44b — base: klucz core pełni rolę klucza klienta (Install)
- Install `$ba`: przy `-Client base` (gdy brak klucza klienta) przekazuje `-DeployKeyPath <deploy_key_core>`.
- Bez tego ETAP 3 (ZAMROŻONY, `Invoke-VMCreation`) padal z "Brak klucza publicznego - przerwano
  przed utworzeniem VM" na czystym hoscie: pub idzie do cloud-init ssh_authorized_keys, host SSH-uje
  prywatną połową `~/.ssh/id_ed25519` (Install-DeployKey).
- Dowód: run 2026-11-17 00:15 (VM structura-base {82797997} usunięta).
- Piny: Install@72b2180, Test@74653fe.

### 44c — ETAP 3: bounded TCP+banner pre-check przed pełnym ssh (setup.ps1)
- Handshake loop (ETAP 3 zamrożony — zmiana z DOWODEM awarii): NAT listener akceptuje TCP nawet gdy gość
  milczy na 22 (subiquity w instalacji) → `ssh.exe` bez timeoutu bannera wisiał 16+ min (0 iteracji).
- Teraz: TCP connect 5 s + banner 15 s; brak bannera → iteracja bez pełnego ssh.
- Dowód: run 2026-11-17 00:22–00:38 (VM {7479428e}, usunięta po diagnozie).
- Re-freeze ETAP 3: freeze_stage.py --stage 3 --evidence (po pozytywnym teście zywej VM).

### 44d — ETAP 3: pełny ssh probe bounded (setup.ps1)
- Drugi poziom tego samego wisienia: ssh wisiał POST-bannera (ConnectTimeout ogranicza tylko TCP;
  gość z dociążonym/slow sshd). Teraz: Start-Process + WaitForExit(40 s) + timeout → `SSH_PROBE_TIMEOUT`.
- Dowód: run 2026-11-17 01:2x — [25min] self-heal boot z dysku → znowu cisza po bannerze ("soft lockup
  CPU#0 stuck for 41s" w gościu — 2 vCPU na tym hoscie widać przeciążone).

### Piny po Fali 44d (CDN zweryfikowany: 3/3 pary byte-identyczne)
- Test@96d4e9e → Install@a27b16b → bootstrap@9163472 → setup@ad7d228 (base).
- setup.ps1 pozostaje ZAMROŻONY na etapach 5/6/8 jako ZMIENIONE (Fala 43) — re-freeze po weryfikacji na żywej VM (decyzja orchestratora).

### Infrastruktura testów (nie-kod)
- Nowy deploy key: `deploy-key-core-f44-test` (read_only, ed25519) w repo structura-core;
  klucz prywatny lokalnie `/opt/data/factor-un/deploy-key-core` (+pub na CiemPincie w klucze).
  Stary `deploy-key-core` na GitHubie NIE MA lokalnej połowy (martwy — do rotacji).
- Ollama key testowy ląduje na CiemPincie w C:\STRUCTURA\klucze\ollama.key (0600 — Windows ACL per user).
- Runy: detached start /b NIE działa (Read-Host wisie); działający mechanizm: foreground powershell
  w sesji ssh z EOF-stdin (printf '' | ssh ...) → Read-Host zwraca pusty string → defaulty.

## Fala 46 (2026-11-17) — RUN 6 post-mortem + wyciek klucza w logu

Kontekst: RUN 6 (02:43-03:47) padł w ETAP 3 (45 min "Permission denied"); autopsja sesji B:
gość KVM/TSC zamrożony (VBox.log DELTA=0 przy VMState=running; "TM: Giving up catch-up attempt
at a 149 s lag"). RUN 7 na tych samych skryptach z -VM_CPU 6 przeszedł ETAP 3 normalnie →
awaria środowiskowa (2 vCPU + KVM-paravirt TSC na CiemPincie), nie regresja skryptu.

### 46b — bootstrap: redakcja klucza w linii "Arguments:" (BEZPIECZEŃSTWO)
- Do tego czasu `***` dotyczyło TYLKO linii "Setup command:" — linia `Arguments: -Client base ...
  -OllamaApiKey <JAWNY KLUCZ>` lądowała w console logu runu testowego (dowód:
  install-console-r6.log, [INFO] Arguments). Teraz: `$argsForLog = $setupArgs -join ' '`;
  przy niepustym `$OllamaApiKey` → `-replace [regex]::Escape($OllamaApiKey), '***'`.
- Piny po Fali 46: Test@947efd0 → Install@e07b58e → bootstrap@c15db33 → setup@330f7a8
  (CDN zweryfikowany 4/4 byte-identyczne).

### 46a — setup.ps1: bump build ID F43-20261116 → F46-20261117
- Reguła "build ID w logu": banner nie był podbijany mimo zmian Fala 44c/44d w setup.ps1 —
  log runów wyglądał identycznie mimo innych skryptów.

## Fala 47 (2026-11-17) — RUN 7: "Containers deployed", potem dwie klasa crashy

Kontekst: RUN 7 (05:15-05:41, VM 9e022fb7, 6 vCPU/8 GB): ETAPy 3-5 PASS, ETAP 6 core PASS
("Containers deployed", 8 kontenerów + runner healthy; core Fala 45 @684e92d verified e2e).
Po tym run padł na DWIE usterki (fixy ponizej); sesja wyczerpała wtedy budżet iteracji.

### 47 — setup.ps1: health-table [Console]::CursorTop w try/catch
- Dowód: transcript RUN 7, "PS>TerminatingError: Nieprawidlowe dojscie" tuż po
  "Waiting for containers to be healthy..." — przy stdout przekierowanym (run
  nie-interaktywny) odczyt pozycji kursora rzuca "handle invalid" i UBIA cały run
  zaraz po deployu kontenerów. Fix: try/catch + pomijanie pozycjonowania przy braku
  konsoli (tabela drukuje się linearnie). Build F47-20261117.
### 47b/c/d — re-piny
- setup@d892aa7 → bootstrap@587122369b → Install@2299456 → Test@72258fb.

## Fala 48 (2026-11-17) — RUN 8 post-mortem: nadpisywanie .env przy re-runie + klucz LLM Hindsight

Kontekst: RUN 8 (05:48-05:50, runner run-f47b: setup @d892aa7 na ISTNIEJĄCEJ VM, stdin-EOF
→ defaulty = menu "istniejąca"): ETAPy 1-3 w ~2 min, ETAP 6: `make deploy` FAIL w ~60 s.
Dowód: setup.log [INFO] DEPLOY_FAILED rc=2 + diag — n8n "Mismatching encryption keys"
(N8N_ENCRYPTION_KEY z REGENEROWANEGO .env != klucz w /home/node/.n8n/config z wolumenu
RUN 7) → dependency failed → abort; Duplicati SettingsEncryptionKeyMismatch (ta sama
klasa); hindsight LLM HTTP 401 (compose fallback API_KEY="ollama" przy ollama.com/v1 —
key NIGDY nie był wstrzykiwany do stack .env).

### 48 — setup.ps1 (Invoke-ContainerDeployment, blok env): .env idempotentny (kept/restore/template)
- Wcześniej: `cp .env.example → .env` nadpisywał .env na KAŻDYM runie; backup do
  /opt/structura/config/.env szedł PRZED generate-secrets (backup = surowy szablon!);
  generate-secrets wyrzucał ŚWIEŻE sekrety nad danymi wolumenów → n8n/duplicati
  restart-loops (pitfall 18 ze skilla, teraz z żywym dowodem RUN 8).
- Teraz: kept (live .env z poprzedniego runa) → restore z config/.env →
  template+generate-secrets wyłącznie przy pierwszym starcie. generate-secrets biegnie
  dalej zawsze (idempotentny — nadpisuje tylko placeholdery). Backup idzie
  PO sekretach i PO wstrzyknięciu klucza LLM; markery CONFIG_ENV_BACKED_UP /
  CONFIG_ENV_BACKUP_FAILED; PS-side fail-check na BACKUP_FAILED.
- Uwaga zakresowa: zmiana leży w Invoke-ContainerDeployment (ETAP 6) — etap i tak
  status ZMIENIONY (Fala 43/47), czeka re-weryfikację na żywej VM + re-freeze orchestratora.

### 48b — setup.ps1 (Invoke-ContainerDeployment, blok env): klucz ollama-cloud → plane LLM Hindsight
- Compose czyta HINDSIGHT_{,RETAIN,CONSOLIDATION,REFLECT}_LLM_API_KEY z .env; bez wpisów
  fallback = literal "ollama" przy https://ollama.com/v1 → HTTP 401 przy każdym retain
  (pamięć martwa "od pudełka"). Teraz: przy -OllamaApiKey (run testowy) klucz wchodzi
  do stack .env (4 role), walidacja znaków jak w ETAP 7, wartość NIE logowana, wpis
  idempotentny (re-run: sed nadpisuje tą samą wartością). Wariant kliencki (bez klucza)
  dostaje jawny WARN "pamieć 401 aż do konfiguracji klienta" — jak dotąd instalacja
  pozostaje nieblokowana.
- Build ID: F47-20261117 → F48-20261117.

### 48e — setup.ps1: ETAP 8 host-side na VBox 7.1.16 (run-side share + autostart)

- Dowód RUN 10 (11:07): "Konfigurowanie wspólnego folderu AI_Workspace..." → FATAL —
  pierwszy żywy ETAP 8 host-side (zamrożony od STAN-2026-09-25, nigdy nie weryfikowany
  na VBox 7.1.16). Trzy usterki w Install-SharedFolder / Install-VmAutostart (ETAP 8 —
  status ZMIENIONY od Fala 43, czeka re-weryfikację + orchestrator re-freeze):
  1. `controlvm <vm> sharedfolder ...` — podkomenda NIE istnieje w 7.1.16 ("Invalid
     parameter 'sharedfolder'"); trwała rejestracja na działającej VM —
     VBOX_E_INVALID_OBJECT_STATE (0x80bb0007, write lock). Żywa forma (sonda
     empiryczna: add + remove OK na działającej VM): `sharedfolder add --transient`.
  2. `sharedfolder list <vm>` — "Unknown subcommand: list"; weryfikacja przez
     `showvminfo --machinereadable` (linia SharedFolderNameTransientMapping).
  3. stderr VBoxManage/schtasks przy globalnym EAP='Stop' → TerminatingError ubijający
     cały ETAP 8 (reguła 4 ze skilla). Blok VBox i schtasks /Delete//Create//Run
     biegną teraz przy EAP='Continue' (try/finally); brak udziału na stderr = normalny stan.
- Trwałość AI_Workspace domknięta: Install-SharedFolder przy vmRunning → --transient
  (ginie przy restarcie), natomiast autostart task generuje C:\STRUCTURA\start-vm.cmd
  (ASCII + CRLF): trwałe `sharedfolder add` przy VM ZATRZYMANEJ (write lock wolny) +
  startvm; VBOX_USER_HOME w pliku (SYSTEM nie dziedziczy env); /TR krótki (limit
  długości schtasks). fstab (nofail, uid=1000) montuje udział przy każdym starcie VM.
- Duplicati-check: grep łapał 'structura-duplicati', kontener nazywa się 'duplicati'
  (compose container_name) → fałszywy WARN przy zdrowym kontenerze; obie nazwy akceptowane.
- Build: F48-20261117 → F49-20261117.

### 48f — setup.ps1: ostatnia bomba EAP w Install-VmAutostart (RUN 11 evidence)

- RUN 11 przeszedł prawie cały ETAP 8 (share zarejestrowany + ZAMONTOWANY w runie,
  autostart task utworzony + zweryfikowany, Duplicati-check OK po 48e) i umarł na:
  `modifyvm --autostart-enabled on` przy DZIAŁAJĄCEJ VM → stderr "already locked for a
  session" → globalne EAP='Stop' → TerminatingError. Fix: blok przy EAP='Continue' +
  rc-based JAWNE pomijanie (schtasks pokrywa autostart). Build F50-20261117.
