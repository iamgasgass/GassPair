#!/usr/bin/env python3
"""Static regression checks for RPPairing import and no-PIN verification."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
swift = (root / "App/ContentView.swift").read_text()
readme = (root / "README.md").read_text()
checks = {
    "file importer UI": 'Import / Validate RP Pairing File' in swift and '.fileImporter(' in swift,
    "required RP fields checked": all(f'plist["{k}"]' in swift for k in ("public_key", "private_key", "identifier", "alt_irk")),
    "public/private key consistency checked": 'privateKeyObject.publicKey.rawRepresentation == publicKey' in swift,
    "atomic import destination": 'rp_pairing_file_imported.plist' in swift and 'replaceItemAt' in swift,
    "PIN documented as absent from an existing record": 'A six-digit PIN is not part of an RPPairing file' in swift,
    "import switches to existing-record mode": 'rpImportedPairingLoaded = true' in swift and 'refreshStoredRPImportState()' in swift,
    "six-digit PIN is for new pairing only": 'if rpImportedPairingLoaded {' in swift and '6-digit pairing PIN (new pairing only)' in swift,
    "existing record uses pair-verify without PIN": 'verifyImportedRPPairingAndSave()' in swift and 'no setup PIN is needed' in swift,
    "pair-verify runs against imported record": 'gasspair_verify_rp_endpoint(h, port, n, f, &result)' in swift,
    "copy only happens after successful pair-verify": 'if rc == 0 {\n                do {' in swift and 'rp_pairing_file_imported_verified.plist' in swift,
    "verified copy read-back is compared": 'guard readBack == sourceData' in swift,
    "new-pair creation still requires six-digit PIN": 'rpEndpointPIN.count == 6' in swift and 'gasspair_create_rp_endpoint' in swift,
    "docs describe no-PIN imported verification": 'Importazione RPPairing senza chiedere il PIN (2.3.2)' in readme,
    "docs warn imported files contain sensitive keys": 'private key' in readme.lower() or 'chiave privata' in readme.lower(),
}
for name, ok in checks.items():
    print(f"{'PASS' if ok else 'FAIL'}: {name}")
if not all(checks.values()):
    raise SystemExit(1)
