import 'package:flutter/material.dart';

import 'focus_frost.dart';
import 'irrigation_data.dart';

/// Detailseite Bewässerung: Zonen mit Zustand + Restlaufzeit, manuelle
/// Bewässerung mit Bestätigung (Zone + Dauer), jederzeit abbrechbare Läufe,
/// Zeitpläne und Automatik nach Bodenfeuchte & Wetter.
class IrrigationDetailScreen extends StatefulWidget {
  final IrrigationController controller;
  const IrrigationDetailScreen({super.key, required this.controller});

  @override
  State<IrrigationDetailScreen> createState() => _IrrigationDetailScreenState();
}

class _IrrigationDetailScreenState extends State<IrrigationDetailScreen> {
  IrrigationController get c => widget.controller;

  Future<void> _startFlow(IrrigationZone zone) async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => _StartDialog(zone: zone),
    );
    if (minutes != null && mounted) c.start(zone, minutes);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: c,
          builder: (context, _) {
            final running = c.runningZone;
            return Padding(
              padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      FocusFrost(
                        autofocus: running == null,
                        onSelect: () => Navigator.of(context).maybePop(),
                        radius: 14,
                        color: scheme.surfaceContainerHighest,
                        padding: const EdgeInsets.all(12),
                        child: const Icon(Icons.arrow_back, size: 26),
                      ),
                      const SizedBox(width: 16),
                      const Text('Bewässerung',
                          style: TextStyle(
                              fontSize: 30, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (running != null) ...[
                    _RunningBanner(
                      zone: running,
                      onStop: () => c.stop(running),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < c.zones.length; i++) ...[
                          Expanded(
                            child: _ZoneCard(
                              zone: c.zones[i],
                              onStart: () => _startFlow(c.zones[i]),
                              onStop: () => c.stop(c.zones[i]),
                              onToggleAuto: () => c.toggleZoneAuto(c.zones[i]),
                            ),
                          ),
                          if (i < c.zones.length - 1)
                            const SizedBox(width: 16),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _AutomatikBar(
                    paused: c.autoPaused,
                    onToggle: () => c.setAutoPaused(!c.autoPaused),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _RunningBanner extends StatelessWidget {
  final IrrigationZone zone;
  final VoidCallback onStop;
  const _RunningBanner({required this.zone, required this.onStop});

  static const _blue = Color(0xFF2E77B0);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 14, 14),
      decoration: BoxDecoration(
        color: _blue.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _blue.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.water_drop, color: _blue, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${zone.name} läuft',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w600)),
                Text('noch ${zone.remainingLabel} min',
                    style: const TextStyle(fontSize: 15, color: _blue)),
              ],
            ),
          ),
          FocusFrost(
            autofocus: true,
            onSelect: onStop,
            radius: 14,
            color: _blue.withValues(alpha: 0.16),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.stop_circle_outlined, size: 20, color: _blue),
              SizedBox(width: 8),
              Text('Stopp',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: _blue)),
            ]),
          ),
        ],
      ),
    );
  }
}

class _ZoneCard extends StatelessWidget {
  final IrrigationZone zone;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onToggleAuto;
  const _ZoneCard({
    required this.zone,
    required this.onStart,
    required this.onStop,
    required this.onToggleAuto,
  });

