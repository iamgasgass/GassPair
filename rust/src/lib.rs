//! GassPair FFI — on-device wireless pairing, no computer required.
//!
//! Two flows are exposed to Swift:
//!
//! 1. **iPhone / iPad (iOS 27+ device-initiated pairing).** GassPair plays the
//!    "pairable host": it listens on a TCP port, hands the
//!    `_remotepairing-pairable-host._tcp` advertisement to Swift (published with
//!    `NetService`, so no multicast entitlement is needed) and lets the device
//!    connect from *Settings › Privacy & Security › Developer Mode › Pair with
//!    GassPair*. The PIN GassPair generates is typed on the device.
//!
//! 2. **Apple TV.** GassPair connects to the Apple TV's
//!    `_remotepairing-manual-pairing._tcp` service as the pairing host; the user
//!    types the PIN shown on the TV into GassPair. The resulting pairing file is
//!    then verified with a second connection (pair-verify).
//!
//! Compared to a bare port of idevice's `pairable_host.rs`, this shim adds:
//! * a cancellable, one-shot [`GassPairSession`] shared by both flows;
//! * a dual-stack (IPv6 + IPv4) listener so the device can reach us whichever
//!   address family mDNS resolves to, with automatic re-binding if iOS reclaims
//!   the listening socket while the app is suspended;
//! * concurrent handling of incoming connections (a stale or failed attempt —
//!   wrong PIN, device backing out — never blocks the next one);
//! * a fresh random host identifier per session so iOS never mistakes us for a
//!   previously paired host and asks for pair-verify (unsupported upstream);
//! * up to three PIN attempts for Apple TV, plus post-pairing verification;
//! * atomic, read-back-validated writes of the pairing file;
//! * panics caught at the FFI boundary instead of aborting the app.

#![allow(clippy::missing_safety_doc)]

use std::ffi::{c_char, c_void, CStr, CString};
use std::future::Future;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use idevice::remote_pairing::{
    errors::RemotePairingError, PairableHost, PairableHostInfo, PeerDevice, RemotePairingClient,
    RpPairingFile, RpPairingSocket,
};
use idevice::IdeviceError;
use idevice::IdeviceService;
use idevice::lockdown::LockdownClient;
use idevice::pairing_file::PairingFile;
use idevice::provider::{IdeviceProvider, TcpProvider};
use idevice::remote_pairing::RemotePairingLockdownService;
use std::net::IpAddr;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch, Mutex as AsyncMutex};
use tokio::task::JoinSet;

// ---------------------------------------------------------------------------
// Public constants (mirrored in gasspair.h)
// ---------------------------------------------------------------------------

pub const GASSPAIR_OK: i32 = 0;
pub const GASSPAIR_ERR: i32 = 1;
pub const GASSPAIR_ERR_INVALID_ARG: i32 = 2;
pub const GASSPAIR_ERR_CANCELLED: i32 = 3;
pub const GASSPAIR_ERR_TIMEOUT: i32 = 4;

/// Host flow: listening on the port in `message`.
pub const GASSPAIR_STATUS_LISTENING: i32 = 1;
/// Host flow: a device connected (peer address in `message`).
pub const GASSPAIR_STATUS_CONNECTED: i32 = 2;
/// Host flow: one attempt failed (reason in `message`); still listening.
pub const GASSPAIR_STATUS_ATTEMPT_FAILED: i32 = 3;
/// Host flow: listener was rebuilt (new port in `message`) and re-advertised.
pub const GASSPAIR_STATUS_RELISTENING: i32 = 4;
/// Apple TV flow: connecting to the address in `message`.
pub const GASSPAIR_STATUS_CONNECTING: i32 = 10;
/// Apple TV flow: the PIN was rejected; a new one will be requested.
pub const GASSPAIR_STATUS_WRONG_PIN: i32 = 11;
/// Apple TV flow: pairing done, verifying the new pairing file.
pub const GASSPAIR_STATUS_VERIFYING: i32 = 12;
/// Apple TV flow: verification failed (reason in `message`); file still saved.
pub const GASSPAIR_STATUS_VERIFY_FAILED: i32 = 13;
/// Both flows: pairing succeeded, writing the pairing file.
pub const GASSPAIR_STATUS_SAVING: i32 = 20;

// Lockdown-trust -> RPPairing progress. These are surfaced in the same UI card
// as the action so users can distinguish a stalled service-open from pairing.
pub const GASSPAIR_STATUS_RP_TRUST_LOADING: i32 = 40;
pub const GASSPAIR_STATUS_RP_LOCKDOWN_SESSION: i32 = 41;
pub const GASSPAIR_STATUS_RP_SERVICE_OPEN: i32 = 42;
pub const GASSPAIR_STATUS_RP_PAIRING: i32 = 43;
pub const GASSPAIR_STATUS_RP_CONFIRMING: i32 = 44;
pub const GASSPAIR_STATUS_RP_VERIFYING: i32 = 45;
pub const GASSPAIR_STATUS_RP_SAVING: i32 = 46;
pub const GASSPAIR_STATUS_RP_COMPLETE: i32 = 47;
pub const GASSPAIR_STATUS_RP_FAILED: i32 = 48;

const HOST_ATTEMPT_TIMEOUT: Duration = Duration::from_secs(300);
const ATV_CONNECT_TIMEOUT: Duration = Duration::from_secs(6);
const ATV_PIN_ATTEMPTS: u32 = 3;
const ATV_VERIFY_TIMEOUT: Duration = Duration::from_secs(20);

// ---------------------------------------------------------------------------
// FFI types
// ---------------------------------------------------------------------------

pub type GassPairReadyCb = Option<
    extern "C" fn(
        ctx: *mut c_void,
        service_id: *const c_char,
        port: u16,
        txt_keys: *const *const c_char,
        txt_vals: *const *const c_char,
        txt_count: usize,
    ),
