#![forbid(unsafe_code)]

//! GassPair macOS companion.
//!
//! This process is intentionally separate from the iOS app. It uses macOS's
//! usbmuxd-backed idevice provider to open `RemotePairingLockdownService`,
//! using a Lockdown pairing file imported from the iPhone. LocalDevVPN only
//! routes traffic between the iPhone and this pinned-TLS endpoint; it does not
//! pretend to implement usbmuxd on iOS.

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use idevice::{
    Idevice, IdeviceError, IdeviceService,
    lockdown::LockdownClient,
    pairing_file::PairingFile,
    provider::{IdeviceProvider, UsbmuxdProvider},
    remote_pairing::{RemotePairingClient, RemotePairingLockdownService, RpPairingFile},
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
};
use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair, SanType, PKCS_ECDSA_P256_SHA256};
use rustls::{
    pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer},
    ServerConfig,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    future::Future,
    net::{IpAddr, SocketAddr},
    path::{Path, PathBuf},
    pin::Pin,
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::Semaphore,
    time::timeout,
};
use tokio_rustls::{server::TlsStream, TlsAcceptor};
use uuid::Uuid;

const API_PATH: &str = "/api/v1";
const MAX_HEADER_BYTES: usize = 16 * 1024;
const MAX_BODY_BYTES: usize = 3 * 1024 * 1024;
const MAX_CONNECTIONS: usize = 4;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(360);
const HOST_LABEL: &str = "GassPair macOS companion";
const REMOTE_PAIRING_PIN: &str = "000000";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ApiRequest {
    action: String,
    token: String,
    #[serde(default)]
    udid: Option<String>,
    #[serde(default)]
    lockdown_pairing_plist_base64: Option<String>,
    #[serde(default)]
    rp_pairing_plist_base64: Option<String>,
    #[serde(default)]
    host_label: Option<String>,
}

#[derive(Debug, Serialize)]
struct DeviceSummary {
    udid: String,
    transport: String,
}

#[derive(Debug, Serialize)]
struct ApiResponse {
    ok: bool,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    devices: Option<Vec<DeviceSummary>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pairing_file_base64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pairing_file_name: Option<String>,
    verified: bool,
}

impl ApiResponse {
    fn success(message: impl Into<String>) -> Self {
        Self {
            ok: true,
            message: message.into(),
            devices: None,
            pairing_file_base64: None,
            pairing_file_name: None,
            verified: false,
        }
    }

    fn failure(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
            devices: None,
            pairing_file_base64: None,
            pairing_file_name: None,
            verified: false,
        }
    }
}

#[derive(Clone)]
struct ServerState {
    token: Arc<String>,
    bind_addr: SocketAddr,
}

/// Delegate actual service-port opens to usbmuxd but override pair-record
/// lookup with the explicit Lockdown plist that the user imported on iOS.
/// This is what a raw `TcpProvider` cannot provide: `connect(port)` calls the
/// Mac's usbmuxd Connect operation for the selected device.
#[derive(Debug)]
struct ImportedLockdownUsbmuxdProvider {
    inner: UsbmuxdProvider,
    pairing_file: PairingFile,
}

impl IdeviceProvider for ImportedLockdownUsbmuxdProvider {
    fn connect(
        &self,
        port: u16,
    ) -> Pin<Box<dyn Future<Output = std::result::Result<Idevice, IdeviceError>> + Send>> {
        self.inner.connect(port)
    }

    fn label(&self) -> &str {
        self.inner.label()
    }

