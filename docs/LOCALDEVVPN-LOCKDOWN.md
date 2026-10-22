# LocalDevVPN / Lockdown self-pairing status

GassPair currently implements Remote Pairing (RPPairing), not the classic Lockdown pairing record flow. The `Test LocalDevVPN → Lockdown` screen is deliberately diagnostic only.

## What the probe verifies

- A TCP connection can be opened to the user-entered destination on port `62078`.
- The peer replies to the Lockdown plist `QueryType` request with `com.apple.mobile.lockdown`.
- The peer answers `GetValue(ProductVersion)`.

It sends no `Pair` or `CUPairingCreate` request and writes no pairing record.

The timeout diagnostic distinguishes these cases:

- **TCP never reached ready:** address, route, tunnel configuration, or port reachability issue; no request was confirmed sent.
- **TCP ready, zero reply bytes:** the socket handshake succeeded, but `QueryType` received no response. This is different from a failed route and points toward the destination endpoint, packet path, or a silently ignored request.
- **Partial response bytes:** the peer sent something, but it did not complete a valid length-prefixed plist frame before the deadline.

The 12-second timeout covers the entire probe, so an unusually slow TCP handshake can leave less time for the protocol round-trip. The diagnostic is evidence about transport only, not proof of pairing support.

## Why this is not yet a classic pairing implementation

The `idevicepair -w` code path invokes Companion User (CU) pairing and the PIN/SRP exchange. Public libimobiledevice documentation says that CU pairing is currently supported by Apple TV devices; its `lockdownd_cu_pairing_create` API is documented with the same limitation. iOS/iPadOS self-initiated development pairing uses the separate Remote Pairing (RPPairing) flow on supported versions.

References:

- https://github.com/libimobiledevice/libimobiledevice/blob/master/docs/idevicepair.1
- https://libimobiledevice.org/docs/libimobiledevice/1.4.0/lockdown_8h_a624871ea957a778920ecffe2d75d964f.html
- https://github.com/jkcoxson/LocalDevVPN

A successful probe is necessary evidence for the routing hypothesis, but not sufficient evidence that iOS 26.1 will accept a classic self-pair request. Before implementing and shipping a pairing writer, the next proof would need to establish that the target iPhone exposes a supported pairing operation over that connection and returns a valid classic pair record. Until then, no fake or speculative record is written.