>;
pub type GassPairPinCb = Option<extern "C" fn(ctx: *mut c_void, pin: *const c_char)>;
pub type GassPairPinRequestCb = Option<extern "C" fn(ctx: *mut c_void, attempt: u32)>;
pub type GassPairStatusCb =
    Option<extern "C" fn(ctx: *mut c_void, code: i32, message: *const c_char)>;

#[repr(C)]
pub struct GassPairResult {
    pub error: *mut c_char,
    pub device_name: *mut c_char,
    pub device_model: *mut c_char,
    pub device_udid: *mut c_char,
    pub pairing_file_path: *mut c_char,
    pub host_alt_irk_hex: *mut c_char,
    /// 1 if the pairing was verified with a second connection (Apple TV only).
    pub verified: i32,
}

impl GassPairResult {
    fn empty() -> Self {
        Self {
            error: ptr::null_mut(),
            device_name: ptr::null_mut(),
            device_model: ptr::null_mut(),
            device_udid: ptr::null_mut(),
            pairing_file_path: ptr::null_mut(),
            host_alt_irk_hex: ptr::null_mut(),
            verified: 0,
        }
    }
}

/// A one-shot pairing session. Create it, run exactly one flow on it from a
/// background thread, cancel/submit PINs from any thread, and free it after
/// the run function has returned.
pub struct GassPairSession {
    cancel: watch::Sender<bool>,
    _cancel_keepalive: watch::Receiver<bool>,
    pin_tx: mpsc::UnboundedSender<String>,
    pin_rx: Mutex<Option<mpsc::UnboundedReceiver<String>>>,
    used: AtomicBool,
}

impl GassPairSession {
    fn new() -> Self {
        let (cancel, keep) = watch::channel(false);
        let (pin_tx, pin_rx) = mpsc::unbounded_channel();
        Self {
            cancel,
            _cancel_keepalive: keep,
            pin_tx,
            pin_rx: Mutex::new(Some(pin_rx)),
            used: AtomicBool::new(false),
        }
    }
}

#[derive(Clone, Copy)]
struct Callbacks {
    ready: GassPairReadyCb,
    pin: GassPairPinCb,
    pin_request: GassPairPinRequestCb,
    status: GassPairStatusCb,
    ctx: *mut c_void,
}
// The Swift side marshals every callback onto the main queue itself.
unsafe impl Send for Callbacks {}
unsafe impl Sync for Callbacks {}

impl Callbacks {
    fn status(&self, code: i32, message: &str) {
        if let Some(cb) = self.status {
            let c = to_cstring(message);
            cb(self.ctx, code, c.as_ptr());
        }
    }

    fn pin(&self, pin: &str) {
        if let Some(cb) = self.pin {
            let c = to_cstring(pin);
            cb(self.ctx, c.as_ptr());
        }
    }

    fn pin_request(&self, attempt: u32) {
        if let Some(cb) = self.pin_request {
            cb(self.ctx, attempt);
        }
    }

    fn ready(&self, service_id: &str, port: u16, host_info: &PairableHostInfo) {
        let Some(cb) = self.ready else { return };
        let records = host_info.mdns_txt_records(service_id);
        let keys: Vec<CString> = records.iter().map(|(k, _)| to_cstring(k)).collect();
        let vals: Vec<CString> = records.iter().map(|(_, v)| to_cstring(v)).collect();
        let key_ptrs: Vec<*const c_char> = keys.iter().map(|s| s.as_ptr()).collect();
        let val_ptrs: Vec<*const c_char> = vals.iter().map(|s| s.as_ptr()).collect();
        let id = to_cstring(service_id);
        cb(
            self.ctx,
            id.as_ptr(),
            port,
            key_ptrs.as_ptr(),
            val_ptrs.as_ptr(),
            records.len(),
        );
    }
}

enum Fail {
    Cancelled,
    Timeout(String),
    Error(String),
}

struct Paired {
    name: String,
    model: String,
    udid: String,
    path: String,
    host_alt_irk_hex: String,
    verified: bool,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn to_cstring(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

fn raw_cstr(s: &str) -> *mut c_char {
    to_cstring(s).into_raw()
}

fn report_rp_progress(callback: GassPairStatusCb, ctx: *mut c_void, code: i32, message: &str) {
    if let Some(callback) = callback {
        // C strings cannot contain NUL. Keep reporting best-effort and never panic
        // across the FFI boundary due to a malformed diagnostic string.
        let safe = message.replace('\0', " ");
        if let Ok(text) = CString::new(safe) {
            callback(ctx, code, text.as_ptr());
        }
    }
}


unsafe fn opt_str(p: *const c_char, default: &str) -> String {
    if p.is_null() {
        return default.to_string();
    }
    match CStr::from_ptr(p).to_str() {
        Ok(s) if !s.trim().is_empty() => s.to_string(),
        _ => default.to_string(),
    }
}

/// Formats 16 random bytes as an RFC 4122 version-4 UUID string. The bytes come
/// from the freshly generated (public) Ed25519 key, which is uniformly random.
fn random_uuid(seed: &[u8]) -> String {
    let mut b = [0u8; 16];
    for (i, byte) in seed.iter().take(16).enumerate() {
        b[i] = *byte;
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    format!(
        "{}-{}-{}-{}-{}",
        hex(&b[0..4]),
        hex(&b[4..6]),
        hex(&b[6..8]),
        hex(&b[8..10]),
        hex(&b[10..16])
    )
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic".to_string()
    }
}

fn fresh_pairing_file(name: &str) -> RpPairingFile {
    let mut file = RpPairingFile::generate(name);
    // `generate` derives the identifier from the name (UUIDv3), i.e. it would be
    // identical on every run. A random identifier guarantees the device treats
    // each session as a brand-new host and always runs pair-setup.
    file.identifier = random_uuid(&file.public_key_bytes());
    file
}

/// Writes the pairing file atomically and reads it back to make sure what is on
/// disk parses and carries the peer's identity key.
async fn save_pairing_file(file: &RpPairingFile, path: &str) -> Result<(), String> {
    let target = Path::new(path);
    if let Some(parent) = target.parent() {
        if !parent.as_os_str().is_empty() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|e| format!("failed to create {}: {e}", parent.display()))?;
        }
    }
    let tmp = format!("{path}.tmp");
    tokio::fs::write(&tmp, file.to_bytes())
        .await
        .map_err(|e| format!("failed to write pairing file: {e}"))?;
    tokio::fs::rename(&tmp, target)
        .await
        .map_err(|e| format!("failed to move pairing file into place: {e}"))?;

