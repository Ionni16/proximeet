class ConnectionRequest {
  final String id;
  final String senderUid;
  final String receiverUid;
  final String status;
  final DateTime? createdAt;

  ConnectionRequest({
    required this.id,
    required this.senderUid,
    required this.receiverUid,
    required this.status,
    this.createdAt,
  });

  factory ConnectionRequest.fromMap(String id, Map<String, dynamic> map) {
    return ConnectionRequest(
      id: id,
      senderUid: map['senderUid'] ?? '',
      receiverUid: map['receiverUid'] ?? '',
      status: map['status'] ?? 'pending',
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
    required this.note,
  });

  String get fullName => '$firstName $lastName';

  factory WalletContact.fromMap(Map<String, dynamic> map) {
    return WalletContact(
      uid: map['uid'] ?? '',
      firstName: map['firstName'] ?? '',
      lastName: map['lastName'] ?? '',
      company: map['company'] ?? '',
      role: map['role'] ?? '',
      email: map['email'] ?? '',
      phone: map['phone'] ?? '',
      linkedin: map['linkedin'] ?? '',
      avatarURL: map['avatarURL'] ?? '',
      connectedAt: map['connectedAt']?.toDate(),
      note: map['note'] ?? '',
    );
  }
}