#!/usr/bin/env python3
"""Static regression checks for the Swift RPPairing file import flow."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
swift = (root / "App/ContentView.swift").read_text()
readme = (root / "README.md").read_text()
checks = {
    "file importer UI": 'Import / Validate RP Pairing File' in swift and '.fileImporter(' in swift,
    "required RP fields checked": all(f'plist["{k}"]' in swift for k in ("public_key", "private_key", "identifier", "alt_irk")),
    "public/private key consistency checked": 'privateKeyObject.publicKey.rawRepresentation == publicKey' in swift,
    "atomic import destination": 'rp_pairing_file_imported.plist' in swift and 'replaceItemAt' in swift,
    "local validation is not mislabeled pair-verify": 'This does not prove the remote peer accepts it' in swift,
    "docs warn about private key exposure": 'trattati come segreti' in readme and 'revoca o sostituisci' in readme,
}
for name, ok in checks.items():
    print(f"{'PASS' if ok else 'FAIL'}: {name}")
if not all(checks.values()):
    raise SystemExit(1)