    let bytes = tokio::fs::read(target)
        .await
        .map_err(|e| format!("failed to read back pairing file: {e}"))?;
    let parsed = RpPairingFile::from_bytes(&bytes)
        .map_err(|e| format!("pairing file on disk is invalid: {e}"))?;
    if parsed.identifier != file.identifier || parsed.alt_irk.as_deref().map(<[u8]>::len) != Some(16)
    {
        return Err("pairing file on disk is incomplete".into());
    }
    Ok(())
}

/// Dual-stack listener: `[::]:port` with `IPV6_V6ONLY` off accepts IPv4-mapped
/// connections too. Falls back to IPv4-only if IPv6 is unavailable.
fn bind_listener(port: u16) -> std::io::Result<TcpListener> {
    use socket2::{Domain, Protocol, Socket, Type};

    fn make(domain: Domain, addr: SocketAddr) -> std::io::Result<std::net::TcpListener> {
        let socket = Socket::new(domain, Type::STREAM, Some(Protocol::TCP))?;
        if domain == Domain::IPV6 {
            socket.set_only_v6(false)?;
        }
        socket.set_reuse_address(true)?;
        socket.set_nonblocking(true)?;
        socket.bind(&addr.into())?;
        socket.listen(32)?;
        Ok(socket.into())
    }

    let std_listener = make(Domain::IPV6, SocketAddr::from((Ipv6Addr::UNSPECIFIED, port)))
        .or_else(|_| make(Domain::IPV4, SocketAddr::from((Ipv4Addr::UNSPECIFIED, port))))?;
    TcpListener::from_std(std_listener)
}

/// Runs `work` on a fresh runtime, racing it against the session's cancel flag
/// and an optional overall timeout. Panics are turned into errors.
fn run_flow<F>(session: &GassPairSession, timeout: Option<Duration>, work: F) -> Result<Paired, Fail>
where
    F: Future<Output = Result<Paired, Fail>>,
{
    // A current-thread runtime + LocalSet: everything runs on the calling
    // (background) thread, so none of idevice's futures need to be `Send`.
    let rt = match tokio::runtime::Builder::new_current_thread()
        .thread_name("gasspair")
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => return Err(Fail::Error(format!("failed to start runtime: {e}"))),
    };

    let mut cancel_rx = session.cancel.subscribe();
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let local = tokio::task::LocalSet::new();
        local.block_on(&rt, async move {
            if *cancel_rx.borrow() {
                return Err(Fail::Cancelled);
            }
            let bounded = async {
                match timeout {
                    Some(limit) => tokio::time::timeout(limit, work).await.unwrap_or_else(|_| {
                        Err(Fail::Timeout(format!(
                            "No device finished pairing within {} minutes.",
                            limit.as_secs() / 60
                        )))
                    }),
                    None => work.await,
                }
            };
            tokio::select! {
                result = bounded => result,
                _ = cancel_rx.wait_for(|cancelled| *cancelled) => Err(Fail::Cancelled),
            }
        })
    }));
    rt.shutdown_background();

    match outcome {
        Ok(result) => result,
        Err(payload) => Err(Fail::Error(format!(
            "internal error: {}",
            panic_message(payload.as_ref())
        ))),
    }
}

unsafe fn write_outcome(out: *mut GassPairResult, outcome: Result<Paired, Fail>) -> i32 {
    match outcome {
        Ok(p) => {
            (*out).device_name = raw_cstr(&p.name);
            (*out).device_model = raw_cstr(&p.model);
            (*out).device_udid = raw_cstr(&p.udid);
            (*out).pairing_file_path = raw_cstr(&p.path);
            (*out).host_alt_irk_hex = raw_cstr(&p.host_alt_irk_hex);
            (*out).verified = i32::from(p.verified);
            GASSPAIR_OK
        }
        Err(Fail::Cancelled) => {
            (*out).error = raw_cstr("Cancelled.");
            GASSPAIR_ERR_CANCELLED
        }
        Err(Fail::Timeout(msg)) => {
            (*out).error = raw_cstr(&msg);
            GASSPAIR_ERR_TIMEOUT
        }
        Err(Fail::Error(msg)) => {
            (*out).error = raw_cstr(&msg);
            GASSPAIR_ERR
        }
    }
}

fn claim(session: &GassPairSession) -> bool {
    !session.used.swap(true, Ordering::SeqCst)
}

// ---------------------------------------------------------------------------
// Session API
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn gasspair_session_new() -> *mut GassPairSession {
    Box::into_raw(Box::new(GassPairSession::new()))
}

/// Cancels the running flow (if any). Safe to call from any thread, any number
/// of times, before or during the run.
#[no_mangle]
pub unsafe extern "C" fn gasspair_session_cancel(session: *mut GassPairSession) {
    if let Some(session) = session.as_ref() {
        session.cancel.send_replace(true);
    }
}

/// Hands the six-digit Apple TV PIN to the running flow.
/// Returns 0 on success, 1 for a malformed PIN, 2 for an invalid session.
#[no_mangle]
pub unsafe extern "C" fn gasspair_session_submit_pin(
    session: *mut GassPairSession,
    pin: *const c_char,
) -> i32 {
    let Some(session) = session.as_ref() else {
        return GASSPAIR_ERR_INVALID_ARG;
    };
    let pin = opt_str(pin, "");
    let pin = pin.trim();
    if pin.len() != 6 || !pin.bytes().all(|b| b.is_ascii_digit()) {
        return GASSPAIR_ERR;
    }
    if session.pin_tx.send(pin.to_string()).is_ok() {
        GASSPAIR_OK
    } else {
        GASSPAIR_ERR_INVALID_ARG
    }
}

