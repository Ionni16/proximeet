# Aggiornamento finale Swaply

Correzioni incluse:

- App Check temporaneamente disattivato nell'app finché Android/iOS non vengono registrati correttamente in Firebase Console. Questo evita `Too many attempts` e token placeholder durante i test.
- `deleteAccount` alleggerita: non scansiona più tutti gli eventi.
- fallback locale per eliminazione account quando la Cloud Function restituisce `resource-exhausted`, `unavailable`, `deadline-exceeded` o `internal`.
- pulsante Logout nella sezione Gestione account.
- logout ferma prima BLE/sessione evento e poi esegue Firebase sign-out.
- login LinkedIn mostra l'errore reale e ritenta una volta per errori temporanei.
- correzione null-safety `isForMainFrame != true`.

## Deploy

Dalla cartella principale:

```cmd
flutter clean
flutter pub get
firebase deploy --only functions:linkedinAuth,functions:deleteAccount --project proximeet-5ffe2
flutter run
```

Il deploy Functions è necessario perché `functions/index.js` è stato modificato.
