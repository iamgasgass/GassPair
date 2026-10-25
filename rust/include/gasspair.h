// GassPair FFI — on-device wireless pairing (no computer required).
//
// Built on idevice's remote_pairing (jkcoxson/idevice @ 7bd551c). The mDNS
// advertising of the pairable host is done on the Swift side with NetService
// (mDNSResponder) so the app only needs the Local Network permission, not the
// multicast entitlement.
#ifndef GASSPAIR_H
#define GASSPAIR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Return codes
#define GASSPAIR_OK 0
#define GASSPAIR_ERR 1
#define GASSPAIR_ERR_INVALID_ARG 2
#define GASSPAIR_ERR_CANCELLED 3
#define GASSPAIR_ERR_TIMEOUT 4

// Status codes delivered through GassPairStatusCb
#define GASSPAIR_STATUS_LISTENING 1       // host: message = port
#define GASSPAIR_STATUS_CONNECTED 2       // host: message = peer address
#define GASSPAIR_STATUS_ATTEMPT_FAILED 3  // host: message = reason, still listening
#define GASSPAIR_STATUS_RELISTENING 4     // host: message = new port (re-advertised)
#define GASSPAIR_STATUS_CONNECTING 10     // Apple TV: message = address
#define GASSPAIR_STATUS_WRONG_PIN 11      // Apple TV: a new PIN will be requested
#define GASSPAIR_STATUS_VERIFYING 12      // Apple TV: verifying the pairing
#define GASSPAIR_STATUS_VERIFY_FAILED 13  // Apple TV: message = reason (file still saved)
#define GASSPAIR_STATUS_SAVING 20         // both: writing the pairing file

typedef struct GassPairSession GassPairSession;

// Called (possibly more than once, e.g. after a re-bind) with the service to
// publish as _remotepairing-pairable-host._tcp.
typedef void (*GassPairReadyCb)(void *ctx,
                                const char *service_id,
                                uint16_t port,
                                const char *const *txt_keys,
                                const char *const *txt_vals,
                                size_t txt_count);

// Host flow: the PIN to show the user (one per connection attempt).
typedef void (*GassPairPinCb)(void *ctx, const char *pin);

// Apple TV flow: ask the user for the PIN shown on the TV (attempt starts at 1).
// Answer with gasspair_session_submit_pin.
typedef void (*GassPairPinRequestCb)(void *ctx, uint32_t attempt);

typedef void (*GassPairStatusCb)(void *ctx, int32_t code, const char *message);

typedef struct {
    char *error;
    char *device_name;
    char *device_model;
    char *device_udid;
    char *pairing_file_path;
    char *host_alt_irk_hex;
    int32_t verified;
} GassPairResult;

// Sessions are one-shot: new -> run (on a background thread) -> free.
// cancel / submit_pin may be called from any thread while the run is active.
GassPairSession *gasspair_session_new(void);
void gasspair_session_cancel(GassPairSession *session);
int32_t gasspair_session_submit_pin(GassPairSession *session, const char *pin);
void gasspair_session_free(GassPairSession *session);

// iPhone / iPad (iOS 27+): blocks until paired, cancelled or timed out.
// timeout_secs = 0 means no overall limit.
int32_t gasspair_run_host(GassPairSession *session,
                          const char *name,
                          const char *model,
                          const char *out_path,
                          uint32_t timeout_secs,
                          GassPairReadyCb ready_cb,
                          GassPairPinCb pin_cb,
                          GassPairStatusCb status_cb,
                          void *ctx,
                          GassPairResult *out);

// Apple TV: `hosts` is a newline-separated list of candidate addresses /
// hostnames, tried in order. Blocks until paired, cancelled or failed.
int32_t gasspair_pair_apple_tv(GassPairSession *session,
                               const char *hosts,
                               uint16_t port,
                               const char *name,
                               const char *out_path,
                               GassPairPinRequestCb pin_request_cb,
                               GassPairStatusCb status_cb,
                               void *ctx,
                               GassPairResult *out);

// Create a real RPPairing record through the Lockdown-authenticated
// com.apple.dt.remotepairingdeviced.lockdown service. `port` is normally 62078;
// `lockdown_path` must be an existing, valid Lockdown pairing record for this
// device. Returns success only after a new record passes pair-verify.
int32_t gasspair_create_rp_from_lockdown_endpoint(const char *host, uint16_t port,
                                                   const char *client_name,
                                                   const char *lockdown_path,
                                                   const char *out_path,
                                                   GassPairResult *out);

// Direct RPPairing endpoint operations. Host/port must be the actual RPPairing
// service endpoint, NOT Lockdown TCP/62078. Creation writes only after real
// pair-verify succeeds.
int32_t gasspair_verify_rp_endpoint(const char *host, uint16_t port,
                                    const char *client_name, const char *pairing_path,
                                    GassPairResult *out);
int32_t gasspair_create_rp_endpoint(const char *host, uint16_t port,
                                    const char *client_name, const char *pin,
                                    const char *out_path, GassPairResult *out);

void gasspair_result_free(GassPairResult *r);
const char *gasspair_version(void);

#ifdef __cplusplus
}
#endif

#endif // GASSPAIR_H
