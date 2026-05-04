# 📡 ProxiMeet

> **Tesi di laurea @ Università degli Studi dell'Insubria**  
> Relatore: Prof. Davide Tosi

**ProxiMeet** è un'app mobile cross-platform (Flutter) che ti permette di scoprire le persone intorno a te durante eventi e conferenze — senza dover scambiare numeri o usare le app solite. Basta aprire l'app, entrare nell'evento, e il tuo telefono "vede" chi ti sta vicino via **Bluetooth Low Energy (BLE)**. Da lì puoi mandare la tua card digitale con un tap.

---

## ✨ Funzionalità principali

| Cosa fa | Come |
|---|---|
| 🔵 **Radar BLE** | Mostra le persone vicine in tempo reale su un radar animato |
| 📇 **Card digitali** | Profilo con nome, azienda, ruolo, bio e link social |
| 🤝 **Scambio contatti** | Richiesta con un tap → notifica push → accetta o rifiuta |
| 👛 **Wallet** | Tutti i contatti salvati in un posto solo |
| 📸 **Scanner QR** | Aggiungi qualcuno anche scansionando il suo QR code |
| 🔔 **Notifiche push** | Firebase Cloud Messaging per richieste e conferme |
| 🕐 **Presenza live** | Heartbeat ogni 30 secondi per sapere chi è ancora in zona |

---

## 🧱 Stack tecnologico

**Frontend**
- [Flutter](https://flutter.dev/) — cross-platform (iOS + Android)
- Dart

**Backend / Cloud**
- [Firebase Auth](https://firebase.google.com/products/auth) — login/registrazione
- [Cloud Firestore](https://firebase.google.com/products/firestore) — database realtime
- [Firebase Storage](https://firebase.google.com/products/storage) — avatar e immagini
- [Firebase Cloud Messaging](https://firebase.google.com/products/cloud-messaging) — notifiche push
- [Firebase Cloud Functions](https://firebase.google.com/products/functions) — logica serverless (Node.js 20)

**BLE / Prossimità**
- [`flutter_blue_plus`](https://pub.dev/packages/flutter_blue_plus) — scanning BLE
- [`flutter_ble_peripheral`](https://pub.dev/packages/flutter_ble_peripheral) — advertising BLE
- Codice nativo Swift (iOS) e Kotlin/Java (Android) per operazioni GATT avanzate

**Altre dipendenze notevoli**
- `mobile_scanner` + `qr_flutter` — QR code
- `permission_handler` — gestione permessi runtime
- `cached_network_image` — avatar con cache
- `uuid` — token di prossimità 

---

## 📁 Struttura del progetto

```
lib/
├── core/           # Costanti (UUID BLE, timeout), logger, error handler
├── models/         # Data classes: UserModel, EventModel, NearbyUser, ConnectionModel
├── services/       # Tutta la logica — singleton services
├── screens/        # UI organizzata per feature
│   ├── auth/       # Login, registrazione
│   ├── events/     # Lista eventi
│   ├── home/       # Radar, tab nearby, wallet, profilo
│   ├── profile/    # Modifica profilo
│   └── wallet/     # Contatti salvati
└── widgets/        # Componenti riutilizzabili (avatar, card, ecc.)

functions/          # Firebase Cloud Functions (Node.js)
android/            # Permessi BLE nel manifest + codice nativo Android
ios/                # Implementazione Swift per BLE/GATT nativo
```

---

## 🔄 Come funziona il BLE (in breve)

1. Quando entri in un evento, l'app scrive un **token di prossimità** su Firestore (stringa di 64 caratteri univoca per sessione)
2. Il token viene **broadcastato via GATT** attraverso BLE advertising
3. I dispositivi vicini lo **scansionano**, leggono la caratteristica GATT e risolvono il token → profilo utente su Firestore
4. Il segnale RSSI viene **smussato con EWMA** (α=0.3) per evitare jitter
5. Utenti non visti da **>60 secondi** vengono rimossi dalla lista
6. Quando esci dall'evento, advertising/scanning si fermano e i record di presenza vengono eliminati

---

## 🚀 Setup e avvio

### Prerequisiti

- Flutter SDK `^3.11.4`
- Node.js 20+ (per le Cloud Functions)
- Firebase CLI (`npm install -g firebase-tools`)


### Installazione

```bash
# 1. Clona il repo
git clone https://github.com/Ionni16/proximeet.git
cd proximeet

# 2. Installa le dipendenze Flutter
flutter pub get

# 3. Installa le dipendenze delle Cloud Functions
cd functions && npm install && cd ..
```

### Avvio in sviluppo

```bash
# Avvia su dispositivo/emulatore connesso
flutter run

# Analisi statica
flutter analyze
```

### Build

```bash
flutter build apk          # Android APK
flutter build ipa          # iOS IPA
```

### Cloud Functions

```bash
cd functions

# Sviluppo locale con emulatori
firebase emulators:start --only functions

# Deploy in produzione
firebase deploy --only functions

# Tail dei log live
firebase functions:log
```

---

## ☁️ Cloud Functions

| Funzione | Trigger | Cosa fa |
|---|---|---|
| `sendCardRequest` | Callable | Manda notifica push quando A vuole scambiare la card con B |
| `respondCardRequest` | Callable | Notifica quando B accetta/rifiuta + scrive la connessione su Firestore |
| `cleanupOldDetections` | Ogni ora | Rimuove i record BLE obsoleti |
| `cleanupStalePresence` | Ogni 5 min | Marca come inattivi gli utenti senza heartbeat da >5 min |

---

## 🗄️ Modello dati Firestore

```
users/{uid}                         ← profilo completo
users/{uid}/summary                 ← snapshot leggero per le liste
events/{eventId}                    ← metadati evento
events/{eventId}/presence/{uid}     ← presenza con lastHeartbeat
proximityTokens/{token}             ← mappa token BLE → uid + eventId
connections/{uid}/contacts/{uid2}   ← contatti accettati
connectionRequests/{requestId}      ← richieste in attesa
```

---

## ⚠️ Limitazioni note

- **iOS in background**: quando l'app va in background, iOS smette di fare BLE advertising iBeacon. Questo significa che un dispositivo iOS non viene rilevato da dispositivi Android se non è in primo piano. Android→Android e Android→iOS funzionano regolarmente.
- **BLE advertising su alcuni Android**: alcuni OEM (es. Xiaomi, Huawei) impongono throttling aggressivo allo scanning BLE in background. Risultati migliori con l'app in foreground.
- L'app non è ancora pubblicata su App Store / Google Play — è un prototipo di tesi.

---

## 🏗️ Pattern architetturali

- **Singleton services** — tutti i service si usano tramite `NomeService.instance`, mai istanziati direttamente
- **Streams** — la UI si aggiorna in tempo reale tramite `StreamBuilder` su snapshot Firestore
- **Logging** — si usa sempre `Log.debug()`, `Log.warn()`, `Log.error()` da `core/logger.dart`, mai `print()`
- **Costanti BLE** — UUID e timing vivono in `core/constants.dart`, non inline nel codice

---

## 👤 Autore

**Ionut** — sviluppato come progetto di tesi triennale 
Università degli Studi dell'Insubria | Relatore: Prof. Davide Tosi

---