    fn get_pairing_file(
        &self,
    ) -> Pin<Box<dyn Future<Output = std::result::Result<PairingFile, IdeviceError>> + Send>> {
        let pairing_file = self.pairing_file.clone();
        Box::pin(async move { Ok(pairing_file) })
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let (bind_addr, data_dir) = parse_args()?;
    if !is_safe_bind_ip(bind_addr.ip()) {
        return Err(anyhow!(
            "Refusing to bind to {}. Bind to a specific private/ULA/link-local LocalDevVPN or LAN interface; wildcard and loopback addresses are not allowed.",
            bind_addr.ip()
        ));
    }

    tokio::fs::create_dir_all(&data_dir).await?;
    set_private_dir_permissions(&data_dir)?;
    let token = load_or_create_token(&data_dir)?;
    let (cert_der, key_der) = load_or_create_identity(&data_dir, bind_addr.ip())?;
    let fingerprint = sha256_hex(&cert_der);
    let config = build_tls_config(cert_der, key_der)?;
    let listener = TcpListener::bind(bind_addr)
        .await
        .with_context(|| format!("Could not bind companion listener to {bind_addr}"))?;

    println!("GassPair usbmuxd companion ready");
    println!("Bind: https://{bind_addr}{API_PATH}");
    println!("TLS certificate SHA-256 fingerprint: {fingerprint}");
    println!("Access token file: {}", data_dir.join("access-token.txt").display());
    println!("The iOS app must pin the fingerprint and provide the access token.");
    println!("Only connected devices visible to this Mac's usbmuxd can be selected.");
    println!("Pairing files and request bodies are never logged.");

    let acceptor = TlsAcceptor::from(config);
    let state = ServerState { token: Arc::new(token), bind_addr };
    let permits = Arc::new(Semaphore::new(MAX_CONNECTIONS));

    loop {
        let (socket, peer) = listener.accept().await?;
        let permit = match permits.clone().try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => {
                eprintln!("Rejected connection from {peer}: companion is busy");
                drop(socket);
                continue;
            }
        };
        let acceptor = acceptor.clone();
        let state = state.clone();
        tokio::spawn(async move {
            let _permit = permit;
            if let Err(error) = timeout(REQUEST_TIMEOUT, handle_connection(socket, acceptor, state)).await
                .map_err(|_| anyhow!("request timed out"))
                .and_then(|result| result)
            {
                // Never log request bodies, pair files, tokens, or private keys.
                eprintln!("Companion request from {peer} failed: {error:#}");
            }
        });
    }
}

fn parse_args() -> Result<(SocketAddr, PathBuf)> {
    let mut args = std::env::args().skip(1);
    let mut bind = None;
    let mut data_dir = default_data_dir()?;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--bind" => bind = Some(args.next().ok_or_else(|| anyhow!("--bind requires IP:PORT"))?),
            "--data-dir" => data_dir = PathBuf::from(args.next().ok_or_else(|| anyhow!("--data-dir requires a path"))?),
            "--help" | "-h" => {
                println!("Usage: gasspair-usbmuxd-companion --bind <private-IP:PORT> [--data-dir <path>]");
                println!("Example: gasspair-usbmuxd-companion --bind 10.7.0.2:47821");
                println!("The bind address must be a specific private interface address, not 0.0.0.0 or 127.0.0.1.");
                std::process::exit(0);
            }
            other => return Err(anyhow!("Unknown argument {other:?}; use --help")),
        }
    }
    let bind: SocketAddr = bind.ok_or_else(|| anyhow!("--bind is required. Bind to the Mac's actual LocalDevVPN/LAN IP and a dedicated port."))?
        .parse().context("--bind must be an IP:PORT socket address")?;
    Ok((bind, data_dir))
}

fn default_data_dir() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").ok_or_else(|| anyhow!("HOME is not set"))?;
    Ok(PathBuf::from(home).join("Library/Application Support/GassPairCompanion"))
}

fn is_safe_bind_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => !ip.is_unspecified() && !ip.is_loopback() && (ip.is_private() || ip.is_link_local()),
        IpAddr::V6(ip) => {
            let first = ip.segments()[0];
            !ip.is_unspecified() && !ip.is_loopback() && ((first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80)
        }
    }
}

