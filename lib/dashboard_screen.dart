import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_screen.dart';
import 'garden_data.dart';
import 'ha_client.dart';
import 'irrigation_data.dart';
import 'irrigation_detail_screen.dart';
import 'live_video.dart';
import 'soil_detail_screen.dart';
import 'theme.dart';
import 'updater.dart';

/// Startbildschirm: Kacheln mit Live-Daten aus Home Assistant, fernbedienbar.
class DashboardScreen extends StatefulWidget {
  final HaConfig config;
  final Future<void> Function() onOpenSettings;
  const DashboardScreen(
      {super.key, required this.config, required this.onOpenSettings});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final HaClient _client = HaClient(widget.config);
  Map<String, HaEntity> _states = {};
  bool _loaded = false;
  String? _error;

  Timer? _dataTimer;

  UpdateInfo? _update;
  bool _installing = false;
  double _downloadProgress = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    _dataTimer = Timer.periodic(const Duration(seconds: 20), (_) => _refresh());
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    final u = await Updater.check();
    if (mounted) setState(() => _update = u);
  }

  Future<void> _startUpdate() async {
    if (_update == null) return;
    setState(() {
      _installing = true;
      _downloadProgress = 0;
    });
    final err = await Updater.downloadAndInstall(
      _update!.apkUrl,
      onProgress: (p) {
        if (mounted) setState(() => _downloadProgress = p);
      },
    );
    if (mounted) {
      setState(() => _installing = false);
      if (err != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Update: $err')));
      }
    }
  }

  Future<void> _refresh() async {
    try {
      final s = await _client.getStates();
      if (mounted) {
        setState(() {
          _states = s;
          _loaded = true;
          _error = null;
        });
      }
    } catch (e) {
      // Auch ohne Home Assistant das Dashboard zeigen: die Kamera läuft
      // unabhängig davon (go2rtc), die Wetter-Kacheln bleiben leer.
      if (mounted) {
        setState(() {
          _error = '$e';
          _loaded = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _dataTimer?.cancel();
    _irrigation.dispose();
    super.dispose();
  }

  String get _sdHls => widget.config.hlsUrlForQuality('sd');
  String get _sdRtsp =>
      widget.config.rtspUrl.replaceFirst(RegExp(r'garten(_sd)?'), 'garten_sd');

  // Testdaten, bis echte Sensoren/Ventile angebunden sind.
  final SoilMoisture _soil = demoSoilMoisture();
  final IrrigationController _irrigation = demoIrrigation();

  void _openCamera() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CameraScreen(
        config: widget.config,
        onOpenSettings: widget.onOpenSettings,
      ),
    ));
  }

  void _openSoil() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SoilDetailScreen(data: _soil),
    ));
  }

  void _openIrrigation() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => IrrigationDetailScreen(controller: _irrigation),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final weather = _states['weather.forecast_home'];
    final sun = _states['sun.sun'];
    final sunset = _states['sensor.sun_next_setting'];
    final sunrise = _states['sensor.sun_next_rising'];

    return Scaffold(
      body: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.keyS)) {
            widget.onOpenSettings();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              // Responsiv: TV/Tablet-quer = 3 Spalten, Handy-quer/klein = 2,
              // Handy-hochkant = 1 Spalte (Raster scrollt dann).
              final columns = w >= 900 ? 3 : (w >= 560 ? 2 : 1);
              // Einzelspaltige (hochkant) Kacheln flacher, sonst zu hoch.
              final aspect = columns == 1 ? 16 / 8.5 : 16 / 10;
              final pad = w < 600 ? 16.0 : 28.0;
              final gap = w < 600 ? 14.0 : 20.0;

              final cards = <Widget>[
                _CameraCard(
                  hlsUrl: _sdHls,
                  rtspUrl: _sdRtsp,
                  autofocus: true,
                  onSelect: _openCamera,
                ),
                _WeatherCard(weather: weather),
                _SunCard(sun: sun, sunrise: sunrise, sunset: sunset),
                _SoilCard(data: _soil, onSelect: _openSoil),
                _IrrigationCard(
                    controller: _irrigation, onSelect: _openIrrigation),
              ];

              return Padding(
                padding: EdgeInsets.all(pad),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(
                        weather: weather,
                        error: _error,
                        onOpenSettings: widget.onOpenSettings),
                    SizedBox(height: w < 600 ? 14 : 20),
                    if (_update != null) ...[
                      _UpdateBanner(
                        info: _update!,
                        installing: _installing,
                        progress: _downloadProgress,
                        onUpdate: _startUpdate,
                        onDismiss: () => setState(() => _update = null),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Expanded(
                      child: !_loaded
                          ? const Center(child: CircularProgressIndicator())
                          : GridView.count(
                              crossAxisCount: columns,
                              mainAxisSpacing: gap,
                              crossAxisSpacing: gap,
                              childAspectRatio: aspect,
                              children: cards,
                            ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Kopfzeile
// ---------------------------------------------------------------------------

class _Header extends StatefulWidget {
  final HaEntity? weather;
  final String? error;
  final Future<void> Function() onOpenSettings;
  const _Header(
      {required this.weather,
      required this.error,
      required this.onOpenSettings});

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  late Timer _clock;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t =
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    final temp = widget.weather?.attributes['temperature'];
    // Auf schmalen Displays (Handy hochkant) kompakter: kleinere Schrift,
    // Inline-Wetter entfällt (steht ohnehin als Kachel).
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final titleSize = narrow ? 22.0 : 30.0;
    final clockSize = narrow ? 20.0 : 26.0;
    final iconSize = narrow ? 26.0 : 34.0;

    return Row(
      children: [
        Icon(Icons.eco, size: iconSize),
        const SizedBox(width: 12),
        Expanded(
          child: Text('Garten',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: titleSize, fontWeight: FontWeight.w600)),
        ),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(Icons.cloud_off,
                color: Colors.orangeAccent, size: narrow ? 20 : 22),
          ),
        if (temp != null && !narrow) ...[
          Icon(_conditionIcon(widget.weather!.state), size: 26),
          const SizedBox(width: 8),
          Text('$temp°', style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 12),
        ],
        IconButton(
          tooltip: 'Hell/Dunkel umschalten',
          onPressed: toggleTheme,
          icon: Icon(themeNotifier.value == ThemeMode.dark
              ? Icons.light_mode
              : Icons.dark_mode),
        ),
        IconButton(
          tooltip: 'Einstellungen',
          onPressed: () => widget.onOpenSettings(),
          icon: const Icon(Icons.settings),
        ),
        const SizedBox(width: 8),
        Text(t,
            style:
                TextStyle(fontSize: clockSize, fontWeight: FontWeight.w500)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Karten-Grundgerüst mit Fokus-Rahmen (für D-Pad/Fernbedienung)
// ---------------------------------------------------------------------------

class _FocusCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onSelect;
  final bool autofocus;
  final Color? color;
  const _FocusCard({
    required this.child,
    this.onSelect,
    this.autofocus = false,
    this.color,
  });

  @override
  State<_FocusCard> createState() => _FocusCardState();
}

class _FocusCardState extends State<_FocusCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final baseColor = widget.color ?? scheme.surfaceContainerHighest;
    final radius = BorderRadius.circular(18);

    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onSelect?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onSelect,
        // Fokus = Milchglas: t animiert 0 -> 1. Nicht fokussierte Kacheln
        // bleiben ruhig (t=0 = unverändert opak, kein Blur/Rand/Schatten).
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: _focused ? 1 : 0),
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          builder: (context, t, child) {
            // Oberfläche: opaker Kartenton -> halbtransparent, leicht aufgehellt.
            final surface =
                Color.lerp(baseColor, Colors.white.withValues(alpha: 0.5), t)!;
            return Transform.scale(
              scale: 1 + 0.02 * t, // minimale Vergrößerung
              child: DecoratedBox(
                // dezenter heller Glow + weicher Schatten
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: t <= 0
                      ? null
                      : [
                          BoxShadow(
                            color: Colors.white.withValues(alpha: 0.22 * t),
                            blurRadius: 22 * t,
                            spreadRadius: t,
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.10 * t),
                            blurRadius: 16 * t,
                            offset: Offset(0, 4 * t),
                          ),
                        ],
                ),
                child: DecoratedBox(
                  // feiner weißer Rand (~28 % bei Fokus), im Vordergrund
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.28 * t),
                      width: 1.5,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: radius,
                    child: t <= 0.01
                        ? ColoredBox(color: surface, child: child)
                        : BackdropFilter(
                            // Backdrop-Blur ~14 px (weich hochgeblendet)
                            filter: ImageFilter.blur(
                              sigmaX: 14 * t,
                              sigmaY: 14 * t,
                            ),
                            child: ColoredBox(color: surface, child: child),
                          ),
                  ),
                ),
              ),
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Einzelne Karten
// ---------------------------------------------------------------------------

class _CameraCard extends StatelessWidget {
  final String hlsUrl;
  final String rtspUrl;
  final VoidCallback onSelect;
  final bool autofocus;
  const _CameraCard({
    required this.hlsUrl,
    required this.rtspUrl,
    required this.onSelect,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return _FocusCard(
      autofocus: autofocus,
      onSelect: onSelect,
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Echtes Live-Bild (SD, stumm), pausiert im Vollbild.
          LiveVideo(
            hlsUrl: hlsUrl,
            rtspUrl: rtspUrl,
            muted: true,
            fit: BoxFit.cover,
            pauseWhenCovered: true,
          ),
          Positioned(
            left: 12,
            bottom: 10,
            child: Row(children: [
              Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                    color: Colors.redAccent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              const Text('Garten · Live',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black)])),
            ]),
          ),
          const Positioned(
            right: 10,
            top: 10,
            child: Icon(Icons.open_in_full, color: Colors.white70, size: 20),
          ),
        ],
      ),
    );
  }
}