  static const _blue = Color(0xFF2E77B0);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = zone.running;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(zone.name,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          // Zustand
          if (running)
            _chip(Icons.water_drop, 'läuft · noch ${zone.remainingLabel} min',
                _blue)
          else if (zone.nextStart != null)
            _chip(Icons.schedule, 'Nächster Start ${_hm(zone.nextStart!)}',
                scheme.onSurfaceVariant)
          else
            _chip(Icons.check_circle_outline, 'Bereit',
                scheme.onSurfaceVariant),
          const SizedBox(height: 10),
          // Automatik-Status (Icon + Text, nicht nur Farbe)
          Row(children: [
            Icon(zone.auto ? Icons.autorenew : Icons.pause_circle_outline,
                size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(zone.auto ? 'Automatik an' : 'Automatik aus',
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 6),
          // Zeitpläne
          if (zone.schedules.isEmpty)
            Text('Kein Zeitplan',
                style: TextStyle(
                    fontSize: 13, color: scheme.onSurfaceVariant))
          else
            for (final s in zone.schedules)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(s.label,
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
              ),
          const Spacer(),
          // Aktion: läuft -> Stopp, sonst -> Jetzt bewässern
          if (running)
            FocusFrost(
              onSelect: onStop,
              radius: 14,
              color: _blue.withValues(alpha: 0.16),
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: const Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.stop_circle_outlined, size: 20, color: _blue),
                  SizedBox(width: 8),
                  Text('Stopp',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, color: _blue)),
                ]),
              ),
            )
          else
            FocusFrost(
              onSelect: onStart,
              radius: 14,
              color: scheme.inverseSurface,
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.play_arrow, size: 20, color: scheme.onInverseSurface),
                  const SizedBox(width: 8),
                  Text('Jetzt bewässern',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: scheme.onInverseSurface)),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String text, Color color) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 6),
          Flexible(
              child: Text(text,
                  style:
                      TextStyle(color: color, fontWeight: FontWeight.w600))),
        ],
      );
}

class _AutomatikBar extends StatelessWidget {
  final bool paused;
  final VoidCallback onToggle;
  const _AutomatikBar({required this.paused, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(paused ? Icons.pause_circle_outline : Icons.autorenew,
              color: paused ? scheme.onSurfaceVariant : scheme.onSurface),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(paused ? 'Automatik pausiert' : 'Automatik aktiv',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600)),
                Text('Steuert nach Bodenfeuchte & Wetter',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          FocusFrost(
            onSelect: onToggle,
            radius: 14,
            color: scheme.surfaceContainerHigh,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(paused ? Icons.play_arrow : Icons.pause,
                  size: 18, color: scheme.onSurface),
              const SizedBox(width: 6),
              Text(paused ? 'Fortsetzen' : 'Pausieren',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
          ),
        ],
      ),
    );
  }
}

/// Bestätigungsdialog: zeigt Zone + Dauer klar an, bevor gestartet wird.
class _StartDialog extends StatefulWidget {
  final IrrigationZone zone;
  const _StartDialog({required this.zone});

  @override
  State<_StartDialog> createState() => _StartDialogState();
}

class _StartDialogState extends State<_StartDialog> {
  static const _options = [5, 10, 15, 30];
  int _minutes = 10;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: scheme.surfaceContainerHigh,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Jetzt bewässern',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 14),
            // Zone + gewählte Dauer klar anzeigen
            Row(children: [
              Icon(Icons.place_outlined, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Zone: ${widget.zone.name}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.timer_outlined, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Dauer: $_minutes Minuten',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final m in _options)
                  FocusFrost(
                    autofocus: m == _minutes,
                    onSelect: () => setState(() => _minutes = m),
                    radius: 12,
                    color: m == _minutes
                        ? scheme.inverseSurface
                        : scheme.surfaceContainerHighest,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 10),
                    child: Text('$m min',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: m == _minutes
                                ? scheme.onInverseSurface
                                : scheme.onSurface)),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FocusFrost(
                  onSelect: () => Navigator.of(context).pop(),
                  radius: 12,
                  color: scheme.surfaceContainerHighest,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: const Text('Abbrechen',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 12),
                FocusFrost(
                  onSelect: () => Navigator.of(context).pop(_minutes),
                  radius: 12,
                  color: scheme.inverseSurface,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.play_arrow, size: 20, color: scheme.onInverseSurface),
                    const SizedBox(width: 6),
                    Text('Starten',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: scheme.onInverseSurface)),
                  ]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _hm(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
