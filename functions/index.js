const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

admin.initializeApp();

// ── UTILITY ──────────────────────────────────────────────

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

// ── FUNZIONE 1: sendCardRequest ───────────────────────────
// Invia notifica push quando A vuole scambiare il biglietto con B.
//
// NOTA: La richiesta viene scritta su Firestore dal client (FirestoreService).
// Questa funzione gestisce SOLO la notifica push.
exports.sendCardRequest = onCall(async (request) => {
  const { receiverUid } = request.data;
  const senderUid = request.auth?.uid;

  if (!senderUid) {
    throw new HttpsError("unauthenticated", "Devi essere autenticato.");
  }
  if (!receiverUid) {
    throw new HttpsError("invalid-argument", "receiverUid mancante.");
  }

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
        },
        android: { priority: "high" },
        apns: {
          payload: {
            aps: { sound: "default", badge: 1 },
          },
        },
      });
    }
  } catch (e) {
    console.error("Errore notifica sendCardRequest:", e);
  }

  return { success: true };
});

// ── FUNZIONE 2: respondCardRequest ────────────────────────
// Invia notifica push quando B accetta/rifiuta la richiesta di A.
//
// NOTA: Il wallet viene scritto dal client (FirestoreService.respondToRequest).
// Questa funzione gestisce SOLO la notifica push.
// Questo evita il problema di doppia scrittura wallet (client + CF).
exports.respondCardRequest = onCall(async (request) => {
  const { senderUid, accepted } = request.data;
  const receiverUid = request.auth?.uid;

  if (!receiverUid) {
    throw new HttpsError("unauthenticated", "Devi essere autenticato.");
  }
  if (!senderUid) {
    throw new HttpsError("invalid-argument", "senderUid mancante.");
  }

  try {
    const receiverName = await getUserName(receiverUid);
    const senderToken = await getUserFcmToken(senderUid);

    if (senderToken) {
      await admin.messaging().send({
        token: senderToken,
        notification: {
          title: accepted ? "Richiesta accettata!" : "Richiesta rifiutata",
          body: accepted
            ? `${receiverName} ha accettato il tuo biglietto`
            : `${receiverName} ha rifiutato la tua richiesta`,
        },
        data: {
          type: "card_response",
          receiverUid,
          accepted: accepted.toString(),
        },
        android: { priority: "high" },
        apns: {
          payload: {
            aps: { sound: "default" },
          },
        },
      });
    }
  } catch (e) {
    console.error("Errore notifica respondCardRequest:", e);
  }

  return { success: true };
});

// ── FUNZIONE 3: cleanupOldDetections ─────────────────────
// Cancella rilevazioni BLE più vecchie di 10 minuti.
// Gira automaticamente ogni ora.
//
// FIX: il vecchio codice cercava nella collection "bleDetections"
// che non esiste. Il path corretto è:
//   events/{eventId}/detections/{uid}/nearby/{targetUid}
exports.cleanupOldDetections = onSchedule("every 60 minutes", async () => {
  const db = admin.firestore();
  const tenMinutesAgo = admin.firestore.Timestamp.fromDate(
    new Date(Date.now() - 10 * 60 * 1000)
  );

  try {
    // Recupera tutti gli eventi attivi
    const events = await db
      .collection("events")
      .where("isActive", "==", true)
      .get();

    let totalDeleted = 0;

    for (const eventDoc of events.docs) {
      const eventId = eventDoc.id;

      // Per ogni evento, trova tutti i documenti "detections/{uid}"
      const detectionDocs = await db
        .collection("events")
        .doc(eventId)
        .collection("detections")
        .listDocuments();

      for (const detDocRef of detectionDocs) {
        // Dentro ogni detections/{uid}, cerca nearby vecchi
        const oldNearby = await detDocRef
          .collection("nearby")
          .where("lastSeen", "<", tenMinutesAgo)
          .get();

        if (oldNearby.empty) continue;

        const batch = db.batch();
        oldNearby.docs.forEach((d) => batch.delete(d.ref));
        await batch.commit();
        totalDeleted += oldNearby.size;
      }
    }

    console.log(`Cleanup completato: ${totalDeleted} detections rimosse`);
  } catch (e) {
    console.error("Errore cleanup:", e);
  }
});

// ── FUNZIONE 4: cleanupStalePresence ─────────────────────
// Marca come inattivi gli utenti il cui heartbeat è fermo da >5 min.
// Gira ogni 5 minuti.
exports.cleanupStalePresence = onSchedule("every 5 minutes", async () => {
  const db = admin.firestore();
  const fiveMinutesAgo = admin.firestore.Timestamp.fromDate(
    new Date(Date.now() - 5 * 60 * 1000)
  );

  try {
    const events = await db
      .collection("events")
      .where("isActive", "==", true)
      .get();

    let totalCleaned = 0;

    for (const eventDoc of events.docs) {
      const stale = await db
        .collection("events")
        .doc(eventDoc.id)
        .collection("presence")
        .where("isActive", "==", true)
        .where("lastSeen", "<", fiveMinutesAgo)
        .get();

      if (stale.empty) continue;

      const batch = db.batch();
      stale.docs.forEach((d) => {
        batch.update(d.ref, {
          isActive: false,
          leftAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      });
      await batch.commit();
      totalCleaned += stale.size;
    }

    console.log(`Presence cleanup: ${totalCleaned} utenti marcati inattivi`);
  } catch (e) {
    console.error("Errore presence cleanup:", e);
  }
});
