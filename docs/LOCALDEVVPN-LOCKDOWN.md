

## Version 2.3.5 — service socket transport diagnostics

The imported Lockdown path no longer relies on a single opaque `RemotePairingLockdownService::connect` result. It explicitly reports Lockdown connection, authentication `StartSession`, `StartService` for `com.apple.dt.remotepairingdeviced.lockdown`, the device-assigned dynamic port, a direct TCP connection to that port, service TLS, and RPPairing protocol I/O. A `device socket io failed` error is annotated with transport context. This helps distinguish a Lockdown-success/service-transport failure from an RPPairing protocol failure.

The upstream implementation of `idevice_pair` restricts this operation to `Link::Usbmuxd`; that includes Mac-side Wi-Fi device discovery/transport mediated by usbmuxd. The iOS app's `TcpProvider` is not usbmuxd. LocalDevVPN alone cannot guarantee the private remote-pairing service can be reached over raw TCP. If the target rejects or closes the dynamic service socket, GassPair reports the stage and saves no file; it does not fabricate an RPPairing record.
