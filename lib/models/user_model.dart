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

  String get fullName => '$firstName $lastName';

  /// Per Firestore — usa Timestamp, non ISO string.
  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'firstName': firstName,
      'lastName': lastName,
      'email': email,
      'company': company,
      'role': role,
      'avatarURL': avatarURL,
      'linkedin': linkedin ?? '',
      'github': github ?? '',
      'twitter': twitter ?? '',
      'phone': phone ?? '',
      'bio': bio ?? '',
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  factory UserModel.fromMap(Map<String, dynamic> map) {
    return UserModel(
      uid: map['uid'] ?? '',
      firstName: map['firstName'] ?? '',
      lastName: map['lastName'] ?? '',
      email: map['email'] ?? '',
      company: map['company'] ?? '',
      role: map['role'] ?? '',
      avatarURL: map['avatarURL'] ?? '',
      linkedin: _nonEmpty(map['linkedin']),
      github: _nonEmpty(map['github']),
      twitter: _nonEmpty(map['twitter']),
      phone: _nonEmpty(map['phone']),
      bio: _nonEmpty(map['bio']),
      createdAt: _parseDateTime(map['createdAt']),
    );
  }

  /// Summary compatto per bleMapping / presence.
  Map<String, dynamic> toSummary() {
    return {
      'uid': uid,
      'displayName': fullName,
      'company': company,
      'role': role,
      'avatarURL': avatarURL,
      'bio': bio ?? '',
      'email': email,
      'linkedin': linkedin ?? '',
      'phone': phone ?? '',
    };
  }

  /// Restituisce null se la stringa è vuota o null.
  static String? _nonEmpty(dynamic value) {
    if (value == null) return null;
    final s = value.toString();
    return s.isEmpty ? null : s;
  }

  /// Gestisce sia Timestamp Firestore che ISO string.
  static DateTime _parseDateTime(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
    return DateTime.now();
  }
}
