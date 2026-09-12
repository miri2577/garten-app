import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_screen.dart';
import 'ha_client.dart';
import 'live_video.dart';
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
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _dataTimer?.cancel();
    super.dispose();
  }

  String get _sdHls => widget.config.hlsUrlForQuality('sd');
  String get _sdRtsp =>
      widget.config.rtspUrl.replaceFirst(RegExp(r'garten(_sd)?'), 'garten_sd');

  void _openCamera() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CameraScreen(
        config: widget.config,
        onOpenSettings: widget.onOpenSettings,
      ),
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
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(weather: weather, error: _error),
                const SizedBox(height: 20),
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
                          crossAxisCount: 3,
                          mainAxisSpacing: 20,
                          crossAxisSpacing: 20,
                          childAspectRatio: 16 / 10,
                          children: [
                            _CameraCard(
                              hlsUrl: _sdHls,
                              rtspUrl: _sdRtsp,
                              autofocus: true,
                              onSelect: _openCamera,
                            ),
                            _WeatherCard(weather: weather),
                            _SunCard(sun: sun, sunrise: sunrise, sunset: sunset),
                            const _PlaceholderCard(
                              icon: Icons.grass,
                              title: 'Bodenfeuchte',
                              hint: 'kommt mit den Sensoren',
                            ),
                            const _PlaceholderCard(
                              icon: Icons.water_drop,
                              title: 'Bewässerung',
                              hint: 'kommt später',
                            ),
                            _SettingsCard(onSelect: widget.onOpenSettings),
                          ],
                        ),
                ),
              ],
            ),
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
  const _Header({required this.weather, required this.error});

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
    return Row(
      children: [
        const Icon(Icons.eco, size: 34),
        const SizedBox(width: 12),
        const Text('Garten',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600)),
        const Spacer(),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(children: [
              const Icon(Icons.cloud_off, color: Colors.orangeAccent, size: 20),
              const SizedBox(width: 6),
              Text('offline', style: TextStyle(color: Colors.orangeAccent)),
            ]),
          ),
        if (temp != null) ...[
          Icon(_conditionIcon(widget.weather!.state), size: 26),
          const SizedBox(width: 8),
          Text('$temp°', style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 20),
        ],
        IconButton(
          tooltip: 'Hell/Dunkel umschalten',
          onPressed: toggleTheme,
          icon: Icon(themeNotifier.value == ThemeMode.dark
              ? Icons.light_mode
              : Icons.dark_mode),
        ),
        const SizedBox(width: 8),
        Text(t,
            style:
                const TextStyle(fontSize: 26, fontWeight: FontWeight.w500)),
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: widget.color ?? scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: _focused ? scheme.primary : Colors.transparent,
              width: 3,
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.5),
                      blurRadius: 18,
                    )
                  ]
                : null,
          ),
          clipBehavior: Clip.antiAlias,
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

class _PlaceholderCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;
  const _PlaceholderCard(
      {required this.icon, required this.title, required this.hint});

  @override
  Widget build(BuildContext context) {
    return _FocusCard(
      child: Opacity(
        opacity: 0.55,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 30),
              const Spacer(),
              Text(title, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 4),
              Text(hint,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final Future<void> Function() onSelect;
  const _SettingsCard({required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return _FocusCard(
      onSelect: () => onSelect(),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.settings, size: 34),
            SizedBox(height: 10),
            Text('Einstellungen', style: TextStyle(fontSize: 18)),
          ],
        ),
      ),
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
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.system_update, color: scheme.onPrimaryContainer),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              installing
                  ? 'Lädt Update … ${(progress * 100).round()} %'
                  : 'Neue Version verfügbar${info.versionName.isNotEmpty ? " (${info.versionName})" : ""}',
              style: TextStyle(
                  color: scheme.onPrimaryContainer,
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
                color: scheme.onPrimaryContainer,
              ),
            )
          else ...[
            TextButton(onPressed: onDismiss, child: const Text('Später')),
            const SizedBox(width: 8),
            FilledButton.icon(
              autofocus: true,
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
