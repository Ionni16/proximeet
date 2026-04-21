import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String uid;
  final String firstName;
  final String lastName;
  final String email;
  final String company;
  final String role;
  final String avatarURL;
  final String? linkedin;
  final String? github;
  final String? twitter;
  final String? phone;
  final String? bio;
  final DateTime createdAt;

  UserModel({
    required this.uid,
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.company,
    required this.role,
    required this.avatarURL,
    this.linkedin,
    this.github,
    this.twitter,
    this.phone,
    this.bio,
    required this.createdAt,
  });

  String get fullName {
    final parts = [firstName.trim(), lastName.trim()]
        .where((p) => p.isNotEmpty)
        .toList();
    return parts.join(' ');
  }

  /// Per Firestore — usa Timestamp, non ISO string.
  Map<String, dynamic> toMap() {
    return {
      'uid': uid.trim(),
      'firstName': firstName.trim(),
      'lastName': lastName.trim(),
      'email': email.trim().toLowerCase(),
      'company': company.trim(),
      'role': role.trim(),
      'avatarURL': avatarURL.trim(),
      'linkedin': _normalizedOptional(linkedin),
      'github': _normalizedOptional(github),
      'twitter': _normalizedOptional(twitter),
      'phone': _normalizedOptional(phone),
      'bio': _normalizedOptional(bio),
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  factory UserModel.fromMap(Map<String, dynamic> map) {
    return UserModel(
      uid: _stringOrEmpty(map['uid']),
      firstName: _stringOrEmpty(map['firstName']),
      lastName: _stringOrEmpty(map['lastName']),
      email: _stringOrEmpty(map['email']).toLowerCase(),
      company: _stringOrEmpty(map['company']),
      role: _stringOrEmpty(map['role']),
      avatarURL: _stringOrEmpty(map['avatarURL']),
      linkedin: _nonEmpty(map['linkedin']),
      github: _nonEmpty(map['github']),
      twitter: _nonEmpty(map['twitter']),
      phone: _nonEmpty(map['phone']),
      bio: _nonEmpty(map['bio']),
      createdAt: _parseDateTime(map['createdAt']),
    );
  }

  /// Summary pubblico compatto per bleMapping / nearby.
  Map<String, dynamic> toSummary() {
    return {
      'uid': uid.trim(),
      'displayName': fullName,
      'company': company.trim(),
      'role': role.trim(),
      'avatarURL': avatarURL.trim(),
      'bio': (bio ?? '').trim(),
    };
  }

  /// Dati contatto completi utili per wallet / connessioni salvate.
  Map<String, dynamic> toWalletContactData() {
    return {
      'uid': uid.trim(),
      'firstName': firstName.trim(),
      'lastName': lastName.trim(),
      'displayName': fullName,
      'company': company.trim(),
      'role': role.trim(),
      'email': email.trim().toLowerCase(),
      'phone': _normalizedOptional(phone),
      'linkedin': _normalizedOptional(linkedin),
      'github': _normalizedOptional(github),
      'twitter': _normalizedOptional(twitter),
      'avatarURL': avatarURL.trim(),
      'bio': _normalizedOptional(bio),
    };
  }

  static String _stringOrEmpty(dynamic value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  static String _normalizedOptional(String? value) {
    return value?.trim() ?? '';
  }

  /// Restituisce null se la stringa è vuota o null.
  static String? _nonEmpty(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }

  /// Gestisce sia Timestamp Firestore che ISO string.
  static DateTime _parseDateTime(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
    return DateTime.now();
  }
}