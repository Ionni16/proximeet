const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

admin.initializeApp();

// ── UTILITY ──────────────────────────────────────────────

async function getUserFcmToken(userId) {
  const db = admin.firestore();
  const doc = await db.collection("users").doc(userId).get();
  if (!doc.exists) throw new Error(`Utente ${userId} non trovato`);
  return doc.data().fcmToken || null;
}

async function getUserName(userId) {
  const db = admin.firestore();
  const doc = await db.collection("users").doc(userId).get();
  if (!doc.exists) return "Qualcuno";
  const data = doc.data();
  return `${data.firstName} ${data.lastName}`;
}

// ── FUNZIONE 1: sendCardRequest ───────────────────────────
// Chiamata quando A vuole scambiare il biglietto con B
exports.sendCardRequest = onCall(async (request) => {
  const { receiverUid } = request.data;
  const senderUid = request.auth?.uid;

  if (!senderUid) {
    throw new HttpsError("unauthenticated", "Devi essere autenticato.");
  }
  if (!receiverUid) {
    throw new HttpsError("invalid-argument", "receiverUid mancante.");
  }

  const db = admin.firestore();

  // Salva richiesta su Firestore
  await db
    .collection("connectionRequests")
    .doc(`${senderUid}_${receiverUid}`)
    .set({
      senderUid,
      receiverUid,
      status: "pending",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

  // Invia notifica push a B
  try {
    const senderName = await getUserName(senderUid);
    const receiverToken = await getUserFcmToken(receiverUid);

    if (receiverToken) {
      await admin.messaging().send({
        token: receiverToken,
        notification: {
          title: "Nuova richiesta biglietto",
          body: `${senderName} vuole scambiare il biglietto con te`,
        },
        data: {
          type: "card_request",
          senderUid,
          senderName,
          requestId: `${senderUid}_${receiverUid}`,
        },
        android: {
          priority: "high",
        },
      });
    }
  } catch (e) {
    console.error("Errore notifica:", e);
  }

  return { success: true };
});

// ── FUNZIONE 2: respondCardRequest ────────────────────────
// Chiamata quando B accetta o rifiuta la richiesta di A
exports.respondCardRequest = onCall(async (request) => {
  const { senderUid, accepted } = request.data;
  const receiverUid = request.auth?.uid;

  if (!receiverUid) {
    throw new HttpsError("unauthenticated", "Devi essere autenticato.");
  }
  if (!senderUid) {
    throw new HttpsError("invalid-argument", "senderUid mancante.");
  }

  const db = admin.firestore();
  const requestId = `${senderUid}_${receiverUid}`;
  const status = accepted ? "accepted" : "rejected";

  // Aggiorna stato richiesta
  await db
    .collection("connectionRequests")
    .doc(requestId)
    .update({
      status,
      respondedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

  // Se accettata salva nel wallet di entrambi
  if (accepted) {
    const [senderDoc, receiverDoc] = await Promise.all([
      db.collection("users").doc(senderUid).get(),
      db.collection("users").doc(receiverUid).get(),
    ]);

    const senderData = senderDoc.data();
    const receiverData = receiverDoc.data();

    // Salva nel wallet del sender
    await db
      .collection("connections")
      .doc(senderUid)
      .collection("contacts")
      .doc(receiverUid)
      .set({
        uid: receiverUid,
        firstName: receiverData.firstName,
        lastName: receiverData.lastName,
        company: receiverData.company,
        role: receiverData.role,
        email: receiverData.email,
        phone: receiverData.phone || "",
        linkedin: receiverData.linkedin || "",
        avatarURL: receiverData.avatarURL || "",
        connectedAt: admin.firestore.FieldValue.serverTimestamp(),
        note: "",
      });

    // Salva nel wallet del receiver
    await db
      .collection("connections")
      .doc(receiverUid)
      .collection("contacts")
      .doc(senderUid)
      .set({
        uid: senderUid,
        firstName: senderData.firstName,
        lastName: senderData.lastName,
        company: senderData.company,
        role: senderData.role,
        email: senderData.email,
        phone: senderData.phone || "",
        linkedin: senderData.linkedin || "",
        avatarURL: senderData.avatarURL || "",
        connectedAt: admin.firestore.FieldValue.serverTimestamp(),
        note: "",
      });
  }

  // Notifica push al sender con la risposta
  try {
    const receiverName = await getUserName(receiverUid);
    const senderToken = await getUserFcmToken(senderUid);

    if (senderToken) {
      await admin.messaging().send({
        token: senderToken,
        notification: {
          title: accepted
            ? "Richiesta accettata!"
            : "Richiesta rifiutata",
          body: accepted
            ? `${receiverName} ha accettato il tuo biglietto`
            : `${receiverName} ha rifiutato la tua richiesta`,
        },
        data: {
          type: "card_response",
          receiverUid,
          accepted: accepted.toString(),
        },
        android: {
          priority: "high",
        },
      });
    }
  } catch (e) {
    console.error("Errore notifica risposta:", e);
  }

  return { success: true };
});

// ── FUNZIONE 3: cleanupOldDetections ─────────────────────
// Cancella rilevazioni BLE più vecchie di 10 minuti
// Gira automaticamente ogni ora
exports.cleanupOldDetections = onSchedule("every 60 minutes", async () => {
  const db = admin.firestore();
  const tenMinutesAgo = new Date(Date.now() - 10 * 60 * 1000);

  const collections = await db.collection("bleDetections").listDocuments();

  for (const docRef of collections) {
    const oldDetections = await docRef
      .collection("detections")
      .where("timestamp", "<", tenMinutesAgo)
      .get();

    const batch = db.batch();
    oldDetections.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }

  console.log("Cleanup completato");
});