# GassPair

App SwiftUI per iOS che crea il **pairing file Remote (RPPairing) senza computer**. Basata su [idevice](https://github.com/jkcoxson/idevice).

- **Funziona da iOS 16** (bundle id `com.iamgasgass.gasspair`).
- **Su iOS 27+** l'iPhone/iPad può associarsi **a se stesso**.
- **Da iOS 16 a iOS 26** l'app associa una **Apple TV** oppure fa da host per **un altro iPhone/iPad con iOS 27+** sulla stessa Wi-Fi. Un dispositivo con iOS 16–26 non può associarsi a se stesso: la voce «Pair with…» in Modalità sviluppatore esiste solo da iOS 27 (limite di Apple, non dell'app).

## Cosa fa

- **Diagnostica LocalDevVPN** — verifica che un indirizzo instradato dal tunnel raggiunga `lockdownd` su TCP `62078` e risponda al protocollo plist (`QueryType` + `ProductVersion`). Dopo un test positivo, una sezione sperimentale separata permette all’utente di confermare l’invio di una vera richiesta Lockdown `Pair`; il flusso tenta poi `StartSession` TLS e scrive il file solo se la verifica e il read-back riescono.

> **Limite importante su iOS 26.1:** la raggiungibilità di `lockdownd` non abilita automaticamente il pairing classico del dispositivo con sé stesso. La documentazione pubblica di `idevicepair -w` e di `lockdownd_cu_pairing_create` descrive il flusso PIN/CU-SRP come supportato da Apple TV; iPhone/iPad usano il flusso Remote Pairing nelle versioni iOS che lo supportano. LocalDevVPN può cambiare il percorso di rete, ma non aggiunge al demone un protocollo di pairing che il dispositivo non espone. Riferimenti: [idevicepair](https://github.com/libimobiledevice/libimobiledevice/blob/master/docs/idevicepair.1), [lockdownd CU pairing](https://libimobiledevice.org/docs/libimobiledevice/1.4.0/lockdown_8h_a624871ea957a778920ecffe2d75d964f.html).

| Metodo | Come funziona | Dove si inserisce il codice |
| --- | --- | --- |
| **iPhone / iPad** (iOS 27+) | GassPair si annuncia sulla rete locale come "computer" a cui associarsi; il dispositivo stesso si collega da Impostazioni. | Sul dispositivo, in Impostazioni (il codice arriva in notifica, nella Live Activity e negli appunti). |
| **Apple TV** | GassPair si collega all'Apple TV che è sulla schermata di associazione. | In GassPair (il codice è mostrato sull'Apple TV). |
| **Diagnostica LocalDevVPN** | Verifica Lockdown; opzionalmente tenta `Pair` dopo conferma esplicita. | Modalità sperimentale distinta da RPPairing e da CU/SRP. |

Il file risultante si esporta con **Export Pairing File** ed è anche in **File › Sul mio iPhone › GassPair**:

- `rp_pairing_file.plist` — iPhone/iPad
- `appletv_rp_pairing_file.plist` — Apple TV

## Diagnostica LocalDevVPN

1. Connetti LocalDevVPN e attendi lo stato **Connected**. Collega l'iPhone a una rete Wi-Fi effettiva: il progetto LocalDevVPN ha un problema documentato in alcune condizioni di sola rete cellulare.
2. In GassPair tocca **Test LocalDevVPN → Lockdown** e usa il valore **Device/Peer IP** configurato in LocalDevVPN, non il tunnel/interface IP.
3. Inserisci un host, non una rete. Per esempio, `10.7.0.1` è un host; `10.7.0.1/32` è una notazione CIDR. GassPair riconosce e rimuove automaticamente `/32` o `/128`; una subnet come `/24` viene rifiutata invece di essere interpretata arbitrariamente come host.
4. Esegui prima **TCP only**: se non raggiunge `ready`, nessun comando Lockdown viene inviato. Se TCP riesce, esegui **TCP + Lockdown**, che verifica `QueryType` e `GetValue(ProductVersion)`.
5. Puoi condividere il rapporto diagnostico, che include la destinazione normalizzata, le transizioni di `NWConnection`, i byte ricevuti e la fase esatta del timeout.

