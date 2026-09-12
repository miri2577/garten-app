import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import 'ha_client.dart';

/// Vollbild-Live-Ansicht der Kamera.
///
/// - **Android/Android TV:** ExoPlayer (video_player) auf go2rtcs HLS-Stream.
///   HLS-Segmente beginnen mit einem Keyframe; ExoPlayer beherrscht die
///   MediaTek-TV-Decoder zuverlässig (dieselbe Basis wie native TV-Apps) —
///   damit verschwindet das Bildrauschen von media_kit/WebView.
/// - **Sonst (Linux-Desktop):** direkter RTSP-Stream via media_kit/libmpv.
class CameraScreen extends StatefulWidget {
  final HaConfig config;
  final Future<void> Function() onOpenSettings;
  const CameraScreen(
      {super.key, required this.config, required this.onOpenSettings});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  // media_kit-Pfad (Desktop)
  Player? _player;
  VideoController? _mkController;
  // ExoPlayer-Pfad (Android)
  VideoPlayerController? _exo;
  Timer? _liveTimer;

  String _status = 'Verbinde …';
  bool _error = false;
  bool _playing = false;
  String _sourceLabel = '';

  // Qualität: gewünschter Modus ('auto'|'hd'|'sd') und aktuell aktive Stufe.
  late String _mode = widget.config.videoQuality;
  String _activeQuality = 'hd';

  // Explizite Fokusverwaltung für die Bedienleiste (D-Pad links/rechts).
  final FocusNode _backFocus = FocusNode(debugLabel: 'back');
  final FocusNode _qualityFocus = FocusNode(debugLabel: 'quality');
  final FocusNode _refreshFocus = FocusNode(debugLabel: 'refresh');

  List<FocusNode> get _navNodes =>
      [_backFocus, if (_useExo) _qualityFocus, _refreshFocus];

  void _moveFocus(int dir) {
    final nodes = _navNodes;
    final idx = nodes.indexWhere((n) => n.hasFocus);
    final cur = idx < 0 ? 0 : idx;
    final next = (cur + dir).clamp(0, nodes.length - 1);
    nodes[next].requestFocus();
  }

