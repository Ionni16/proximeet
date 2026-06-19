# Swaply – correzioni complete

Questa versione contiene insieme le correzioni per:

- selezione e aggiornamento foto profilo su Android e iOS;
- aggiornamento immediato dell'avatar senza cache obsoleta;
- login LinkedIn OAuth con `state`, pulizia WebView, timeout ed errori leggibili;
- cancellazione completa dell'account tramite Cloud Function idempotente;
- timeout e retry della callable `deleteAccount`;
- inizializzazione Firebase App Check;
- configurazione Firebase CLI (`firebase.json` e `.firebaserc`);
- callback Android moderno `enableOnBackInvokedCallback`.

## Prima esecuzione

Dalla cartella principale:

```bash
flutter clean
flutter pub get
flutter run
```

## Deploy obbligatorio delle Cloud Functions

La cancellazione account e LinkedIn funzionano con il nuovo codice solo dopo il deploy:

```bash
firebase login
firebase use proximeet-5ffe2
firebase functions:secrets:set LINKEDIN_CLIENT_SECRET
firebase deploy --only functions:linkedinAuth,functions:deleteAccount
```

Se il secret LinkedIn è già configurato, non reinserirlo e usa direttamente il deploy.

Per vedere l'errore server reale:

```bash
firebase functions:log --only deleteAccount
```

## LinkedIn Developer Console

Il redirect URL autorizzato deve essere esattamente:

```text
https://proximeet-5ffe2.web.app/linkedin-callback
```

Il prodotto OpenID Connect deve consentire gli scope:

```text
openid profile email
```

## Firebase App Check

Nel progetto Firebase registra:

- Android: package `com.ionut.proximeet.proximeeet_app`, provider Play Integrity;
- iOS: il Bundle ID effettivo dell'app, provider DeviceCheck.

Durante `flutter run` viene usato il provider debug. Il token debug stampato nei log va registrato nella Console Firebase solo se hai già attivato l'enforcement. Non attivare l'enforcement delle Functions finché Android e iOS non risultano registrati e verificati.

## Perché deleteAccount falliva

La precedente Function eseguiva una `collectionGroup("contacts")` e interrompeva tutta la cancellazione al primo errore, restituendo soltanto `INTERNAL`. La nuova versione:

- elimina le copie del contatto usando gli UID già presenti nel wallet;
- non dipende dalla collection-group query;
- tratta ogni blocco di dati separatamente;
- è sicura da richiamare una seconda volta;
- elimina Firebase Auth per ultimo;
- ha timeout di 540 secondi;
- registra nei log lo step esatto che ha dato errore.
