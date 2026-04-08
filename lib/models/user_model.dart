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

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'firstName': firstName,
      'lastName': lastName,
      'email': email,
      'company': company,
      'role': role,
      'avatarURL': avatarURL,
      'linkedin': linkedin,
      'github': github,
      'twitter': twitter,
      'phone': phone,
      'bio': bio,
      'createdAt': createdAt.toIso8601String(),
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
      linkedin: map['linkedin'],
      github: map['github'],
      twitter: map['twitter'],
      phone: map['phone'],
      bio: map['bio'],
      createdAt: DateTime.parse(
        map['createdAt'] ?? DateTime.now().toIso8601String(),
      ),
    );
  }

  /// Summary compatto per bleMapping / presence
  Map<String, dynamic> toSummary() {
    return {
      'uid': uid,
      'displayName': fullName,
      'company': company,
      'role': role,
      'avatarURL': avatarURL,
    };
  }
}
