#!/usr/bin/env python3
"""
freeze_stage.py - zamyka/odmraza etap instalacji (patrz verify_frozen.py).

ZAMKNIECIE (po udanej weryfikacji na zywej VM):
    python3 scripts/freeze_stage.py --stage 6 \
        --function Invoke-ContainerDeployment \
        --evidence "8/8 kontenerow healthy, docker ps potwierdzone"

ODMROZENIE (swiadoma decyzja):
    python3 scripts/freeze_stage.py --unfreeze 4 \
        --reason "blokada dpkg wymaga zmiany kolejnosci - weryfikacja od nowa"
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_frozen as vf  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", type=int, help="numer etapu do ZAMKNIECIA")
    ap.add_argument("--function", help="nazwa funkcji PowerShell dla tego etapu")
    ap.add_argument("--evidence", default="", help="czym potwierdzono dzialanie")
    ap.add_argument("--unfreeze", type=int, help="numer etapu do ODMROZENIA")
    ap.add_argument("--reason", default="", help="powod odmrozenia (wymagany)")
    args = ap.parse_args()

    if not os.path.exists(vf.SETUP):
        print("BLAD: nie znalazlem", vf.SETUP)
        return 2

    with open(vf.SETUP, encoding="utf-8") as f:
        source = f.read()

    state = vf.load_state()
    stages = state.setdefault("stages", {})

    # ---- ODMROZENIE ----
    if args.unfreeze:
        key = str(args.unfreeze)
        if key not in stages:
            print(f"Etap {key} nie jest zamkniety.")
            return 1
        if not args.reason.strip():
            print("BLAD: --reason jest WYMAGANY przy odmrazaniu.")
            print("Zamkniete etapy byly zweryfikowane na zywej VM - bez powodu")
            print("nie ma podstaw sadzic, ze zmiana jest bezpieczna.")
            return 1
        st = stages.pop(key)
        if "unfrozen_log" not in state:
            state["unfrozen_log"] = []
        state["unfrozen_log"].append({
            "stage": key, "function": st["function"], "reason": args.reason
        })
        vf.save_state(state)
        print(f"Etap {key} ({st['function']}) ODMROZONY.")
        print(f"  powod: {args.reason}")
        print()
        print("PAMIETAJ: przed ponownym zamknieciem przejdz kroki weryfikacji")
        print("z ETAPY.md (sekcja DOWODY) na ZYWEJ VM.")
        return 0

    # ---- ZAMKNIECIE ----
    if not args.stage or not args.function:
        ap.print_help()
        return 1

    h = vf.body_hash(source, args.function)
    if h is None:
        print(f"BLAD: funkcji '{args.function}' nie ma w setup.ps1.")
        print("Sprawdz nazwe: grep -n '^function' factor-vm-win11/setup.ps1")
        return 1

    stages[str(args.stage)] = {
        "function": args.function,
        "hash": h,
        "evidence": args.evidence,
    }
    vf.save_state(state)
    print(f"Etap {args.stage} ({args.function}) ZAMKNIETY.")
    print(f"  hash: {h}")
    if args.evidence:
        print(f"  dowod: {args.evidence}")
    print()
    print("Od teraz verify_frozen.py bedzie pilnowac, ze ta funkcja sie nie zmieni.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
