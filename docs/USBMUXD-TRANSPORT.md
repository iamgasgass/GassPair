# GassPair RPPairing through usbmuxd

## 2.4.0 — integrated companion (no Mac)

The usbmuxd companion now runs **inside GassPair** (`rust/src/embedded_mux.rs`, Swift `App/IntegratedUsbmuxdCompanion.swift`). The macOS helper is kept only as an optional fallback.

### Why it can live in the app

`RemotePairingLockdownService::connect(provider)` is generic over `IdeviceProvider`. The provider contributes exactly two things:

1. `connect(port)` — a device socket for `port`. For a device that the Mac's usbmuxd reaches over the network, usbmuxd's `Connect` is a TCP connection from the host to `<device-ip>:<port>`.
2. `get_pairing_file()` — the Lockdown trust (the Mac helper already replaced usbmuxd's record with the imported one).

Everything above that — Lockdown `StartSession` with HostID/SystemBUID, `StartService com.apple.dt.remotepairingdeviced.lockdown`, optional service TLS, the RPPairing exchange — is done by idevice and is identical for every provider. `EmbeddedMuxProvider` implements those two methods in the app, towards the device reached through LocalDevVPN (`10.7.0.1`) or Wi-Fi.

### Automatic flow

1. The Lockdown.plist is imported (the only user action). The companion screen opens and starts by itself.
2. **Device discovery** replaces "list usbmuxd devices + pick UDID": the candidate endpoints (optional user address, `10.7.0.1`, then the device's own `en*` IPv4 addresses) are tried in order; the first one that accepts an authenticated Lockdown session with the imported trust wins. UDID, name, model and iOS version are read from Lockdown, and the UDID must match the record when the record carries one.
3. If no endpoint answers (LocalDevVPN off, other network), the app **retries on its own** with back-off (5 s → 30 s) and immediately when it returns to the foreground.
4. Two passes on `RemotePairingLockdownService` ("Pairing through Lockdown", "Saving the pairing on the device"), then a **third fresh connection** for `attempt_pair_verify` + `validate_pairing` only.
5. Atomic save + read-back in Rust, then complete file protection and an Ed25519 consistency check in Swift. Nothing is written if any step fails; failures after the device was reached are not retried automatically.

Every step (Lockdown connect, StartSession, StartService, device socket, service TLS, each pass, verify) has its own timeout and status message. idevice prints every `io::Error` as "device socket io failed"; the integrated companion appends the Debug form so the real cause (reset, EOF, refused, timeout) is visible.

### Boundaries

- If lockdownd refuses `StartService` for this service on a network route (some iOS builds may offer it on USB only), no network client — the app, or the Mac helper with a wireless device — can open it. The error says so; the only alternative then is the Mac companion with the device on a **USB cable**.
- The imported Lockdown.plist must be a genuine record already trusted by that device.
- End-to-end behaviour must still be confirmed on a real device; the static tests and unit tests do not prove that a given iOS build allows the service on the route used.

---

## Historical notes (2.3.7 macOS helper)


## Why the iOS-only TCP path cannot open this service

`com.apple.dt.remotepairingdeviced.lockdown` is opened by the upstream `idevice_pair` flow through `RemotePairingLockdownService::connect(provider)`, where `provider` is a usbmuxd-backed `UsbmuxdProvider`. This provider uses the Mac's usbmuxd Connect operation to open the device-assigned service port. Reaching TCP/62078 with a raw iOS `TcpProvider` proves only that the Lockdown port is reachable; it does not implement usbmuxd device/socket multiplexing. The iOS app therefore must not open the dynamic service port directly.

## Architecture in this release

This repository now includes a macOS executable in `companion/`. GassPair on iOS connects to the helper through HTTPS on a specific LocalDevVPN/LAN address. The helper uses the real Mac-local usbmuxd provider, while the imported `Lockdown.plist` is injected as the provider's `get_pairing_file()` result. The helper verifies that this credential can establish a TLS Lockdown session for the selected UDID, then opens `RemotePairingLockdownService` through usbmuxd.

The helper creates a fresh `RpPairingFile`, follows the upstream `idevice_pair::remote_file()` two-pass sequence (“Pairing through Lockdown”, then “Saving the pairing on the device”), opens a third fresh usbmuxd-backed service connection, and runs `attempt_pair_verify()` followed by `validate_pairing()` without falling back to another setup attempt. The RPPairing bytes are returned only after this verification and a local parse/read-back check. The iOS app independently checks the plist, atomically saves it with complete file protection, and compares read-back bytes before advertising success.

## Secure helper-to-phone channel

- TLS is mandatory. The helper creates a self-signed ECDSA certificate with a SAN for the exact bind IP and prints the SHA-256 fingerprint of the DER certificate.
- The iOS app pins that fingerprint and verifies the host/IP certificate identity. It rejects a mismatch.
- The helper requires a random access token (stored at mode `0600` inside the macOS Application Support directory). The token is not logged after its initial generation.
- The imported Lockdown plist and returned RPPairing plist travel only inside the pinned TLS connection. HTTP caching is disabled and the helper never logs request bodies or key material.
- The helper binds only to a specific private/ULA/link-local interface address; wildcard and loopback addresses are rejected. The access token should still be treated as a secret.
- Requests are size-limited, authenticated, and served with a bounded connection concurrency and timeout. Supported actions are `list_devices`, `create_rppairing`, and `verify_rppairing`.

## Build and run

On the Mac that already sees the target iPhone in usbmuxd over Wi-Fi (no USB cable is required if the wireless usbmuxd connection is already established):

```sh
cd GassPair
cargo build --release --manifest-path companion/Cargo.toml
./companion/target/release/gasspair-usbmuxd-companion --bind <MAC-IP-REACHABLE-FROM-IPHONE>:47821
```

On first run the helper creates a certificate/private key and prints the certificate SHA-256 fingerprint and a new access token. Keep the token file and private key private. On later starts, retrieve the same token from `~/Library/Application Support/GassPairCompanion/access-token.txt`. If rotating the token, stop the helper, remove that file, and restart. If rotating TLS identity, remove the corresponding `server-*.cert.der` and `server-*.key.der`, restart, and update the iPhone pin.

The bind IP must be an actual Mac interface address that the iPhone can reach; `10.7.0.1` in the earlier diagnostics was the iPhone's destination address, not necessarily the Mac address. Confirm the Mac is running/connected to the network route and allow the dedicated port in the macOS firewall if asked.

In GassPair, open **macOS usbmuxd companion**, enter Mac IP, port, SHA-256 fingerprint and token, then list usbmuxd devices. Select the exact UDID, import the trusted `Lockdown.plist`, and choose **Create + pair-verify + save via usbmuxd**. To verify an existing RPPairing file, import it and choose the verify-only action.

## Boundaries and failure behavior

- This helper requires the iPhone/iPad to be visible to the Mac's usbmuxd (including wireless device discovery) and a valid Lockdown pairing file that successfully starts TLS for that exact UDID.
- LocalDevVPN routes network packets but does not implement usbmuxd. The Mac helper is the usbmuxd component; the app will not claim a self-contained iOS-only route.
- The helper never writes a synthetic RPPairing record and never returns a record if setup, fresh pair-verify, validation, or read-back parsing fails.
- The imported Lockdown plist's private key is handled in memory by the helper and is not persisted by this project. The generated RPPairing private key returns to the iPhone only within the pinned TLS channel.
- End-to-end behavior still needs a real Mac + wireless-usbmuxd iPhone test; source-level tests do not prove the environment has the target visible or the pairing policy allows RPPairing.
