#!/usr/bin/env python3
"""Static regression checks for RPPairing import + no-PIN verification inside usbmuxd (integrated)."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
main = (root / "App/ContentView.swift").read_text()
view = (root / "App/IntegratedUsbmuxdCompanionView.swift").read_text()
engine = (root / "App/IntegratedUsbmuxdCompanion.swift").read_text()
mux = (root / "rust/src/embedded_mux.rs").read_text()
readme = (root / "README.md").read_text()
verify = mux[mux.index("pub(crate) async fn verify_flow"):mux.index("#[cfg(test)]")]
checks = {
    "old main-screen import card removed": "Import / Validate RP Pairing File" not in main and "showingRPFileImporter" not in main,
    "RPPairing import lives in usbmuxd (integrated)": "Existing RPPairing" in view and ".fileImporter(" in view and "storeImportedRP" in view,
    "required RP fields checked": all(f'plist["{k}"]' in engine for k in ("public_key", "private_key", "identifier", "alt_irk")),
    "public/private key consistency checked": "key.publicKey.rawRepresentation == publicKey" in engine,
    "atomic protected import destination": "rp_pairing_file_imported.plist" in engine and "data.write(to: importedRPURL, options: [.atomic])" in engine,
    "verify uses pair-verify only (no setup, no PIN)": "client.connect(" not in verify and "validate_pairing(&mut record)" in verify,
    "verified copy is byte-compared": "back != bytes" in mux,
    "docs warn imported files contain sensitive keys": "chiave privata" in readme.lower() or "private key" in readme.lower(),
}
for name, ok in checks.items():
    print(f"{'PASS' if ok else 'FAIL'}: {name}")
if not all(checks.values()):
    raise SystemExit(1)
