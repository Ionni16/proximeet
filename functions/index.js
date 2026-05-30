const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");
const querystring = require("querystring");

admin.initializeApp();

const linkedinClientSecret = defineSecret("LINKEDIN_CLIENT_SECRET");

async function getUserFcmToken(userId) {
  const db = admin.firestore();
  const doc = await db.collection("users").doc(userId).get();
  if (!doc.exists) return null;
  return doc.data().fcmToken || null;
}

async function getUserName(userId) {
  const db = admin.firestore();
  const doc = await db.collection("users").doc(userId).get();
  if (!doc.exists) return "Qualcuno";
  const data = doc.data();
  return `${data.firstName} ${data.lastName}`;
}

function httpsPost(url, postData, headers = {}) {
  return new Promise((resolve, reject) => {
    const urlObj = new URL(url);
    const bodyString =
      typeof postData === "string" ? postData : querystring.stringify(postData);
    const options = {
      hostname: urlObj.hostname,
      path: urlObj.pathname + urlObj.search,
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "Content-Length": Buffer.byteLength(bodyString),
        ...headers,
      },
    };
    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        try { resolve(JSON.parse(data)); } catch { resolve(data); }
      });
    });
    req.on("error", reject);
    req.write(bodyString);
    req.end();
  });
}

function httpsGet(url, headers = {}) {
  return new Promise((resolve, reject) => {
    const urlObj = new URL(url);
    const options = {
      hostname: urlObj.hostname,
      path: urlObj.pathname + urlObj.search,
      method: "GET",
      headers,
    };
    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        try { resolve(JSON.parse(data)); } catch { resolve(data); }
      });
    });
    req.on("error", reject);
    req.end();
  });
}

exports.linkedinAuth = onCall(
  { secrets: [linkedinClientSecret] },
  async (request) => {
    const { code, redirectUri, clientId } = request.data;

    if (!code || !redirectUri || !clientId) {
      throw new HttpsError("invalid-argument", "Parametri mancanti: code, redirectUri, clientId");
    }

    const clientSecret = linkedinClientSecret.value();

    // 1. Scambia il codice per un access token
    let tokenData;
    try {
      tokenData = await httpsPost("https://www.linkedin.com/oauth/v2/accessToken", {
        grant_type: "authorization_code",
        code,
        redirect_uri: redirectUri,
        client_id: clientId,
        client_secret: clientSecret,
      });
    } catch (e) {
      console.error("Errore LinkedIn token exchange:", e);
      throw new HttpsError("internal", "Impossibile ottenere access token LinkedIn");
    }

    if (tokenData.error || !tokenData.access_token) {
      console.error("LinkedIn token error:", tokenData);
      throw new HttpsError("unauthenticated", tokenData.error_description || "Token LinkedIn non valido");
    }

    const accessToken = tokenData.access_token;

    // 2. Recupera profilo utente via OpenID Connect
    let profile;
    try {
      profile = await httpsGet("https://api.linkedin.com/v2/userinfo", {
        Authorization: `Bearer ${accessToken}`,
      });
    } catch (e) {
      console.error("Errore LinkedIn userinfo:", e);
      throw new HttpsError("internal", "Impossibile recuperare profilo LinkedIn");
    }

    if (!profile.sub) {
      console.error("LinkedIn userinfo mancante sub:", profile);
      throw new HttpsError("internal", "Profilo LinkedIn non valido");
    }

    // 3. Crea o aggiorna l'utente Firebase
    const uid = `linkedin_${profile.sub}`;
    const email = profile.email || null;
    const firstName = profile.given_name || "";
    const lastName = profile.family_name || "";
    const photoURL = profile.picture || null;
    const displayName = `${firstName} ${lastName}`.trim();

    // updateRecord: MAI includere email per evitare conflitti con account email/password.
    // L'email viene salvata in Firestore, non serve in Firebase Auth.
    const updateRecord = { displayName };
    if (photoURL) updateRecord.photoURL = photoURL;

    // createRecord: proviamo con email, con fallback senza.
    const createRecord = { uid, displayName };
    if (email) createRecord.email = email;
    if (photoURL) createRecord.photoURL = photoURL;

    try {
      await admin.auth().updateUser(uid, updateRecord);
      console.log(`LinkedIn user aggiornato: ${uid}`);
    } catch (e) {
      if (e.code === "auth/user-not-found") {
        try {
          await admin.auth().createUser(createRecord);
          console.log(`LinkedIn user creato: ${uid}`);
        } catch (createError) {
          if (createError.code === "auth/email-already-exists") {
            const { email: _ignored, ...noEmail } = createRecord;
            await admin.auth().createUser(noEmail);
            console.log(`LinkedIn user creato senza email (email già in uso): ${uid}`);
          } else {
            console.error("Errore createUser LinkedIn:", createError);
            throw new HttpsError("internal", "Errore creazione account");
          }
        }
      } else {
        console.error("Errore updateUser LinkedIn:", e);
        throw new HttpsError("internal", "Errore aggiornamento account");
      }
    }

    // 4. Controlla se esiste già un documento Firestore
    const db = admin.firestore();
    const userDoc = await db.collection("users").doc(uid).get();
    const isNewUser = !userDoc.exists;

    // 5. Genera Custom Token
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
  }
);

