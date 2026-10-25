#!/usr/bin/env python3
"""Static regression checks for usbmuxd transport boundary and fail-closed behavior."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
rust = (root / "rust/src/lib.rs").read_text()
readme = (root / "README.md").read_text()
docs = (root / "docs/USBMUXD-TRANSPORT.md").read_text()
start = rust.index("gasspair_create_rp_from_lockdown_endpoint")
end = rust.index("Create a fresh RPPairing record by performing", start)
flow = rust[start:end]
checks = {
    "Lockdown creation explicitly refuses unsupported direct TCP": "Unsupported transport: cannot create RPPairing through direct TCP" in flow,
    "does not open dynamic service port over TcpProvider": "provider.connect(service_port)" not in flow,
    "does not attempt RPPairing exchange in unsupported path": "client.connect(&mut file" not in flow,
    "does not save any record on unsupported path": "save_pairing_file" not in flow,
    "failure callback gives actionable diagnostic": "report_rp_progress(status_cb, ctx, GASSPAIR_STATUS_RP_FAILED, &message)" in flow,
    "docs explain distinction between Lockdown and service socket": "TCP/62078" in docs and "dynamic service port" in docs,
    "docs require a usbmuxd-backed macOS companion": "macOS executable" in docs and "usbmuxd-backed" in docs,
    "README states LocalDevVPN does not implement usbmuxd": "LocalDevVPN routes IP packets and does not itself implement usbmuxd" in readme,
}
failed = False
for label, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'}: {label}")
    failed |= not passed
if failed:
    raise SystemExit(1)
