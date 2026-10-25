# GassPair RPPairing through macOS usbmuxd (2.3.7)

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
