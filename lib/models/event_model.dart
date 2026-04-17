import 'package:cloud_firestore/cloud_firestore.dart';

class EventModel {
  final String id;
  final String name;
  final String description;
  final String location;
  final DateTime startDate;
  final DateTime endDate;
  final bool isActive;

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

  /// Formato data leggibile.
  String get dateRange {
    final start = '${startDate.day}/${startDate.month}';
    final end = '${endDate.day}/${endDate.month}';
    return '$start – $end';
  }

  /// True se l'evento è in corso adesso.
  bool get isOngoing {
    final now = DateTime.now();
    return now.isAfter(startDate) && now.isBefore(endDate);
  }
}
