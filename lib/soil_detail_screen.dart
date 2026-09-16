import 'package:flutter/material.dart';

import 'charts.dart';
import 'focus_frost.dart';
import 'garden_data.dart';

/// Detailseite Bodenfeuchte: Gesamtwert, Verlauf (24 h / 7 Tage), Statusbereiche,
/// mehrere Gartenbereiche mit Zeitstempel + Verbindungsstatus und Verknüpfung
/// zur passenden Bewässerungszone.
class SoilDetailScreen extends StatefulWidget {
  final SoilMoisture data;
  const SoilDetailScreen({super.key, required this.data});

  @override
  State<SoilDetailScreen> createState() => _SoilDetailScreenState();
}

class _SoilDetailScreenState extends State<SoilDetailScreen> {
  bool _weekly = false;

  void _openZone(String zone) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('Bewässerung folgt · $zone'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = widget.data;
    final status = d.status;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Kopfzeile: Zurück + Titel + Stand
              Row(
                children: [
                  FocusFrost(
                    autofocus: true,
                    onSelect: () => Navigator.of(context).maybePop(),
                    radius: 14,
                    color: scheme.surfaceContainerHighest,
                    padding: const EdgeInsets.all(12),
                    child: const Icon(Icons.arrow_back, size: 26),
                  ),
                  const SizedBox(width: 16),
                  const Text('Bodenfeuchte',
                      style: TextStyle(
                          fontSize: 30, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('Stand ${_hm(d.lastUpdate)}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 18),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Links: Zusammenfassung + Umschalter + Diagramm
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SummaryCard(data: d),
                          const SizedBox(height: 16),
                          _RangeToggle(
                            weekly: _weekly,
                            onChanged: (w) => setState(() => _weekly = w),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(8, 14, 14, 8),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: MoistureChart(
                                data: d.averageSeries(_weekly),
                                weekly: _weekly,
                                lineColor: status.color,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 18),
                    // Rechts: Gartenbereiche
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < d.sensors.length; i++) ...[
                            Expanded(
                              child: _SensorCard(
                                sensor: d.sensors[i],
                                onOpenZone: _openZone,
                              ),
                            ),
                            if (i < d.sensors.length - 1)
                              const SizedBox(height: 14),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _SummaryCard extends StatelessWidget {
  final SoilMoisture data;
  const _SummaryCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = data.status;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Gesamt · Mittel aller Bereiche',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text('${data.average} %',
                  style: const TextStyle(
                      fontSize: 52, fontWeight: FontWeight.bold, height: 1.0)),
            ],
          ),
          const SizedBox(width: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _StatusChip(status: status),
              const SizedBox(height: 8),
              SizedBox(
                width: 190,
                child: Text(status.hint,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
              if (data.anyOffline) ...[
                const SizedBox(height: 8),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.cloud_off_outlined,
                      size: 16, color: MoistureStatus.offline.color),
                  const SizedBox(width: 6),
                  Text('${data.offlineCount} Sensor offline',
                      style: TextStyle(color: MoistureStatus.offline.color)),
                ]),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final MoistureStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(status.icon, size: 18, color: status.color),
        const SizedBox(width: 6),
        Text(status.label,
            style: TextStyle(
                color: status.color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _RangeToggle extends StatelessWidget {
  final bool weekly;
  final ValueChanged<bool> onChanged;
  const _RangeToggle({required this.weekly, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      _seg('24 Stunden', !weekly, () => onChanged(false)),
      const SizedBox(width: 10),
      _seg('7 Tage', weekly, () => onChanged(true)),
    ]);
  }

  Widget _seg(String label, bool active, VoidCallback onTap) {
    return _RangeButton(label: label, active: active, onTap: onTap);
  }
}

class _RangeButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _RangeButton(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FocusFrost(
      onSelect: onTap,
      radius: 14,
      color: active ? scheme.inverseSurface : scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: active ? scheme.onInverseSurface : scheme.onSurface,
        ),
      ),
    );
  }
}

class _SensorCard extends StatelessWidget {
  final SoilSensor sensor;
  final void Function(String zone) onOpenZone;
  const _SensorCard({required this.sensor, required this.onOpenZone});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final st = sensor.status;
    final offline = !sensor.online;
    return FocusFrost(
      onSelect: () => onOpenZone(sensor.zone),
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Opacity(
        opacity: offline ? 0.7 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(sensor.name,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(offline ? '– %' : '${sensor.percent} %',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 6),
            Row(children: [
              _StatusChip(status: st),
              const Spacer(),
              Icon(offline ? Icons.cloud_off_outlined : Icons.check_circle,
                  size: 15,
                  color: offline ? MoistureStatus.offline.color : st.color),
              const SizedBox(width: 4),
              Text(_since(sensor.lastSeen),
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 8),
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Sparkline(
                  data: sensor.hourly,
                  color: offline ? MoistureStatus.offline.color : st.color,
                  height: 26,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.water_drop_outlined,
                  size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Bewässerung: ${sensor.zone}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              ),
              Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
            ]),
          ],
        ),
      ),
    );
  }
}

String _hm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _since(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return 'gerade eben';
  if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} Min';
  if (diff.inHours < 24) return 'vor ${diff.inHours} Std';
  return 'vor ${diff.inDays} Tg';
}
