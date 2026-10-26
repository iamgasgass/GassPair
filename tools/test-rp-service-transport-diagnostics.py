#!/usr/bin/env python3
"""Static checks for the integrated companion's stage diagnostics and fail-closed behaviour."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
mux = (root / "rust/src/embedded_mux.rs").read_text()
engine = (root / "App/IntegratedUsbmuxdCompanion.swift").read_text()
open_service = mux[mux.index("async fn open_service"):mux.index("async fn write_verified_copy")]
verify = mux[mux.index("pub(crate) async fn verify_flow"):mux.index("#[cfg(test)]")]
checks = {
    "each service-open step is reported": all(s in open_service for s in ("StartSession", "StartService", "opening device socket", "service TLS")),
    "each step has its own timeout": open_service.count("MUX_STEP_TIMEOUT") >= 4,
    "USB-only refusal is explained honestly": "only offers this service on the USB transport" in open_service,
    "verify-only path never runs setup": "client.connect(" not in verify and "attempt_pair_verify()" in verify,
    "verified copy is read back and compared": "back != bytes" in mux,
    "missing alt_irk blocks saving": "alt_irk) is missing; nothing was saved" in mux,
    "status codes forwarded to Swift": all(c in engine for c in ("GASSPAIR_STATUS_MUX_PROBING", "GASSPAIR_STATUS_MUX_ATTACHED", "GASSPAIR_STATUS_MUX_ENDPOINT_FAILED")),
    "callback copies the C string synchronously": "String(cString: $0)" in engine,
    "runs are cancellable": "gasspair_session_cancel(session)" in engine,
    "failures after attach do not loop automatically": "phase = .failed(message: message)" in engine,
}
failed = False
for label, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'}: {label}")
    failed |= not passed
if failed:
    raise SystemExit(1)
