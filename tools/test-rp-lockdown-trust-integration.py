#!/usr/bin/env python3
"""Regression checks for the safe Lockdown -> RPPairing transport split."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
rust = (root / "rust/src/lib.rs").read_text()
header = (root / "rust/include/gasspair.h").read_text()
swift = (root / "App/ContentView.swift").read_text()
readme = (root / "README.md").read_text()
companion = (root / "companion/src/main.rs").read_text()
docs = (root / "docs/USBMUXD-TRANSPORT.md").read_text()
start = rust.index("gasspair_create_rp_from_lockdown_endpoint")
end = rust.index("Create a fresh RPPairing record by performing", start)
legacy = rust[start:end]
checks = {
    "legacy raw TCP Lockdown-to-RPPairing path fails closed": "Unsupported transport: cannot create RPPairing through direct TCP" in legacy,
    "legacy path never opens the dynamic service socket directly": "provider.connect(service_port)" not in legacy,
    "iOS UI opens macOS usbmuxd companion": "showingMacUSBMuxdCompanion = true" in swift and "Open macOS usbmuxd companion" in swift,
    "no obsolete iOS raw-TCP pairing job is present": not (root / "App/LockdownRPPairingJob.swift").exists(),
    "companion uses real usbmuxd device enumeration": "UsbmuxdConnection::default().await" in companion and ".get_devices().await" in companion,
    "companion delegates dynamic service connections to the usbmuxd provider": "self.inner.connect(port)" in companion,
    "imported Lockdown record is injected into provider trust": "pairing_file: pair_record" in companion and "get_pairing_file" in companion,
    "companion opens RemotePairingLockdownService through usbmuxd": "RemotePairingLockdownService::connect(&provider)" in companion,
    "new record is created through real RPPairing protocol": "client.connect(&mut pairing_file" in companion,
    "fresh verify-only session runs attemptPairVerify and validatePairing": "client.attempt_pair_verify().await" in companion and "client.validate_pairing(&mut pairing_file).await" in companion,
    "record is returned only after independent pair-verify": (lambda flow: flow.index("client.validate_pairing(&mut pairing_file).await") < flow.index("Ok((bytes, format!"))(companion[companion.index("async fn create_rppairing"):companion.index("async fn verify_rppairing")]),
    "helper pins TLS certificate and uses an access token": "certificate SHA-256 fingerprint" in companion and "constant_time_equal" in companion,
    "iOS client pins the exact SHA-256 leaf certificate": "PinnedCompanionTLSDelegate" in (root / "App/MacUsbmuxdCompanionClient.swift").read_text() and "SecTrustSetAnchorCertificates" in (root / "App/MacUsbmuxdCompanionClient.swift").read_text(),
    "pairing payload is sent over HTTPS": "components.scheme = \"https\"" in (root / "App/MacUsbmuxdCompanionClient.swift").read_text(),
    "no record is saved by iOS until helper reports verified": "guard response.verified" in (root / "App/MacUsbmuxdCompanionView.swift").read_text(),
    "docs explain LocalDevVPN is not usbmuxd": "does not implement usbmuxd" in docs.lower(),
    "README includes Mac companion build steps": "companion/Cargo.toml" in readme and "gasspair-usbmuxd-companion --bind" in readme,
}
failed = False
for label, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'}: {label}")
    failed |= not passed
if failed:
    raise SystemExit(1)
