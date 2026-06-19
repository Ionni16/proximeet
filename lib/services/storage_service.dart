import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../core/logger.dart';

/// Gestisce la scelta e l'upload della foto profilo su Firebase Storage.
///
/// Non richiede manualmente permessi di galleria: image_picker usa il Photo
/// Picker di sistema su Android recenti e PHPicker su iOS. Richiedere
/// Permission.photos/storage prima del picker può bloccare Android anche quando
/// il selettore di sistema sarebbe disponibile.
class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  final FirebaseStorage _storage = FirebaseStorage.instance;
  final ImagePicker _picker = ImagePicker();

  Future<File?> pickImage() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 88,
        requestFullMetadata: false,
      );
      if (picked == null) return null;

      final file = File(picked.path);
      if (!await file.exists()) {
        throw StateError('Il file selezionato non è più disponibile.');
      }
      if (await file.length() == 0) {
        throw StateError('Il file selezionato è vuoto.');
      }
      return file;
    } catch (e) {
      Log.e('STORAGE', 'Errore selezione immagine', e);
      rethrow;
    }
  }

  /// Carica ogni nuova foto con un nome diverso.
  ///
  /// Il file resta `avatars/<uid>.jpg` per essere compatibile con le regole Storage
  /// esistenti, ma al download URL viene aggiunto un parametro di versione.
  /// In questo modo iOS e CachedNetworkImage aggiornano subito la cache.
  Future<String?> uploadAvatar(String uid, File imageFile) async {
    try {
      if (uid.trim().isEmpty) {
        throw ArgumentError('UID utente mancante');
      }
      if (!await imageFile.exists()) {
        throw StateError('Immagine locale non trovata');
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final ref = _storage.ref().child('avatars/$uid.jpg');
      final task = await ref.putFile(
        imageFile,
        SettableMetadata(
          contentType: 'image/jpeg',
          cacheControl: 'public,max-age=3600',
          customMetadata: {
            'ownerUid': uid,
            'uploadedAt': timestamp.toString(),
          },
        ),
      );
      final url = await task.ref.getDownloadURL();
      final separator = url.contains('?') ? '&' : '?';
      final versionedUrl = '$url${separator}v=$timestamp';
      Log.d('STORAGE', 'Avatar caricato correttamente');
      return versionedUrl;
    } on FirebaseException catch (e) {
      Log.e('STORAGE', 'Errore Firebase Storage [${e.code}]', e);
      rethrow;
    } catch (e) {
      Log.e('STORAGE', 'Errore upload avatar', e);
      rethrow;
    }
  }
}
