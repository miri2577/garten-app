import 'dart:math';

import 'package:flutter/material.dart';

/// Statusbereiche für Bodenfeuchte — verständlich statt nackter Zahlen.
enum MoistureStatus { dry, optimal, wet, offline }

extension MoistureStatusX on MoistureStatus {
  String get label => switch (this) {
        MoistureStatus.dry => 'trocken',
        MoistureStatus.optimal => 'optimal',
        MoistureStatus.wet => 'feucht',
        MoistureStatus.offline => 'offline',
      };

  /// Kurzer erklärender Zusatz für die Detailseite.
  String get hint => switch (this) {
        MoistureStatus.dry => 'Boden trocken – bald gießen',
        MoistureStatus.optimal => 'Feuchte im guten Bereich',
        MoistureStatus.wet => 'Boden gut durchfeuchtet',
        MoistureStatus.offline => 'Kein aktueller Messwert',
      };

  Color get color => switch (this) {
        MoistureStatus.dry => const Color(0xFFC77E2E), // warmes Ocker
        MoistureStatus.optimal => const Color(0xFF3E8E5A), // Garten-Grün
        MoistureStatus.wet => const Color(0xFF2E77B0), // Wasser-Blau
        MoistureStatus.offline => const Color(0xFF9AA0A6), // grau
      };

  IconData get icon => switch (this) {
        MoistureStatus.dry => Icons.local_fire_department_outlined,
        MoistureStatus.optimal => Icons.eco_outlined,
        MoistureStatus.wet => Icons.water_drop_outlined,
        MoistureStatus.offline => Icons.cloud_off_outlined,
      };
}

/// Statusgrenzen (Prozent). Bewusst zentral, damit Kachel und Detail gleich sind.
MoistureStatus statusForPercent(int p) {
  if (p < 30) return MoistureStatus.dry;
  if (p <= 60) return MoistureStatus.optimal;
  return MoistureStatus.wet;
}

/// Ein Bodenfeuchte-Sensor bzw. Gartenbereich.
class SoilSensor {
  final String name; // z.B. Hochbeet, Rasen, Gewächshaus
  final String zone; // zugehörige Bewässerungszone
  final int percent; // aktueller Messwert
  final bool online;
  final DateTime lastSeen;
  final List<int> hourly; // letzte 24 Stundenwerte (ältester zuerst)
  final List<int> daily; // letzte 7 Tageswerte (ältester zuerst)

  const SoilSensor({
    required this.name,
    required this.zone,
    required this.percent,
    required this.online,
    required this.lastSeen,
    required this.hourly,
    required this.daily,
  });

  MoistureStatus get status =>
      online ? statusForPercent(percent) : MoistureStatus.offline;

  List<int> series(bool weekly) => weekly ? daily : hourly;
}

/// Gesamtzustand der Bodenfeuchte über alle Sensoren.
class SoilMoisture {
  final List<SoilSensor> sensors;
  const SoilMoisture(this.sensors);

  List<SoilSensor> get online => sensors.where((s) => s.online).toList();
  bool get anyOffline => sensors.any((s) => !s.online);
  int get offlineCount => sensors.where((s) => !s.online).length;

  /// Repräsentativer Gesamtwert = Mittel der Online-Sensoren.
  int get average {
    final on = online;
    if (on.isEmpty) return 0;
    return (on.map((s) => s.percent).reduce((a, b) => a + b) / on.length)
        .round();
  }

  MoistureStatus get status =>
      online.isEmpty ? MoistureStatus.offline : statusForPercent(average);

  DateTime get lastUpdate => sensors
      .map((s) => s.lastSeen)
      .reduce((a, b) => a.isAfter(b) ? a : b);

  /// Mittlere Verlaufslinie über alle Online-Sensoren.
  List<int> averageSeries(bool weekly) {
    final on = online;
    if (on.isEmpty) return const [];
    final len = on.first.series(weekly).length;
    return List.generate(len, (i) {
      final vals = on.map((s) => s.series(weekly)[i]);
      return (vals.reduce((a, b) => a + b) / vals.length).round();
    });
  }
}

/// Erzeugt plausible Testdaten, bis echte Sensoren angebunden sind.
/// Natürlich wirkender Verlauf: langsames Abtrocknen mit gelegentlichem
/// Gieß-/Regen-Sprung, dazu etwas Rauschen. Deterministisch (fester Seed).
SoilMoisture demoSoilMoisture() {
  final now = DateTime.now();
  final rnd = Random(42);

  List<int> gen(int target, int len, {int step = 1}) {
    // Rückwärts vom aktuellen Zielwert einen weichen Verlauf bauen.
    final out = <double>[target.toDouble()];
    var v = target.toDouble();
    for (var i = 1; i < len; i++) {
      // rückwärts: vorher meist etwas feuchter (trocknet zur Gegenwart),
      // mit vereinzelten Gieß-Sprüngen nach unten (=vorher deutlich feuchter).
      v += 0.8 * step + (rnd.nextDouble() - 0.45) * 3.0 * step;
      if (rnd.nextDouble() < 0.12) v += 8.0 * step; // Gieß-/Regen-Ereignis
      v = v.clamp(8, 92);
      out.add(v);
    }
    return out.reversed.map((e) => e.round()).toList();
  }

  return SoilMoisture([
    SoilSensor(
      name: 'Hochbeet',
      zone: 'Zone 1 · Hochbeet',
      percent: 45,
      online: true,
      lastSeen: now.subtract(const Duration(minutes: 3)),
      hourly: gen(45, 24),
      daily: gen(45, 7, step: 4),
    ),
    SoilSensor(
      name: 'Rasen',
      zone: 'Zone 2 · Rasenfläche',
      percent: 39,
      online: true,
      lastSeen: now.subtract(const Duration(minutes: 6)),
      hourly: gen(39, 24),
      daily: gen(39, 7, step: 4),
    ),
    SoilSensor(
      name: 'Gewächshaus',
      zone: 'Zone 3 · Gewächshaus',
      percent: 58,
      online: false, // offline -> demonstriert den Hinweis
      lastSeen: now.subtract(const Duration(hours: 3, minutes: 12)),
      hourly: gen(58, 24),
      daily: gen(58, 7, step: 4),
    ),
  ]);
}
