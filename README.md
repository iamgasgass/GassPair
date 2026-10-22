# GassPair

App SwiftUI per iOS che crea il **pairing file Remote (RPPairing) senza computer**. Basata su [idevice](https://github.com/jkcoxson/idevice).

- **Funziona da iOS 16** (bundle id `com.iamgasgass.gasspair`).
- **Su iOS 27+** l'iPhone/iPad può associarsi **a se stesso**.
- **Da iOS 16 a iOS 26** l'app associa una **Apple TV** oppure fa da host per **un altro iPhone/iPad con iOS 27+** sulla stessa Wi-Fi. Un dispositivo con iOS 16–26 non può associarsi a se stesso: la voce «Pair with…» in Modalità sviluppatore esiste solo da iOS 27 (limite di Apple, non dell'app).

## Cosa fa

- **Diagnostica LocalDevVPN** — verifica che un indirizzo instradato dal tunnel raggiunga `lockdownd` su TCP `62078` e risponda al protocollo plist (`QueryType` + `ProductVersion`). È una sonda di rete: non invia richieste di pairing e non crea file.

> **Limite importante su iOS 26.1:** la raggiungibilità di `lockdownd` non abilita automaticamente il pairing classico del dispositivo con sé stesso. La documentazione pubblica di `idevicepair -w` e di `lockdownd_cu_pairing_create` descrive il flusso PIN/CU-SRP come supportato da Apple TV; iPhone/iPad usano il flusso Remote Pairing nelle versioni iOS che lo supportano. LocalDevVPN può cambiare il percorso di rete, ma non aggiunge al demone un protocollo di pairing che il dispositivo non espone. Riferimenti: [idevicepair](https://github.com/libimobiledevice/libimobiledevice/blob/master/docs/idevicepair.1), [lockdownd CU pairing](https://libimobiledevice.org/docs/libimobiledevice/1.4.0/lockdown_8h_a624871ea957a778920ecffe2d75d964f.html).

| Metodo | Come funziona | Dove si inserisce il codice |
| --- | --- | --- |
| **iPhone / iPad** (iOS 27+) | GassPair si annuncia sulla rete locale come "computer" a cui associarsi; il dispositivo stesso si collega da Impostazioni. | Sul dispositivo, in Impostazioni (il codice arriva in notifica, nella Live Activity e negli appunti). |
| **Apple TV** | GassPair si collega all'Apple TV che è sulla schermata di associazione. | In GassPair (il codice è mostrato sull'Apple TV). |
| **Diagnostica LocalDevVPN** | Verifica l'accesso al servizio Lockdown su un indirizzo instradato dal tunnel. | Non applicabile: non esegue il pairing. |

Il file risultante si esporta con **Export Pairing File** ed è anche in **File › Sul mio iPhone › GassPair**:

- `rp_pairing_file.plist` — iPhone/iPad
- `appletv_rp_pairing_file.plist` — Apple TV

## Diagnostica LocalDevVPN

1. Connetti LocalDevVPN e attendi lo stato **Connected**. Collega l'iPhone a una rete Wi-Fi effettiva: il progetto LocalDevVPN ha un problema documentato in alcune condizioni di sola rete cellulare.
2. In GassPair tocca **Test LocalDevVPN → Lockdown** e usa il valore **Device/Peer IP** configurato in LocalDevVPN, non il tunnel/interface IP.
3. Inserisci un host, non una rete. Per esempio, `10.7.0.1` è un host; `10.7.0.1/32` è una notazione CIDR. GassPair riconosce e rimuove automaticamente `/32` o `/128`; una subnet come `/24` viene rifiutata invece di essere interpretata arbitrariamente come host.
4. Esegui prima **TCP only**: se non raggiunge `ready`, nessun comando Lockdown viene inviato. Se TCP riesce, esegui **TCP + Lockdown**, che verifica `QueryType` e `GetValue(ProductVersion)`.
5. Puoi condividere il rapporto diagnostico, che include la destinazione normalizzata, le transizioni di `NWConnection`, i byte ricevuti e la fase esatta del timeout.

Un esito positivo conferma solo il percorso TCP e, nella modalità completa, il protocollo plist. Non prova che `Pair` o `CUPairingCreate` siano consentiti sull'iPhone e non genera un pairing file. GassPair non può ispezionare o correggere la route Network Extension di LocalDevVPN; se TCP non arriva a `ready`, prima va risolto il trasporto. Il progetto evita deliberatamente di presentare un file speculativo come successo.

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
