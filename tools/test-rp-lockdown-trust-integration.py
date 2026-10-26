#!/usr/bin/env python3
"""Regression checks for Lockdown trust -> RPPairing via the integrated usbmuxd companion."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
rust = (root / "rust/src/lib.rs").read_text()
mux = (root / "rust/src/embedded_mux.rs").read_text()
header = (root / "rust/include/gasspair.h").read_text()
swift = (root / "App/ContentView.swift").read_text()
engine = (root / "App/IntegratedUsbmuxdCompanion.swift").read_text()
view = (root / "App/IntegratedUsbmuxdCompanionView.swift").read_text()
readme = (root / "README.md").read_text()
companion = (root / "companion/src/main.rs").read_text()
docs = (root / "docs/USBMUXD-TRANSPORT.md").read_text()

create = mux[mux.index("pub(crate) async fn create_flow"):mux.index("pub(crate) async fn verify_flow")]
checks = {
    # Rust engine
    "integrated module is compiled into the FFI": "mod embedded_mux;" in rust,
    "provider implements usbmuxd Connect in-app": "impl IdeviceProvider for EmbeddedMuxProvider" in mux and "TcpStream::connect(target)" in mux,
    "provider returns the imported Lockdown trust": "fn get_pairing_file" in mux and "self.pairing_file.clone()" in mux,
    "device is discovered automatically over candidate endpoints": "pub(crate) async fn attach" in mux and "UniqueDeviceID" in mux,
    "LocalDevVPN is the default endpoint": "Ipv4Addr::new(10, 7, 0, 1)" in mux,
    "record UDID must match the device": "is not the one in the imported Lockdown record" in mux,
    "service is RemotePairingLockdownService via StartService": "RemotePairingLockdownService::service_name()" in mux and "start_service(" in mux,
    "service TLS honoured when requested": "idevice.start_session(&provider.pairing_file, legacy)" in mux,
    "two-pass upstream sequence": all(s in create for s in ("Pairing through Lockdown", "Saving the pairing on the device")),
    "independent verify on a third connection": "Independent pair-verify" in create and "verifier\n            .attempt_pair_verify()" in create,
    "save happens only after verification": create.index("validate_pairing(&mut pairing_file)") < create.index("save_pairing_file(&pairing_file, &out_path)"),
    "real io::Error is surfaced": "format!(\"{e:?}\")" in mux,
    # FFI surface
    "FFI create exported": "gasspair_mux_create_rppairing" in rust and "gasspair_mux_create_rppairing" in header,
    "FFI verify exported": "gasspair_mux_verify_rppairing" in rust and "gasspair_mux_verify_rppairing" in header,
    "FFI probe exported": "gasspair_mux_probe" in rust and "gasspair_mux_probe" in header,
    "result carries endpoint and iOS version": "char *endpoint;" in header and "char *os_version;" in header and "(*r).endpoint" in rust,
    "legacy entry point delegates to integrated engine": "gasspair_mux_create_rppairing(session, host" in rust,
    # Swift
    "main screen opens the integrated companion": "showingIntegratedCompanion = true" in swift and "Open usbmuxd (integrated)" in swift,
    "Lockdown import starts the companion automatically": "IntegratedUsbmuxdCompanion.shared.lockdownImported()" in swift,
    "no manual host/fingerprint/token/UDID fields in integrated view": not any(k in view for k in ("SecureField", "fingerprint", "Device UDID\"")),
    "automatic retry while the route is down": "scheduleRetry" in engine and "waitingForRoute" in engine,
    "retries when the app returns to foreground": "IntegratedUsbmuxdCompanion.shared.appBecameActive()" in (root / "App/GassPairApp.swift").read_text(),
    "output is protected and re-validated": "FileProtectionType.complete" in engine and "RPPairingFileCheck.validate" in engine,
    "no obsolete iOS raw-TCP pairing job is present": not (root / "App/LockdownRPPairingJob.swift").exists(),
    # Optional Mac fallback still intact
    "Mac companion kept as optional fallback": "Optional fallback" in view and "self.inner.connect(port)" in companion,
    "docs describe the integrated companion": "integrated" in docs.lower() and "10.7.0.1" in docs,
    "integrated screen is fully glass (no Form)": "Form {" not in view and "glassCard(" in view and "GlassSection(" in view,
    "Mac fallback screen is glass too": "Form {" not in (root / "App/MacUsbmuxdCompanionView.swift").read_text(),
    "README documents 2.4.0": "2.4.0" in readme and "Companion usbmuxd integrato" in readme,
}
failed = False
for label, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'}: {label}")
    failed |= not passed
if failed:
    raise SystemExit(1)
