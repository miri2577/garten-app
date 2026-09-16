import 'dart:async';

import 'package:flutter/material.dart';

/// Ein Zeitplan-Eintrag einer Zone (Anzeige).
class IrrigationSchedule {
  final String days; // z.B. "Mo–Fr"
  final TimeOfDay time;
  final int minutes;
  const IrrigationSchedule(this.days, this.time, this.minutes);

  String get label =>
      '$days · ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} · $minutes min';
}

/// Eine Bewässerungszone mit veränderlichem Laufzustand.
class IrrigationZone {
  final String id;
  final String name; // Hochbeet, Rasen, Gewächshaus
  final String soilArea; // zugehöriger Bodenfeuchte-Bereich
  bool auto; // Automatik für diese Zone aktiv
  Duration remaining; // > 0 => läuft gerade
  TimeOfDay? nextStart; // nächster geplanter Start
  final List<IrrigationSchedule> schedules;

  IrrigationZone({
    required this.id,
    required this.name,
    required this.soilArea,
    required this.auto,
    required this.remaining,
    required this.nextStart,
    required this.schedules,
  });

  bool get running => remaining > Duration.zero;

  String get remainingLabel {
    final m = remaining.inMinutes;
    final s = remaining.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// Der wichtigste Gesamtzustand (für die Kachel).
enum IrrigationSummary { running, autoPaused, scheduled, off }

/// Hält die Zonen und steuert Start/Stopp mit Sekunden-Countdown.
class IrrigationController extends ChangeNotifier {
  final List<IrrigationZone> zones;
  bool autoPaused;
  Timer? _ticker;

  IrrigationController(this.zones, {this.autoPaused = false});

  IrrigationZone? get runningZone {
    for (final z in zones) {
      if (z.running) return z;
    }
    return null;
  }

  /// Frühester geplanter Start (Zeit + Zone) über alle Zonen.
  IrrigationZone? get nextScheduled {
    IrrigationZone? best;
    for (final z in zones) {
      if (z.nextStart == null) continue;
      if (best == null ||
          _mins(z.nextStart!) < _mins(best.nextStart!)) {
        best = z;
      }
    }
    return best;
  }

  int _mins(TimeOfDay t) => t.hour * 60 + t.minute;

  IrrigationSummary get summary {
    if (runningZone != null) return IrrigationSummary.running;
    if (autoPaused) return IrrigationSummary.autoPaused;
    if (nextScheduled != null) return IrrigationSummary.scheduled;
    return IrrigationSummary.off;
  }

  /// Manuelle Bewässerung starten. Läuft bereits eine andere Zone, wird sie
  /// gestoppt (keine widersprüchlichen Parallel-Läufe).
  void start(IrrigationZone zone, int minutes) {
    for (final z in zones) {
      if (z != zone) z.remaining = Duration.zero;
    }
    zone.remaining = Duration(minutes: minutes);
    _ensureTicker();
    notifyListeners();
  }

  void stop(IrrigationZone zone) {
    zone.remaining = Duration.zero;
    notifyListeners();
  }

  void stopAll() {
    for (final z in zones) {
      z.remaining = Duration.zero;
    }
    notifyListeners();
  }

  void toggleZoneAuto(IrrigationZone zone) {
    zone.auto = !zone.auto;
    notifyListeners();
  }

  void setAutoPaused(bool v) {
    autoPaused = v;
    notifyListeners();
  }

  void _ensureTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      var any = false;
      for (final z in zones) {
        if (z.running) {
          z.remaining -= const Duration(seconds: 1);
          if (z.remaining < Duration.zero) z.remaining = Duration.zero;
          if (z.running) any = true;
        }
      }
      notifyListeners();
      if (!any) {
        _ticker?.cancel();
        _ticker = null;
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

/// Testdaten, bis echte Ventile angebunden sind.
IrrigationController demoIrrigation() => IrrigationController([
      IrrigationZone(
        id: 'z1',
        name: 'Hochbeet',
        soilArea: 'Hochbeet',
        auto: true,
        remaining: Duration.zero,
        nextStart: const TimeOfDay(hour: 6, minute: 0),
        schedules: const [
          IrrigationSchedule('Mo–Fr', TimeOfDay(hour: 6, minute: 0), 10),
          IrrigationSchedule('Sa·So', TimeOfDay(hour: 7, minute: 30), 8),
        ],
      ),
      IrrigationZone(
        id: 'z2',
        name: 'Rasen',
        soilArea: 'Rasen',
        auto: true,
        remaining: Duration.zero,
        nextStart: const TimeOfDay(hour: 6, minute: 20),
        schedules: const [
          IrrigationSchedule('Mo·Mi·Fr', TimeOfDay(hour: 6, minute: 20), 15),
        ],
      ),
      IrrigationZone(
        id: 'z3',
        name: 'Gewächshaus',
        soilArea: 'Gewächshaus',
        auto: false,
        remaining: Duration.zero,
        nextStart: null,
        schedules: const [],
      ),
    ]);
