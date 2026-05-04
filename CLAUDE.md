# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ProxiMeet** is a Flutter cross-platform mobile application for proximity-based networking at conferences. Users discover nearby attendees via BLE (Bluetooth Low Energy), exchange digital contact cards, and manage their professional network. Firebase provides the cloud backend.

## Common Commands

### Flutter

```bash
flutter pub get           # Install/update dependencies
flutter analyze           # Dart linting (uses flutter_lints)
flutter run               # Run debug build on connected device/emulator
flutter build apk         # Android release build
flutter build ipa         # iOS release build
```

### Cloud Functions (Node.js)

```bash
cd functions
npm install
firebase emulators:start --only functions   # Run locally
firebase deploy --only functions            # Deploy to Firebase (project: proximeet-5ffe2)
firebase functions:log                      # Tail live logs
```

### Firebase

```bash
firebase deploy           # Deploy all (functions + firestore rules + indexes)
firebase emulators:start  # Start full local emulator suite
```

## Architecture

### Layer Structure

```
lib/
├── core/          # Constants (BLE UUIDs, timeouts), centralized logger, error handler
├── models/        # Pure data classes: UserModel, EventModel, NearbyUser, ConnectionModel
├── services/      # All business logic — singleton services
├── screens/       # UI screens organized by feature (auth/, events/, home/, profile/, wallet/)
└── widgets/       # Reusable UI components
functions/         # Firebase Cloud Functions (Node.js 20)
android/           # Android-specific BLE manifest permissions + native code
ios/               # iOS Swift implementation for native BLE/GATT
```

### Service Layer (lib/services/)

All services use a static `instance` singleton accessor. Key services and their responsibilities:

| Service | Responsibility |
|---|---|
| `auth_service.dart` | Firebase Auth + Firestore user profile CRUD |
| `firestore_service.dart` | Events, connections, contact requests, Firestore queries |
| `event_session_service.dart` | Join/leave event, writes presence record + ephemeral proximity token |
| `ble_scanner_service.dart` | BLE scanning via `flutter_blue_plus` |
| `ble_advertiser_service.dart` | BLE peripheral advertising |
| `platform_beacon_service.dart` | Platform channel bridge → native iOS Swift / Android Java for GATT |
| `nearby_detection_service.dart` | Resolves BLE scan results to user profiles; EWMA RSSI smoothing |
| `presence_heartbeat_service.dart` | 30-second heartbeat keeping Firestore presence record fresh |
| `storage_service.dart` | Firebase Storage file uploads (avatars) |

### BLE / Proximity Flow

1. On joining an event, `event_session_service` writes an ephemeral 64-char proximity token to `proximityTokens/{token}` in Firestore and starts BLE advertising.
2. `ble_advertiser_service` + `platform_beacon_service` broadcast the token via GATT characteristic.
3. `ble_scanner_service` discovers nearby devices; `nearby_detection_service` reads their GATT characteristics, resolves the token to a Firestore user profile, applies EWMA RSSI smoothing (α=0.3), and emits a debounced (900ms) stream of `NearbyUser` objects.
4. Stale entries (>60 sec without update) are automatically purged from the in-memory map.
5. Leaving the event stops advertising/scanning and deletes the presence + token records.

### Contact Exchange Flow

1. User A taps "Connect" on User B from the nearby list → writes a request document.
2. `sendCardRequest` Cloud Function is triggered → FCM push notification to User B.
3. User B accepts → `respondCardRequest` Cloud Function fires → FCM to User A + writes `connections/{uid}/contacts/{uid2}` for both parties.

### Firestore Data Model

```
users/{uid}                         — full profile (toMap)
users/{uid}/summary                 — lightweight profile snapshot (toSummary)
events/{eventId}                    — event metadata
events/{eventId}/presence/{uid}     — presence with lastHeartbeat timestamp
proximityTokens/{token}             — maps ephemeral BLE token → uid + eventId
connections/{uid}/contacts/{uid2}   — accepted contacts
connectionRequests/{requestId}      — pending exchange requests
```

### Cloud Functions (functions/index.js)

- `sendCardRequest` — notifies receiver via FCM when a card request is sent
- `respondCardRequest` — notifies sender via FCM on acceptance/rejection
- `cleanupOldDetections` — hourly scheduled job: removes stale BLE detection records
- `cleanupStalePresence` — runs every 5 min: marks users inactive if no heartbeat in >5 min

### Key Patterns

- **Singletons:** `ServiceName.instance` throughout — never instantiate directly.
- **Streams:** UI subscribes to Firestore snapshots for real-time updates (events, wallet, nearby users).
- **UserModel serialization:** `.toMap()` for full Firestore writes, `.toSummary()` for lightweight snapshots, `.toWalletContactData()` for wallet display.
- **Logging:** Use `Log.debug()`, `Log.warn()`, `Log.error()` from `core/logger.dart` — never `print()`.
- **BLE constants:** UUIDs and timing values live in `core/constants.dart`; edit there rather than inline.

### Platform-Specific BLE

GATT operations that Flutter plugins don't fully support are handled natively:
- **iOS:** Swift code in `ios/` communicates via Flutter platform channel `platform_beacon_service.dart`
- **Android:** Java/Kotlin in `android/`

When modifying BLE behavior, changes often need to be made in both the Dart service layer and the native platform code.
