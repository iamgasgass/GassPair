//! Integrated (in-app) usbmuxd companion.
//!
//! The macOS companion opened `com.apple.dt.remotepairingdeviced.lockdown`
//! through `UsbmuxdProvider`. For a device that usbmuxd reaches over the
//! network, usbmuxd's `Connect` operation is nothing more than a TCP connection
//! from the host to `<device-ip>:<port>`; the Lockdown session that sits on top
//! of it (StartSession with HostID/SystemBUID, StartService, optional service
//! TLS) is performed by idevice itself, identically for every provider.
//!
//! [`EmbeddedMuxProvider`] reproduces that `Connect` step inside the app,
//! towards the device reached through LocalDevVPN (`10.7.0.1` by default) or
//! any other candidate address handed in by Swift. On top of it this module runs
//! exactly the sequence the macOS companion ran, fully automatically:
//!
//! 1. load the imported `Lockdown.plist` and probe each candidate endpoint until
//!    one accepts an authenticated Lockdown session (this also discovers the
//!    device UDID / name / iOS version, so the user never selects anything);
//! 2. open `RemotePairingLockdownService` and run the upstream two-pass
//!    sequence ("Pairing through Lockdown", "Saving the pairing on the device");
//! 3. open a third, fresh service connection and run `attempt_pair_verify` +
//!    `validate_pairing` — never falling back to setup;
//! 4. only then write the record atomically and read it back.
//!
//! No synthetic record is ever produced: every failure stops the flow and is
//! reported with the stage and the underlying I/O error (idevice's
//! `device socket io failed` hides the `io::Error`; we surface its Debug form).

use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::pin::Pin;
use std::time::Duration;

use idevice::lockdown::LockdownClient;
use idevice::pairing_file::PairingFile;
use idevice::provider::IdeviceProvider;
use idevice::remote_pairing::{PeerDevice, RemotePairingLockdownService, RpPairingFile};
use idevice::{Idevice, IdeviceError, IdeviceService};
use tokio::net::TcpStream;

use crate::{
    fresh_pairing_file, hex, save_pairing_file, Callbacks, Fail, Paired, GASSPAIR_STATUS_RP_COMPLETE,
    GASSPAIR_STATUS_RP_CONFIRMING, GASSPAIR_STATUS_RP_LOCKDOWN_SESSION, GASSPAIR_STATUS_RP_PAIRING,
    GASSPAIR_STATUS_RP_SAVING, GASSPAIR_STATUS_RP_SERVICE_OPEN, GASSPAIR_STATUS_RP_TRUST_LOADING,
    GASSPAIR_STATUS_RP_VERIFYING,
};

/// Integrated companion: probing the candidate endpoint in `message`.
pub const GASSPAIR_STATUS_MUX_PROBING: i32 = 60;
/// Integrated companion: device attached. `message` = `udid\nname\nproductType\niOS\nendpoint`.
pub const GASSPAIR_STATUS_MUX_ATTACHED: i32 = 61;
/// Integrated companion: a candidate endpoint was skipped (reason in `message`).
pub const GASSPAIR_STATUS_MUX_ENDPOINT_FAILED: i32 = 62;

/// Default LocalDevVPN / StikDebug loopback address of the device itself.
pub const DEFAULT_MUX_ENDPOINT: IpAddr = IpAddr::V4(Ipv4Addr::new(10, 7, 0, 1));

const MUX_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const MUX_PROBE_TIMEOUT: Duration = Duration::from_secs(15);
const MUX_STEP_TIMEOUT: Duration = Duration::from_secs(15);
const MUX_PAIR_PASS_TIMEOUT: Duration = Duration::from_secs(120);
const MUX_VERIFY_TIMEOUT: Duration = Duration::from_secs(30);
/// Over an already-trusted Lockdown channel no consent PIN is shown; this is the
/// value upstream `idevice-tools remotepairing-lockdown pair` uses as well.
const LOCKDOWN_CHANNEL_PIN: &str = "000000";

