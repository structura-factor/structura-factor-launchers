# ============================================================================
# STRUCTURA FACTOR - launchers
# ============================================================================
# Ten Makefile obsluguje PRACE NAD INSTALATOREM (nie instalacje u klienta).
#
# Kluczowa komenda: make check-frozen
#   Pilnuje, ze ZAMKNIETE etapy instalacji (1-5, zweryfikowane na zywej VM)
#   nie zostaly zmienione. Jesli ktos je ruszy - zatrzymuje prace.
#
# Po co: przez tydzien cofnelismy sie z 8/8 dzialajacych etapow do 5, bo
# kazda naprawa "przy okazji" psula cos, co juz dzialalo. Fala 36 dodala
# krok w ETAPIE 4 - tresc instalacji Dockera byla identyczna, ale zmienila
# sie KOLEJNOSC, i Docker przestal sie instalowac.
# ============================================================================

.PHONY: help check-frozen verify freeze-status

help:
	@echo "STRUCTURA FACTOR - launchers"
	@echo ""
	@echo "  make check-frozen     - sprawdz czy zamkniete etapy sa nietkniete"
	@echo "  make verify           - pelna weryfikacja (skladnia PS + ASCII + etapy)"
	@echo "  make freeze-status    - pokaz ktore etapy sa zamkniete"
	@echo ""
	@echo "Zamykanie/odmrazanie etapow:"
	@echo "  python3 scripts/freeze_stage.py --stage N --function NazwaFunkcji --evidence \"...\""
	@echo "  python3 scripts/freeze_stage.py --unfreeze N --reason \"...\""

# --- BLOKADA ZAMKNIETYCH ETAPOW -------------------------------------------
# Uruchamiaj PRZED kazda zmiana w setup.ps1 i po niej.
check-frozen:
	@python3 scripts/verify_frozen.py

freeze-status:
	@python3 -c "import json; d=json.load(open('frozen_stages.json')); \
	print('Zamkniete etapy:'); \
	[print(f\"  {k}: {v['function']}  [{v['hash']}]  {v.get('evidence','')}\") \
	 for k,v in sorted(d.get('stages',{}).items(), key=lambda x:int(x[0]))]" 2>/dev/null \
	 || echo "  (brak zamknietych etapow)"

# --- PELNA WERYFIKACJA ----------------------------------------------------
# To samo, co robimy recznie przed kazdym commitem instalatora.
verify: check-frozen
	@echo ""
	@echo "=== Skladnia PowerShell ==="
	@DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 pwsh -NoProfile -Command \
	  "$$e=$$null; [System.Management.Automation.Language.Parser]::ParseFile('factor-vm-win11/setup.ps1',[ref]$$null,[ref]$$e)|Out-Null; \
	   if($$e.Count -gt 0){ Write-Host ('  BLEDOW: ' + $$e.Count); $$e | Select-Object -First 5 | ForEach-Object { Write-Host ('    linia ' + $$_.Extent.StartLineNumber + ': ' + $$_.Message) }; exit 1 } else { Write-Host '  OK' }"
	@echo ""
	@echo "=== Nie-ASCII w plikach wykonywalnych (PS 5.1 wymaga czystego ASCII) ==="
	@python3 -c "import sys; \
	bad=0; \
	files=['factor-vm-win11/setup.ps1','Install-STRUCTURA-FACTOR.ps1','bootstrap.ps1','Test-STRUCTURA-FACTOR.ps1']; \
	[print(f'  {f}: {sum(1 for b in open(f,\"rb\").read() if b>127)}') for f in files]; \
	sys.exit(0)"
	@echo ""
	@echo "Weryfikacja zakonczona."