/// Frees a session. Only call after the run function has returned.
#[no_mangle]
pub unsafe extern "C" fn gasspair_session_free(session: *mut GassPairSession) {
    if !session.is_null() {
        drop(Box::from_raw(session));
    }
}

#[no_mangle]
pub unsafe extern "C" fn gasspair_result_free(r: *mut GassPairResult) {
    if r.is_null() {
        return;
    }
    for p in [
        (*r).error,
        (*r).device_name,
        (*r).device_model,
        (*r).device_udid,
        (*r).pairing_file_path,
        (*r).host_alt_irk_hex,
    ] {
        if !p.is_null() {
            drop(CString::from_raw(p));
        }
    }
    *r = GassPairResult::empty();
}

#[no_mangle]
pub extern "C" fn gasspair_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}


// ---------------------------------------------------------------------------
// Direct RPPairing endpoint operations (LocalDevVPN or LAN)
// ---------------------------------------------------------------------------

/// Verify an existing RPPairing record against a real RemotePairing service.
/// `host:port` MUST be the advertised RPPairing service endpoint, not Lockdown
/// TCP/62078. Returns 0 only after pair-verify and validate_pairing both pass.
#[no_mangle]
pub unsafe extern "C" fn gasspair_verify_rp_endpoint(
    host: *const c_char,
    port: u16,
    client_name: *const c_char,
    pairing_path: *const c_char,
    out: *mut GassPairResult,
) -> i32 {
    if out.is_null() || port == 0 { return GASSPAIR_ERR_INVALID_ARG; }
    *out = GassPairResult::empty();
    let host = opt_str(host, "");
    let name = opt_str(client_name, "GassPair");
    let path = opt_str(pairing_path, "");
    if host.is_empty() || path.is_empty() {
        (*out).error = raw_cstr("Host and pairing file path are required.");
        return GASSPAIR_ERR_INVALID_ARG;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build()
            .map_err(|e| format!("runtime: {e}"))?;
        rt.block_on(async {
            let bytes = tokio::fs::read(&path).await.map_err(|e| format!("read pairing file: {e}"))?;
            let mut file = RpPairingFile::from_bytes(&bytes).map_err(|e| format!("invalid RPPairing file: {e}"))?;
            let addr = format!("{}:{}", host, port);
            let stream = tokio::time::timeout(Duration::from_secs(8), TcpStream::connect(&addr)).await
                .map_err(|_| "TCP connect timed out".to_string())?
                .map_err(|e| format!("TCP connect failed: {e}"))?;
            let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), &name);
            tokio::time::timeout(Duration::from_secs(20), async {
                client.attempt_pair_verify().await.map_err(|e| format!("pair-verify handshake failed: {e}"))?;
                client.validate_pairing(&mut file).await.map_err(|e| format!("pair-verify validation failed: {e}"))?;
                Ok::<(), String>(())
            }).await.map_err(|_| "pair-verify timed out".to_string())??;
            Ok::<String, String>(format!("RPPairing pair-verify succeeded against {addr}."))
        })
    }));
    match result {
        Ok(Ok(message)) => { (*out).verified = 1; (*out).device_name = raw_cstr(&message); GASSPAIR_OK }
        Ok(Err(e)) => { (*out).error = raw_cstr(&e); GASSPAIR_ERR }
        Err(_) => { (*out).error = raw_cstr("Internal panic while verifying RPPairing endpoint."); GASSPAIR_ERR }
    }
}

/// Opens remotepairingdeviced.lockdown with stage-specific diagnostics over the
/// TCP provider. The public `IdeviceService::connect` helper hides each step and
/// collapses failures into errors like "device socket io failed"; doing the
/// steps explicitly tells us whether Lockdown auth, StartService, the dynamic
/// service socket, or RPPairing protocol I/O is the failing boundary.
async fn open_rp_lockdown_service_over_tcp(
    provider: &TcpProvider,
    client_name: &str,
    stage: &str,
    status_cb: GassPairStatusCb,
    ctx: *mut c_void,
) -> Result<RemotePairingLockdownService, String> {
    report_rp_progress(
        status_cb,
        ctx,
        GASSPAIR_STATUS_RP_LOCKDOWN_SESSION,
        &format!("{stage}: connecting to Lockdown TCP on the configured endpoint…"),
    );
    let mut lockdown = tokio::time::timeout(
        Duration::from_secs(10),
        LockdownClient::connect(provider),
    )
    .await
    .map_err(|_| format!("{stage}: connecting to Lockdown TCP/62078 timed out after 10 seconds"))?
    .map_err(|e| explain_rp_transport_error(&format!("{stage}: Lockdown TCP connection failed"), e))?;

    let pairing_file = provider
        .get_pairing_file()
        .await
        .map_err(|e| format!("{stage}: could not load imported Lockdown trust record: {e}"))?;
    report_rp_progress(
        status_cb,
        ctx,
        GASSPAIR_STATUS_RP_LOCKDOWN_SESSION,
        &format!("{stage}: Lockdown socket opened; authenticating with imported HostID/SystemBUID via StartSession TLS…"),
    );
    let legacy = tokio::time::timeout(
        Duration::from_secs(15),
        lockdown.start_session(&pairing_file),
    )
    .await
    .map_err(|_| format!("{stage}: Lockdown StartSession TLS timed out after 15 seconds"))?
    .map_err(|e| explain_rp_transport_error(&format!("{stage}: Lockdown StartSession TLS failed"), e))?;

    let version = lockdown
        .get_value(Some("ProductVersion"), None)
        .await
        .ok()
        .and_then(|v| v.as_string().map(str::to_owned))
        .unwrap_or_else(|| "unknown".to_string());
    let service_name = RemotePairingLockdownService::service_name().into_owned();
    report_rp_progress(
        status_cb,
        ctx,
        GASSPAIR_STATUS_RP_SERVICE_OPEN,
        &format!("{stage}: authenticated Lockdown session established (iOS {version}); requesting StartService for {service_name}…"),
    );
    let (service_port, ssl) = tokio::time::timeout(
        Duration::from_secs(12),
        lockdown.start_service(service_name.clone()),
    )
    .await
    .map_err(|_| format!("{stage}: Lockdown StartService({service_name}) timed out after 12 seconds"))?
    .map_err(|e| explain_rp_transport_error(&format!("{stage}: Lockdown refused StartService({service_name})"), e))?;

    report_rp_progress(
        status_cb,
        ctx,
        GASSPAIR_STATUS_RP_SERVICE_OPEN,
        &format!("{stage}: Lockdown returned service port {service_port} (EnableServiceSSL={ssl}). Now opening that service socket directly through LocalDevVPN; this is distinct from TCP/62078…"),
    );
    let mut service_socket = tokio::time::timeout(
        Duration::from_secs(10),
        provider.connect(service_port),
    )
    .await
    .map_err(|_| format!("{stage}: service {service_name} port {service_port} was not reachable over LocalDevVPN within 10 seconds. Lockdown TCP/62078 may work while this second port is not routed."))?
    .map_err(|e| explain_rp_transport_error(&format!("{stage}: TCP connection to Lockdown-assigned service port {service_port} failed"), e))?;

    if ssl {
        report_rp_progress(
            status_cb,
            ctx,
            GASSPAIR_STATUS_RP_SERVICE_OPEN,
            &format!("{stage}: the service requires TLS; establishing the service TLS session using the imported Lockdown record…"),
        );
        tokio::time::timeout(
            Duration::from_secs(15),
            service_socket.start_session(&pairing_file, legacy),
        )
        .await
        .map_err(|_| format!("{stage}: TLS setup on service port {service_port} timed out after 15 seconds"))?
        .map_err(|e| explain_rp_transport_error(&format!("{stage}: TLS setup on service port {service_port} failed"), e))?;
    }

    report_rp_progress(
        status_cb,
        ctx,
        GASSPAIR_STATUS_RP_SERVICE_OPEN,
        &format!("{stage}: service port {service_port} is connected; constructing the RPPairing protocol client…"),
    );
    RemotePairingLockdownService::from_stream(service_socket)
        .await
        .map_err(|e| explain_rp_transport_error(&format!("{stage}: converting the service socket to RemotePairingLockdownService failed"), e))
}

