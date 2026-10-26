# GassPair

App SwiftUI per iOS che crea il **pairing file Remote (RPPairing) senza computer**. Basata su [idevice](https://github.com/jkcoxson/idevice).

- **Funziona da iOS 16** (bundle id `com.iamgasgass.gasspair`).
- **Su iOS 27+** l'iPhone/iPad può associarsi **a se stesso**.
- **Da iOS 16 a iOS 26** l'app associa una **Apple TV** oppure fa da host per **un altro iPhone/iPad con iOS 27+** sulla stessa Wi-Fi. Un dispositivo con iOS 16–26 non può associarsi a se stesso: la voce «Pair with…» in Modalità sviluppatore esiste solo da iOS 27 (limite di Apple, non dell'app).

## Importare un file RPPairing esistente

La schermata principale include **Import / Validate RP Pairing File**. Accetta un plist esistente, controlla che sia un dizionario con `public_key`, `private_key`, `identifier` e `alt_irk`, verifica le lunghezze (32, 32, UUID valido e 16 byte) e controlla che la chiave pubblica Ed25519 corrisponda alla chiave derivata dalla chiave privata. Se supera i controlli, il file originale viene copiato atomicamente in Documents come `rp_pairing_file_imported.plist`.

**Importante:** questo è un controllo locale d'integrità, non un `pair-verify` remoto. La verifica remota richiede un endpoint RPPairing effettivo (host/porta e ruolo del peer corretti); la porta Lockdown `62078` non è un endpoint RPPairing e non va usata per questo test. Il codice non inventa credenziali né dichiara verificato un record soltanto perché il plist è valido.

I file di pairing contengono una chiave privata e devono essere trattati come segreti. Non incollare chiavi private in issue, log o repository. Poiché la chiave privata inclusa in una conversazione va considerata esposta, genera una nuova identità/record dal client autorizzato e revoca o sostituisci quella precedente prima di usarla per un pairing sensibile.

## Cosa fa

| Metodo | Come funziona | Dove si inserisce il codice |
| --- | --- | --- |
| **iPhone / iPad** (iOS 27+) | GassPair si annuncia sulla rete locale come "computer" a cui associarsi; il dispositivo stesso si collega da Impostazioni. | Sul dispositivo, in Impostazioni (il codice arriva in notifica, nella Live Activity e negli appunti). |
| **Apple TV** | GassPair si collega all'Apple TV che è sulla schermata di associazione. | In GassPair (il codice è mostrato sull'Apple TV). |

Il file risultante si esporta con **Export Pairing File** ed è anche in **File › Sul mio iPhone › GassPair**:

