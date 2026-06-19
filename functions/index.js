const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");
const querystring = require("querystring");

admin.initializeApp();

const linkedinClientSecret = defineSecret("LINKEDIN_CLIENT_SECRET");
const LINKEDIN_CLIENT_ID = "77ldn2lgmzxacy";
const LINKEDIN_REDIRECT_URI = "https://proximeet-5ffe2.web.app/linkedin-callback";

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
        let parsed;
        try { parsed = JSON.parse(data); } catch { parsed = data; }
        resolve({ statusCode: res.statusCode || 0, data: parsed });
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
        let parsed;
        try { parsed = JSON.parse(data); } catch { parsed = data; }
        resolve({ statusCode: res.statusCode || 0, data: parsed });
      });
    });
    req.on("error", reject);
    req.end();
  });
}

exports.linkedinAuth = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 120,
    memory: "256MiB",
    enforceAppCheck: false,
    secrets: [linkedinClientSecret],
  },
  async (request) => {
    const { code } = request.data || {};

    if (!code || typeof code !== "string") {
      throw new HttpsError("invalid-argument", "Codice LinkedIn mancante");
    }

    const clientSecret = linkedinClientSecret.value();

    // 1. Scambia il codice per un access token
    let tokenData;
    try {
      const tokenResponse = await httpsPost("https://www.linkedin.com/oauth/v2/accessToken", {
        grant_type: "authorization_code",
        code,
        redirect_uri: LINKEDIN_REDIRECT_URI,
        client_id: LINKEDIN_CLIENT_ID,
        client_secret: clientSecret,
      });
      tokenData = tokenResponse.data;
      if (tokenResponse.statusCode < 200 || tokenResponse.statusCode >= 300) {
        console.error("LinkedIn token HTTP error:", tokenResponse.statusCode, tokenData);
      }
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
      const profileResponse = await httpsGet("https://api.linkedin.com/v2/userinfo", {
        Authorization: `Bearer ${accessToken}`,
      });
      profile = profileResponse.data;
      if (profileResponse.statusCode < 200 || profileResponse.statusCode >= 300) {
        console.error("LinkedIn userinfo HTTP error:", profileResponse.statusCode, profile);
        throw new Error(`LinkedIn userinfo HTTP ${profileResponse.statusCode}`);
      }
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
exports.deleteAccount = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 180,
    memory: "256MiB",
    enforceAppCheck: false,
  },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError(
        "unauthenticated",
        "Devi essere autenticato per eliminare l'account."
      );
    }

    const db = admin.firestore();
    const warnings = [];
    const warn = (step, error) => {
      console.warn(`deleteAccount [${uid}] ${step}`, error);
      warnings.push(step);
    };

    try {
      // Operazioni limitate e indipendenti: niente scansione di tutti gli eventi,
      // che può consumare quota e produrre RESOURCE_EXHAUSTED.
      try {
        await db.recursiveDelete(db.collection("connections").doc(uid));
      } catch (error) {
        warn("connections", error);
      }

      for (const field of ["senderUid", "receiverUid"]) {
        try {
          const snap = await db
            .collection("connectionRequests")
            .where(field, "==", uid)
            .limit(500)
            .get();
          if (!snap.empty) {
            const batch = db.batch();
            snap.docs.forEach((doc) => batch.delete(doc.ref));
            await batch.commit();
          }
        } catch (error) {
          warn(`connectionRequests:${field}`, error);
        }
      }

      try {
        await db.collection("users").doc(uid).delete();
      } catch (error) {
        warn("user-profile", error);
      }

      try {
        await admin
          .storage()
          .bucket()
          .file(`avatars/${uid}.jpg`)
          .delete({ ignoreNotFound: true });
      } catch (error) {
        warn("avatar", error);
      }

      // Auth viene eliminato per ultimo. Da questo punto il client torna al login.
      try {
        await admin.auth().deleteUser(uid);
      } catch (error) {
        if (error?.code !== "auth/user-not-found") throw error;
      }

      return { success: true, warnings };
    } catch (error) {
      console.error(`deleteAccount [${uid}] errore finale`, error);
      throw new HttpsError(
        "internal",
        error?.message || "Impossibile completare l'eliminazione dell'account."
      );
    }
  }
);

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