  bool get _useExo =>
      !kIsWeb && Platform.isAndroid && widget.config.hlsUrl.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_useExo) {
      _initExo();
    } else {
      _player = Player();
      _mkController = VideoController(_player!);
      _configurePlayer();
      _startMediaKit();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _backFocus.requestFocus();
    });
  }

  /// Startqualität bestimmen: SD/HD fix, oder Auto — und im Auto-Modus direkt SD,
  /// wenn dieses Gerät HD schon einmal nicht dekodieren konnte.
  Future<void> _initExo() async {
    if (_mode == 'sd') {
      _activeQuality = 'sd';
    } else if (_mode == 'hd') {
      _activeQuality = 'hd';
    } else {
      _activeQuality = await HaConfig.hdUnsupported() ? 'sd' : 'hd';
    }
    await _startExo();
  }

  String get _qualityLabel {
    final active = _activeQuality == 'hd' ? 'HD' : 'SD';
    if (_mode == 'auto') return 'Auto ($active)';
    return active;
  }

  // ---- ExoPlayer / HLS (Android) ----
  Future<void> _startExo() async {
    setState(() {
      _status = 'Hole Kamera-Stream ($_qualityLabel) …';
      _error = false;
      _playing = false;
    });
    _sourceLabel = 'go2rtc · $_qualityLabel';
    try {
      final url = widget.config.hlsUrlForQuality(_activeQuality);
      final c = VideoPlayerController.networkUrl(
        Uri.parse(url),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _exo = c;
      // Timeout gegen Endlos-Laden (z.B. hängender Decoder nach HD-Fehlschlag).
      await c.initialize().timeout(const Duration(seconds: 20));
      // ExoPlayer startet bei Live-HLS an der Live-Kante. KEIN seekTo hier —
      // ein Sprung ans Ende direkt nach initialize() blockiert die Wiedergabe.
      await c.play();
      c.addListener(_exoListener);
      _liveTimer?.cancel();
      _liveTimer = Timer.periodic(const Duration(seconds: 12), (_) {
        final v = _exo?.value;
        if (v != null && v.isInitialized && v.isPlaying) {
          if (v.duration - v.position > const Duration(seconds: 10)) {
            _exo?.seekTo(v.duration - const Duration(seconds: 2));
          }
        }
      });
      _mcRetries = 0; // erfolgreicher Start -> Zähler zurücksetzen
      if (mounted) setState(() => _playing = true);
    } catch (e) {
      _handleExoError('$e');
    }
  }

  void _exoListener() {
    final v = _exo?.value;
    if (v != null && v.hasError) {
      _handleExoError(v.errorDescription ?? 'unbekannt');
    }
  }

  bool _fallingBack = false;
  int _mcRetries = 0;

  Future<void> _disposeExo() async {
    _exo?.removeListener(_exoListener);
    await _exo?.dispose();
    _exo = null;
  }

  /// Fehlerbehandlung:
  /// - HD überfordert den Decoder (EXCEEDS_CAPABILITIES) -> dauerhaft merken, auf SD.
  /// - Sonst transienter Decoder-Fehler (z.B. Kachel gibt den einzigen Hardware-
  ///   Decoder gerade erst frei) -> kurz warten und erneut versuchen.
  Future<void> _handleExoError(String desc) async {
    if (_fallingBack) return;
    final capExceeded = desc.contains('EXCEEDS_CAPABILITIES');

    if (_mode == 'auto' && _activeQuality == 'hd' && capExceeded) {
      await HaConfig.setHdUnsupported();
      _fallingBack = true;
      _activeQuality = 'sd';
      await _disposeExo();
      await Future.delayed(const Duration(milliseconds: 600));
      await _startExo();
      _fallingBack = false;
      return;
    }

    if (!capExceeded && _mcRetries < 4) {
      _mcRetries++;
      _fallingBack = true;
      await _disposeExo();
      await Future.delayed(const Duration(milliseconds: 700));
      await _startExo();
      _fallingBack = false;
      return;
    }

    if (!_error && mounted) {
      setState(() {
        _error = true;
        _status = 'Wiedergabefehler ($_qualityLabel): $desc';
      });
    }
  }

  /// Qualität durchschalten: Auto -> HD -> SD -> Auto. Wahl wird gespeichert.
  Future<void> _cycleQuality() async {
    _mode = _mode == 'auto' ? 'hd' : (_mode == 'hd' ? 'sd' : 'auto');
    _activeQuality = _mode == 'sd' ? 'sd' : 'hd';
    await HaConfig.saveQuality(_mode);
    _exo?.removeListener(_exoListener);
    await _exo?.dispose();
    _exo = null;
    await _startExo();
  }

  // ---- media_kit / RTSP (Desktop) ----
  Future<void> _configurePlayer() async {
    final p = _player!.platform;
    if (p is NativePlayer) {
      await p.setProperty('rtsp-transport', 'tcp');
      await p.setProperty('hwdec', 'no');
      await p.setProperty('cache', 'yes');
      await p.setProperty('cache-secs', '1.5');
      await p.setProperty('demuxer-readahead-secs', '1.5');
    }
  }

  Future<void> _startMediaKit() async {
    setState(() {
      _status = 'Hole Kamera-Stream …';
      _error = false;
      _playing = false;
    });
    try {
      String url;
      if (widget.config.hasDirectStream) {
        url = widget.config.rtspUrl.trim();
        _sourceLabel = 'Direkt (go2rtc)';
      } else {
        final client = HaClient(widget.config);
        if (!await client.ping()) {
          throw 'Home Assistant nicht erreichbar oder Token ungültig';
        }
        url = await client.getCameraHlsUrl(widget.config.cameraEntity);
        _sourceLabel = 'Home Assistant (HLS)';
      }
      await _player!.open(Media(url));
      if (mounted) setState(() => _playing = true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _status = 'Fehler: $e';
        });
      }
    }
  }

  Future<void> _retry() async {
    if (_useExo) {
      _fallingBack = false;
      if (_mode == 'sd') {
        _activeQuality = 'sd';
      } else if (_mode == 'hd') {
        _activeQuality = 'hd';
      } else {
        _activeQuality = await HaConfig.hdUnsupported() ? 'sd' : 'hd';
      }
      _exo?.removeListener(_exoListener);
      await _exo?.dispose();
      _exo = null;
      await _startExo();
    } else {
      await _startMediaKit();
    }
  }

  void _back() => Navigator.of(context).maybePop();

  @override
  void dispose() {
    _liveTimer?.cancel();
    _backFocus.dispose();
    _qualityFocus.dispose();
    _refreshFocus.dispose();
    _exo?.removeListener(_exoListener);
    _exo?.dispose();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Focus(
        // KEIN autofocus hier — sonst schluckt dieser Knoten den Fokus und die
        // Buttons sind per Fernbedienung nicht erreichbar. Key-Events erreichen
        // diesen Knoten trotzdem, weil er Vorfahre der fokussierten Buttons ist.
        onKeyEvent: (node, event) {
          // Android-Zurück NICHT hier abfangen (System poppt selbst -> ein Pop).
          if (event is KeyDownEvent) {
            final k = event.logicalKey;
            // Bedienleiste per D-Pad links/rechts durchschalten.
            if (k == LogicalKeyboardKey.arrowRight) {
              _moveFocus(1);
              return KeyEventResult.handled;
            }
            if (k == LogicalKeyboardKey.arrowLeft) {
              _moveFocus(-1);
              return KeyEventResult.handled;
            }
            // Fokussierten Button auslösen (Fallback, falls InkWell es nicht tut).
            if (k == LogicalKeyboardKey.select ||
                k == LogicalKeyboardKey.enter ||
                k == LogicalKeyboardKey.gameButtonA) {
              if (_qualityFocus.hasFocus) {
                _cycleQuality();
                return KeyEventResult.handled;
              }
              if (_refreshFocus.hasFocus) {
                _retry();
                return KeyEventResult.handled;
              }
              if (_backFocus.hasFocus) {
                _back();
                return KeyEventResult.handled;
              }
            }
            if (k == LogicalKeyboardKey.escape) {
              _back();
              return KeyEventResult.handled;
            }
            if (k == LogicalKeyboardKey.keyR) {
              _retry();
              return KeyEventResult.handled;
            }
            if (k == LogicalKeyboardKey.keyS ||
                k == LogicalKeyboardKey.contextMenu) {
              widget.onOpenSettings();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              _content(),
              // Bedienleiste oben — als Row für zuverlässige D-Pad-Navigation.
              Positioned(
                left: 12,
                right: 12,
                top: 12,
                child: SafeArea(
                  bottom: false,
                  child: FocusTraversalGroup(
                    child: Row(
                      children: [
                        _RoundButton(
                          icon: Icons.arrow_back,
                          tooltip: 'Zurück',
                          focusNode: _backFocus,
                          onPressed: _back,
                        ),
                        const Spacer(),
                        if (_useExo) ...[
                          _PillButton(
                            icon: Icons.hd_outlined,
                            label: _qualityLabel,
                            tooltip: 'Qualität: Auto / HD / SD',
                            focusNode: _qualityFocus,
                            onPressed: _cycleQuality,
                          ),
                          const SizedBox(width: 12),
                        ],
                        _RoundButton(
                          icon: Icons.refresh,
                          tooltip: 'Neu laden',
                          focusNode: _refreshFocus,
                          onPressed: _retry,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                bottom: 12,
                child: Text(
                  'Garten · $_sourceLabel  ·  Zurück = beenden',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content() {
    if (_error) {
      return _Overlay(status: _status, error: true, onRetry: _retry);
    }
    if (_useExo) {
      if (_playing && _exo != null && _exo!.value.isInitialized) {
        return Center(
          child: AspectRatio(
            aspectRatio: _exo!.value.aspectRatio == 0
                ? 16 / 9
                : _exo!.value.aspectRatio,
            child: VideoPlayer(_exo!),
          ),
        );
      }
      return _Overlay(status: _status, error: false, onRetry: _retry);
    }
    if (_playing && _mkController != null) {
      return Video(controller: _mkController!, fit: BoxFit.contain);
    }
    return _Overlay(status: _status, error: false, onRetry: _retry);
  }
}

/// Runder, halbtransparenter Button. InkWell sorgt für zuverlässige Aktivierung
/// per DPAD-OK/Enter auf Android TV; onFocusChange treibt die Hervorhebung.
class _RoundButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.focusNode,
  });

  @override
  State<_RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<_RoundButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: widget.tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onPressed,
          focusNode: widget.focusNode,
          customBorder: const CircleBorder(),
          onFocusChange: (f) => setState(() => _focused = f),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: _focused ? primary : Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
              border: Border.all(
                color: _focused ? Colors.white : Colors.white24,
                width: 2,
              ),
            ),
            child: Icon(widget.icon, color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }
}

/// Fokussierbare Pille mit Symbol + Text (z.B. Qualitätsumschalter).
class _PillButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  const _PillButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.focusNode,
  });

  @override
  State<_PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<_PillButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final radius = BorderRadius.circular(27);
    return Tooltip(
      message: widget.tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onPressed,
          focusNode: widget.focusNode,
          borderRadius: radius,
          onFocusChange: (f) => setState(() => _focused = f),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: _focused ? primary : Colors.black.withValues(alpha: 0.45),
              borderRadius: radius,
              border: Border.all(
                color: _focused ? Colors.white : Colors.white24,
                width: 2,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, color: Colors.white, size: 22),
                const SizedBox(width: 8),
                Text(widget.label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Overlay extends StatelessWidget {
  final String status;
  final bool error;
  final VoidCallback onRetry;
  const _Overlay(
      {required this.status, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!error) const CircularProgressIndicator(),
          if (error)
            const Icon(Icons.videocam_off, size: 56, color: Colors.white54),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ),
          if (error) ...[
            const SizedBox(height: 24),
            FilledButton.icon(
              autofocus: true,
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Erneut versuchen'),
            ),
          ],
        ],
      ),
    );
  }
}
