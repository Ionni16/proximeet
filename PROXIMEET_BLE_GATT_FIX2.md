# ProxiMeet BLE GATT Fix 2

Questa versione rende il rilevamento BLE GATT più simmetrico e reattivo in foreground/radar mode.

## Correzioni chiave

### iOS

- Il GATT advertising parte solo dopo `peripheralManager(_:didAdd:)`.
- Questo evita il caso in cui Android vede l'iPhone, si connette, ma non trova ancora service/characteristic.
- Advertising payload minimale: solo Service UUID, senza LocalName.
- Scan restart periodico ogni 12 secondi.
- Dedupe connessioni con `connectionInFlight`, `lastAttemptAt`, `lastReadAt`.
- Eventi diagnostici: `gattServiceReady`, `advertisingStarted`, `scanMatch`, `servicesDiscovered`, `tokenReadStarted`, `tokenReadComplete`, `gattPeer`.

### Android

- Il GATT advertising parte solo dopo `BluetoothGattServerCallback.onServiceAdded`.
- Scan senza filtro hardware obbligatorio; filtro manuale su `scanRecord.serviceUuids`.
- Questo migliora Android che deve rilevare advertising iOS con UUID 128-bit.
- Retry controllato su fallimenti, così non entra in loop `connectGatt -> discoverServices -> close`.
- Un solo `discoverServices()` per connessione.
- Scan restart periodico ogni 15 secondi.
- Eventi diagnostici dettagliati.

### Dart

- `NearbyDetectionService` viene avviato prima del plugin BLE nativo.
- Così le prime detection `gattPeer` non vengono perse.

## Aspettativa corretta

In foreground/radar mode, con entrambe le app aperte e stesso evento, la detection dovrebbe arrivare tipicamente entro pochi secondi.

Non è tecnicamente corretto promettere rilevamento istantaneo garantito in background su iOS/Android: i sistemi operativi possono limitare scan/advertising per privacy e batteria.

## Log da controllare

Su entrambi i device cerca:

```text
Native event: {type: gattServiceReady, ...}
Native event: {type: advertisingStarted, ...}
Native event: {type: scanStarted, ...}
Native event: {type: scanMatch, ...}
Native event: {type: servicesDiscovered, ...}
Native event: {type: tokenReadStarted, ...}
Native event: {type: tokenReadComplete, status: 0, bytes: ...}
Native event: {type: gattPeer, token: ..., rssi: ...}
```

Se manca `advertisingStarted`, il device non si sta facendo trovare.
Se c'è `scanMatch` ma manca `gattPeer`, controlla `servicesDiscovered` e `tokenCharacteristicMissing`.
Se c'è `gattPeer` ma non appare nella UI, il problema è Firestore `proximityTokens` o rules.