// ---------------------------------------------------------------------------
// Provider: the in-app equivalent of usbmuxd `Connect`
// ---------------------------------------------------------------------------

/// Same contract as idevice's `UsbmuxdProvider` with an imported pair record:
/// `connect(port)` opens a device socket for `port`; `get_pairing_file()`
/// returns the imported Lockdown trust instead of asking usbmuxd for it.
#[derive(Debug, Clone)]
pub(crate) struct EmbeddedMuxProvider {
    addr: IpAddr,
    pairing_file: PairingFile,
    label: String,
}

impl IdeviceProvider for EmbeddedMuxProvider {
    fn connect(
        &self,
        port: u16,
    ) -> Pin<Box<dyn Future<Output = Result<Idevice, IdeviceError>> + Send>> {
        let target = SocketAddr::new(self.addr, port);
        let label = self.label.clone();
        Box::pin(async move {
            let stream = tokio::time::timeout(MUX_CONNECT_TIMEOUT, TcpStream::connect(target))
                .await
                .map_err(|_| IdeviceError::Timeout)??;
            // usbmuxd device sockets behave like an unbuffered pipe; Nagle only
            // adds latency to the small plist frames RPPairing exchanges.
            let _ = stream.set_nodelay(true);
            Ok(Idevice::new(Box::new(stream), label))
        })
    }

    fn label(&self) -> &str {
        &self.label
    }

    fn get_pairing_file(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<PairingFile, IdeviceError>> + Send>> {
        let pairing_file = self.pairing_file.clone();
        Box::pin(async move { Ok(pairing_file) })
    }
}

/// Device discovered on a candidate endpoint with the imported trust.
pub(crate) struct Attached {
    provider: EmbeddedMuxProvider,
    udid: String,
    name: String,
    product_type: String,
    version: String,
}

/// Result of an integrated-companion operation.
pub(crate) struct MuxOutcome {
    pub udid: String,
    pub name: String,
    pub product_type: String,
    pub version: String,
    pub endpoint: String,
    pub path: String,
    pub alt_irk_hex: String,
    pub verified: bool,
}

impl MuxOutcome {
    fn from_attached(attached: &Attached, path: String, alt_irk_hex: String, verified: bool) -> Self {
        Self {
            udid: attached.udid.clone(),
            name: attached.name.clone(),
            product_type: attached.product_type.clone(),
            version: attached.version.clone(),
            endpoint: attached.provider.addr.to_string(),
            path,
            alt_irk_hex,
            verified,
        }
    }

