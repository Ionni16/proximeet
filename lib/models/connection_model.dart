import '../core/parsing.dart';

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
      senderUid: parseString(map['senderUid']),
      receiverUid: parseString(map['receiverUid']),
      eventId: parseString(map['eventId']),
      status: parseString(map['status']).isEmpty
          ? 'pending'
          : parseString(map['status']),
      createdAt: parseDateTime(map['createdAt']),
      senderDisplayName: parseString(map['senderDisplayName']),
      senderRole: parseString(map['senderRole']),
      senderCompany: parseString(map['senderCompany']),
      senderAvatarURL: parseString(map['senderAvatarURL']),
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
    this.note = '',
  });

  String get fullName {
    final name = '$firstName $lastName'.trim();
    return name.isEmpty ? 'Contatto' : name;
  }

  factory WalletContact.fromMap(Map<String, dynamic> map) {
    return WalletContact(
      uid: parseString(map['uid']),
      firstName: parseString(map['firstName']),
      lastName: parseString(map['lastName']),
      company: parseString(map['company']),
      role: parseString(map['role']),
      email: parseString(map['email']),
      phone: parseString(map['phone']),
      linkedin: parseString(map['linkedin']),

      // Retro-compatibilità: i vecchi documenti possono avere l'avatar
      // sotto chiavi diverse. In lettura le accettiamo tutte; in scrittura
      // (toMap) usiamo solo avatarURL.
      avatarURL: parseString(
        map['avatarURL'] ??
            map['avatarUrl'] ??
            map['photoURL'] ??
            map['photoUrl'] ??
            map['avatar'],
      ),

      connectedAt: parseDateTime(map['connectedAt']),
      eventName: parseString(map['eventName']),
      note: parseString(map['note']),
    );
  }

  /// Serializzazione canonica: una sola chiave per l'avatar (`avatarURL`).
  /// Le scritture nel wallet avvengono comunque server-side; questo
  /// metodo resta per completezza e per eventuali usi locali/test.
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
      'eventName': eventName,
      'note': note,
    };
  }
}
