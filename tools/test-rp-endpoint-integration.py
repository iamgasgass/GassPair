#!/usr/bin/env python3
"""Static regression tests for real remote RPPairing endpoint operations."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
rust = (root / "rust/src/lib.rs").read_text()
header = (root / "rust/include/gasspair.h").read_text()
swift = (root / "App/ContentView.swift").read_text()
view = (root / "App/IntegratedUsbmuxdCompanionView.swift").read_text()
readme = (root / "README.md").read_text()
checks = {
    "Swift imports generated C FFI module in the integrated engine": "import GassPairFFI" in (root / "App/IntegratedUsbmuxdCompanion.swift").read_text(),
    "Rust FFI result struct is exported in C header": "} GassPairResult;" in header,
    "Rust FFI result free function is exported in C header": "gasspair_result_free(GassPairResult *r)" in header,
    "FFI create endpoint": "gasspair_create_rp_endpoint" in rust and "gasspair_create_rp_endpoint" in header,
    "FFI verify endpoint": "gasspair_verify_rp_endpoint" in rust and "gasspair_verify_rp_endpoint" in header,
    "actual pair-verify handshake": "attempt_pair_verify().await" in rust,
    "actual pairing validation": "validate_pairing(&mut file).await" in rust,
    "create verifies before saving": rust.index("validate_pairing(&mut file).await", rust.index("gasspair_create_rp_endpoint")) < rust.index("save_pairing_file(&file, &path).await", rust.index("gasspair_create_rp_endpoint")),
    "manual remote endpoint card removed from the app": "Remote RPPairing endpoint" not in swift and "gasspair_create_rp_endpoint" not in swift,
    "imported record uses no-PIN pair-verify flow in usbmuxd (integrated)": "companion.start(.verifyImported)" in view,
    "Lockdown port explicitly disclaimed": "62078" in readme and "endpoint RPPairing" in readme,
    "import verification runs on the live device": "gasspair_mux_verify_rppairing" in (root / "App/IntegratedUsbmuxdCompanion.swift").read_text(),
}
for label, passed in checks.items(): print(f"{'PASS' if passed else 'FAIL'}: {label}")
if not all(checks.values()): raise SystemExit(1)