Un esito positivo della sola diagnostica conferma solo il percorso TCP e il protocollo plist. La modalità sperimentale invia `Request=Pair`, poi tenta `StartSession` TLS e salva un record Lockdown classico solo dopo esito positivo e verifica di rilettura. Non implementa CU/SRP e non garantisce che iOS 26.1 consenta il self-pairing. Il `SystemBUID` generato localmente non è quello di usbmuxd/macOS: compatibilità con il database pairing del Mac non è stabilita. GassPair non può ispezionare o correggere la route Network Extension di LocalDevVPN; se TCP non arriva a `ready`, prima va risolto il trasporto. Il progetto evita deliberatamente di presentare un file speculativo come successo.

## Uso

### iPhone o iPad

1. Apri GassPair e tocca **Pair iPhone or iPad**. Consenti **Rete locale** e **Notifiche**.
2. Sullo stesso dispositivo: **Impostazioni › Privacy e sicurezza › Modalità sviluppatore**, scorri in fondo e tocca **Pair with GassPair**.
3. Inserisci il codice a 6 cifre: lo trovi nella notifica di GassPair, nella Live Activity ed è già copiato negli appunti.
4. Alla notifica "Pairing complete" torna in GassPair e tocca **Export Pairing File**.

Se sbagli il codice non serve ricominciare: tocca di nuovo **Pair with GassPair** e ne arriva uno nuovo (GassPair resta in ascolto). Se la voce non compare, esci e rientra in Modalità sviluppatore oppure tocca **Restart**.

Lascia attivo **Silent audio** (predefinito): tiene GassPair attivo in background mentre sei in Impostazioni, su qualsiasi versione da iOS 16. **Location** è un'alternativa.

### Apple TV

1. Sull'Apple TV: **Impostazioni › Telecomandi e dispositivi › App Remote e dispositivi** (lascia aperta quella schermata).
2. In GassPair tocca **Pair Apple TV** e scegli l'Apple TV (tocca **Refresh** se non compare).
3. Inserisci il codice mostrato sulla TV (si invia da solo alla sesta cifra). Se è sbagliato GassPair ne chiede uno nuovo (fino a 3 tentativi).
4. GassPair verifica il pairing con una seconda connessione e poi tocca **Export Pairing File**.

## Compilare senza PC (GitHub Actions)

Serve solo un account GitHub dal browser del telefono. La build gira sui Mac di GitHub e produce un `GassPair.ipa` non firmato da installare con il tuo strumento di sideload on-device (SideStore, Feather, …).

**Opzione A — dallo zip (la più semplice da telefono)**

1. Crea un repository vuoto su github.com.
2. **Add file › Upload files** → carica `GassPair.zip` nella radice del repo.
3. **Add file › Create new file** → nome `.github/workflows/gasspair-from-zip.yml`, incolla il contenuto di `tools/gasspair-from-zip.yml` (è dentro lo zip) e fai commit.
4. La build parte da sola (oppure **Actions › GassPair build from zip › Run workflow**). Quando è verde, l'IPA è nella sezione **Releases** del repo.

**Opzione B — repository completo**