fn explain_rp_transport_error(stage: &str, error: impl std::fmt::Display) -> String {
    let detail = error.to_string();
    let lower = detail.to_ascii_lowercase();
    let is_device_socket_io = lower.contains("device socket io failed")
        || lower.contains("device socket i/o failed")
        || lower.contains("devicesocketio");
    if !is_device_socket_io {
        return format!("{stage}: {detail}");
    }

    if stage.contains("RPPairing") || stage.contains("RemotePairingLockdownService") {
        format!(
            "{stage}: device socket I/O failed ({detail}). The authenticated RemotePairingLockdownService socket was opened, but its RPPairing wire exchange failed. Upstream idevice_pair accesses this private service through usbmuxd; a raw TcpProvider over LocalDevVPN is not usbmuxd multiplexing. This is a transport-boundary failure, not a PIN guess to retry. No RPPairing file is saved unless the full protocol and pair-verify complete."
        )
    } else if stage.contains("service port") || stage.contains("StartService") || stage.contains("service TLS") {
        format!(
            "{stage}: device socket I/O failed ({detail}). Lockdown TCP/62078 may be reachable while the separate device-assigned RemotePairingLockdownService socket is not usable through raw TCP. Upstream idevice_pair opens this private service through usbmuxd; LocalDevVPN routes IP packets but does not implement usbmuxd multiplexing. No RPPairing file was saved."
        )
    } else {
        format!(
            "{stage}: device socket I/O failed ({detail}). The failure occurred in the Lockdown control/authentication phase, before the RPPairing wire exchange. Check that the imported Lockdown.plist belongs to this exact device and can start a TLS session over the selected route. No RPPairing file was saved."
        )
    }
}

/// Create a new RPPairing record using an existing, user-imported Lockdown
/// trust record over a TCP-reachable Lockdown endpoint (e.g. LocalDevVPN).
/// This follows idevice_pair's RemotePairingLockdownService path, not raw TCP
/// to an RPPairing port. The imported Lockdown record is used only to start the
/// authenticated Lockdown session; the new RPPairing record is created by the
/// device's remotepairingdeviced service and is verified before being saved.
#[no_mangle]
pub unsafe extern "C" fn gasspair_create_rp_from_lockdown_endpoint(
    host: *const c_char,
    port: u16,
    client_name: *const c_char,
    lockdown_path: *const c_char,
    out_path: *const c_char,
    status_cb: GassPairStatusCb,
    ctx: *mut c_void,
    out: *mut GassPairResult,
) -> i32 {
    if out.is_null() || port == 0 { return GASSPAIR_ERR_INVALID_ARG; }
    *out = GassPairResult::empty();
    let host = opt_str(host, "");
    let _name = opt_str(client_name, "GassPair");
    let lockdown_path = opt_str(lockdown_path, "");
    let _out_path = opt_str(out_path, "rp_pairing_file_from_lockdown.plist");
    if host.is_empty() || lockdown_path.is_empty() {
        (*out).error = raw_cstr("Host and imported Lockdown pairing file are required.");
        return GASSPAIR_ERR_INVALID_ARG;
    }

    // Important: this operation cannot be implemented correctly by connecting
    // to TCP/62078 and then opening Lockdown's returned dynamic service port.
    // The upstream idevice_pair implementation uses a usbmuxd-backed provider
    // for RemotePairingLockdownService. An iOS app's TcpProvider plus
    // LocalDevVPN is only raw IP routing; it does not provide usbmuxd's device
    // socket/multiplexing semantics. Fail closed here rather than retrying an
    // incompatible transport or ever reporting/saving a synthetic record.
    let message = format!(
        "Unsupported transport: cannot create RPPairing through direct TCP ({host}:{port}). Lockdown TCP reachability does not provide usbmuxd device-socket semantics for RemotePairingLockdownService. LocalDevVPN routes IP packets but does not implement usbmuxd. No RPPairing exchange was started and no file was written. Use a usbmuxd-backed macOS companion/relay for this operation, or use an endpoint that genuinely exposes the RPPairing protocol."
    );
    report_rp_progress(status_cb, ctx, GASSPAIR_STATUS_RP_FAILED, &message);
    (*out).error = raw_cstr(&message);
    GASSPAIR_ERR
}

