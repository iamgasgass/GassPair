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
use idevice::services::lockdown::LockdownClient;
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
pub unsafe extern "C" fn gasspair_string_free(value: *mut c_char) {
    if !value.is_null() { drop(CString::from_raw(value)); }
}

#[no_mangle]
pub extern "C" fn gasspair_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}


/// Experimental classic Lockdown pairing over a caller-supplied TCP route.
/// This is deliberately separate from Remote Pairing and requires an explicit
/// user action in the UI. It only writes a record after Pair and StartSession
/// both succeed. A successful network probe alone never calls this function.
#[no_mangle]
pub unsafe extern "C" fn gasspair_classic_lockdown_pair(
    host: *const c_char,
    out_path: *const c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if host.is_null() || out_path.is_null() || out_error.is_null() {
        return GASSPAIR_ERR_INVALID_ARG;
    }
    *out_error = ptr::null_mut();
    let host = opt_str(host, "");
    let out_path = opt_str(out_path, "");
    if host.is_empty() || out_path.is_empty() || out_path.contains('\0') {
        *out_error = raw_cstr("Invalid host or output path.");
        return GASSPAIR_ERR_INVALID_ARG;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("Could not create async runtime: {e}"))?;
        let local = tokio::task::LocalSet::new();
        local.block_on(&rt, async {
            tokio::time::timeout(Duration::from_secs(35), async {
                let address = if host.contains(':') { format!("[{host}]:62078") } else { format!("{host}:62078") };
                let stream = TcpStream::connect(&address)
                    .await
                    .map_err(|e| format!("TCP connect to {address} failed: {e}"))?;
                let idevice = idevice::Idevice::new(
                    Box::new(stream),
                    "GassPair classic Lockdown pairing",
                );
                let mut lockdown = LockdownClient::new(idevice);
                let service_type = lockdown.idevice.get_type().await
                    .map_err(|e| format!("Lockdown QueryType failed: {e}"))?;
                if service_type != "com.apple.mobile.lockdown" {
                    return Err(format!("Unexpected Lockdown service type: {service_type}"));
                }
                let version = lockdown.get_value(Some("ProductVersion"), None).await
                    .map_err(|e| format!("GetValue(ProductVersion) failed: {e}"))?;
                let version = version.as_string().unwrap_or("unknown").to_string();
                let host_id = uuid::Uuid::new_v4().to_string();
                // A stable BUID is normally managed by usbmuxd. For this isolated
                // on-device experiment, use a valid persisted-format UUID and report it.
                // It is not claimed to be shared with a Mac/usbmuxd pairing database.
                let system_buid = uuid::Uuid::new_v4().to_string();
                let record = match lockdown
                    .pair_once(host_id, system_buid, Some("GassPair LocalDevVPN"))
                    .await
                {
                    Ok(record) => record,
                    Err(idevice::IdeviceError::GetProhibited) => {
                        return Err(format!(
                            "iOS {version} explicitly prohibited classic Lockdown Pair on this connection (GetProhibited). TCP and Lockdown plist diagnostics are working, but the device refuses this pairing method. GassPair will not retry, bypass the refusal, or create a synthetic pairing record. Use Apple's supported Remote Pairing flow for iPhone/iPad; the documented idevicepair -w CU/SRP flow is for Apple TV. No pairing file was written."
                        ));
                    }
                    Err(error) => {
                        return Err(format!(
                            "Classic Lockdown Pair failed on iOS {version}: {error}. No pairing file was written."
                        ));
                    }
                };
                lockdown
                    .start_session(&record)
                    .await
                    .map_err(|e| format!("Pair returned a record, but StartSession TLS verification failed: {e}. No pairing file was written."))?;
                let bytes = record
                    .serialize()
                    .map_err(|e| format!("Could not serialize the verified pairing record: {e}"))?;
                let target = Path::new(&out_path);
                if let Some(parent) = target.parent() {
                    tokio::fs::create_dir_all(parent).await
                        .map_err(|e| format!("Could not create output directory: {e}"))?;
                }
                let tmp = format!("{out_path}.tmp-{}", uuid::Uuid::new_v4());
                tokio::fs::write(&tmp, &bytes).await
                    .map_err(|e| format!("Could not write temporary pairing record: {e}"))?;
                tokio::fs::rename(&tmp, target).await
                    .map_err(|e| { let _ = std::fs::remove_file(&tmp); format!("Could not atomically install pairing record: {e}") })?;
                let readback = tokio::fs::read(target).await
                    .map_err(|e| format!("Could not read back pairing record: {e}"))?;
                idevice::pairing_file::PairingFile::from_bytes(&readback)
                    .map_err(|e| format!("Saved file did not parse as a classic pairing record: {e}"))?;
                Ok::<String, String>(format!("Classic Lockdown Pair and StartSession TLS succeeded on iOS {version}. Saved and re-read verified pairing record: {out_path}. SystemBUID is local to this GassPair attempt; compatibility with usbmuxd/macOS has not been established."))
            }).await.map_err(|_| "Classic Lockdown pairing timed out after 35 seconds. No success is assumed.".to_string())?
        })
    }));
    match result {
        Ok(Ok(message)) => { *out_error = raw_cstr(&message); GASSPAIR_OK }
        Ok(Err(message)) => { *out_error = raw_cstr(&message); GASSPAIR_ERR }
        Err(payload) => { *out_error = raw_cstr(&format!("Caught internal panic: {}", panic_message(payload.as_ref()))); GASSPAIR_ERR }
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