exports.sendCardRequest = onCall(async (request) => {
  const { receiverUid } = request.data;
  const senderUid = request.auth?.uid;
  if (!senderUid) throw new HttpsError("unauthenticated", "Devi essere autenticato.");
  if (!receiverUid) throw new HttpsError("invalid-argument", "receiverUid mancante.");
  try {
    const senderName = await getUserName(senderUid);
    const receiverToken = await getUserFcmToken(receiverUid);
    if (receiverToken) {
      await admin.messaging().send({
        token: receiverToken,
        notification: { title: "Nuova richiesta biglietto", body: `${senderName} vuole scambiare il biglietto con te` },
        data: { type: "card_request", senderUid, senderName },
        android: { priority: "high" },
        apns: { payload: { aps: { sound: "default", badge: 1 } } },
      });
    }
  } catch (e) { console.error("Errore notifica sendCardRequest:", e); }
  return { success: true };
});

exports.respondCardRequest = onCall(async (request) => {
  const { senderUid, accepted } = request.data;
  const receiverUid = request.auth?.uid;
  if (!receiverUid) throw new HttpsError("unauthenticated", "Devi essere autenticato.");
  if (!senderUid) throw new HttpsError("invalid-argument", "senderUid mancante.");
  try {
    const receiverName = await getUserName(receiverUid);
    const senderToken = await getUserFcmToken(senderUid);
    if (senderToken) {
      await admin.messaging().send({
        token: senderToken,
        notification: {
          title: accepted ? "Richiesta accettata!" : "Richiesta rifiutata",
          body: accepted ? `${receiverName} ha accettato il tuo biglietto` : `${receiverName} ha rifiutato la tua richiesta`,
        },
        data: { type: "card_response", receiverUid, accepted: accepted.toString() },
        android: { priority: "high" },
        apns: { payload: { aps: { sound: "default" } } },
      });
    }
  } catch (e) { console.error("Errore notifica respondCardRequest:", e); }
  return { success: true };
});

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
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Devi essere autenticato per eliminare l'account.");
  }

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

      // detections/{uid} + sottocollezione nearby (le mie rilevazioni)
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

exports.cleanupOldDetections = onSchedule("every 60 minutes", async () => {
  const db = admin.firestore();
  const tenMinutesAgo = admin.firestore.Timestamp.fromDate(new Date(Date.now() - 10 * 60 * 1000));
  try {
    const events = await db.collection("events").where("isActive", "==", true).get();
    let totalDeleted = 0;
    for (const eventDoc of events.docs) {
      const detectionDocs = await db.collection("events").doc(eventDoc.id).collection("detections").listDocuments();
      for (const detDocRef of detectionDocs) {
        const oldNearby = await detDocRef.collection("nearby").where("lastSeen", "<", tenMinutesAgo).get();
        if (oldNearby.empty) continue;
        const batch = db.batch();
        oldNearby.docs.forEach((d) => batch.delete(d.ref));
        await batch.commit();
        totalDeleted += oldNearby.size;
      }
    }
    console.log(`Cleanup completato: ${totalDeleted} detections rimosse`);
  } catch (e) { console.error("Errore cleanup:", e); }
});

exports.cleanupStalePresence = onSchedule("every 5 minutes", async () => {
  const db = admin.firestore();
  const fiveMinutesAgo = admin.firestore.Timestamp.fromDate(new Date(Date.now() - 5 * 60 * 1000));
  try {
    const events = await db.collection("events").where("isActive", "==", true).get();
    let totalCleaned = 0;
    for (const eventDoc of events.docs) {
      const stale = await db.collection("events").doc(eventDoc.id).collection("presence")
        .where("isActive", "==", true).where("lastSeen", "<", fiveMinutesAgo).get();
      if (stale.empty) continue;
      const batch = db.batch();
      stale.docs.forEach((d) => { batch.update(d.ref, { isActive: false, leftAt: admin.firestore.FieldValue.serverTimestamp() }); });
      await batch.commit();
      totalCleaned += stale.size;
    }
    console.log(`Presence cleanup: ${totalCleaned} utenti marcati inattivi`);
  } catch (e) { console.error("Errore presence cleanup:", e); }
});
