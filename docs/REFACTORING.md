# ProxiMeet — Refactoring architetturale

Questo documento riassume il refactoring che porta ProxiMeet a un'architettura
più solida e pronta al pubblico, e spiega **come fare il deploy nell'ordine
corretto** (importante: alcune modifiche sono incompatibili con i client vecchi).

---

## 1. Cosa è cambiato e perché

### 1.1 Autorizzazione: la fiducia si sposta sul server
Prima il client scriveva in documenti di **altri** utenti (wallet altrui,
risposte alle richieste, propagazione avatar). Era impossibile da rendere
sicuro con le Firestore Rules. Ora:

- **`sendConnectionRequest`** e **`respondConnectionRequest`** sono Cloud
  Functions `onCall`. Il server verifica in modo autorevole:
  - evento esistente e attivo;
  - presenza **viva** di entrambi gli utenti (heartbeat recente) — è il gate
    principale anche per il QR;
  - per le richieste **BLE**, una detection recente con RSSI sopra soglia,
    letta lato server da `events/{e}/detections/{sender}/nearby/{target}`;
  - assenza di duplicati in **entrambe** le direzioni (transazione).
  I dati denormalizzati del mittente vengono letti dal profilo lato server:
  il client non può falsificarli.
- La **doppia scrittura nei wallet** avviene lato server in un batch atomico.
- **`syncProfileToWallets`** (trigger `onDocumentUpdated`) propaga le modifiche
  del profilo nei wallet dei contatti, eliminando sia il fan-out avatar dal
  client sia l'idratazione N+1 a ogni snapshot del wallet.

### 1.2 Firestore Rules e Storage Rules (prima assenti dal repo)
- `firestore.rules`: ogni utente scrive **solo** nei propri documenti; le
  scritture cross-utente passano dalle Cloud Functions. Validazione dei campi
  con `hasOnly`, `uid`/`createdAt` immutabili, `detections` con `rssi` vincolato
  a `[-127, 0]` e `lastSeen == request.time`.
- `storage.rules`: `avatars/{uid}.jpg` scrivibile solo dal proprietario,
  `< 5MB`, solo `image/*`.
- `firestore.indexes.json`: indici compositi per le richieste in arrivo e per
  la presenza stale, più gli override collection-group per `contacts.uid`,
  `nearby.lastSeen`, `proximityTokens.expiresAt`.

### 1.3 LinkedIn OAuth: hardening
- La Cloud Function `linkedinAuth` accetta **solo** il `code`. `client_id` e
  `redirect_uri` sono costanti server-side, così il client secret (in Secret
  Manager) non può essere usato con parametri scelti dal chiamante.
- Lo `state` anti-CSRF è generato con `Random.secure()` nel WebView e
  **verificato** al callback: un mismatch scarta il flusso.

### 1.4 Notifiche push (prima rotte end-to-end)
Tre cause risolte:
1. le Cloud Function di richiesta non venivano mai chiamate dall'app → ora
   `FirestoreService` le invoca e il server manda la push (`sendPushSafe`,
   che rimuove i token FCM scaduti);
2. mancava la gestione `onMessage`/`onMessageOpenedApp` → nuovo
   **`NotificationService`** (SnackBar in foreground, navigazione su tap,
   refresh del token);
3. mancava `POST_NOTIFICATIONS` (Android 13+) → aggiunto al manifest.

### 1.5 Permessi BLE su Android (bug di correttezza)
`BlePermissionsService` ora distingue per `sdkInt`:
- **Android 12+**: richiede `BLUETOOTH_SCAN/ADVERTISE/CONNECT`, niente
  location (manifest con `neverForLocation`);
- **Android ≤ 11**: richiede solo `ACCESS_FINE_LOCATION`.
Prima un permesso necessario negato poteva risultare "ok".

