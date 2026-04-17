import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/logger.dart';

/// Servizio per upload foto e gestione storage Firebase.
///
/// Singleton: usa [StorageService.instance].
class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  final FirebaseStorage _storage = FirebaseStorage.instance;
  final ImagePicker _picker = ImagePicker();

  Future<bool> requestPhotoPermission() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 33) {
        final status = await Permission.photos.request();
        return status.isGranted;
      } else {
        final status = await Permission.storage.request();
        return status.isGranted;
      }
    }
    return true;
  }

  Future<File?> pickImage() async {
    final granted = await requestPhotoPermission();
    if (!granted) {
      Log.w('STORAGE', 'Permesso foto negato');
      return null;
    }

    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked == null) return null;
    return File(picked.path);
  }

  Future<String?> uploadAvatar(String uid, File imageFile) async {
    try {
      final ref = _storage.ref().child('avatars/$uid.jpg');
      final task = await ref.putFile(
        imageFile,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      final url = await task.ref.getDownloadURL();
      Log.d('STORAGE', 'Avatar caricato: $url');
      return url;
    } catch (e) {
      Log.e('STORAGE', 'Errore upload', e);
      return null;
    }
  }
}