fn load_or_create_token(data_dir: &Path) -> Result<String> {
    let path = data_dir.join("access-token.txt");
    if path.exists() {
        let token = std::fs::read_to_string(&path).context("Could not read access-token.txt")?;
        let token = token.trim().to_owned();
        if token.len() < 48 {
            return Err(anyhow!("Existing access-token.txt is too short; remove it and restart to rotate the token."));
        }
        return Ok(token);
    }
    let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    std::fs::write(&path, format!("{token}\n")).context("Could not save access token")?;
    set_private_file_permissions(&path)?;
    println!("New access token (copy into GassPair now): {token}");
    Ok(token)
}

fn load_or_create_identity(data_dir: &Path, ip: IpAddr) -> Result<(Vec<u8>, Vec<u8>)> {
    let safe_ip = ip.to_string().replace(':', "_").replace('.', "_");
    let cert_path = data_dir.join(format!("server-{safe_ip}.cert.der"));
    let key_path = data_dir.join(format!("server-{safe_ip}.key.der"));
    if cert_path.exists() && key_path.exists() {
        return Ok((std::fs::read(cert_path)?, std::fs::read(key_path)?));
    }

    let mut params = CertificateParams::default();
    params.subject_alt_names = vec![SanType::IpAddress(ip)];
    let mut distinguished_name = DistinguishedName::new();
    distinguished_name.push(DnType::CommonName, "GassPair usbmuxd companion");
    params.distinguished_name = distinguished_name;
    let key_pair = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256)
        .context("Could not create companion TLS key")?;
    let certificate = params.self_signed(&key_pair)
        .context("Could not create companion TLS certificate")?;
    let cert_der = certificate.der().as_ref().to_vec();
    let key_der = key_pair.serialize_der();
    std::fs::write(&cert_path, &cert_der)?;
    std::fs::write(&key_path, &key_der)?;
    set_private_file_permissions(&cert_path)?;
    set_private_file_permissions(&key_path)?;
    Ok((cert_der, key_der))
}

fn build_tls_config(cert_der: Vec<u8>, key_der: Vec<u8>) -> Result<Arc<ServerConfig>> {
    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let config = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .context("Could not set safe TLS protocol versions")?
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(cert_der)],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key_der)),
        )
        .context("Could not configure pinned TLS certificate")?;
    let mut config = config;
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(Arc::new(config))
}

fn sha256_hex(data: &[u8]) -> String {
    Sha256::digest(data).iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(unix)]
fn set_private_file_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}
#[cfg(not(unix))]
fn set_private_file_permissions(_path: &Path) -> Result<()> { Ok(()) }

#[cfg(unix)]
fn set_private_dir_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}
#[cfg(not(unix))]
fn set_private_dir_permissions(_path: &Path) -> Result<()> { Ok(()) }

async fn handle_connection(socket: TcpStream, acceptor: TlsAcceptor, state: ServerState) -> Result<()> {
    let mut stream = timeout(Duration::from_secs(10), acceptor.accept(socket))
        .await.context("TLS handshake timed out")??;
    let (method, path, body) = read_http_request(&mut stream).await?;
    if method != "POST" || path != API_PATH {
        write_http_json(&mut stream, 404, &ApiResponse::failure("Unknown endpoint." )).await?;
        return Ok(());
    }
    let request: ApiRequest = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(_) => {
            write_http_json(&mut stream, 400, &ApiResponse::failure("Invalid API request JSON." )).await?;
            return Ok(());
        }
    };
    if !constant_time_equal(request.token.as_bytes(), state.token.as_bytes()) {
        write_http_json(&mut stream, 401, &ApiResponse::failure("Companion access token rejected." )).await?;
        return Ok(());
    }

    let response = match request.action.as_str() {
        "list_devices" => match list_devices().await {
            Ok(devices) => {
                let mut response = ApiResponse::success(format!("Found {} device(s) visible to this Mac's usbmuxd.", devices.len()));
                response.devices = Some(devices);
                response
            }
            Err(error) => ApiResponse::failure(format!("usbmuxd device enumeration failed: {error:#}")),
        },
        "create_rppairing" => match create_rppairing(&request).await {
            Ok((bytes, message)) => {
                let mut response = ApiResponse::success(message);
                response.pairing_file_base64 = Some(BASE64.encode(bytes));
                response.pairing_file_name = Some("rp_pairing_file_from_lockdown_verified.plist".into());
                response.verified = true;
                response
            }
            Err(error) => ApiResponse::failure(format!("RPPairing creation failed: {error:#}. No verified record was returned.")),
        },
        "verify_rppairing" => match verify_rppairing(&request).await {
            Ok(message) => {
                let mut response = ApiResponse::success(message);
                response.verified = true;
                response
            }
            Err(error) => ApiResponse::failure(format!("RPPairing verification failed: {error:#}. No verified copy was returned.")),
        },
        _ => ApiResponse::failure("Unsupported action. Use list_devices, create_rppairing, or verify_rppairing."),
    };
    let status = if response.ok { 200 } else { 400 };
    write_http_json(&mut stream, status, &response).await?;
    let _ = state.bind_addr; // retained for future structured audit metadata; never log secrets.
    Ok(())
}

fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() { return false; }
    let mut diff = 0u8;
    for (a, b) in left.iter().zip(right) { diff |= a ^ b; }
    diff == 0
}

async fn read_http_request<S: AsyncRead + Unpin>(stream: &mut S) -> Result<(String, String, Vec<u8>)> {
    let mut raw = Vec::with_capacity(8192);
    let mut chunk = [0u8; 8192];
    let header_end = loop {
        if let Some(index) = raw.windows(4).position(|window| window == b"\r\n\r\n") {
            break index;
        }
        if raw.len() > MAX_HEADER_BYTES { return Err(anyhow!("HTTP headers exceed safety limit")); }
        let read = stream.read(&mut chunk).await?;
        if read == 0 { return Err(anyhow!("connection closed before HTTP headers completed")); }
        raw.extend_from_slice(&chunk[..read]);
    };
    if header_end > MAX_HEADER_BYTES { return Err(anyhow!("HTTP headers exceed safety limit")); }
    let header_text = std::str::from_utf8(&raw[..header_end]).context("HTTP headers are not UTF-8")?;
    let mut lines = header_text.split("\r\n");
    let mut request_line = lines.next().unwrap_or_default().split_whitespace();
    let method = request_line.next().unwrap_or_default().to_string();
    let path = request_line.next().unwrap_or_default().to_string();
    if method.is_empty() || path.is_empty() { return Err(anyhow!("malformed HTTP request line")); }
    let mut content_length = None;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = Some(value.trim().parse::<usize>().context("invalid Content-Length")?);
            }
            if name.eq_ignore_ascii_case("transfer-encoding") { return Err(anyhow!("chunked transfer encoding is not supported")); }
        }
    }
    let content_length = content_length.ok_or_else(|| anyhow!("Content-Length is required"))?;
    if content_length > MAX_BODY_BYTES { return Err(anyhow!("request body exceeds {} byte safety limit", MAX_BODY_BYTES)); }
    let body_start = header_end + 4;
    let mut body = raw.get(body_start..).unwrap_or_default().to_vec();
    body.truncate(content_length);
    while body.len() < content_length {
        let need = (content_length - body.len()).min(chunk.len());
        let read = stream.read(&mut chunk[..need]).await?;
        if read == 0 { return Err(anyhow!("connection closed before request body completed")); }
        body.extend_from_slice(&chunk[..read]);
    }
    Ok((method, path, body))
}