/// Create a fresh RPPairing record by performing the real RemotePairing PIN
/// protocol against an advertised service endpoint. This is NOT a Lockdown
/// pairing operation. The service must actually speak RPPairing on host:port.
#[no_mangle]
pub unsafe extern "C" fn gasspair_create_rp_endpoint(
    host: *const c_char,
    port: u16,
    client_name: *const c_char,
    pin: *const c_char,
    out_path: *const c_char,
    out: *mut GassPairResult,
) -> i32 {
    if out.is_null() || port == 0 { return GASSPAIR_ERR_INVALID_ARG; }
    *out = GassPairResult::empty();
    let host = opt_str(host, "");
    let name = opt_str(client_name, "GassPair");
    let pin = opt_str(pin, "");
    let path = opt_str(out_path, "");
    if host.is_empty() || path.is_empty() || pin.len() != 6 || !pin.bytes().all(|b| b.is_ascii_digit()) {
        (*out).error = raw_cstr("Provide a real RPPairing host, port, output path, and six-digit PIN.");
        return GASSPAIR_ERR_INVALID_ARG;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build()
            .map_err(|e| format!("runtime: {e}"))?;
        rt.block_on(async {
            let addr = format!("{}:{}", host, port);
            let stream = tokio::time::timeout(Duration::from_secs(8), TcpStream::connect(&addr)).await
                .map_err(|_| "TCP connect timed out".to_string())?
                .map_err(|e| format!("TCP connect failed: {e}"))?;
            let mut file = fresh_pairing_file(&name);
            let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), &name);
            let pin_for_attempt = pin.clone();
            tokio::time::timeout(Duration::from_secs(60), client.connect(&mut file, move || {
                let supplied_pin = pin_for_attempt.clone();
                async move { supplied_pin }
            })).await
                .map_err(|_| "RPPairing setup timed out".to_string())?
                .map_err(|e| format!("RPPairing setup rejected or failed: {e}"))?;
            let peer = client.paired_peer_device().map_err(|e| format!("pairing completed without peer identity: {e}"))?.clone();
            drop(client);
            // Verify on a fresh connection before writing any record to disk.
            let stream = tokio::time::timeout(Duration::from_secs(8), TcpStream::connect(&addr)).await
                .map_err(|_| "verification TCP connect timed out".to_string())?
                .map_err(|e| format!("verification TCP connect failed: {e}"))?;
            let mut verifier = RemotePairingClient::new(RpPairingSocket::new(stream), &name);
            tokio::time::timeout(Duration::from_secs(20), async {
                verifier.attempt_pair_verify().await.map_err(|e| format!("pair-verify handshake failed: {e}"))?;
                verifier.validate_pairing(&mut file).await.map_err(|e| format!("pair-verify validation failed: {e}"))?;
                Ok::<(), String>(())
            }).await.map_err(|_| "pair-verify timed out".to_string())??;
            save_pairing_file(&file, &path).await?;
            Ok::<(String, String, String), String>((peer.name, peer.model, peer.remotepairing_udid))
        })
    }));
    match result {
        Ok(Ok((device_name, model, udid))) => {
            (*out).device_name = raw_cstr(&device_name); (*out).device_model = raw_cstr(&model);
            (*out).device_udid = raw_cstr(&udid); (*out).pairing_file_path = raw_cstr(&path); (*out).verified = 1;
            GASSPAIR_OK
        }
        Ok(Err(e)) => { (*out).error = raw_cstr(&e); GASSPAIR_ERR }
        Err(_) => { (*out).error = raw_cstr("Internal panic during RPPairing creation."); GASSPAIR_ERR }
    }
}

// ---------------------------------------------------------------------------
// Flow 1: iPhone / iPad (device-initiated, we are the pairable host)
// ---------------------------------------------------------------------------

/// Blocks until a device pairs, the session is cancelled, or `timeout_secs`
/// (0 = no limit) elapses.
#[no_mangle]
pub unsafe extern "C" fn gasspair_run_host(
    session: *mut GassPairSession,
    name: *const c_char,
    model: *const c_char,
    out_path: *const c_char,
    timeout_secs: u32,
    ready_cb: GassPairReadyCb,
    pin_cb: GassPairPinCb,
    status_cb: GassPairStatusCb,
    ctx: *mut c_void,
    out: *mut GassPairResult,
) -> i32 {
    if out.is_null() {
        return GASSPAIR_ERR_INVALID_ARG;
    }
    *out = GassPairResult::empty();
    let Some(session) = session.as_ref() else {
        (*out).error = raw_cstr("invalid session");
        return GASSPAIR_ERR_INVALID_ARG;
    };
    if !claim(session) {
        (*out).error = raw_cstr("session already used");
        return GASSPAIR_ERR_INVALID_ARG;
    }

    let name = opt_str(name, "GassPair");
    let model = opt_str(model, "Mac17,7");
    let out_path = opt_str(out_path, "rp_pairing_file.plist");
    let cbs = Callbacks {
        ready: ready_cb,
        pin: pin_cb,
        pin_request: None,
        status: status_cb,
        ctx,
    };
    let timeout = (timeout_secs > 0).then(|| Duration::from_secs(u64::from(timeout_secs)));

    let outcome = run_flow(session, timeout, host_flow(name, model, out_path, cbs));
    write_outcome(out, outcome)
}

type HostAttempt = Result<(PeerDevice, RpPairingFile), String>;

