import io
import re

p = "/opt/data/sf-work/structura-factor-launchers/factor-vm-win11/setup.ps1"
lines = io.open(p, encoding="utf-8").read().split("\n")

# Znajdz WSZYSTKIE here-doki bash w here-stringach PowerShell.
# Wzorzec: << DELIM  (opcjonalnie <<- ktory zjada TABULATORY, nie spacje)
opens = []
for i, l in enumerate(lines, 1):
    m = re.search(r"<<-?\s*([A-Za-z_][A-Za-z0-9_]*)", l)
    if m and "tee " in l or (m and "cat " in l and "<<" in l):
        opens.append((i, m.group(1), len(l) - len(l.lstrip())))

print("Here-doki bash w setup.ps1:")
print()
bad = []
for ln, delim, ind in opens:
    # znajdz zamykajacy delimiter
    close_ln = None
    close_ind = None
    for j in range(ln, len(lines)):
        if lines[j].strip() == delim:
            close_ln = j + 1
            close_ind = len(lines[j]) - len(lines[j].lstrip())
            break
    status = "OK" if close_ind == 0 else f"WCIETY ({close_ind} spacji) <-- BLAD"
    if close_ind != 0:
        bad.append((ln, delim, close_ln, close_ind))
    print(f"  linia {ln:5d}: << {delim:12s} (otwarcie wciecie={ind})")
    print(f"           zamkniecie: linia {close_ln}, wciecie={close_ind}  -> {status}")

print()
if bad:
    print("=" * 70)
    print("  BLAD: zamykajace delimitery z wcieciem")
    print("=" * 70)
    for ln, delim, cln, ind in bad:
        print(f"  {delim}: otwarcie linia {ln}, zamkniecie linia {cln} z {ind} spacjami")
    print()
    print("Bash wymaga, by zamykajacy delimiter byl na POCZATKU LINII.")
    print("'<<-' zjada tylko TABULATORY, nie spacje. Wciecie = here-doc sie")
    print("nie domyka -> zawartosc leci jako komendy -> unit systemd pusty/smieci.")
else:
    print("Wszystkie delimitery na poczatku linii.")