async fn write_http_json(stream: &mut TlsStream<TcpStream>, status: u16, response: &ApiResponse) -> Result<()> {
    let body = serde_json::to_vec(response)?;
    let phrase = match status { 200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found", _ => "Error" };
    let headers = format!(
        "HTTP/1.1 {status} {phrase}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n",
        body.len()
    );
    stream.write_all(headers.as_bytes()).await?;
    stream.write_all(&body).await?;
    stream.shutdown().await?;
    Ok(())
}

async fn list_devices() -> Result<Vec<DeviceSummary>> {
    let mut connection = UsbmuxdConnection::default().await.context("Could not connect to local usbmuxd")?;
    let devices = connection.get_devices().await.context("usbmuxd GetDeviceList failed")?;
    Ok(devices.into_iter().map(|device| DeviceSummary {
        udid: device.udid,
        transport: format!("{:?}", device.connection_type),
    }).collect())
}

fn host_label() -> String {
    format!("GassPair-{}", Uuid::new_v4().simple().to_string()[..8].to_owned())
}

fn imported_provider(device: &idevice::usbmuxd::UsbmuxdDevice, pair_record: PairingFile) -> ImportedLockdownUsbmuxdProvider {
    let label = host_label();
    ImportedLockdownUsbmuxdProvider {
        inner: device.to_provider(UsbmuxdAddr::default(), label),
        pairing_file: pair_record,
    }
}

async fn open_trusted_provider(udid: &str, lockdown_bytes: &[u8]) -> Result<ImportedLockdownUsbmuxdProvider> {
    if udid.trim().is_empty() { return Err(anyhow!("Select a device UDID from the companion's usbmuxd device list.")); }
    let pair_record = PairingFile::from_bytes(lockdown_bytes).context("Imported Lockdown.plist is invalid or missing required certificates/keys")?;
    if let Some(record_udid) = pair_record.udid.as_deref() {
        if !record_udid.eq_ignore_ascii_case(udid) {
            return Err(anyhow!("Imported Lockdown record UDID does not match the selected target device."));
        }
    }
    let mut connection = UsbmuxdConnection::default().await.context("Could not connect to local macOS usbmuxd")?;
    let devices = connection.get_devices().await.context("usbmuxd GetDeviceList failed")?;
    let device = devices.into_iter().find(|device| device.udid.eq_ignore_ascii_case(udid))
        .ok_or_else(|| anyhow!("Device {udid} is not currently visible to macOS usbmuxd. Confirm Wi-Fi pairing/network discovery works in idevice_pair and refresh the device list."))?;
    Ok(imported_provider(&device, pair_record))
}

async fn verify_lockdown_trust(provider: &dyn IdeviceProvider, expected_udid: &str) -> Result<String> {
    let mut lockdown = timeout(Duration::from_secs(25), LockdownClient::connect(provider))
        .await.context("Lockdown connection/StartSession with imported trust timed out")??;
    let actual_udid = lockdown.get_value(Some("UniqueDeviceID"), None).await?
        .as_string().map(str::to_owned)
        .ok_or_else(|| anyhow!("Lockdown did not return UniqueDeviceID as a string"))?;
    if !actual_udid.eq_ignore_ascii_case(expected_udid) {
        return Err(anyhow!("Authenticated Lockdown session resolved to a different UDID than requested."));
    }
    let version = lockdown.get_value(Some("ProductVersion"), None).await?
        .as_string().map(str::to_owned).unwrap_or_else(|| "unknown".into());
    Ok(version)
}

async fn create_rppairing(request: &ApiRequest) -> Result<(Vec<u8>, String)> {
    let udid = request.udid.as_deref().ok_or_else(|| anyhow!("udid is required"))?;
    let lockdown_b64 = request.lockdown_pairing_plist_base64.as_deref().ok_or_else(|| anyhow!("lockdown_pairing_plist_base64 is required"))?;
    let lockdown_bytes = BASE64.decode(lockdown_b64).context("Lockdown plist base64 is invalid")?;
    if lockdown_bytes.len() > 2 * 1024 * 1024 { return Err(anyhow!("Lockdown plist exceeds 2 MiB")); }
    let provider = open_trusted_provider(udid, &lockdown_bytes).await?;
    let version = verify_lockdown_trust(&provider, udid).await
        .context("Imported Lockdown trust was not accepted by this target over the Mac's usbmuxd provider")?;
    let label = request.host_label.as_deref().filter(|value| !value.trim().is_empty()).unwrap_or(HOST_LABEL);

    let mut pairing_file = RpPairingFile::generate(label);
    // Match the upstream idevice_pair remote_file() flow. It opens the private
    // usbmuxd-backed service twice: first to establish remote pairing, then to
    // persist/confirm that record on the peer. A raw TCP socket to Lockdown
    // port 62078 cannot replace either dynamically opened service connection.
    let create = async {
        for stage in ["Pairing through Lockdown", "Saving the pairing on the device"] {
            let service = RemotePairingLockdownService::connect(&provider).await
                .context("usbmuxd could not open com.apple.dt.remotepairingdeviced.lockdown")?;
            let mut client = service.into_client(label).context("Could not initialise RPPairing client")?;
            client.connect(&mut pairing_file, || async { REMOTE_PAIRING_PIN.to_string() }).await
                .with_context(|| format!("RemotePairingLockdownService failed during '{stage}'"))?;
        }
        Ok::<(), anyhow::Error>(())
    };
    timeout(Duration::from_secs(240), create).await.context("RPPairing setup/save sequence exceeded 240 seconds")??;

    // A third, fresh verify-only service session prevents us from publishing a
    // record merely because setup/save returned successfully. It never falls back to setup.
    let verify = async {
        let service = RemotePairingLockdownService::connect(&provider).await
            .context("usbmuxd could not reopen RemotePairingLockdownService for verification")?;
        let mut client = service.into_client(label).context("Could not initialise verification client")?;
        client.attempt_pair_verify().await.context("Remote RPPairing attemptPairVerify failed")?;
        client.validate_pairing(&mut pairing_file).await.context("Remote RPPairing validate_pairing failed")?;
        Ok::<(), anyhow::Error>(())
    };
    timeout(Duration::from_secs(30), verify).await.context("RPPairing pair-verify exceeded 30 seconds")??;

    let bytes = pairing_file.to_bytes();
    RpPairingFile::from_bytes(&bytes).context("The serialized RPPairing file did not pass read-back parsing")?;
    Ok((bytes, format!("Created RPPairing for device {udid} (iOS {version}) using macOS usbmuxd and imported Lockdown trust; a fresh RPPairing pair-verify passed.")))
}

async fn verify_rppairing(request: &ApiRequest) -> Result<String> {
    let udid = request.udid.as_deref().ok_or_else(|| anyhow!("udid is required"))?;
    let lockdown_b64 = request.lockdown_pairing_plist_base64.as_deref().ok_or_else(|| anyhow!("lockdown_pairing_plist_base64 is required"))?;
    let rp_b64 = request.rp_pairing_plist_base64.as_deref().ok_or_else(|| anyhow!("rp_pairing_plist_base64 is required"))?;
    let lockdown_bytes = BASE64.decode(lockdown_b64).context("Lockdown plist base64 is invalid")?;
    let rp_bytes = BASE64.decode(rp_b64).context("RPPairing plist base64 is invalid")?;
    if lockdown_bytes.len() > 2 * 1024 * 1024 || rp_bytes.len() > 1024 * 1024 {
        return Err(anyhow!("One of the pairing files exceeds its safety limit"));
    }
    let mut pairing_file = RpPairingFile::from_bytes(&rp_bytes).context("Imported RPPairing plist is invalid")?;
    let provider = open_trusted_provider(udid, &lockdown_bytes).await?;
    verify_lockdown_trust(&provider, udid).await.context("Imported Lockdown trust failed over usbmuxd")?;
    let operation = async {
        let service = RemotePairingLockdownService::connect(&provider).await
            .context("usbmuxd could not open RemotePairingLockdownService")?;
        let mut client: RemotePairingClient<_> = service.into_client(HOST_LABEL)
            .context("Could not initialise RPPairing verification client")?;
        client.attempt_pair_verify().await.context("RPPairing attemptPairVerify failed")?;
        client.validate_pairing(&mut pairing_file).await.context("RPPairing validate_pairing failed")?;
        Ok::<(), anyhow::Error>(())
    };
    timeout(Duration::from_secs(30), operation).await.context("RPPairing verification timed out")??;
    Ok(format!("Imported RPPairing record passed pair-verify and validate_pairing on device {udid}."))
}