    pub(crate) fn into_paired(self) -> (Paired, String, String) {
        (
            Paired {
                name: self.name,
                model: self.product_type,
                udid: self.udid,
                path: self.path,
                host_alt_irk_hex: self.alt_irk_hex,
                verified: self.verified,
            },
            self.endpoint,
            self.version,
        )
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// `IdeviceError`'s Display collapses every `io::Error` into "device socket io
/// failed". Add the Debug form so the real cause (reset, EOF, refused, …) shows.
pub(crate) fn describe(e: &IdeviceError) -> String {
    let display = e.to_string();
    let debug = format!("{e:?}");
    if debug == display {
        display
    } else {
        format!("{display} [{debug}]")
    }
}

/// Parses a newline/comma separated list of candidate device addresses.
/// Always ends up with at least the LocalDevVPN default.
pub(crate) fn parse_endpoints(raw: &str) -> Vec<IpAddr> {
    let mut out: Vec<IpAddr> = Vec::new();
    for item in raw.split(|c: char| c == '\n' || c == ',' || c == ';') {
        let candidate = item.trim();
        if candidate.is_empty() {
            continue;
        }
        // Accept "ip:port" / "[v6]:port" too and ignore the port (Lockdown is
        // always 62078), as well as a bracketed bare IPv6 address.
        let parsed = candidate
            .parse::<SocketAddr>()
            .map(|s| s.ip())
            .ok()
            .or_else(|| candidate.trim_start_matches('[').trim_end_matches(']').parse::<IpAddr>().ok());
        if let Some(ip) = parsed {
            if !ip.is_unspecified() && !ip.is_multicast() && !out.contains(&ip) {
                out.push(ip);
            }
        }
    }
    if out.is_empty() {
        out.push(DEFAULT_MUX_ENDPOINT);
    }
    out
}

async fn load_lockdown_trust(path: &str, cbs: &Callbacks) -> Result<PairingFile, Fail> {
    cbs.status(GASSPAIR_STATUS_RP_TRUST_LOADING, "Loading the imported Lockdown trust record…");
    let bytes = tokio::fs::read(path)
        .await
        .map_err(|e| Fail::Error(format!("Could not read the imported Lockdown.plist: {e}")))?;
    if bytes.len() > 2 * 1024 * 1024 {
        return Err(Fail::Error("The imported Lockdown.plist exceeds 2 MiB.".into()));
    }
    PairingFile::from_bytes(&bytes).map_err(|e| {
        Fail::Error(format!(
            "The imported Lockdown.plist is invalid or misses certificates/keys: {}",
            describe(&e)
        ))
    })
}

async fn lockdown_string(lockdown: &mut LockdownClient, key: &str) -> Option<String> {
    lockdown
        .get_value(Some(key), None)
        .await
        .ok()
        .and_then(|v| v.as_string().map(str::to_owned))
}

async fn probe_endpoint(provider: &EmbeddedMuxProvider) -> Result<(String, String, String, String), String> {
    let mut lockdown = LockdownClient::connect(provider)
        .await
        .map_err(|e| format!("Lockdown TCP/62078 not reachable ({})", describe(&e)))?;
    lockdown
        .start_session(&provider.pairing_file)
        .await
        .map_err(|e| format!("the imported Lockdown trust was rejected by StartSession ({})", describe(&e)))?;
    let udid = lockdown_string(&mut lockdown, "UniqueDeviceID")
        .await
        .ok_or_else(|| "the authenticated Lockdown session did not return UniqueDeviceID".to_string())?;
    let name = lockdown_string(&mut lockdown, "DeviceName").await.unwrap_or_default();
    let product_type = lockdown_string(&mut lockdown, "ProductType").await.unwrap_or_default();
    let version = lockdown_string(&mut lockdown, "ProductVersion")
        .await
        .unwrap_or_else(|| "unknown".into());
    Ok((udid, name, product_type, version))
}

/// Automatic replacement for "list usbmuxd devices + pick a UDID": the first
/// endpoint that accepts an authenticated Lockdown session with the imported
/// trust wins, and its identity is checked against the record.
pub(crate) async fn attach(
    endpoints: &[IpAddr],
    pairing_file: &PairingFile,
    label: &str,
    cbs: &Callbacks,
) -> Result<Attached, Fail> {
    let mut failures = Vec::new();
    for ip in endpoints {
        cbs.status(GASSPAIR_STATUS_MUX_PROBING, &ip.to_string());
        let provider = EmbeddedMuxProvider {
            addr: *ip,
            pairing_file: pairing_file.clone(),
            label: label.to_string(),
        };
        let probed = tokio::time::timeout(MUX_PROBE_TIMEOUT, probe_endpoint(&provider)).await;
        let reason = match probed {
            Ok(Ok((udid, name, product_type, version))) => {
                let record_matches = pairing_file
                    .udid
                    .as_deref()
                    .map_or(true, |record| record.eq_ignore_ascii_case(&udid));
                if record_matches {
                    cbs.status(
                        GASSPAIR_STATUS_MUX_ATTACHED,
                        &format!("{udid}\n{name}\n{product_type}\n{version}\n{ip}"),
                    );
                    return Ok(Attached { provider, udid, name, product_type, version });
                }
                format!("the device answering here ({udid}) is not the one in the imported Lockdown record")
            }
            Ok(Err(reason)) => reason,
            Err(_) => format!("no answer within {} s", MUX_PROBE_TIMEOUT.as_secs()),
        };
        cbs.status(GASSPAIR_STATUS_MUX_ENDPOINT_FAILED, &format!("{ip}: {reason}"));
        failures.push(format!("{ip}: {reason}"));
    }
    Err(Fail::Error(format!(
        "No device accepted the imported Lockdown trust. Make sure LocalDevVPN is connected (or the device is reachable on the same network) and that the Lockdown.plist belongs to this device. Tried — {}",
        failures.join(" · ")
    )))
}

/// Exactly what `IdeviceService::connect` does for `RemotePairingLockdownService`,
/// split into steps so the UI can show which boundary fails.
async fn open_service(
    provider: &EmbeddedMuxProvider,
    stage: &str,
    cbs: &Callbacks,
) -> Result<RemotePairingLockdownService, Fail> {
    let step = |what: &str| format!("{stage}: {what}");
    let timed_out = |what: &str| Fail::Error(format!("{stage}: {what} timed out after {} s", MUX_STEP_TIMEOUT.as_secs()));

    cbs.status(GASSPAIR_STATUS_RP_LOCKDOWN_SESSION, &step("authenticating to Lockdown with the imported trust…"));
    let mut lockdown = tokio::time::timeout(MUX_STEP_TIMEOUT, LockdownClient::connect(provider))
        .await
        .map_err(|_| timed_out("Lockdown connect"))?
        .map_err(|e| Fail::Error(step(&format!("Lockdown connect failed ({})", describe(&e)))))?;
    let legacy = tokio::time::timeout(MUX_STEP_TIMEOUT, lockdown.start_session(&provider.pairing_file))
        .await
        .map_err(|_| timed_out("StartSession"))?
        .map_err(|e| Fail::Error(step(&format!("StartSession failed ({})", describe(&e)))))?;

    let service_name = RemotePairingLockdownService::service_name().into_owned();
    cbs.status(GASSPAIR_STATUS_RP_SERVICE_OPEN, &step(&format!("StartService {service_name}…")));
    let (port, ssl) = tokio::time::timeout(MUX_STEP_TIMEOUT, lockdown.start_service(service_name.clone()))
        .await
        .map_err(|_| timed_out("StartService"))?
        .map_err(|e| {
            Fail::Error(step(&format!(
                "lockdownd refused StartService({service_name}) on this route ({}). If iOS only offers this service on the USB transport, it cannot be opened over the network by any client.",
                describe(&e)
            )))
        })?;

    cbs.status(GASSPAIR_STATUS_RP_SERVICE_OPEN, &step(&format!("opening device socket for service port {port} (SSL={ssl})…")));
    let mut idevice = provider
        .connect(port)
        .await
        .map_err(|e| Fail::Error(step(&format!("device socket for service port {port} could not be opened ({})", describe(&e)))))?;
    if ssl {
        tokio::time::timeout(MUX_STEP_TIMEOUT, idevice.start_session(&provider.pairing_file, legacy))
            .await
            .map_err(|_| timed_out("service TLS"))?
            .map_err(|e| Fail::Error(step(&format!("service TLS on port {port} failed ({})", describe(&e)))))?;
    }
    if let Some(udid) = provider.pairing_file.udid.clone() {
        idevice.set_udid(udid);
    }
    Ok(RemotePairingLockdownService::new(idevice))
}

async fn write_verified_copy(bytes: &[u8], path: &str) -> Result<(), String> {
    let tmp = format!("{path}.tmp");
    tokio::fs::write(&tmp, bytes)
        .await
        .map_err(|e| format!("failed to write verified copy: {e}"))?;
    tokio::fs::rename(&tmp, path)
        .await
        .map_err(|e| format!("failed to move verified copy into place: {e}"))?;
    let back = tokio::fs::read(path)
        .await
        .map_err(|e| format!("failed to read back verified copy: {e}"))?;
    if back != bytes {
        let _ = tokio::fs::remove_file(path).await;
        return Err("verified copy differs after read-back; it was removed".into());
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Flows
// ---------------------------------------------------------------------------

/// Probe only: find the device and report its identity.
pub(crate) async fn probe_flow(
    endpoints: Vec<IpAddr>,
    lockdown_path: String,
    label: String,
    cbs: Callbacks,
) -> Result<MuxOutcome, Fail> {
    let trust = load_lockdown_trust(&lockdown_path, &cbs).await?;
    let attached = attach(&endpoints, &trust, &label, &cbs).await?;
    Ok(MuxOutcome::from_attached(&attached, String::new(), String::new(), false))
}

/// Full automatic creation: attach → two passes → independent verify → save.
pub(crate) async fn create_flow(
    endpoints: Vec<IpAddr>,
    lockdown_path: String,
    label: String,
    out_path: String,
    cbs: Callbacks,
) -> Result<MuxOutcome, Fail> {
    let trust = load_lockdown_trust(&lockdown_path, &cbs).await?;
    let attached = attach(&endpoints, &trust, &label, &cbs).await?;

    let mut pairing_file: RpPairingFile = fresh_pairing_file(&label);
    let mut peer: Option<PeerDevice> = None;
    for (index, stage) in ["Pairing through Lockdown", "Saving the pairing on the device"]
        .into_iter()
        .enumerate()
    {
        let code = if index == 0 { GASSPAIR_STATUS_RP_PAIRING } else { GASSPAIR_STATUS_RP_CONFIRMING };
        cbs.status(code, &format!("{stage}…"));
        let service = open_service(&attached.provider, stage, &cbs).await?;
        let mut client = service
            .into_client(&label)
            .map_err(|e| Fail::Error(format!("{stage}: could not start the RPPairing client ({})", describe(&e))))?;
        tokio::time::timeout(
            MUX_PAIR_PASS_TIMEOUT,
            client.connect(&mut pairing_file, || async { LOCKDOWN_CHANNEL_PIN.to_string() }),
        )
        .await
        .map_err(|_| Fail::Timeout(format!("{stage}: no answer from remotepairingdeviced within {} s", MUX_PAIR_PASS_TIMEOUT.as_secs())))?
        .map_err(|e| Fail::Error(format!("{stage}: RPPairing exchange failed ({})", describe(&e))))?;
        if peer.is_none() {
            peer = client.paired_peer_device().ok().cloned();
        }
    }

    // Third, fresh connection: verify only, never fall back to setup.
    let stage = "Independent pair-verify";
    cbs.status(GASSPAIR_STATUS_RP_VERIFYING, &format!("{stage} on a fresh connection…"));
    let service = open_service(&attached.provider, stage, &cbs).await?;
    let mut verifier = service
        .into_client(&label)
        .map_err(|e| Fail::Error(format!("{stage}: could not start the verification client ({})", describe(&e))))?;
    tokio::time::timeout(MUX_VERIFY_TIMEOUT, async {
        verifier
            .attempt_pair_verify()
            .await
            .map_err(|e| format!("{stage}: attemptPairVerify failed ({})", describe(&e)))?;
        verifier
            .validate_pairing(&mut pairing_file)
            .await
            .map_err(|e| format!("{stage}: the device did not accept the new record ({})", describe(&e)))?;
        Ok::<(), String>(())
    })
    .await
    .map_err(|_| Fail::Timeout(format!("{stage} timed out after {} s", MUX_VERIFY_TIMEOUT.as_secs())))?
    .map_err(Fail::Error)?;

    let alt_irk = pairing_file
        .alt_irk
        .clone()
        .or_else(|| peer.as_ref().map(|p| p.alt_irk.clone()))
        .filter(|irk| irk.len() == 16)
        .ok_or_else(|| Fail::Error("Pair-verify passed but the device identity (alt_irk) is missing; nothing was saved.".into()))?;
    pairing_file.alt_irk = Some(alt_irk.clone());

    cbs.status(GASSPAIR_STATUS_RP_SAVING, "Saving the verified RPPairing record…");
    save_pairing_file(&pairing_file, &out_path).await.map_err(Fail::Error)?;
    cbs.status(GASSPAIR_STATUS_RP_COMPLETE, &out_path);
    Ok(MuxOutcome::from_attached(&attached, out_path, hex(&alt_irk), true))
}

/// Verify an existing RPPairing record against the device (no setup), then
/// write a verified copy.
pub(crate) async fn verify_flow(
    endpoints: Vec<IpAddr>,
    lockdown_path: String,
    rp_path: String,
    label: String,
    out_path: String,
    cbs: Callbacks,
) -> Result<MuxOutcome, Fail> {
    let rp_bytes = tokio::fs::read(&rp_path)
        .await
        .map_err(|e| Fail::Error(format!("Could not read the RPPairing file: {e}")))?;
    let mut record = RpPairingFile::from_bytes(&rp_bytes)
        .map_err(|e| Fail::Error(format!("The RPPairing file is invalid: {}", describe(&e))))?;
    let trust = load_lockdown_trust(&lockdown_path, &cbs).await?;
    let attached = attach(&endpoints, &trust, &label, &cbs).await?;

    let stage = "Pair-verify of the existing record";
    cbs.status(GASSPAIR_STATUS_RP_VERIFYING, &format!("{stage}…"));
    let service = open_service(&attached.provider, stage, &cbs).await?;
    let mut client = service
        .into_client(&label)
        .map_err(|e| Fail::Error(format!("{stage}: could not start the RPPairing client ({})", describe(&e))))?;
    tokio::time::timeout(MUX_VERIFY_TIMEOUT, async {
        client
            .attempt_pair_verify()
            .await
            .map_err(|e| format!("{stage}: attemptPairVerify failed ({})", describe(&e)))?;
        client
            .validate_pairing(&mut record)
            .await
            .map_err(|e| format!("{stage}: the device does not recognise this record ({})", describe(&e)))?;
        Ok::<(), String>(())
    })
    .await
    .map_err(|_| Fail::Timeout(format!("{stage} timed out after {} s", MUX_VERIFY_TIMEOUT.as_secs())))?
    .map_err(Fail::Error)?;

    cbs.status(GASSPAIR_STATUS_RP_SAVING, "Writing the verified copy…");
    write_verified_copy(&rp_bytes, &out_path).await.map_err(Fail::Error)?;
    cbs.status(GASSPAIR_STATUS_RP_COMPLETE, &out_path);
    let irk = record.alt_irk.as_deref().map(hex).unwrap_or_default();
    Ok(MuxOutcome::from_attached(&attached, out_path, irk, true))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoints_default_to_localdevvpn() {
        assert_eq!(parse_endpoints(""), vec![DEFAULT_MUX_ENDPOINT]);
        assert_eq!(parse_endpoints("  \n , "), vec![DEFAULT_MUX_ENDPOINT]);
    }

    #[test]
    fn endpoints_are_parsed_deduplicated_and_ordered() {
        let parsed = parse_endpoints("192.168.1.20\n10.7.0.1, 192.168.1.20;[fd00::1]\n10.7.0.1:62078\n[fd00::1]:62078\n0.0.0.0\nnot-an-ip");
        assert_eq!(
            parsed,
            vec![
                "192.168.1.20".parse::<IpAddr>().unwrap(),
                DEFAULT_MUX_ENDPOINT,
                "fd00::1".parse::<IpAddr>().unwrap(),
            ]
        );
    }
}
