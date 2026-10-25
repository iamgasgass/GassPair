#!/usr/bin/env python3
"""Static regression checks for creating RPPairing from an imported Lockdown trust record."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
rust = (root / "rust/src/lib.rs").read_text()
header = (root / "rust/include/gasspair.h").read_text()
swift = (root / "App/ContentView.swift").read_text()
cargo = (root / "rust/Cargo.toml").read_text()
checks = {
    "TCP provider feature enabled": '"tcp"' in cargo,
    "FFI exported for Lockdown-trust RP creation": "gasspair_create_rp_from_lockdown_endpoint" in rust and "gasspair_create_rp_from_lockdown_endpoint" in header,
    "imports standard Lockdown PairingFile": "PairingFile::from_bytes(&bytes)" in rust,
    "uses authenticated RemotePairingLockdownService": "RemotePairingLockdownService::connect(&provider)" in rust,
    "does not use classic Request=Pair for this operation": 'lockdown.pair(' not in rust[rust.index("gasspair_create_rp_from_lockdown_endpoint"):rust.index("Create a fresh RPPairing record by performing")],
    "strict pair-verify after creation": "verifier.attempt_pair_verify()" in rust and "verifier.validate_pairing(&mut file)" in rust,
    "saves only after verification": rust.index("verifier.validate_pairing(&mut file)") < rust.index("save_pairing_file(&file, &out_path).await?", rust.index("gasspair_create_rp_from_lockdown_endpoint")),
    "Swift importer and action wired": "importLockdownPairingFile(result)" in swift and "createRPPairingFromLockdownTrust()" in swift,
    "Lockdown endpoint port 62078": "gasspair_create_rp_from_lockdown_endpoint(h, 62078" in swift,
}
failed = False
for name, ok in checks.items():
    print(f"{'PASS' if ok else 'FAIL'}: {name}")
    failed |= not ok
raise SystemExit(1 if failed else 0)
