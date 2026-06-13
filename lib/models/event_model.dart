import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/parsing.dart';

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

  /// Parsing difensivo: un documento con un campo data malformato non
  /// deve far crashare l'intera lista eventi. Le date assenti/illeggibili
  /// degradano all'epoch invece di lanciare (vedi core/parsing.dart).
  factory EventModel.fromMap(String id, Map<String, dynamic> map) {
    return EventModel(
      id: id,
      name: parseString(map['name']),
      description: parseString(map['description']),
      location: parseString(map['location']),
      startDate: parseDateTimeOr(map['startDate']),
      endDate: parseDateTimeOr(map['endDate']),
      isActive: parseBool(map['isActive']),
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

  /// Intervallo di date dell'evento in formato leggibile (es. "12/1 – 13/1").
  String get dateRange {
    final start = '${startDate.day}/${startDate.month}';
    final end = '${endDate.day}/${endDate.month}';
    return '$start – $end';
  }

  /// True se l'evento è già iniziato e non è ancora finito.
  bool get isOngoing {
    final now = DateTime.now();
    return now.isAfter(startDate) && now.isBefore(endDate);
  }
}
