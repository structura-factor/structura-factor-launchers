#!/usr/bin/env python3
"""
FROZEN_STAGES - twarda blokada zamknietych etapow.

ZASADA: etap ZAMKNIETY = nie ruszamy. Nie "ostroznie", nie "tylko poprawka",
nie "przy okazji". W ogole.

Po co: przez tydzien cofnelismy sie z 8/8 dzialajacych etapow do 5, bo kazda
naprawa "przy okazji" psula cos, co juz dzialalo. Fala 36 dodala blok `ensure`
PRZED instalacja Dockera - tresc instalacji Dockera byla identyczna, ale
zmienila sie KOLEJNOSC, i Docker przestal sie instalowac (blokada dpkg).

JAK DZIALA:
  frozen_stages.json   - dla kazdego zamknietego etapu: nazwa funkcji i SHA256
                         jej ciala wziete z zamrozonego commita
  verify_frozen.py     - porownuje AKTUALNE cialo funkcji z zapisanym hashem
                         (ten plik)
  make check-frozen    - uruchamia weryfikacje

Jesli hash sie nie zgadza - ktos (czlowiek albo agent) zmienil zamkniety etap.
Weryfikacja NIE naprawia automatycznie. Mowi WPROST i wymaga decyzji.

JAK ZAMKNAC NOWY ETAP (po udanej weryfikacji na zywej VM):
  python3 scripts/freeze_stage.py --stage 6 --function Invoke-ContainerDeployment

JAK ODMROZIC (swiadoma decyzja, wymaga uzasadnienia):
  python3 scripts/freeze_stage.py --unfreeze 4 --reason "konkretny powod"
"""

import hashlib
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETUP = os.path.join(REPO, "factor-vm-win11", "setup.ps1")
STATE = os.path.join(REPO, "frozen_stages.json")


def function_body(source: str, name: str):
    """Wyciaga cialo funkcji PowerShell (od 'function Nazwa {' do zamykajacego '}').

    Liczy nawiasy klamrowe, zeby poprawnie obsluzyc zagniezdzone bloki
    (if/foreach/try) - proste szukanie pierwszej '}' na poczatku linii nie
    dziala, bo funkcje maja wiele poziomow.
    """
    m = re.search(r"^function\s+" + re.escape(name) + r"\s*\{", source, re.M)
    if not m:
        return None
    start = m.start()
    i = m.end() - 1  # pozycja '{'
    depth = 0
    in_single = False
    in_double = False
    while i < len(source):
        ch = source[i]
        # Pomijamy nawiasy wewnatrz stringow ("..." i '...'), bo tam '{' nie
        # liczy sie do zagniezdzenia. Uproszczone, ale wystarcza dla naszego kodu.
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif not in_single and not in_double:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return source[start:i + 1]
        i += 1
    return None


def norm(text: str) -> str:
    """Normalizacja przed hashowaniem.

    Powod: komentarze i biale znaki nie zmieniaja DZIALANIA, a zmieniaja hash.
    Chcemy lapac zmiany ZACHOWANIA, nie kosmetyki - inaczej kazdy komentarz
    wymagalby odmrazania etapu i blokada stalaby sie bezuzyteczna.
    Usuwamy: komentarze (#... do konca linii), wciacia, puste linie.
    """
    out = []
    for line in text.split("\n"):
        s = line.strip()
        if not s:
            continue
        # usun komentarz na koncu linii (ale nie '#' wewnatrz stringa)
        if " #" in s:
            s = s.split(" #", 1)[0].rstrip()
        if s.startswith("#"):
            continue
        out.append(re.sub(r"\s+", " ", s))
    return "\n".join(out)


def body_hash(source: str, name: str):
    body = function_body(source, name)
    if body is None:
        return None
    return hashlib.sha256(norm(body).encode("utf-8")).hexdigest()[:16]


def load_state():
    if not os.path.exists(STATE):
        return {"stages": {}}
    with open(STATE, encoding="utf-8") as f:
        return json.load(f)


def save_state(state):
    with open(STATE, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=True)
        f.write("\n")


def main():
    if not os.path.exists(SETUP):
        print("BLAD: nie znalazlem", SETUP)
        return 2

    with open(SETUP, encoding="utf-8") as f:
        source = f.read()

    state = load_state()
    stages = state.get("stages", {})

    if not stages:
        print("Brak zamknietych etapow (frozen_stages.json pusty).")
        return 0

    print("Weryfikacja ZAMKNIETYCH etapow (nie wolno ich zmieniac):")
    print()
    broken = []
    for num in sorted(stages, key=lambda x: int(x)):
        st = stages[num]
        name = st["function"]
        expected = st["hash"]
        actual = body_hash(source, name)
        label = f"  Etap {num} ({name})"
        if actual is None:
            print(f"{label}: FUNKCJA NIE ISTNIEJE")
            broken.append((num, name, expected, "brak"))
        elif actual == expected:
            print(f"{label}: NIETKNIETY  [{expected}]")
        else:
            print(f"{label}: ZMIENIONY!  oczekiwany {expected}, jest {actual}")
            broken.append((num, name, expected, actual))

    print()
    if broken:
        print("=" * 70)
        print("  STOP - ZAMKNIETY ETAP ZOSTAL ZMIENIONY")
        print("=" * 70)
        for num, name, exp, act in broken:
            print(f"  Etap {num}: {name}  {exp} -> {act}")
        print()
        print("Zamkniete etapy byly ZWERYFIKOWANE NA ZYWEJ VM. Zmiana wymaga:")
        print("  1. uzasadnienia (co i dlaczego) w commit message,")
        print("  2. PONOWNEJ weryfikacji krok po kroku (patrz ETAPY.md, sekcja DOWODY),")
        print("  3. swiadomego odmrozenia:")
        print("       python3 scripts/freeze_stage.py --unfreeze <etap> --reason \"...\"")
        print()
        return 1

    print("Wszystkie zamkniete etapy nietkniete. OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
