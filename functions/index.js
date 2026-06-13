/**
 * ProxiMeet — Cloud Functions (backend)
 *
 * Architettura: tutta la logica che richiede fiducia (creazione/risposta
 * richieste di contatto, scrittura nei wallet, notifiche push, pulizia dati)
 * vive qui, lato server. Il client Flutter non scrive mai in documenti di
 * altri utenti: le Firestore Rules (firestore.rules) lo impediscono.
 *
 * Funzioni esposte (onCall):
 *  - linkedinAuth              login LinkedIn via OAuth2 → Custom Token Firebase
 *  - sendConnectionRequest     crea una richiesta di scambio biglietto (con
 *                              verifica server-side di prossimità/presenza)
 *  - respondConnectionRequest  accetta/rifiuta una richiesta e scrive i wallet
 *  - deleteAccount             eliminazione completa account (Guideline 5.1.1v)
 *
 * Trigger Firestore:
 *  - syncProfileToWallets      propaga le modifiche profilo nei wallet altrui
 *
 * Scheduled:
 *  - cleanupStaleDetections        elimina detections vecchie (>10 min)
 *  - cleanupStalePresence          marca inattivi gli utenti senza heartbeat
 *  - cleanupExpiredProximityTokens elimina i token BLE scaduti
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");
const querystring = require("querystring");

admin.initializeApp();

// ─────────────────────────────────────────────────────────────────────────────
// Costanti
// ─────────────────────────────────────────────────────────────────────────────

// LinkedIn OAuth: client_id e redirect_uri sono costanti SERVER-SIDE.
// Il client manda solo il "code": così il secret non può mai essere usato
// con parametri scelti dal chiamante.
const LINKEDIN_CLIENT_ID = "77ldn2lgmzxacy";
const LINKEDIN_REDIRECT_URI = "https://proximeet-5ffe2.web.app/linkedin-callback";
const linkedinClientSecret = defineSecret("LINKEDIN_CLIENT_SECRET");

// Devono restare allineate a lib/core/constants.dart (AppConstants).
const CONTACT_GATING_SECONDS = 120; // finestra di validità di una detection BLE
const RSSI_MIN_FOR_REQUEST = -80;   // soglia minima (AppConstants.rssiMedium)
const PRESENCE_FRESH_SECONDS = 300; // presenza "viva" = heartbeat < 5 minuti

// Pulizia dati
const DETECTION_TTL_MINUTES = 10;
const PRESENCE_STALE_MINUTES = 5;
const TOKEN_GRACE_MINUTES = 10;
const CLEANUP_PAGE_SIZE = 450;

const ALLOWED_REQUEST_SOURCES = new Set(["ble", "qr"]);

// Campi del profilo che, se cambiano, vanno propagati nei wallet dei contatti.
const WALLET_SYNCED_FIELDS = [
  "firstName",
  "lastName",
  "company",
  "role",
  "email",
  "phone",
  "linkedin",
  "avatarURL",
];

// ─────────────────────────────────────────────────────────────────────────────
// Helper di validazione input
// ─────────────────────────────────────────────────────────────────────────────

function requireString(value, name, { min = 1, max = 512 } = {}) {
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", `Parametro non valido: ${name}`);
  }
  const trimmed = value.trim();
  if (trimmed.length < min || trimmed.length > max) {
    throw new HttpsError("invalid-argument", `Parametro non valido: ${name}`);
  }
  return trimmed;
}

function requireBoolean(value, name) {
  if (typeof value !== "boolean") {
    throw new HttpsError("invalid-argument", `Parametro non valido: ${name}`);
  }
  return value;
}

function requireAuth(request) {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Devi essere autenticato.");
  }
  return uid;
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper Firestore / FCM
// ─────────────────────────────────────────────────────────────────────────────

async function getUserData(uid) {
  const doc = await admin.firestore().collection("users").doc(uid).get();
  if (!doc.exists) return null;
  return doc.data();
}

function displayNameOf(userData) {
  if (!userData) return "Qualcuno";
  const name = `${userData.firstName || ""} ${userData.lastName || ""}`.trim();
  return name || "Qualcuno";
}

/**
 * Invio push best-effort: non blocca mai il flusso principale.
 * Se il token risulta non più registrato, lo rimuove dal profilo
 * così non ci riproviamo a vuoto.
 */