async fn host_flow(
    name: String,
    model: String,
    out_path: String,
    cbs: Callbacks,
) -> Result<Paired, Fail> {
    let pairing_file = fresh_pairing_file(&name);
    let host_info = PairableHostInfo::generate(&name, &model);
    let service_id = pairing_file.identifier.clone();
    let host_alt_irk_hex = hex(&host_info.alt_irk);

    let mut listener =
        bind_listener(0).map_err(|e| Fail::Error(format!("failed to open a listening port: {e}")))?;
    let mut port = listener
        .local_addr()
        .map_err(|e| Fail::Error(format!("no local address: {e}")))?
        .port();

    cbs.ready(&service_id, port, &host_info);
    cbs.status(GASSPAIR_STATUS_LISTENING, &port.to_string());

    let mut attempts: JoinSet<HostAttempt> = JoinSet::new();
    let mut accept_errors: u32 = 0;

    loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok((stream, peer)) => {
                    accept_errors = 0;
                    let _ = stream.set_nodelay(true);
                    cbs.status(GASSPAIR_STATUS_CONNECTED, &peer.to_string());
                    attempts.spawn_local(host_attempt(stream, pairing_file.clone(), host_info.clone(), cbs));
                }
                Err(e) => {
                    accept_errors += 1;
                    if accept_errors < 3 {
                        tokio::time::sleep(Duration::from_millis(250)).await;
                        continue;
                    }
                    // The listening socket is likely dead (iOS reclaims sockets of
                    // suspended apps). Rebuild it and advertise the new port.
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    match bind_listener(port).or_else(|_| bind_listener(0)) {
                        Ok(fresh) => {
                            listener = fresh;
                            if let Ok(addr) = listener.local_addr() {
                                port = addr.port();
                            }
                            accept_errors = 0;
                            cbs.ready(&service_id, port, &host_info);
                            cbs.status(GASSPAIR_STATUS_RELISTENING, &port.to_string());
                        }
                        Err(bind_err) if accept_errors > 40 => {
                            return Err(Fail::Error(format!(
                                "the listening socket stopped working ({e}) and could not be reopened ({bind_err})"
                            )));
                        }
                        Err(_) => {}
                    }
                }
            },
            Some(joined) = attempts.join_next(), if !attempts.is_empty() => match joined {
                Ok(Ok((peer, file))) => {
                    cbs.status(GASSPAIR_STATUS_SAVING, &peer.name);
                    save_pairing_file(&file, &out_path).await.map_err(Fail::Error)?;
                    return Ok(Paired {
                        name: peer.name,
                        model: peer.model,
                        udid: peer.remotepairing_udid,
                        path: out_path,
                        host_alt_irk_hex,
                        verified: false,
                    });
                }
                Ok(Err(reason)) => cbs.status(GASSPAIR_STATUS_ATTEMPT_FAILED, &reason),
                Err(join_err) => cbs.status(
                    GASSPAIR_STATUS_ATTEMPT_FAILED,
                    &format!("pairing attempt crashed: {join_err}"),
                ),
            },
        }
    }
}

async fn host_attempt(
    stream: TcpStream,
    mut file: RpPairingFile,
    host_info: PairableHostInfo,
    cbs: Callbacks,
) -> HostAttempt {
    let mut host = PairableHost::new(RpPairingSocket::new_device(stream), host_info);
    let accepted = tokio::time::timeout(
        HOST_ATTEMPT_TIMEOUT,
        host.accept(&mut file, move |pin| async move { cbs.pin(&pin) }),
    )
    .await;

    match accepted {
        Err(_) => Err("The device did not finish pairing within 5 minutes.".into()),
        Ok(Err(e)) => Err(describe_host_error(&e)),
        Ok(Ok(peer)) => {
            // Keep the socket open briefly so the device reads M6 and closes
            // the connection on its own terms.
            tokio::time::sleep(Duration::from_millis(1500)).await;
            drop(host);
            Ok((peer, file))
        }
    }
}

