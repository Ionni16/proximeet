# Correzioni applicate

## Foto profilo Android e iOS

- Rimosso il blocco preventivo basato su `Permission.photos` / `Permission.storage`.
  `image_picker` usa direttamente il selettore foto di sistema e gestisce le
  differenze tra Android e iOS.
- Aggiunti controlli sul file selezionato prima dell'upload.
- L'avatar continua a essere salvato in `avatars/<uid>.jpg`, così resta
  compatibile con le regole Firebase Storage già esistenti.
- Il download URL salvato in Firestore contiene ora un parametro `v=<timestamp>`.
  Questo forza l'aggiornamento della cache e impedisce a iPhone e
  `CachedNetworkImage` di mostrare la foto precedente.
- La modifica foto dal profilo mostra ora un errore esplicito se selezione,
  upload o aggiornamento Firestore falliscono.

## Login LinkedIn

- Generazione di uno `state` OAuth casuale e crittograficamente sicuro.
- Verifica dello `state` ricevuto nel callback per evitare callback non validi.
- Pulizia cookie e cache WebView prima di ogni nuovo tentativo.
- Gestione distinta degli errori WebView, degli errori LinkedIn e dei callback
  incompleti, con pulsante Riprova.
- La Cloud Function non accetta più `clientId` e `redirectUri` dal telefono:
  usa esclusivamente i valori configurati lato server.
- Controllo degli status HTTP nelle chiamate LinkedIn token/userinfo.

## Operazioni necessarie dopo la sostituzione

1. Distribuire le Cloud Functions:
   `cd functions && npm install && firebase deploy --only functions:linkedinAuth`
2. Verificare nella LinkedIn Developer Console che il redirect autorizzato sia
   esattamente:
   `https://proximeet-5ffe2.web.app/linkedin-callback`
3. Verificare che il secret Firebase esista:
   `firebase functions:secrets:access LINKEDIN_CLIENT_SECRET`
4. Ricompilare completamente l'app, senza hot reload:
   `flutter clean && flutter pub get && flutter run`

Nota: nel progetto ricevuto non sono presenti `firebase.json` e
`storage.rules`; non è quindi possibile verificare localmente le regole Storage
attualmente distribuite. Il percorso dell'avatar è stato mantenuto invariato per
ridurre il rischio di incompatibilità.