- `rp_pairing_file.plist` — iPhone/iPad
- `appletv_rp_pairing_file.plist` — Apple TV

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
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./build-rust.sh      # Rust FFI -> GassPairFFI.xcframework
xcodegen generate    # GassPair.xcodeproj
open GassPair.xcodeproj
```

Requisiti per compilare: Xcode 27, Rust, `xcodegen`. App minima: **iOS 16**.

## Architettura

- `rust/src/lib.rs` — FFI C su `idevice::remote_pairing` (`rust/include/gasspair.h`). Sessioni cancellabili, listener dual-stack IPv6/IPv4 con riapertura automatica, tentativi di connessione gestiti in parallelo, identificativo host casuale per sessione, 3 tentativi PIN + verifica per Apple TV, scrittura atomica e verificata del file, panic intercettati.
- `App/PairingController.swift` — orchestrazione dei due flussi, annuncio mDNS con `NetService` (basta il permesso Rete locale, niente entitlement multicast), keep-alive con audio silenzioso/posizione + background task UIKit (tutto compatibile iOS 16). Su iOS 26+ l'interfaccia usa Liquid Glass, sotto usa materiali traslucidi.
- `App/AppleTVDiscovery.swift` — ricerca `_remotepairing-manual-pairing._tcp` con indirizzi IPv4/IPv6 risolti.
- `rust/src/embedded_mux.rs` + `App/IntegratedUsbmuxdCompanion*.swift` — companion usbmuxd integrato (2.4.0): provider in-app equivalente a usbmuxd `Connect`, ricerca automatica del dispositivo, RPPairing a due passaggi + verifica indipendente.

## Licenza

MIT, **non commerciale**. Libero per uso personale/non commerciale; per uso commerciale contattare StephenDev0@outlook.com. Vedi [LICENSE](LICENSE).


## Versione 2.2.0 — import e controllo locale RPPairing

- Aggiunto import tramite il selettore file di iOS.
- Convalida del formato plist, campi richiesti, dimensioni delle chiavi, UUID, lunghezza `alt_irk` e coerenza della coppia Ed25519.
- Copia atomica del file importato, mantenendo separato il record importato dai pairing generati dall'app.
- Messaggio esplicito che distingue validazione locale da verifica di rete `pair-verify`.

Non è stato aggiunto un `pair-verify` arbitrario contro `10.7.0.1:62078`: quello è il servizio Lockdown classico, non un endpoint RPPairing. Per implementare la verifica remota effettiva bisogna usare l'endpoint/ruolo del servizio RPPairing esposto dal dispositivo e le API supportate dalla versione upstream di `idevice`.


## Versione 2.3.0 — operazioni RPPairing remote

Aggiunti due endpoint FFI che usano il client `idevice::remote_pairing` contro un vero servizio RPPairing TCP:

- `gasspair_verify_rp_endpoint`: legge un `RpPairingFile` esistente, esegue `attempt_pair_verify` e `validate_pairing`, e restituisce successo solo se entrambi passano.
- `gasspair_create_rp_endpoint`: esegue il protocollo RPPairing con PIN sul servizio indicato, apre una seconda connessione e verifica il record prima di salvarlo atomicamente.

La UI accetta host, porta e PIN, permette di creare e verificare record e indica il percorso di output. L'host/porta devono identificare il servizio RPPairing effettivo (ad esempio il servizio pubblicizzato dal peer); `10.7.0.1:62078` è Lockdown classico e non funzionerà come endpoint RPPairing. LocalDevVPN può fornire routing verso un endpoint, ma non trasforma Lockdown in RPPairing e non bypassa l'autenticazione. Il flusso richiede che il peer remoto esponga RPPairing e mostri/accetti il PIN previsto dal protocollo.

La creazione salva il file soltanto dopo un pair-verify riuscito. La verifica usa il file importato `rp_pairing_file_imported.plist`; la creazione salva `rp_pairing_file_remote_verified.plist`. Le chiavi private restano locali e non sono scritte nei log.

### Limiti di verifica della build

I test statici e il parsing Swift sono eseguiti nel repository di sviluppo. La build Cargo per target iOS/Xcode e il test end-to-end contro un endpoint RPPairing reale devono ancora essere eseguiti in CI o su dispositivo; non vengono dichiarati riusciti da questa integrazione sorgente.


## Build fix 2.3.1 — Swift C-FFI import

The remote RPPairing actions in `ContentView.swift` call `GassPairResult`, `gasspair_create_rp_endpoint`, `gasspair_verify_rp_endpoint`, and `gasspair_result_free`. These declarations are supplied by the generated `GassPairFFI` Clang module (from `rust/include/gasspair.h` and the `GassPairFFI.xcframework` built by `build-rust.sh`). Swift imports are file-scoped, so importing `GassPairFFI` in `PairingController.swift` does not expose its declarations in `ContentView.swift`. Version 2.3.1 imports the module directly in `ContentView.swift` and adds a regression check for this integration.


## Importazione RPPairing senza chiedere il PIN (2.3.2)

Quando importi un plist RPPairing valido, GassPair passa automaticamente alla modalità **Verify imported + pair-verify + save** e nasconde il campo PIN. Il PIN di sei cifre non è contenuto nel pairing plist: il file persiste `public_key`, `private_key`, `identifier` e `alt_irk`; il PIN è un codice temporaneo di pair-setup. Per un record già esistente, l'app esegue `pair-verify` contro l'endpoint configurato senza iniziare un nuovo pair-setup e, solo dopo l'esito remoto positivo, copia atomicamente il file in `rp_pairing_file_imported_verified.plist`, rilegge il file e ne confronta i byte. Il file importato originale non viene modificato.

Se non hai importato un record, GassPair mostra invece il campo PIN e il flusso **Create new + pair-verify + save**: la nuova creazione richiede il codice temporaneo fornito dal servizio remoto, non può ricavarlo da un altro plist. Usa solo l'endpoint RPPairing effettivo; la porta Lockdown `62078` non è il servizio RPPairing.


## Create RPPairing from an imported Lockdown trust record (2.3.4)

Historical note (superseded by 2.3.6): an earlier implementation attempted to use `TcpProvider` to reach the private service. This was not equivalent to the usbmuxd-backed upstream transport and could fail with `device socket io failed`. Version 2.3.6 disables that incompatible attempt; see `docs/USBMUXD-TRANSPORT.md`.


### Import Lockdown trust and create a new RPPairing record (2.3.4)

Historical note (superseded by 2.3.6): the previous UI described direct TCP creation as if it reproduced the upstream usbmuxd route. It did not. The current UI and backend report the transport requirement and do not attempt creation over that unsupported path.


## Lockdown-trust RPPairing status and diagnostics (2.3.4)

The **Create RPPairing from trusted Lockdown record** card now displays progress and final errors in-place instead of writing the result only in the separate remote-endpoint card lower in the scroll view. Rust reports each stage over the FFI callback: Lockdown plist loading, authenticated Lockdown/service open, RPPairing create/confirm, fresh pair-verify, and atomic save. The service-open and verification stages have individual timeouts and explain if the Lockdown port is reachable but the secondary service socket is not reachable through the selected route. Other RPPairing actions are disabled during this job so two writes cannot race on the same output record.

The operation now uses `fresh_pairing_file(&name)` so each new RPPairing attempt gets a fresh identifier derived from the newly generated key, instead of reusing the deterministic identifier from `RpPairingFile::generate("GassPair")`. The file is still published only after independent pair-verify succeeds. A timeout or error is shown inside the button card with recent stage history; no success is claimed and no new verified file is exported.


## RPPairing service-socket diagnostics (2.3.5)

Historical note (superseded by 2.3.6): the staged direct-TCP diagnostic flow has been removed from the creation path because it cannot reproduce usbmuxd device-socket semantics.

This is a diagnostic and compatibility improvement, not a claim that the private service is supported over raw TCP. Upstream `idevice_pair` uses its `usbmuxd` link for `RemotePairingLockdownService`; Wi-Fi visibility in macOS can still be mediated by usbmuxd. LocalDevVPN routes IP packets and does not itself implement usbmuxd service multiplexing. If Lockdown on TCP/62078 works but the internal service socket or its first RPPairing exchange fails, no record is saved. The message will include the actual failing stage and dynamic port when available, so we can tell if the next step requires a usbmuxd-backed helper rather than more changes to the PIN/crypto exchange.

LocalDevVPN by itself is not that companion: a separate usbmuxd-backed macOS component is required to reproduce the upstream service transport.


## Versione 2.3.7 — companion macOS con provider usbmuxd

La creazione RPPairing dal `Lockdown.plist` importato ora passa attraverso il companion macOS incluso in `companion/`, perché `RemotePairingLockdownService` deve essere aperto con un provider usbmuxd e non con una `TcpProvider` diretta su iOS. Il client iOS usa TLS con pin SHA-256 del certificato e token d'accesso; il companion controlla che il record Lockdown apra una sessione TLS per l'UDID scelto, apre il servizio RPPairing tramite usbmuxd, replica la sequenza upstream in due passaggi (pairing e salvataggio sul dispositivo), quindi esegue `attempt_pair_verify` + `validate_pairing` su una terza connessione indipendente. Il file viene restituito e salvato sul telefono soltanto dopo il successo di tutte le verifiche.

### Compilare ed avviare il companion sul Mac

Sul Mac che vede l'iPhone in usbmuxd attraverso Wi-Fi/rete (la connessione usbmuxd wireless deve essere già attiva; USB non è necessaria se il dispositivo è già visibile):

```sh
cargo build --release --manifest-path companion/Cargo.toml
./companion/target/release/gasspair-usbmuxd-companion --bind <IP-MAC-RAGGIUNGIBILE>:47821
```

Al primo avvio il companion stampa il fingerprint SHA-256 del certificato TLS e genera un token d'accesso; il token è conservato con permessi restrittivi in `~/Library/Application Support/GassPairCompanion/access-token.txt`. Inserisci host, porta, fingerprint e token in **macOS usbmuxd companion** in GassPair. Il bind deve essere l'IP reale del Mac raggiungibile dall'iPhone, non l'IP dell'iPhone usato nei test precedenti. Il servizio rifiuta wildcard e loopback, richiede TLS pinning e token e non scrive le pairing keys nei log.

Dopo aver inserito i parametri, premi **Connect securely and list usbmuxd devices**, seleziona il corretto UDID, importa il Lockdown.plist fidato e scegli **Create + pair-verify + save via usbmuxd**. Per verificare un RPPairing esistente usa la funzione Verify: non avvia un nuovo pair-setup.

Il companion usa la libreria upstream `idevice` e l'API `UsbmuxdProvider`; LocalDevVPN fornisce solo la route IP verso il Mac. Se l'iPhone non è visibile al Mac tramite usbmuxd o il Lockdown record non apre TLS per quel dispositivo, l'operazione si ferma senza restituire un file. Il flusso end-to-end deve essere confermato su un Mac reale e un iPhone reale; i test statici non sostituiscono questa prova.


## Versione 2.3.8 — sequenza RPPairing upstream

Il companion macOS ora replica la sequenza a due connessioni usata da `idevice_pair::remote_file()` per il servizio `com.apple.dt.remotepairingdeviced.lockdown`: “Pairing through Lockdown” e “Saving the pairing on the device”. Dopo questi passaggi apre una terza connessione usbmuxd dedicata esclusivamente alla verifica `attempt_pair_verify` + `validate_pairing`. Il record viene restituito solo dopo il superamento della verifica indipendente. Il timeout di setup/save è stato aumentato a 240 secondi per coprire entrambe le operazioni.


## Versione 2.4.0 — Companion usbmuxd integrato (niente Mac)

Il companion usbmuxd ora è **dentro l'app** e fa tutto da solo. Non servono più Mac, IP, fingerprint, token o scelta dell'UDID.

**Uso:** importa il `Lockdown.plist` (schermata principale › *Import Lockdown.plist*). Si apre **usbmuxd (integrated)** e parte automaticamente:

1. trova il dispositivo provando, in ordine, l'eventuale indirizzo extra, **LocalDevVPN `10.7.0.1`** e gli indirizzi Wi‑Fi del dispositivo; il primo che accetta una sessione Lockdown autenticata col record importato vince (UDID, nome, modello e versione iOS vengono letti da Lockdown e l'UDID deve coincidere con quello del record);
2. se il dispositivo non è raggiungibile (LocalDevVPN spento, altra rete) **riprova da solo** (5 → 30 s) e subito quando torni nell'app;
3. apre `com.apple.dt.remotepairingdeviced.lockdown`, esegue i due passaggi upstream («Pairing through Lockdown», «Saving the pairing on the device») e poi una **terza connessione** solo per `attempt_pair_verify` + `validate_pairing`;
4. salva `rp_pairing_file_from_lockdown_verified.plist` in modo atomico, con protezione completa e controllo della coppia Ed25519; il file è esportabile e visibile in **File › Sul mio iPhone › GassPair**.

Se hai importato un RPPairing esistente, **Verify imported RPPairing on the device** esegue solo pair-verify (nessun PIN, nessun nuovo setup) e scrive `rp_pairing_file_imported_usbmuxd_verified.plist`.

**Perché funziona senza Mac:** il companion macOS usava `UsbmuxdProvider`, ma per un iPhone raggiunto via rete l'operazione `Connect` di usbmuxd è una connessione TCP a `IP-dispositivo:porta`; tutto il resto (StartSession, StartService, TLS del servizio, RPPairing) lo fa `idevice` allo stesso modo con qualsiasi provider. `EmbeddedMuxProvider` implementa quel `Connect` nell'app. Le note 2.3.4–2.3.8 qui sopra che dichiaravano necessario il Mac sono superate.

**Limiti onesti:** se una build di iOS offre questo servizio solo su USB, lockdownd rifiuta `StartService` su qualunque percorso di rete (anche il Mac con iPhone in Wi‑Fi): l'app lo dice esplicitamente e in quel caso resta come ripiego facoltativo il companion macOS con il **cavo USB** (*Mac companion (optional fallback)*). Ogni errore indica la fase esatta e la causa I/O reale; nessun file viene salvato se un passaggio fallisce. Il flusso end-to-end va confermato su un dispositivo reale.

API FFI nuove: `gasspair_mux_probe`, `gasspair_mux_create_rppairing`, `gasspair_mux_verify_rppairing` (stati 40–48 e 60–62). `gasspair_create_rp_from_lockdown_endpoint` resta per compatibilità e ora usa il motore integrato.


## Versione 2.4.1 — interfaccia Liquid Glass per usbmuxd (integrated)

- Rimosse dalla schermata principale le schede **Import / Validate RP Pairing File** e **Remote RPPairing endpoint** (con i relativi campi host/porta/PIN). Al loro posto c'è la sola scheda **usbmuxd (integrated)**, che mostra lo stato in tempo reale e permette di aprire il companion o importare il `Lockdown.plist`.
- L'import e la verifica di un RPPairing esistente ora sono dentro **usbmuxd (integrated)** › *Existing RPPairing* (stessi controlli: campi, lunghezze, UUID, `alt_irk`, coppia Ed25519; la verifica è solo pair-verify sul dispositivo, senza PIN).
- La schermata **usbmuxd (integrated)** e il ripiego **Mac companion** sono stati riscritti interamente con card Liquid Glass native (`glassEffect`, `.glass` / `.glassProminent`, `GlassEffectContainer` su iOS 26+; materiali traslucidi da iOS 16 a 25), con gli stessi modificatori del resto dell'app (`glassCard`, `pillButton`, `glassCapsule`) più `GlassComponents.swift`.
- Le funzioni FFI `gasspair_create_rp_endpoint` / `gasspair_verify_rp_endpoint` restano nella libreria per compatibilità, ma l'app non le usa più.


## Versione 2.4.2 — primo passaggio RPPairing più robusto

Dopo una reinstallazione dell'app (o comunque quando sul dispositivo resta il record di un pairing precedente) remotepairingdeviced poteva chiudere il canale durante «Pairing through Lockdown» (`UnexpectedEof … without sending TLS close_notify`). Il primo passaggio ora prova, ciascuno su una connessione nuova:

1. l'identità **upstream** (identificatore derivato dal nome host come `RpPairingFile::generate`, handshake → pair-verify → pair-setup): è ciò che fanno `idevice_pair` e il companion Mac e sostituisce il record precedente dello stesso host;
2. se il dispositivo chiude il canale: **pair-setup diretto** (senza il pair-verify destinato a fallire) con un nome host univoco `GassPair-XXXXXX` e identificatore casuale, per non collidere con il record lasciato dalla corsa precedente;
3. lo stesso, ancora una volta dopo una breve pausa.

Si passa al tentativo successivo solo se il dispositivo chiude la connessione; un rifiuto esplicito o un timeout fermano subito. Il secondo passaggio e la verifica indipendente usano la stessa identità scelta; nessun file viene salvato se un passaggio fallisce. L'errore finale elenca tutti i tentativi con la causa reale.