Carica tutta la cartella (ad es. con l'app iOS *Working Copy*). Il workflow `.github/workflows/build.yml` compila a ogni push; con un tag `v*` allega l'IPA alla release.

### Build locale (facoltativa, su Mac)

```sh
./tools/test-localdevvpn-destination.sh  # host/CIDR parser tests; macOS or Linux with Swift
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./build-rust.sh      # Rust FFI -> GassPairFFI.xcframework
xcodegen generate    # GassPair.xcodeproj
open GassPair.xcodeproj
```

Requisiti per la build iOS: Xcode 27, Rust, `xcodegen`. App minima: **iOS 16**. Il test del parser non richiede Xcode e controlla gli input IPv4/IPv6, CIDR, hostname e input malformati.

## Architettura

- `rust/src/lib.rs` — FFI C su `idevice::remote_pairing` (`rust/include/gasspair.h`). Sessioni cancellabili, listener dual-stack IPv6/IPv4 con riapertura automatica, tentativi di connessione gestiti in parallelo, identificativo host casuale per sessione, 3 tentativi PIN + verifica per Apple TV, scrittura atomica e verificata del file, panic intercettati.
- `App/PairingController.swift` — orchestrazione dei due flussi, annuncio mDNS con `NetService` (basta il permesso Rete locale, niente entitlement multicast), keep-alive con audio silenzioso/posizione + background task UIKit (tutto compatibile iOS 16). Su iOS 26+ l'interfaccia usa Liquid Glass, sotto usa materiali traslucidi.
- `App/AppleTVDiscovery.swift` — ricerca `_remotepairing-manual-pairing._tcp` con indirizzi IPv4/IPv6 risolti.

## Licenza

MIT, **non commerciale**. Libero per uso personale/non commerciale; per uso commerciale contattare StephenDev0@outlook.com. Vedi [LICENSE](LICENSE).


## LocalDevVPN TCP + Lockdown crash fix (2.2.1)

Fixed a `Foundation.Data` index bug in the two-request diagnostic. `Data.removeFirst()` can advance `startIndex`; indexing its next response as `received[0]...received[3]` could trap when `QueryType` succeeded and `GetValue(ProductVersion)` started. The parser now uses indices relative to `startIndex`, rebases data after consuming a frame, and initializes fresh receive buffers for each request. A regression test covers sequential frames and fragmented headers/bodies.

Run `tools/test-lockdown-frame-index.sh` to execute the regression test on a machine with Swift installed. This fix addresses the crash path; it does not imply that classic self-pairing is supported by iOS.


## Classic Lockdown Pair sperimentale (2.3.0)

Dopo `Lockdown is reachable`, la sezione **Experimental classic Lockdown pairing** consente di confermare esplicitamente un tentativo reale `Request=Pair` sull'host configurato. Il backend Rust usa la libreria `idevice`, genera un `HostID` e un `SystemBUID` locali, gestisce gli errori restituiti da Lockdown, tenta `StartSession` TLS e scrive `classic_lockdown_pairing_file.plist` atomicamente solo dopo il successo della sessione e il read-back del plist. Il flusso è distinto dal Remote Pairing (RPPairing).

Limiti: questa è una prova sperimentale e non è stata validata su un iPhone reale in questa build environment. Un `SystemBUID` locale non è quello del Mac/usbmuxd e non è garantito che il file sia importabile nel pairing store del Mac. La funzione non implementa il protocollo CU/SRP di `idevicepair -w`; iOS può rifiutare `Pair` su una connessione self-routed. Non verrà creato alcun file in caso di errore o mancata verifica TLS.


## Rust build fixes (2.3.1)

Corrected the Classic Lockdown Pair backend to match the pinned `idevice` API: `QueryType` is sent through `LockdownClient.idevice.get_type()`, and `start_session` is called with the single `PairingFile` parameter expected by the pinned revision. Added `uuid` as a direct Cargo dependency because the FFI backend calls `uuid::Uuid::new_v4()` for `HostID`, local `SystemBUID`, and temporary filenames.

The Swift regression scripts pass in this environment. A full `cargo build` / Xcode build still must be run by CI or on a machine with the Rust iOS targets and Xcode installed; these source fixes should not be described as a successful device build until that run passes.


### Classic Lockdown Pair refusal (2.3.2)

When the device returns `GetProhibited` to `Request=Pair`, the backend now reports an explicit device-side refusal, does not retry, and does not write a pairing record. A successful TCP/Lockdown diagnostic does not override this refusal. Use the supported Remote Pairing flow for iPhone/iPad; CU/SRP via `idevicepair -w` is documented for Apple TV and is a different protocol.