### 1.6 Qualità e robustezza
- **Parsing difensivo** (`core/parsing.dart`): i modelli non crashano più su un
  documento con data malformata (niente più cast `as Timestamp`).
- **`NearbyDetectionService`**: filtra i token non attivi/scaduti, usa
  `docChanges` invece di riscorrere l'intera collezione, risolve solo token
  validi e **non perde più memoria** in `_rssiSmoothed` (mappa uid→token).
- **`PresenceHeartbeatService`**: ogni battito rinnova anche `expiresAt` del
  proximity token; tutte le scritture hanno `catchError`.
- **Tema** estratto in `core/theme.dart` (`withOpacity` → `withValues`);
  `main.dart` ora snello con `navigatorKey` e `scaffoldMessengerKey` globali.
- **`WalletContact.toMap`** scrive una sola chiave avatar (`avatarURL`); in
  lettura restano accettate le chiavi legacy.
- **Test** aggiunti per costanti, parsing e modelli (`test/`).
- `analysis_options.yaml` con lint moderati aggiuntivi.

> Nota: il file vuoto `lib/screens/wallet/wallet_screen.dart` è codice morto e
> può essere eliminato dal progetto (il wallet vive in `screens/home/wallet_tab.dart`).

---

## 2. Ordine di deploy (IMPORTANTE)

Eseguire **in questo ordine**. Le nuove Rules sono più restrittive: un client
vecchio che prova a scrivere nei wallet altrui verrà bloccato, quindi l'app va
aggiornata **dopo** il backend.

```bash
# 1. Indici (vanno creati prima delle query che li usano)
firebase deploy --only firestore:indexes
#    Attendere che gli indici risultino "Enabled" nella console Firestore.

# 2. Regole Firestore + Storage
firebase deploy --only firestore:rules,storage

# 3. Cloud Functions
#    Verificare che il secret LinkedIn esista:
firebase functions:secrets:set LINKEDIN_CLIENT_SECRET   # se non già impostato
cd functions && npm install && cd ..
firebase deploy --only functions

# 4. App (build e pubblicazione store / distribuzione)
flutter pub get
flutter test          # esegue i test aggiunti
flutter analyze
flutter build appbundle   # Android
flutter build ipa         # iOS
```

### Applicare l'overlay
I file in questo zip vanno copiati sopra il progetto esistente mantenendo i
percorsi (`lib/...`, `functions/index.js`, `firestore.rules`, ecc.). I file
nuovi (es. `core/theme.dart`, `core/parsing.dart`,
`services/notification_service.dart`, la cartella `test/`) si aggiungono;
gli altri **sostituiscono** gli originali.

---

## 3. Note di migrazione

- **Client vecchi incompatibili**: dopo il deploy delle Rules, le versioni
  precedenti dell'app non riusciranno più a inviare/accettare richieste
  (scrivevano lato client). Forzare l'aggiornamento.
- **Wallet esistenti**: continuano a funzionare. I documenti contatto vengono
  riallineati al primo `syncProfileToWallets` utile (quando il profilo del
  contatto cambia). Le chiavi avatar legacy restano leggibili.
- **Segreti negli archivi**: lo zip del progetto condiviso in precedenza
  conteneva `android/app/proximeet-release-key.jks` e `android/key.properties`
  con password in chiaro. Escluderli da qualunque archivio/condivisione futura
  e valutare la **rotazione** della keystore se l'archivio è uscito dal
  controllo. (`.gitignore` già li esclude dal repo Git.)

---

## 4. TODO futuri (non bloccanti)

- **QR con nonce a tempo**: oggi il QR contiene l'uid ed è gated dalla presenza
  viva del target. Un nonce monouso/scadente eliminerebbe del tutto il replay.
- **Ruoli organizer/admin**: gli eventi sono creati da console; un ruolo
  organizer consentirebbe la gestione in-app con Rules dedicate.
- **Firebase App Check**: per limitare l'uso delle callable ai soli client
  legittimi dell'app.
