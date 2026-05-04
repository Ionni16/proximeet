class ConnectionRequest {
  final String id;
  final String senderUid;
  final String receiverUid;
  final String eventId;
  final String status;
  final DateTime? createdAt;
  final String senderDisplayName;
  final String senderRole;
  final String senderCompany;
  final String senderAvatarURL;

  ConnectionRequest({
    required this.id,
    required this.senderUid,
    required this.receiverUid,
    required this.eventId,
    required this.status,
    this.createdAt,
    this.senderDisplayName = '',
    this.senderRole = '',
    this.senderCompany = '',
    this.senderAvatarURL = '',
  });

  factory ConnectionRequest.fromMap(String id, Map<String, dynamic> map) {
    return ConnectionRequest(
      id: id,
      senderUid: (map['senderUid'] ?? '').toString(),
      receiverUid: (map['receiverUid'] ?? '').toString(),
      eventId: (map['eventId'] ?? '').toString(),
      status: (map['status'] ?? 'pending').toString(),
      createdAt: map['createdAt']?.toDate(),
      senderDisplayName: (map['senderDisplayName'] ?? '').toString().trim(),
      senderRole: (map['senderRole'] ?? '').toString().trim(),
      senderCompany: (map['senderCompany'] ?? '').toString().trim(),
      senderAvatarURL: (map['senderAvatarURL'] ?? '').toString().trim(),
    );
  }
}

class WalletContact {
  final String uid;
  final String firstName;
  final String lastName;
  final String company;
  final String role;
  final String email;
  final String phone;
  final String linkedin;
  final String avatarURL;
  final DateTime? connectedAt;
  final String eventName;
  final String note;

  WalletContact({
    required this.uid,
    required this.firstName,
    required this.lastName,
    required this.company,
    required this.role,
    required this.email,
    required this.phone,
    required this.linkedin,
    required this.avatarURL,
    this.connectedAt,
    this.eventName = '',
    required this.note,
  });

  String get fullName {
    final name = '$firstName $lastName'.trim();
    return name.isEmpty ? 'Contatto' : name;
  }

  factory WalletContact.fromMap(Map<String, dynamic> map) {
    return WalletContact(
      uid: (map['uid'] ?? '').toString(),
      firstName: (map['firstName'] ?? '').toString(),
      lastName: (map['lastName'] ?? '').toString(),
      company: (map['company'] ?? '').toString(),
      role: (map['role'] ?? '').toString(),
      email: (map['email'] ?? '').toString(),
      phone: (map['phone'] ?? '').toString(),
      linkedin: (map['linkedin'] ?? '').toString(),

      // L'URL dell'avatar può avere nomi diversi nei vecchi documenti Firestore, proviamo tutti.
      avatarURL: (map['avatarURL'] ??
              map['avatarUrl'] ??
              map['photoURL'] ??
              map['photoUrl'] ??
              map['avatar'] ??
              '')
          .toString()
          .trim(),

      connectedAt: map['connectedAt']?.toDate(),
      eventName: (map['eventName'] ?? '').toString(),
      note: (map['note'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'firstName': firstName,
      'lastName': lastName,
      'company': company,
      'role': role,
      'email': email,
      'phone': phone,
      'linkedin': linkedin,
      'avatarURL': avatarURL,
      'avatarUrl': avatarURL,
      'photoURL': avatarURL,
      'eventName': eventName,
      'note': note,
    };
  }
}