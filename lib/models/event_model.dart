import 'package:cloud_firestore/cloud_firestore.dart';

class EventModel {
  final String id;
  final String name;
  final String description;
  final String location;
  final DateTime startDate;
  final DateTime endDate;
  final bool isActive;

  /// UUID fisso del service BLE per quest'app (uguale per tutti gli eventi).
  /// Serve a flutter_blue_plus per filtrare lo scan solo su dispositivi ProxiMeet.
  static const String appBleServiceUuid =
      '12345678-1234-1234-1234-123456789abc';

  EventModel({
    required this.id,
    required this.name,
    this.description = '',
    required this.location,
    required this.startDate,
    required this.endDate,
    required this.isActive,
  });

  factory EventModel.fromMap(String id, Map<String, dynamic> map) {
    return EventModel(
      id: id,
      name: map['name'] ?? '',
      description: map['description'] ?? '',
      location: map['location'] ?? '',
      startDate: (map['startDate'] as Timestamp).toDate(),
      endDate: (map['endDate'] as Timestamp).toDate(),
      isActive: map['isActive'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'location': location,
      'startDate': Timestamp.fromDate(startDate),
      'endDate': Timestamp.fromDate(endDate),
      'isActive': isActive,
    };
  }
}
