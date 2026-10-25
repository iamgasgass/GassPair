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
