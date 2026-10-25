#!/usr/bin/env python3
"""Static regression tests for real remote RPPairing endpoint operations."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
rust = (root / "rust/src/lib.rs").read_text()
header = (root / "rust/include/gasspair.h").read_text()
swift = (root / "App/ContentView.swift").read_text()
readme = (root / "README.md").read_text()
checks = {
    "FFI create endpoint": "gasspair_create_rp_endpoint" in rust and "gasspair_create_rp_endpoint" in header,
    "FFI verify endpoint": "gasspair_verify_rp_endpoint" in rust and "gasspair_verify_rp_endpoint" in header,
    "actual pair-verify handshake": "attempt_pair_verify().await" in rust,
    "actual pairing validation": "validate_pairing(&mut file).await" in rust,
    "create verifies before saving": rust.index("validate_pairing(&mut file).await", rust.index("gasspair_create_rp_endpoint")) < rust.index("save_pairing_file(&file, &path).await", rust.index("gasspair_create_rp_endpoint")),
    "remote endpoint UI": "Remote RPPairing endpoint" in swift and "Create + pair-verify + save" in swift,
    "Lockdown port explicitly disclaimed": "62078" in readme and "endpoint RPPairing" in readme,
    "import verification uses real endpoint": "gasspair_verify_rp_endpoint" in swift,
}
for label, passed in checks.items(): print(f"{'PASS' if passed else 'FAIL'}: {label}")
if not all(checks.values()): raise SystemExit(1)
