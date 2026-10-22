# LocalDevVPN / Lockdown self-pairing status

GassPair implements Remote Pairing (RPPairing). The LocalDevVPN screen is a layered transport/protocol diagnostic; it is not yet a classic Lockdown pairing client.

## Input normalization

The destination field accepts an IPv4/IPv6 host or hostname. It can normalize a full-width host CIDR such as `10.7.0.1/32` to `10.7.0.1`, or `[::1]/128` to `::1`. It deliberately rejects subnet prefixes such as `10.7.0.0/24`: a subnet is not a socket destination and the app must not guess which host the user intended. URLs, paths, and inline ports are rejected because the test always targets TCP/62078.

## Two independent tests

- **TCP only** waits for `NWConnection.State.ready` without sending application data. Its timeout means the TCP handshake did not complete; no Lockdown request was sent.
- **TCP + Lockdown** sends the length-prefixed plist `QueryType`, validates `Type = com.apple.mobile.lockdown`, then requests `GetValue(ProductVersion)` and verifies a nonempty `Value`. Errors, truncated frames, invalid plists, peer close, and timeouts are reported separately.

The diagnostic records network state transitions and byte counts in a shareable report. Request/response framing is bounded to 2 MiB. It never sends `Pair` or `CUPairingCreate`, does not request trust, and does not write pairing data.

## LocalDevVPN routing notes

Use the LocalDevVPN **Device/Peer IP** that its configuration routes, not the tunnel/interface IP. CIDR notation describes a route prefix, not part of an address passed to `NWConnection`. On LocalDevVPN versions/configurations where the peer host is `10.7.0.1`, the socket destination should be `10.7.0.1:62078`, not `10.7.0.1/32:62078`.

LocalDevVPN has a public issue describing the peer route as unreachable when the tunnel starts on cellular-only; its maintainer says cellular-only operation is a known Apple-imposed limitation. This means an active Wi-Fi association can matter; merely enabling Wi-Fi may not be sufficient. See https://github.com/jkcoxson/LocalDevVPN/issues/31. GassPair cannot inspect or reconfigure LocalDevVPN's packet tunnel from another app.

## Why this does not claim classic iOS self-pairing

The public `idevicepair` manual documents its `-w` CU/SRP flow as Apple TV-only, and the public `lockdownd_cu_pairing_create` API has the same limitation. The `idevice_pair` project also documents that, for iPhone/iPad over Wi-Fi, its wireless onboarding creates an RPPairing record and that a classic Lockdown pairing file requires the usbmuxd path. A successful TCP and plist round trip is not evidence that iOS 26.1 accepts a classic self-pair request. An actual pairing implementation requires a device-observed successful Lockdown pairing transaction and a validated record schema; this project does not fabricate a record when that proof is absent.

References:

- https://github.com/libimobiledevice/libimobiledevice/blob/master/docs/idevicepair.1
- https://github.com/libimobiledevice/libimobiledevice/blob/master/include/libimobiledevice/lockdown.h
- https://github.com/jkcoxson/LocalDevVPN/issues/31
- https://github.com/jkcoxson/idevice_pair#over-wi-fi-with-iphone-or-ipad