async function sendPushSafe(uid, { title, body, data = {} }) {
  let token = null;
  try {
    const user = await getUserData(uid);
    token = user?.fcmToken || null;
    if (!token) return;

    await admin.messaging().send({
      token,
      notification: { title, body },
      data,
      android: { priority: "high" },
      apns: { payload: { aps: { sound: "default", badge: 1 } } },
    });
  } catch (e) {
    if (e?.code === "messaging/registration-token-not-registered") {
      await admin
        .firestore()
        .collection("users")
        .doc(uid)
        .update({ fcmToken: admin.firestore.FieldValue.delete() })
        .catch(() => {});
      console.log(`sendPushSafe: token FCM scaduto rimosso per ${uid}`);
    } else {
      console.error(`sendPushSafe: errore invio notifica a ${uid}:`, e);
    }
  }
}

function isFresh(timestamp, maxSeconds) {
  if (!timestamp || typeof timestamp.toMillis !== "function") return false;
  return Date.now() - timestamp.toMillis() <= maxSeconds * 1000;
}

/**
 * Esegue una query paginata eliminando i documenti trovati.
 * Ritorna il numero totale di documenti eliminati.
 */
async function deleteByQuery(buildQuery) {
  const db = admin.firestore();
  let totalDeleted = 0;

  // Loop finché la pagina è piena: l'ultima pagina parziale chiude il ciclo.
  for (;;) {
    const snap = await buildQuery().limit(CLEANUP_PAGE_SIZE).get();
    if (snap.empty) break;

    const batch = db.batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();

    totalDeleted += snap.size;
    if (snap.size < CLEANUP_PAGE_SIZE) break;
  }

  return totalDeleted;
}

// ─────────────────────────────────────────────────────────────────────────────
// HTTP minimale per le chiamate a LinkedIn
// ─────────────────────────────────────────────────────────────────────────────

function httpsRequest(method, url, { headers = {}, body = null } = {}) {
  return new Promise((resolve, reject) => {
    const urlObj = new URL(url);
    const bodyString =
      body == null
        ? null
        : typeof body === "string"
          ? body
          : querystring.stringify(body);

    const options = {
      hostname: urlObj.hostname,
      path: urlObj.pathname + urlObj.search,
      method,
      headers: {
        ...(bodyString != null && {
          "Content-Type": "application/x-www-form-urlencoded",
          "Content-Length": Buffer.byteLength(bodyString),
        }),
        ...headers,
      },
      timeout: 10000,
    };

    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        let parsed;
        try {
          parsed = JSON.parse(data);
        } catch {
          parsed = data;
        }
        resolve({ statusCode: res.statusCode, body: parsed });
      });
    });

    req.on("timeout", () => req.destroy(new Error("Request timeout")));
    req.on("error", reject);
    if (bodyString != null) req.write(bodyString);
    req.end();
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// linkedinAuth — OAuth2 LinkedIn → Custom Token Firebase
// ─────────────────────────────────────────────────────────────────────────────

