#!/usr/bin/env python3
"""Static protocol/security contract tests for the macOS usbmuxd companion."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
server = (root / "companion/src/main.rs").read_text()
client = (root / "App/MacUsbmuxdCompanionClient.swift").read_text()
view = (root / "App/MacUsbmuxdCompanionView.swift").read_text()
workflow = (root / ".github/workflows/build.yml").read_text()
checks = {
    "helper only binds explicit private/local IPs": "Refusing to bind" in server and "is_safe_bind_ip" in server,
    "TLS certificate has IP SAN": "SanType::IpAddress(ip)" in server,
    "TLS identity fingerprint is SHA-256": "sha256_hex(&cert_der)" in server and "Sha256::digest" in server,
    "random token is persisted with private permissions": "access-token.txt" in server and "from_mode(0o600)" in server,
    "request token is compared without early byte mismatch exit": "constant_time_equal" in server,
    "HTTP request/body are bounded": "MAX_HEADER_BYTES" in server and "MAX_BODY_BYTES" in server,
    "server restricts route and method": 'method != "POST" || path != API_PATH' in server,
    "companion supports only allow-listed actions": all(f'"{action}"' in server for action in ("list_devices", "create_rppairing", "verify_rppairing")),
    "device identity is compared after authenticated Lockdown": "UniqueDeviceID" in server and "does not match the selected target device" in server,
    "RPPairing setup occurs via usbmuxd provider": "RemotePairingLockdownService::connect(&provider)" in server and "UsbmuxdProvider" in server,
    "new record follows upstream two-pass RPPairing flow": "for stage in [" in server and all(stage in server for stage in ("Pairing through Lockdown", "Saving the pairing on the device")) and "RPPairing setup/save sequence exceeded 240 seconds" in server,
    "verify-only path doesn't call setup": "async fn verify_rppairing" in server and "attempt_pair_verify().await" in server and "validate_pairing(&mut pairing_file).await" in server,
    "output private key never gets logged": "Pairing files and request bodies are never logged." in server,
    "iOS client uses ephemeral URLSession": "URLSessionConfiguration.ephemeral" in client,
    "iOS rejects certificate pin mismatch": "tlsPinMismatch" in client and "cancelAuthenticationChallenge" in client,
    "iOS stores successful output with complete protection": "FileProtectionType.complete" in view and "guard readBack == data" in view,
    "CI builds macOS companion": "cargo build --release --manifest-path companion/Cargo.toml" in workflow,
}
failed=False
for label, ok in checks.items():
    print(f"{'PASS' if ok else 'FAIL'}: {label}")
    failed |= not ok
if failed: raise SystemExit(1)
