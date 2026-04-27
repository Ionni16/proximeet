class ConnectionRequest {
  final String id;
  final String senderUid;
  final String receiverUid;
  final String eventId;
  final String status;
  final DateTime? createdAt;

  ConnectionRequest({
    required this.id,
    required this.senderUid,
    required this.receiverUid,
    required this.eventId,
    required this.status,
    this.createdAt,
  });

  factory ConnectionRequest.fromMap(String id, Map<String, dynamic> map) {
    return ConnectionRequest(
      id: id,
      senderUid: (map['senderUid'] ?? '').toString(),
      receiverUid: (map['receiverUid'] ?? '').toString(),
      eventId: (map['eventId'] ?? '').toString(),
      status: (map['status'] ?? 'pending').toString(),
      createdAt: map['createdAt']?.toDate(),
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

      // Compatibilità con tutti i nomi campo usati nel progetto / Firestore.
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