exports.linkedinAuth = onCall(
  { secrets: [linkedinClientSecret] },
  async (request) => {
    // Unico input accettato dal client: il codice autorizzativo.
    // clientId/redirectUri sono costanti server-side (vedi sopra).
    const code = requireString(request.data?.code, "code", { max: 2048 });

    const clientSecret = linkedinClientSecret.value();

    // 1. Scambia il codice per un access token
    let tokenResponse;
    try {
      tokenResponse = await httpsRequest(
        "POST",
        "https://www.linkedin.com/oauth/v2/accessToken",
        {
          body: {
            grant_type: "authorization_code",
            code,
            redirect_uri: LINKEDIN_REDIRECT_URI,
            client_id: LINKEDIN_CLIENT_ID,
            client_secret: clientSecret,
          },
        },
      );
    } catch (e) {
      console.error("linkedinAuth: errore token exchange:", e);
      throw new HttpsError("internal", "Impossibile ottenere access token LinkedIn");
    }

    const tokenData = tokenResponse.body;
    if (
      tokenResponse.statusCode !== 200 ||
      !tokenData ||
      tokenData.error ||
      !tokenData.access_token
    ) {
      console.error("linkedinAuth: token error:", tokenResponse.statusCode, tokenData);
      throw new HttpsError(
        "unauthenticated",
        tokenData?.error_description || "Token LinkedIn non valido",
      );
    }

    const accessToken = tokenData.access_token;

    // 2. Recupera profilo utente via OpenID Connect
    let profile;
    try {
      const profileResponse = await httpsRequest(
        "GET",
        "https://api.linkedin.com/v2/userinfo",
        { headers: { Authorization: `Bearer ${accessToken}` } },
      );
      profile = profileResponse.body;
    } catch (e) {
      console.error("linkedinAuth: errore userinfo:", e);
      throw new HttpsError("internal", "Impossibile recuperare profilo LinkedIn");
    }

    if (!profile || typeof profile.sub !== "string" || !profile.sub) {
      console.error("linkedinAuth: userinfo senza sub:", profile);
      throw new HttpsError("internal", "Profilo LinkedIn non valido");
    }

    // 3. Crea o aggiorna l'utente Firebase Auth
    const uid = `linkedin_${profile.sub}`;
    const email = profile.email || null;
    const firstName = profile.given_name || "";
    const lastName = profile.family_name || "";
    const photoURL = profile.picture || null;
    const displayName = `${firstName} ${lastName}`.trim();

    // updateRecord: MAI includere email per evitare conflitti con account
    // email/password. L'email viene salvata in Firestore, non in Firebase Auth.
    const updateRecord = { displayName };
    if (photoURL) updateRecord.photoURL = photoURL;

    // createRecord: proviamo con email, con fallback senza.
    const createRecord = { uid, displayName };
    if (email) createRecord.email = email;
    if (photoURL) createRecord.photoURL = photoURL;

    try {
      await admin.auth().updateUser(uid, updateRecord);
      console.log(`linkedinAuth: utente aggiornato ${uid}`);
    } catch (e) {
      if (e.code === "auth/user-not-found") {
        try {
          await admin.auth().createUser(createRecord);
          console.log(`linkedinAuth: utente creato ${uid}`);
        } catch (createError) {
          if (createError.code === "auth/email-already-exists") {
            const { email: _ignored, ...noEmail } = createRecord;
            await admin.auth().createUser(noEmail);
            console.log(`linkedinAuth: utente creato senza email (già in uso): ${uid}`);
          } else {
            console.error("linkedinAuth: errore createUser:", createError);
            throw new HttpsError("internal", "Errore creazione account");
          }
        }
      } else {
        console.error("linkedinAuth: errore updateUser:", e);
        throw new HttpsError("internal", "Errore aggiornamento account");
      }
    }

    // 4. Esiste già un profilo Firestore?
    const userDoc = await admin.firestore().collection("users").doc(uid).get();
    const isNewUser = !userDoc.exists;

    // 5. Custom Token per il login lato client
    const customToken = await admin.auth().createCustomToken(uid);

    return {
      customToken,
      isNewUser,
      profile: {
        uid,
        firstName,
        lastName,
        email: email || "",
        photoURL: photoURL || "",
        linkedinSub: profile.sub,
      },
    };
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// sendConnectionRequest — crea una richiesta di scambio biglietto
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Verifica SERVER-SIDE prima di creare la richiesta:
 *  - mittente autenticato, con profilo, presente e attivo nell'evento;
 *  - destinatario con profilo, presente e attivo nell'evento (heartbeat
 *    recente): un QR fotografato non funziona se la persona non è lì;
 *  - per source "ble": detection recente (< CONTACT_GATING_SECONDS) con
 *    RSSI sopra soglia, letta da events/{e}/detections/{sender}/nearby/{target};
 *  - nessuna richiesta pendente/accettata già esistente, in nessuna direzione.
 *
 * I dati denormalizzati del mittente (nome, ruolo…) vengono letti dal profilo
 * lato server: il client non può falsificarli.
 */
exports.sendConnectionRequest = onCall(async (request) => {
  const senderUid = requireAuth(request);
  const targetUid = requireString(request.data?.targetUid, "targetUid", { max: 128 });
  const eventId = requireString(request.data?.eventId, "eventId", { max: 128 });
  const source = requireString(request.data?.source, "source", { max: 8 });

  if (!ALLOWED_REQUEST_SOURCES.has(source)) {
    throw new HttpsError("invalid-argument", "Parametro non valido: source");
  }
  if (targetUid === senderUid) {
    throw new HttpsError(
      "failed-precondition",
      "Non puoi inviare una richiesta a te stesso",
    );
  }

  const db = admin.firestore();

  // Evento esistente e attivo
  const eventDoc = await db.collection("events").doc(eventId).get();
  if (!eventDoc.exists || eventDoc.data().isActive !== true) {
    throw new HttpsError("failed-precondition", "Evento non attivo");
  }
  const eventRef = eventDoc.ref;

  // Profili di entrambi
  const [senderData, targetData] = await Promise.all([
    getUserData(senderUid),
    getUserData(targetUid),
  ]);
  if (!senderData) {
    throw new HttpsError("failed-precondition", "Completa il tuo profilo prima");
  }
  if (!targetData) {
    throw new HttpsError("not-found", "Utente non trovato");
  }

  // Presenza viva di entrambi nell'evento (heartbeat recente).
  // Per il QR è il gate principale: il codice contiene solo l'uid, quindi
  // verifichiamo che il destinatario sia davvero all'evento adesso.
  const [senderPresence, targetPresence] = await Promise.all([
    eventRef.collection("presence").doc(senderUid).get(),
    eventRef.collection("presence").doc(targetUid).get(),
  ]);

  const senderAlive =
    senderPresence.exists &&
    senderPresence.data().isActive === true &&
    isFresh(senderPresence.data().lastSeen, PRESENCE_FRESH_SECONDS);
  if (!senderAlive) {
    throw new HttpsError("failed-precondition", "Non risulti attivo nell'evento");
  }

  const targetAlive =
    targetPresence.exists &&
    targetPresence.data().isActive === true &&
    isFresh(targetPresence.data().lastSeen, PRESENCE_FRESH_SECONDS);
  if (!targetAlive) {
    throw new HttpsError(
      "failed-precondition",
      "L'utente non risulta attivo nell'evento in questo momento",
    );
  }

  // Gating di prossimità per richieste via BLE
  if (source === "ble") {
    const detection = await eventRef
      .collection("detections")
      .doc(senderUid)
      .collection("nearby")
      .doc(targetUid)
      .get();

    if (!detection.exists) {
      throw new HttpsError(
        "failed-precondition",
        "Utente non rilevato nelle vicinanze",
      );
    }

    const det = detection.data();
    if (!isFresh(det.lastSeen, CONTACT_GATING_SECONDS)) {
      throw new HttpsError("failed-precondition", "Utente non più nelle vicinanze");
    }

    const rssi = typeof det.rssi === "number" ? det.rssi : null;
    if (rssi === null || rssi < RSSI_MIN_FOR_REQUEST) {
      throw new HttpsError(
        "failed-precondition",
        "Segnale troppo debole per inviare la richiesta",
      );
    }
  }

  // Creazione transazionale: niente duplicati, in nessuna direzione.
  const requestId = `${senderUid}_${targetUid}_${eventId}`;
  const reverseId = `${targetUid}_${senderUid}_${eventId}`;
  const requestRef = db.collection("connectionRequests").doc(requestId);
  const reverseRef = db.collection("connectionRequests").doc(reverseId);

  await db.runTransaction(async (tx) => {
    const [existing, reverse] = await Promise.all([
      tx.get(requestRef),
      tx.get(reverseRef),
    ]);

    if (existing.exists) {
      const status = existing.data().status;
      if (status === "pending") {
        throw new HttpsError("already-exists", "Richiesta già inviata");
      }
      if (status === "accepted") {
        throw new HttpsError("already-exists", "Già connessi");
      }
      // status "rejected": consentiamo un nuovo tentativo sovrascrivendo.
    }

    if (reverse.exists) {
      const status = reverse.data().status;
      if (status === "accepted") {
        throw new HttpsError("already-exists", "Già connessi");
      }
      if (status === "pending") {
        throw new HttpsError(
          "already-exists",
          "Questa persona ti ha già inviato una richiesta: controlla le richieste in arrivo",
        );
      }
    }

    tx.set(requestRef, {
      senderUid,
      receiverUid: targetUid,
      eventId,
      status: "pending",
      source,
      senderDisplayName: displayNameOf(senderData),
      senderCompany: senderData.company || "",
      senderRole: senderData.role || "",
      senderAvatarURL: (senderData.avatarURL || "").trim(),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  // Notifica al destinatario (best-effort, fuori dalla transazione)
  await sendPushSafe(targetUid, {
    title: "Nuova richiesta biglietto",
    body: `${displayNameOf(senderData)} vuole scambiare il biglietto con te`,
    data: { type: "connection_request", requestId, senderUid },
  });

  return { success: true, requestId };
});

// ─────────────────────────────────────────────────────────────────────────────
// respondConnectionRequest — accetta/rifiuta e scrive i wallet
// ─────────────────────────────────────────────────────────────────────────────

/** Costruisce il documento contatto salvato nel wallet di `ownerUid`. */
function walletContactFrom(profile, contactUid, eventName) {
  return {
    uid: contactUid,
    firstName: profile.firstName || "",
    lastName: profile.lastName || "",
    company: profile.company || "",
    role: profile.role || "",
    email: profile.email || "",
    phone: profile.phone || "",
    linkedin: profile.linkedin || "",
    avatarURL: (profile.avatarURL || "").trim(),
    connectedAt: admin.firestore.FieldValue.serverTimestamp(),
    eventName: eventName || "",
    note: "",
  };
}

/**
 * Solo il DESTINATARIO della richiesta può rispondere: il controllo usa
 * request.auth.uid, mai un uid passato dal client. La doppia scrittura nei
 * wallet avviene qui con privilegi admin, in un batch atomico: le Rules
 * tengono `connections/**` in sola lettura per i client.
 */
exports.respondConnectionRequest = onCall(async (request) => {
  const callerUid = requireAuth(request);
  const requestId = requireString(request.data?.requestId, "requestId", { max: 512 });
  const accepted = requireBoolean(request.data?.accepted, "accepted");

  const db = admin.firestore();
  const requestRef = db.collection("connectionRequests").doc(requestId);

  let requestData = null;

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(requestRef);
    if (!snap.exists) {
      throw new HttpsError("not-found", "Richiesta non trovata");
    }

    const data = snap.data();
    if (data.receiverUid !== callerUid) {
      throw new HttpsError(
        "permission-denied",
        "Solo il destinatario può rispondere a questa richiesta",
      );
    }

    const status = data.status || "pending";
    if (status !== "pending") {
      throw new HttpsError(
        "failed-precondition",
        status === "accepted" ? "Richiesta già accettata" : "Richiesta già gestita",
      );
    }

    requestData = data;

    tx.update(requestRef, {
      status: accepted ? "accepted" : "rejected",
      respondedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  const senderUid = requestData.senderUid;
  const receiverUid = requestData.receiverUid;

  if (!accepted) {
    await sendPushSafe(senderUid, {
      title: "Richiesta rifiutata",
      body: "La tua richiesta di scambio biglietto è stata rifiutata",
      data: { type: "connection_response", accepted: "false", requestId },
    });
    return { success: true };
  }

  // Accettata: leggiamo i profili aggiornati e scriviamo ENTRAMBI i wallet
  // in un unico batch (atomico: o tutti e due o nessuno).
  const [senderData, receiverData] = await Promise.all([
    getUserData(senderUid),
    getUserData(receiverUid),
  ]);
  if (!senderData || !receiverData) {
    throw new HttpsError("internal", "Profilo contatto non trovato");
  }

  let eventName = "";
  if (requestData.eventId) {
    const eventDoc = await db.collection("events").doc(requestData.eventId).get();
    eventName = eventDoc.exists ? eventDoc.data().name || "" : "";
  }

  const batch = db.batch();
  batch.set(
    db.collection("connections").doc(senderUid).collection("contacts").doc(receiverUid),
    walletContactFrom(receiverData, receiverUid, eventName),
    { merge: true },
  );
  batch.set(
    db.collection("connections").doc(receiverUid).collection("contacts").doc(senderUid),
    walletContactFrom(senderData, senderUid, eventName),
    { merge: true },
  );
  await batch.commit();

  await sendPushSafe(senderUid, {
    title: "Richiesta accettata!",
    body: `${displayNameOf(receiverData)} ha accettato il tuo biglietto`,
    data: { type: "connection_response", accepted: "true", requestId },
  });

  return { success: true };
});

// ─────────────────────────────────────────────────────────────────────────────
// syncProfileToWallets — propaga le modifiche profilo nei wallet altrui
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Prima questa propagazione la faceva il client scrivendo nei wallet degli
 * altri utenti (impossibile da permettere nelle Rules). Ora è un trigger:
 * quando users/{uid} cambia in uno dei campi denormalizzati, aggiorniamo
 * tutte le copie in connections/{x}/contacts/{uid} con una collection-group
 * query (richiede l'indice in firestore.indexes.json).
 */
exports.syncProfileToWallets = onDocumentUpdated("users/{uid}", async (event) => {
  const before = event.data.before.data() || {};
  const after = event.data.after.data() || {};
  const uid = event.params.uid;

  const changed = {};
  for (const field of WALLET_SYNCED_FIELDS) {
    const prev = before[field] ?? "";
    const next = after[field] ?? "";
    if (prev !== next) changed[field] = next;
  }

  if (Object.keys(changed).length === 0) return;

  const db = admin.firestore();
  const copies = await db.collectionGroup("contacts").where("uid", "==", uid).get();
  if (copies.empty) return;

  const bulkWriter = db.bulkWriter();
  bulkWriter.onWriteError((error) => {
    if (error.failedAttempts < 3) return true;
    console.error(
      `syncProfileToWallets: update fallito ${error.documentRef.path}:`,
      error.message,
    );
    return false;
  });

  for (const doc of copies.docs) {
    bulkWriter.update(doc.ref, changed);
  }
  await bulkWriter.close();

  console.log(
    `syncProfileToWallets: ${copies.size} wallet aggiornati per ${uid} ` +
      `(campi: ${Object.keys(changed).join(", ")})`,
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// deleteAccount — eliminazione completa account e dati
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Elimina COMPLETAMENTE l'account dell'utente autenticato e tutti i suoi dati.
 *
 * Conforme alla App Store Review Guideline 5.1.1(v): l'eliminazione è avviata
 * dall'utente dall'interno dell'app, è permanente e rimuove tutti i dati
 * personali, senza richiedere passaggi esterni (telefonate, email, siti web).
 *
 * Usa SEMPRE request.auth.uid (mai un uid passato dal client): un utente può
 * eliminare solo il proprio account.
 *
 * Ordine: prima tutti i dati Firestore/Storage, poi l'utente Auth per ultimo,
 * così se qualcosa fallisce a metà l'utente può ritentare (l'Auth è ancora vivo).
 */
exports.deleteAccount = onCall(async (request) => {
  const uid = requireAuth(request);

  const db = admin.firestore();
  const bulkWriter = db.bulkWriter();
  // Non bloccare l'intera cancellazione per il fallimento di un singolo doc:
  // ritenta qualche volta, poi prosegui.
  bulkWriter.onWriteError((error) => {
    if (error.failedAttempts < 3) return true;
    console.error(`deleteAccount: doc non eliminato ${error.documentRef.path}:`, error.message);
    return false;
  });

  try {
    // 1. Documento utente principale (contiene profilo, fcmToken, ecc.)
    await db.collection("users").doc(uid).delete();

    // 2. Wallet dell'utente: connections/{uid} e tutta la sottocollezione contacts
    await db.recursiveDelete(db.collection("connections").doc(uid), bulkWriter);

    // 3. Rimuovi l'utente dai wallet di TUTTI gli altri (collection group su contacts).
    //    Ogni contatto salvato ha un campo `uid` = uid del contatto.
    const inOthersWallets = await db
      .collectionGroup("contacts")
      .where("uid", "==", uid)
      .get();
    for (const doc of inOthersWallets.docs) {
      bulkWriter.delete(doc.ref);
    }

    // 4. Richieste di connessione in cui l'utente è mittente o destinatario.
    const sent = await db.collection("connectionRequests").where("senderUid", "==", uid).get();
    const received = await db.collection("connectionRequests").where("receiverUid", "==", uid).get();
    for (const doc of [...sent.docs, ...received.docs]) {
      bulkWriter.delete(doc.ref);
    }

    // 5. Dati legati agli eventi: presence, proximityTokens, detections.
    const events = await db.collection("events").get();
    for (const eventDoc of events.docs) {
      const eventRef = db.collection("events").doc(eventDoc.id);

      // presence/{uid}
      bulkWriter.delete(eventRef.collection("presence").doc(uid));

      // proximityTokens dove uid == uid (la chiave del doc è il token, non l'uid)
      const tokens = await eventRef.collection("proximityTokens").where("uid", "==", uid).get();
      for (const t of tokens.docs) {
        bulkWriter.delete(t.ref);
      }

      // detections/{uid} + sottocollezione nearby (le mie rilevazioni).
      // Le copie di me nei detections ALTRUI scadono da sole con
      // cleanupStaleDetections (TTL 10 minuti).
      await db.recursiveDelete(eventRef.collection("detections").doc(uid), bulkWriter);
    }

    await bulkWriter.close();

    // 6. Avatar su Storage (best-effort: potrebbe non esistere).
    try {
      await admin.storage().bucket().file(`avatars/${uid}.jpg`).delete();
    } catch (e) {
      if (e.code !== 404) {
        console.warn(`deleteAccount: avatar non eliminato per ${uid}:`, e.message);
      }
    }

    // 7. PER ULTIMO: l'utente Firebase Auth.
    await admin.auth().deleteUser(uid);

    console.log(`deleteAccount: account ${uid} eliminato completamente.`);
    return { success: true };
  } catch (e) {
    console.error(`deleteAccount: errore eliminazione account ${uid}:`, e);
    throw new HttpsError("internal", "Impossibile completare l'eliminazione dell'account. Riprova.");
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Scheduled cleanup — O(documenti stale), non O(eventi × documenti)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Elimina le detection BLE più vecchie di DETECTION_TTL_MINUTES.
 * Collection-group query su tutte le sottocollezioni `nearby`
 * (indice in firestore.indexes.json).
 */
exports.cleanupStaleDetections = onSchedule("every 60 minutes", async () => {
  const cutoff = admin.firestore.Timestamp.fromMillis(
    Date.now() - DETECTION_TTL_MINUTES * 60 * 1000,
  );
  try {
    const deleted = await deleteByQuery(() =>
      admin.firestore().collectionGroup("nearby").where("lastSeen", "<", cutoff),
    );
    console.log(`cleanupStaleDetections: ${deleted} detections rimosse`);
  } catch (e) {
    console.error("cleanupStaleDetections: errore:", e);
  }
});

/**
 * Marca isActive=false chi non manda heartbeat da PRESENCE_STALE_MINUTES.
 * Copre il caso "app uccisa senza leaveEvent".
 */
exports.cleanupStalePresence = onSchedule("every 5 minutes", async () => {
  const db = admin.firestore();
  const cutoff = admin.firestore.Timestamp.fromMillis(
    Date.now() - PRESENCE_STALE_MINUTES * 60 * 1000,
  );
  try {
    let totalCleaned = 0;

    for (;;) {
      const stale = await db
        .collectionGroup("presence")
        .where("isActive", "==", true)
        .where("lastSeen", "<", cutoff)
        .limit(CLEANUP_PAGE_SIZE)
        .get();
      if (stale.empty) break;

      const batch = db.batch();
      stale.docs.forEach((d) => {
        batch.update(d.ref, {
          isActive: false,
          leftAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      });
      await batch.commit();

      totalCleaned += stale.size;
      if (stale.size < CLEANUP_PAGE_SIZE) break;
    }

    console.log(`cleanupStalePresence: ${totalCleaned} utenti marcati inattivi`);
  } catch (e) {
    console.error("cleanupStalePresence: errore:", e);
  }
});

/**
 * Elimina i proximity token scaduti (expiresAt + grace period).
 * Il token viene rinnovato dal client a ogni heartbeat: se non viene più
 * rinnovato (leave o app uccisa) scade e qui viene rimosso, così la
 * collection non cresce all'infinito e il preload al join resta leggero.
 */
exports.cleanupExpiredProximityTokens = onSchedule("every 60 minutes", async () => {
  const cutoff = admin.firestore.Timestamp.fromMillis(
    Date.now() - TOKEN_GRACE_MINUTES * 60 * 1000,
  );
  try {
    const deleted = await deleteByQuery(() =>
      admin
        .firestore()
        .collectionGroup("proximityTokens")
        .where("expiresAt", "<", cutoff),
    );
    console.log(`cleanupExpiredProximityTokens: ${deleted} token rimossi`);
  } catch (e) {
    console.error("cleanupExpiredProximityTokens: errore:", e);
  }
});
