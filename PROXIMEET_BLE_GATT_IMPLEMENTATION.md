# ProxiMeet BLE GATT bidirezionale

Questa build sostituisce il path iBeacon/major/minor come trasporto primario con BLE GATT bidirezionale:

- Service UUID fisso: `F2703C30-FA18-4173-8599-016070383C81`
- Characteristic token leggibile: `F2703C31-FA18-4173-8599-016070383C81`
- Token temporaneo generato per sessione evento: `pm:<timestamp-base36>:<uuid>`
- Mapping Firestore: `events/{eventId}/proximityTokens/{token}`

## Flusso

1. `EventSessionService.joinEvent()` genera un token temporaneo.
2. Scrive `events/{eventId}/proximityTokens/{token}` con summary utente e TTL.
3. Avvia `PlatformBeaconService.start(token)`.
4. iOS/Android fanno contemporaneamente:
   - GATT server + advertising del Service UUID fisso;
   - scan del Service UUID;
   - connect/read della characteristic token.
5. Il token letto viene emesso a Dart come `RawBleDetection`.
6. `NearbyDetectionService` risolve il token su `proximityTokens` e aggiorna la UI.

## File principali modificati

- `ios/Runner/AppDelegate.swift`
- `android/app/src/main/kotlin/com/ionut/proximeet/proximeeet_app/ProxiMeetBeaconPlugin.kt`
- `lib/services/platform_beacon_service.dart`
- `lib/services/event_session_service.dart`
- `lib/services/nearby_detection_service.dart`
- `lib/core/constants.dart`
- `lib/models/nearby_user.dart`

## Note operative

- Testare sempre con app in foreground/radar aperto su entrambi i telefoni.
- Su Android servono Nearby Devices + Location consentita per scanning BLE affidabile.
- Su iOS servono permessi Bluetooth. Il background BLE non va trattato come tracking continuo garantito.
- Le Firestore Rules devono permettere lettura/scrittura della collection `events/{eventId}/proximityTokens` agli utenti autenticati ammessi all’evento.

## Rules Firestore da prevedere

Aggiungere una regola equivalente a quella usata per `presence`/`bleMapping`, ad esempio:

```js
match /events/{eventId}/proximityTokens/{token} {
  allow read, write: if request.auth != null;
}
```

La regola sopra è volutamente minimale. In produzione va ristretta ai partecipanti dell’evento.
