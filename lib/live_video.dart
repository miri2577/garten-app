import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import 'main.dart' show routeObserver;

/// Nur solange das Kamera-Vollbild geöffnet wird/ist, gibt die Live-Kachel den
/// einzelnen MediaTek-Hardware-Decoder frei. Bei allen anderen Seiten (Detail,
/// Einstellungen) wird die Kachel nur pausiert. Grund: das ständige Freigeben +
/// Neu-Erzeugen des Decoders (C2MtkVdec) bei jedem Seiten-Öffnen/-Schließen
/// programmierte die MediaTek-Display-Pipeline um -> das Panel-Bild verschob
/// sich (Scaler-Versatz), teils bis in den TV-Startbildschirm.
bool liveTileReleaseForFullscreen = false;

/// Wiederverwendbare Live-Videoansicht.
///
/// - **Android:** ExoPlayer (video_player) auf HLS.
/// - **Sonst (Linux):** media_kit/libmpv auf RTSP.
///
/// Für die Dashboard-Kachel: [muted]=true, [fit]=cover, [pauseWhenCovered]=true
/// (pausiert, sobald das Vollbild darüber liegt).
class LiveVideo extends StatefulWidget {
  final String hlsUrl; // Android
  final String rtspUrl; // Linux
  final bool muted;
  final BoxFit fit;
  final bool pauseWhenCovered;

  const LiveVideo({
    super.key,
    required this.hlsUrl,
    required this.rtspUrl,
    this.muted = true,
    this.fit = BoxFit.cover,
    this.pauseWhenCovered = false,
  });

  @override
  State<LiveVideo> createState() => _LiveVideoState();
}

class _LiveVideoState extends State<LiveVideo> with RouteAware {
  Player? _player;
  VideoController? _mk;
  VideoPlayerController? _exo;
  bool _ready = false;
  bool _failed = false;
  Timer? _liveTimer;

  bool get _useExo =>
      !kIsWeb && Platform.isAndroid && widget.hlsUrl.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      if (_useExo) {
        final c = VideoPlayerController.networkUrl(
          Uri.parse(widget.hlsUrl.trim()),
          // Siehe camera_screen.dart: Texturweg ist auf manchen TV-Chips defekt.
          viewType: VideoViewType.platformView,
        );
        _exo = c;
        await c.initialize();
        await c.setVolume(widget.muted ? 0 : 1);
        // ExoPlayer startet an der Live-Kante; der periodische _keepLive-Timer
        // zieht bei Drift nach. KEIN initialer seekTo (blockiert Live-HLS).
        await c.play();
        _liveTimer = Timer.periodic(const Duration(seconds: 12), (_) => _keepLive());
        if (mounted) setState(() => _ready = true);
      } else {
        final p = Player();
        _player = p;
        _mk = VideoController(p);
        final np = p.platform;
        if (np is NativePlayer) {
          await np.setProperty('rtsp-transport', 'tcp');
          await np.setProperty('hwdec', 'no');
          await np.setProperty('cache', 'yes');
          await np.setProperty('cache-secs', '1.5');
        }
        await p.setVolume(widget.muted ? 0 : 100);
        await p.open(Media(widget.rtspUrl.trim()));
        if (mounted) setState(() => _ready = true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Hält den Live-Stream nah an der Live-Kante (springt vor, wenn er zurückfällt).
  void _keepLive() {
    final c = _exo;
    if (c == null || !c.value.isInitialized || !c.value.isPlaying) return;
    final behind = c.value.duration - c.value.position;
    if (behind > const Duration(seconds: 10)) {
      c.seekTo(c.value.duration - const Duration(seconds: 2));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.pauseWhenCovered) {
      final route = ModalRoute.of(context);
      if (route is PageRoute) routeObserver.subscribe(this, route);
    }
  }

  // Kamera-Vollbild kommt darüber -> Decoder KOMPLETT FREIGEBEN (das Vollbild
  // braucht den einzigen HW-Decoder). Andere Seiten (Detail/Einstellungen) ->
  // nur PAUSIEREN (Decoder bleibt, kein Neu-Erzeugen -> kein Scaler-Versatz).
  @override
  void didPushNext() {
    if (liveTileReleaseForFullscreen) {
      _release();
    } else {
      _pause();
    }
  }

  @override
  void didPopNext() {
    if (_exo == null && _player == null) {
      _restart(); // war freigegeben (Vollbild) -> neu aufbauen
    } else {
      _resume(); // war nur pausiert -> weiterlaufen lassen
    }
  }

  void _pause() {
    _liveTimer?.cancel();
    _liveTimer = null;
    _exo?.pause();
    _player?.pause();
  }

  void _resume() {
    final c = _exo;
    if (c != null) {
      c.play();
      _liveTimer ??=
          Timer.periodic(const Duration(seconds: 12), (_) => _keepLive());
    }
    _player?.play();
  }

  Future<void> _release() async {
    _liveTimer?.cancel();
    _liveTimer = null;
    await _exo?.dispose();
    _exo = null;
    await _player?.dispose();
    _player = null;
    _mk = null;
    if (mounted) setState(() => _ready = false);
  }

  Future<void> _restart() async {
    if (_ready || _exo != null || _player != null) return;
    if (mounted) {
      setState(() {
        _ready = false;
        _failed = false;
      });
    }
    await _start();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    if (widget.pauseWhenCovered) routeObserver.unsubscribe(this);
    _exo?.dispose();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Icon(Icons.videocam_off, color: Colors.white38, size: 40),
        ),
      );
    }
    if (!_ready) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_useExo) {
      final c = _exo!;
      return ClipRect(
        child: FittedBox(
          fit: widget.fit,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: c.value.size.width == 0 ? 640 : c.value.size.width,
            height: c.value.size.height == 0 ? 360 : c.value.size.height,
            child: VideoPlayer(c),
          ),
        ),
      );
    }
    return Video(controller: _mk!, fit: widget.fit, controls: NoVideoControls);
  }
}