fn describe_host_error(e: &IdeviceError) -> String {
    match e {
        IdeviceError::RemotePairing(RemotePairingError::SrpAuthFailed) => {
            "Wrong code entered on the device. Tap Pair with GassPair again — a new code will be shown.".into()
        }
        other => {
            let text = other.to_string();
            if text.contains("pair-verify") {
                "The device tried to reconnect to an older GassPair pairing. Tap Pair with GassPair again; if it keeps happening, reset trusted computers (Settings › General › Transfer or Reset iPhone › Reset › Reset Location & Privacy).".into()
            } else if text.to_lowercase().contains("eof") || text.contains("reset") || text.contains("closed") {
                format!("The device closed the connection ({text}).")
            } else {
                text
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Flow 2: Apple TV (we are the pairing host, TV shows the PIN)
// ---------------------------------------------------------------------------

/// `hosts` is a newline-separated list of candidate addresses/hostnames for the
/// Apple TV, tried in order. Blocks until paired, cancelled or failed.
#[no_mangle]
pub unsafe extern "C" fn gasspair_pair_apple_tv(
    session: *mut GassPairSession,
    hosts: *const c_char,
    port: u16,
    name: *const c_char,
    out_path: *const c_char,
    pin_request_cb: GassPairPinRequestCb,
    status_cb: GassPairStatusCb,
    ctx: *mut c_void,
    out: *mut GassPairResult,
) -> i32 {
    if out.is_null() {
        return GASSPAIR_ERR_INVALID_ARG;
    }
    *out = GassPairResult::empty();
    let Some(session) = session.as_ref() else {
        (*out).error = raw_cstr("invalid session");
        return GASSPAIR_ERR_INVALID_ARG;
    };

    let hosts: Vec<String> = opt_str(hosts, "")
        .lines()
        .map(str::trim)
        .filter(|h| !h.is_empty())
        .map(str::to_string)
        .collect();
    if hosts.is_empty() || port == 0 {
        (*out).error = raw_cstr("invalid Apple TV address");
        return GASSPAIR_ERR_INVALID_ARG;
    }
    if !claim(session) {
        (*out).error = raw_cstr("session already used");
        return GASSPAIR_ERR_INVALID_ARG;
    }
    let Some(pin_rx) = session.pin_rx.lock().ok().and_then(|mut g| g.take()) else {
        (*out).error = raw_cstr("session already used");
        return GASSPAIR_ERR_INVALID_ARG;
    };

    let name = opt_str(name, "GassPair");
    let out_path = opt_str(out_path, "appletv_rp_pairing_file.plist");
    let cbs = Callbacks {
        ready: None,
        pin: None,
        pin_request: pin_request_cb,
        status: status_cb,
        ctx,
    };

    let outcome = run_flow(
        session,
        None,
        apple_tv_flow(hosts, port, name, out_path, cbs, pin_rx),
    );
    write_outcome(out, outcome)
}

async fn connect_any(
    hosts: &[String],
    port: u16,
    cbs: Option<&Callbacks>,
) -> Result<TcpStream, String> {
    let mut errors = Vec::new();
    for round in 0..2 {
        if round > 0 {
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        for host in hosts {
            if let Some(cbs) = cbs {
                cbs.status(GASSPAIR_STATUS_CONNECTING, host);
            }
            match tokio::time::timeout(ATV_CONNECT_TIMEOUT, TcpStream::connect((host.as_str(), port)))
                .await
            {
                Ok(Ok(stream)) => {
                    let _ = stream.set_nodelay(true);
                    return Ok(stream);
                }
                Ok(Err(e)) => errors.push(format!("{host}: {e}")),
                Err(_) => errors.push(format!("{host}: timed out")),
            }
        }
    }
    Err(format!(
        "Couldn't reach the Apple TV. Keep it on the same network with Settings › Remotes and Devices › Remote App and Devices open. ({})",
        errors.join("; ")
    ))
}

async fn apple_tv_flow(
    hosts: Vec<String>,
    port: u16,
    name: String,
    out_path: String,
    cbs: Callbacks,
    pin_rx: mpsc::UnboundedReceiver<String>,
) -> Result<Paired, Fail> {
    let pin_rx = Arc::new(AsyncMutex::new(pin_rx));
    let mut file = fresh_pairing_file(&name);

    let mut attempt: u32 = 0;
    let peer = loop {
        attempt += 1;
        let stream = connect_any(&hosts, port, Some(&cbs))
            .await
            .map_err(Fail::Error)?;
        let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), &name);
        let pin_asked = Arc::new(AtomicBool::new(false));

        let result = {
            let pin_rx = pin_rx.clone();
            let pin_asked = pin_asked.clone();
            let this_attempt = attempt;
            client
                .connect(&mut file, move || {
                    let pin_rx = pin_rx.clone();
                    let pin_asked = pin_asked.clone();
                    async move {
                        pin_asked.store(true, Ordering::SeqCst);
                        let mut rx = pin_rx.lock().await;
                        while rx.try_recv().is_ok() {} // drop stale PINs
                        cbs.pin_request(this_attempt);
                        match rx.recv().await {
                            Some(pin) => pin,
                            // Never hand an invalid PIN to SRP; wait for cancel.
                            None => std::future::pending::<String>().await,
                        }
                    }
                })
                .await
        };

        match result {
            Ok(()) => match client.paired_peer_device() {
                Ok(peer) => break peer.clone(),
                Err(e) => return Err(Fail::Error(format!("Apple TV pairing failed: {e}"))),
            },
            Err(e) => {
                let rejected = matches!(
                    e,
                    IdeviceError::RemotePairing(RemotePairingError::PairingRejected(_))
                );
                let message = describe_atv_error(&e);
                if pin_asked.load(Ordering::SeqCst) && !rejected && attempt < ATV_PIN_ATTEMPTS {
                    cbs.status(GASSPAIR_STATUS_WRONG_PIN, &message);
                    drop(client);
                    tokio::time::sleep(Duration::from_millis(800)).await;
                    continue;
                }
                return Err(Fail::Error(message));
            }
        }
    };

    // Re-connect and pair-verify with the new credentials, like idevice's own
    // pair_apple_tv tool, so we only report a pairing that actually works.
    cbs.status(GASSPAIR_STATUS_VERIFYING, &peer.name);
    tokio::time::sleep(Duration::from_millis(500)).await;
    let mut probe = file.clone();
    let verified = match tokio::time::timeout(
        ATV_VERIFY_TIMEOUT,
        verify_apple_tv(&hosts, port, &name, &mut probe),
    )
    .await
    {
        Ok(Ok(())) => true,
        Ok(Err(e)) => {
            cbs.status(GASSPAIR_STATUS_VERIFY_FAILED, &e);
            false
        }
        Err(_) => {
            cbs.status(GASSPAIR_STATUS_VERIFY_FAILED, "verification timed out");
            false
        }
    };

    cbs.status(GASSPAIR_STATUS_SAVING, &peer.name);
    save_pairing_file(&file, &out_path).await.map_err(Fail::Error)?;

    Ok(Paired {
        name: peer.name,
        model: peer.model,
        udid: peer.remotepairing_udid,
        path: out_path,
        host_alt_irk_hex: String::new(),
        verified,
    })
}

async fn verify_apple_tv(
    hosts: &[String],
    port: u16,
    name: &str,
    file: &mut RpPairingFile,
) -> Result<(), String> {
    let stream = connect_any(hosts, port, None).await?;
    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), name);
    client
        .attempt_pair_verify()
        .await
        .map_err(|e| format!("handshake failed: {e}"))?;
    client
        .validate_pairing(file)
        .await
        .map_err(|e| format!("pair-verify failed: {e}"))
}

fn describe_atv_error(e: &IdeviceError) -> String {
    match e {
        IdeviceError::RemotePairing(RemotePairingError::SrpAuthFailed) => {
            "Wrong code. Enter the new code shown on the Apple TV.".into()
        }
        IdeviceError::RemotePairing(RemotePairingError::PairingRejected(reason)) => {
            if reason.is_empty() {
                "The Apple TV rejected the pairing.".into()
            } else {
                format!("The Apple TV rejected the pairing: {reason}")
            }
        }
        other => format!("Apple TV pairing failed: {other}"),
    }
}

