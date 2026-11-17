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