class _WeatherCard extends StatelessWidget {
  final HaEntity? weather;
  const _WeatherCard({required this.weather});

  @override
  Widget build(BuildContext context) {
    final a = weather?.attributes ?? const {};
    final temp = a['temperature'];
    final hum = a['humidity'];
    final wind = a['wind_speed'];
    return _FocusCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(_conditionIcon(weather?.state ?? ''), size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_conditionLabel(weather?.state ?? ''),
                    style: const TextStyle(fontSize: 17),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
            const Spacer(),
            Text(temp != null ? '$temp°' : '–',
                style:
                    const TextStyle(fontSize: 44, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              [
                if (hum != null) 'Luftfeuchte $hum%',
                if (wind != null) 'Wind $wind km/h',
              ].join('  ·  '),
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _SunCard extends StatelessWidget {
  final HaEntity? sun;
  final HaEntity? sunrise;
  final HaEntity? sunset;
  const _SunCard({required this.sun, required this.sunrise, required this.sunset});

  String _time(HaEntity? e) {
    if (e == null || e.isUnavailable) return '–';
    final dt = DateTime.tryParse(e.state)?.toLocal();
    if (dt == null) return '–';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final day = sun?.state == 'above_horizon';
    return _FocusCard(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(day ? Icons.wb_sunny : Icons.nightlight_round, size: 30),
              const SizedBox(width: 10),
              Text(day ? 'Tag' : 'Nacht', style: const TextStyle(fontSize: 17)),
            ]),
            const Spacer(),
            _row(Icons.wb_twilight, 'Aufgang', _time(sunrise)),
            const SizedBox(height: 10),
            _row(Icons.bedtime, 'Untergang', _time(sunset)),
          ],
        ),
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) => Row(children: [
        Icon(icon, size: 20),
        const SizedBox(width: 10),
        Text(label),
        const Spacer(),
        Text(value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      ]);
}

class _SoilCard extends StatelessWidget {
  final SoilMoisture data;
  final VoidCallback onSelect;
  const _SoilCard({required this.data, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = data.status;
    // Struktur identisch zur Wetter-Kachel (Icon+Label 17, Spacer, großer Wert
    // 44/w600, Untertitel-Zeile) — für konsistente Abstände.
    return _FocusCard(
      onSelect: onSelect,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.grass, size: 30),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Bodenfeuchte',
                    style: TextStyle(fontSize: 17),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
            const Spacer(),
            Text('${data.average} %',
                style:
                    const TextStyle(fontSize: 44, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Row(children: [
              Icon(status.icon, size: 17, color: status.color),
              const SizedBox(width: 6),
              Text(status.label,
                  style: TextStyle(
                      color: status.color, fontWeight: FontWeight.w600)),
              if (data.anyOffline) ...[
                Text('  ·  ', style: TextStyle(color: scheme.onSurfaceVariant)),
                Text('${data.offlineCount} Sensor offline',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ]),
          ],
        ),
      ),
    );
  }
}

class _IrrigationCard extends StatelessWidget {
  final IrrigationController controller;
  final VoidCallback onSelect;
  const _IrrigationCard({required this.controller, required this.onSelect});

  static const _blue = Color(0xFF2E77B0);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        String big;
        String sub;
        IconData subIcon;
        Color subColor = scheme.onSurfaceVariant;
        switch (controller.summary) {
          case IrrigationSummary.running:
            final z = controller.runningZone!;
            big = 'Läuft';
            sub = '${z.name} · noch ${z.remaining.inMinutes} min';
            subIcon = Icons.water_drop;
            subColor = _blue;
          case IrrigationSummary.autoPaused:
            big = 'Pausiert';
            sub = 'Automatik';
            subIcon = Icons.pause_circle_outline;
          case IrrigationSummary.scheduled:
            final z = controller.nextScheduled!;
            final t = z.nextStart!;
            big =
                '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
            sub = 'Nächster Start · ${z.name}';
            subIcon = Icons.schedule;
          case IrrigationSummary.off:
            big = 'Aus';
            sub = 'Automatik aktiv';
            subIcon = Icons.autorenew;
        }
        return _FocusCard(
          onSelect: onSelect,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.water_drop, size: 30),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Bewässerung',
                        style: TextStyle(fontSize: 17),
                        overflow: TextOverflow.ellipsis),
                  ),
                ]),
                const Spacer(),
                Text(big,
                    style: const TextStyle(
                        fontSize: 44, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Row(children: [
                  Icon(subIcon, size: 17, color: subColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(sub,
                        style: TextStyle(color: subColor),
                        overflow: TextOverflow.ellipsis),
                  ),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Hinweisleiste, wenn auf HiDrive eine neue Version bereitliegt.
class _UpdateBanner extends StatelessWidget {
  final UpdateInfo info;
  final bool installing;
  final double progress;
  final VoidCallback onUpdate;
  final VoidCallback onDismiss;
  const _UpdateBanner({
    required this.info,
    required this.installing,
    required this.progress,
    required this.onUpdate,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.system_update, color: scheme.onSurface),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              installing
                  ? 'Lädt Update … ${(progress * 100).round()} %'
                  : 'Neue Version verfügbar${info.versionName.isNotEmpty ? " (${info.versionName})" : ""}',
              style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 17,
                  fontWeight: FontWeight.w600),
            ),
          ),
          if (installing)
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: progress > 0 ? progress : null,
                color: scheme.onSurface,
              ),
            )
          else ...[
            TextButton(onPressed: onDismiss, child: const Text('Später')),
            const SizedBox(width: 8),
            FilledButton.icon(
              autofocus: true,
              style: FilledButton.styleFrom(
                backgroundColor: scheme.inverseSurface,
                foregroundColor: scheme.onInverseSurface,
              ),
              onPressed: onUpdate,
              icon: const Icon(Icons.download),
              label: const Text('Aktualisieren'),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Wetter-Hilfen
// ---------------------------------------------------------------------------

IconData _conditionIcon(String c) {
  switch (c) {
    case 'sunny':
    case 'clear-night':
      return Icons.wb_sunny;
    case 'partlycloudy':
      return Icons.wb_cloudy;
    case 'cloudy':
      return Icons.cloud;
    case 'rainy':
    case 'pouring':
      return Icons.water_drop;
    case 'lightning':
    case 'lightning-rainy':
      return Icons.thunderstorm;
    case 'snowy':
    case 'snowy-rainy':
      return Icons.ac_unit;
    case 'fog':
      return Icons.foggy;
    case 'windy':
    case 'windy-variant':
      return Icons.air;
    default:
      return Icons.cloud_queue;
  }
}

String _conditionLabel(String c) {
  const map = {
    'sunny': 'Sonnig',
    'clear-night': 'Klar',
    'partlycloudy': 'Teils bewölkt',
    'cloudy': 'Bewölkt',
    'rainy': 'Regen',
    'pouring': 'Starkregen',
    'lightning': 'Gewitter',
    'lightning-rainy': 'Gewitter, Regen',
    'snowy': 'Schnee',
    'snowy-rainy': 'Schneeregen',
    'fog': 'Nebel',
    'windy': 'Windig',
    'windy-variant': 'Windig',
    'hail': 'Hagel',
    'exceptional': 'Extrem',
  };
  return map[c] ?? (c.isEmpty ? 'Wetter' : c);
}
