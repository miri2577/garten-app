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
  /// Per Deep Link (garten://camera vom TV-Launcher) geöffnet: Zurück beendet
  /// die App, damit man direkt wieder im Launcher landet statt im Dashboard.
  final bool exitAppOnBack;
  const CameraScreen({
    super.key,
    required this.config,
    required this.onOpenSettings,
    this.exitAppOnBack = false,
  });

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  // media_kit-Pfad (Desktop)
  Player? _player;
  VideoController? _mkController;
  StreamSubscription? _mkLog;
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

  // HD-Downgrade gilt nur für die laufende Sitzung, nicht dauerhaft: Beim
  // Kaltstart kann HD kurz scheitern (der einzige HW-Decoder ist noch von der
  // Kachel belegt). Das darf HD nicht für immer sperren – beim nächsten
  // Öffnen wird im Auto-Modus wieder HD versucht.
  bool _hdBlockedSession = false;
  int _hdCapFails = 0;

  // Explizite Fokusverwaltung für die Bedienleiste (D-Pad links/rechts).
  // Bedienelemente + Infozeile blenden sich nach kurzer Ruhe aus; jede Taste,
  // Maus- oder Touch-Aktion holt sie für ein paar Sekunden zurück.
  bool _controlsVisible = true;
  Timer? _hideTimer;
  static const _hideAfter = Duration(seconds: 4);

  void _showControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
    _hideTimer = Timer(_hideAfter, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  final FocusNode _backFocus = FocusNode(debugLabel: 'back');
  final FocusNode _qualityFocus = FocusNode(debugLabel: 'quality');
  final FocusNode _refreshFocus = FocusNode(debugLabel: 'refresh');

  List<FocusNode> get _navNodes => [
    _backFocus,
    if (_qualityAvailable) _qualityFocus,
    _refreshFocus,
  ];

  void _moveFocus(int dir) {
    final nodes = _navNodes;
    final idx = nodes.indexWhere((n) => n.hasFocus);
    final cur = idx < 0 ? 0 : idx;
    final next = (cur + dir).clamp(0, nodes.length - 1);
    nodes[next].requestFocus();
  }

  // Bild auf Android über ExoPlayer (RTSP video-only, rendert HD bildschirm-
  // füllend, kein Surface-Problem). Ton getrennt über libmpv (audio-only, ohne
  // Video also ohne Surface). media_kit-Video nur noch auf dem Linux-Desktop.
  bool get _useExo => !kIsWeb && Platform.isAndroid;

  bool get _qualityAvailable => widget.config.hasDirectStream;

  @override
  void initState() {
    super.initState();
    // Alt-Flag entfernen: HD wird im Auto-Modus wieder versucht.
    HaConfig.clearHdUnsupported();
    if (_useExo) {
      _initExo();
    } else {
      _player = Player(
        configuration: const PlayerConfiguration(
          logLevel: MPVLogLevel.info,
          // WICHTIG: 'rtsp' + 'rtsps' explizit erlauben. Das gebundelte
          // Android-ffmpeg nimmt sonst die (zu enge) Standardliste und
          // verweigert das Öffnen der rtsp://-URL -> Dauer-Ladekreis.
          protocolWhitelist: [
            'file', 'data', 'crypto', 'tcp', 'tls', 'udp', 'rtp',
            'http', 'https', 'rtsp', 'rtsps',
          ],
        ),
      );
      _mkLog = _player!.stream.log.listen((l) {
        // ignore: avoid_print
        print('MPV[${l.level}] ${l.prefix}: ${l.text}');
      });
      _mkController = VideoController(_player!);
      _initMediaKit();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _backFocus.requestFocus();
      _showControls();
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
      _activeQuality = _hdBlockedSession ? 'sd' : 'hd';
    }
    await _startExo();
    // Ton bewusst verzögert: starten Video- und Audio-RTSP-Sitzung gleichzeitig,
    // beantwortet go2rtc das zweite DESCRIBE mit 404. 2,5 s Abstand genügen.
    _audioStartTimer?.cancel();
    _audioStartTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) _startAudio();
    });
  }

  String get _qualityLabel {
    final active = _activeQuality == 'hd' ? 'HD' : 'SD';
    if (_mode == 'auto') return 'Auto ($active)';
    return active;
  }

  // ---- ExoPlayer (Android) ----
  // Bild läuft über HLS (auf dem TV-Decoder zuverlässig, full HD), Ton über
  // einen getrennten RTSP-Player (siehe unten). Warum getrennt: koppelt man
  // Bild und Ton in EINER RTSP-Sitzung, friert das Bild nach Sekunden ein;
  // startet man beide RTSP-Sitzungen gleichzeitig, liefert go2rtc dem zweiten
  // DESCRIBE ein 404. Getrennte Transporte umgehen beides.
  String _transport = 'rtsp';

  bool get _rtspAvailable => widget.config.rtspUrl.trim().isNotEmpty;

  // ---- Ton: eigener Player über media_kit/libmpv ----
  // NICHT über einen zweiten ExoPlayer: dessen RTSP-Client beantwortet eine
  // zweite gleichzeitige Sitzung im selben Prozess grundsätzlich mit DESCRIBE
  // 404 (unabhängig von Query oder Streamnamen). libmpv bringt einen eigenen
  // RTSP-Stack mit und läuft konfliktfrei neben dem ExoPlayer-Bild.
  Player? _audio;
  Timer? _audioStartTimer;

  StreamSubscription? _audioLog;

  Future<void> _startAudio() async {
    if (!_rtspAvailable || _audio != null) return;
    // Bewährten gekoppelten Stream nehmen (der lieferte Ton), aber die SD-Variante
    // (kleiner Video-Overhead) und mit vid=no -> libmpv dekodiert nur den Ton,
    // kein Video, also keine Surface. Der separate garten_audio-Stream liefert
    // "Invalid data" und fällt weg.
    final url = widget.config.rtspUrlForQuality('sd');
    try {
      final p = Player(
        configuration: const PlayerConfiguration(
          logLevel: MPVLogLevel.info,
          protocolWhitelist: [
            'file', 'data', 'crypto', 'tcp', 'tls', 'udp', 'rtp',
            'http', 'https', 'rtsp', 'rtsps',
          ],
        ),
      );
      _audio = p;
      _audioLog = p.stream.log.listen((l) {
        // ignore: avoid_print
        print('AMPV[${l.level}] ${l.prefix}: ${l.text}');
      });
      final np = p.platform;
      if (np is NativePlayer) {
        await np.setProperty('rtsp-transport', 'tcp'); // go2rtc nur TCP
        await np.setProperty('vid', 'no'); // reiner Ton -> kein Video/Surface
        // Puffer gegen "Audio device underrun" -> sonst hungert die Ausgabe aus
        // und der Ton klingt verzerrt / nach falscher Geschwindigkeit.
        await np.setProperty('cache', 'yes');
        await np.setProperty('cache-secs', '2');
        await np.setProperty('demuxer-readahead-secs', '2');
        // Ausgabe mit nativer Geräte-Samplerate (TV = 48 kHz); Kamera liefert
        // 8 kHz -> libmpv resampled sauber hoch.
        await np.setProperty('audio-samplerate', '48000');
      }
      await p.setVolume(100);
      await p.open(Media(url), play: true);
      // ignore: avoid_print
      print('AUDIO: libmpv geöffnet -> $url');
    } catch (e) {
      // ignore: avoid_print
      print('AUDIO-FEHLER: $e ($url)');
      await _stopAudio();
    }
  }

  Future<void> _stopAudio() async {
    final a = _audio;
    _audio = null;
    await _audioLog?.cancel();
    _audioLog = null;
    await a?.dispose();
  }

  Future<void> _startExo() async {
    if (!_rtspAvailable) _transport = 'hls';
    setState(() {
      _status = 'Hole Kamera-Stream ($_qualityLabel) …';
      _error = false;
      _playing = false;
    });
    _sourceLabel =
        'go2rtc ${_transport.toUpperCase()} · $_qualityLabel${_rtspAvailable ? ' · Ton' : ''}';
    try {
      final url = _transport == 'rtsp'
          ? widget.config.rtspVideoUrl(_activeQuality)
          : widget.config.hlsUrlForQuality(_activeQuality);
      final c = VideoPlayerController.networkUrl(
        Uri.parse(url),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        // SurfaceView statt Textur: auf dem Google TV Streamer wird die
        // Video-Textur falsch skaliert (Bild oben links, Rest gruen).
        viewType: VideoViewType.platformView,
      );
      _exo = c;
      // Timeout gegen Endlos-Laden (z.B. hängender Decoder nach HD-Fehlschlag).
      await c.initialize().timeout(const Duration(seconds: 20));
      // ExoPlayer startet bei Live-HLS an der Live-Kante. KEIN seekTo hier —
      // ein Sprung ans Ende direkt nach initialize() blockiert die Wiedergabe.
      await c.play();
      c.addListener(_exoListener);
      _liveTimer?.cancel();
      // Live-Kante nachziehen gibt es nur bei HLS; RTSP ist ohnehin live und
      // hat keine Dauer, in die man springen könnte.
      if (_transport == 'hls') {
        _liveTimer = Timer.periodic(const Duration(seconds: 12), (_) {
          final v = _exo?.value;
          if (v != null && v.isInitialized && v.isPlaying) {
            if (v.duration - v.position > const Duration(seconds: 10)) {
              _exo?.seekTo(v.duration - const Duration(seconds: 2));
            }
          }
        });
      }
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
  /// - Sind die Versuche über RTSP aufgebraucht -> einmalig auf HLS wechseln.
  Future<void> _handleExoError(String desc) async {
    if (_fallingBack) return;
    final capExceeded = desc.contains('EXCEEDS_CAPABILITIES');

    // Quellfehler (RTSP-Handshake, Netz, 4xx) sind keine Decoder-Hänger:
    // nicht viermal warten, sondern sofort auf HLS ausweichen.
    final sourceError =
        desc.contains('Source error') ||
        desc.contains('SETUP') ||
        desc.contains('Response code') ||
        desc.contains('Unable to connect');
    if (sourceError && _transport == 'rtsp') {
      _transport = 'hls';
      _mcRetries = 0;
      _fallingBack = true;
      await _disposeExo();
      await Future.delayed(const Duration(milliseconds: 300));
      await _startExo();
      _fallingBack = false;
      return;
    }

    if (_mode == 'auto' && _activeQuality == 'hd' && capExceeded) {
      _hdCapFails++;
      _fallingBack = true;
      await _disposeExo();
      await Future.delayed(const Duration(milliseconds: 600));
      if (_hdCapFails < 2) {
        // Erster Fehlschlag: HW-Decoder ist beim Kaltstart evtl. nur kurz von
        // der Kachel belegt -> HD gleich nochmal versuchen (nicht sperren).
        await _startExo();
      } else {
        // Wiederholt: dieses Gerät schafft HD gerade nicht -> nur für DIESE
        // Sitzung auf SD, beim nächsten Öffnen wird HD erneut versucht.
        _hdBlockedSession = true;
        _activeQuality = 'sd';
        await _startExo();
      }
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

    if (!capExceeded && _transport == 'rtsp') {
      _transport = 'hls';
      _mcRetries = 0;
      _fallingBack = true;
      await _disposeExo();
      await Future.delayed(const Duration(milliseconds: 500));
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
    await _startMediaKit(); // öffnet den Player mit der neuen Qualität neu
  }

  /// Startqualität bestimmen (Auto/HD/SD, HD-Sperre gemerkt) und Player starten.
  Future<void> _initMediaKit() async {
    if (_mode == 'sd') {
      _activeQuality = 'sd';
    } else if (_mode == 'hd') {
      _activeQuality = 'hd';
    } else {
      _activeQuality = _hdBlockedSession ? 'sd' : 'hd';
    }
    await _configurePlayer();
    await _startMediaKit();
  }

  // ---- media_kit / RTSP (Desktop) ----
  Future<void> _configurePlayer() async {
    final p = _player!.platform;
    if (p is NativePlayer) {
      // go2rtc kann RTSP nur über TCP (UDP -> 461). hwdec/vo/Surface verwaltet
      // media_kit auf Android selbst (VideoController) — hier NICHT anfassen,
      // sonst bricht die Textur-Einrichtung (Resize 1x1 / schwarzes Bild).
      await p.setProperty('rtsp-transport', 'tcp');
    }
  }

  String _lastUrl = '';
  Timer? _videoWatchdog;
  int _mkRestarts = 0;
  Duration _lastPos = Duration.zero;
  int _stallTicks = 0;

  /// Wartet, bis media_kit der Video-Surface eine Größe zugewiesen hat
  /// (controller.rect != null). Das passiert nach dem ersten Layout des
  /// Video-Widgets; erst dann existiert die native Surface für den Decoder.
  Future<void> _waitForSurfaceRect() async {
    final c = _mkController;
    if (c == null || c.rect.value != null) return;
    final done = Completer<void>();
    void check() {
      if (c.rect.value != null && !done.isCompleted) done.complete();
    }
    c.rect.addListener(check);
    check();
    await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    c.rect.removeListener(check);
  }

  /// Stall-Wächter: prüft alle 2 s, ob die Wiedergabe weiterläuft. Steht die
  /// Position (eingefrorene Pipeline), wird — nachdem die Surface sicher da ist —
  /// der Stream neu geöffnet. Läuft die Wiedergabe, wird der Zähler genullt.
  void _armVideoWatchdog() {
    _videoWatchdog?.cancel();
    _lastPos = _player?.state.position ?? Duration.zero;
    _stallTicks = 0;
    _videoWatchdog = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || _player == null || _lastUrl.isEmpty) return;
      final st = _player!.state;
      final advancing = st.position != _lastPos;
      _lastPos = st.position;
      if (advancing && (st.width ?? 0) > 0) {
        _stallTicks = 0;
        _mkRestarts = 0; // läuft stabil
        return;
      }
      _stallTicks++;
      if (_stallTicks >= 3 && _mkRestarts < 6) {
        // ~6 s kein Fortschritt -> neu öffnen. Hardware-Decoding bleibt (kein
        // Software-Ausweichen — das wäre auf schwächeren Geräten zu schwer);
        // vor dem Öffnen ist die Surface durch _waitForSurfaceRect sicher da.
        _mkRestarts++;
        _stallTicks = 0;
        // ignore: avoid_print
        print('MK: Stillstand -> Stream neu öffnen (#$_mkRestarts)');
        try {
          await _waitForSurfaceRect();
          await _player!.open(Media(_lastUrl));
        } catch (_) {}
      }
    });
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
        url = widget.config.rtspUrlForQuality(_activeQuality);
        _sourceLabel = 'go2rtc RTSP · $_qualityLabel · Ton';
      } else {
        final client = HaClient(widget.config);
        if (!await client.ping()) {
          throw 'Home Assistant nicht erreichbar oder Token ungültig';
        }
        url = await client.getCameraHlsUrl(widget.config.cameraEntity);
        _sourceLabel = 'Home Assistant (HLS)';
      }
      _lastUrl = url;
      await _waitForSurfaceRect(); // Surface muss eine Größe haben, bevor der
      // Hardware-Decoder startet (sonst "surface NULL")
      // ignore: avoid_print
      print('MK: öffne $url');
      await _player!.setVolume(100); // Ton im Vollbild an
      await _player!.open(Media(url));
      // ignore: avoid_print
      print('MK: open() zurückgekehrt für $url');
      if (mounted) setState(() => _playing = true);
      _armVideoWatchdog();
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
      _mcRetries = 0;
      _transport = 'rtsp'; // manuelles Neuladen probiert wieder den Weg mit Ton
      await _stopAudio();
      _audioStartTimer?.cancel();
      _audioStartTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted) _startAudio();
      });
      if (_mode == 'sd') {
        _activeQuality = 'sd';
      } else if (_mode == 'hd') {
        _activeQuality = 'hd';
      } else {
        _activeQuality = _hdBlockedSession ? 'sd' : 'hd';
      }
      _exo?.removeListener(_exoListener);
      await _exo?.dispose();
      _exo = null;
      await _startExo();
    } else {
      await _startMediaKit();
    }
  }

  void _back() {
    if (widget.exitAppOnBack) {
      SystemNavigator.pop(); // Activity beenden -> zurück zum Launcher
      return;
    }
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _hideTimer?.cancel();
    _audioStartTimer?.cancel();
    _videoWatchdog?.cancel();
    _mkLog?.cancel();
    _stopAudio();
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
      // Deep-Link-Modus: System-Zurück nicht auf das Dashboard poppen,
      // sondern die App beenden (siehe exitAppOnBack).
      canPop: !widget.exitAppOnBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.exitAppOnBack) SystemNavigator.pop();
      },
      child: Focus(
        // KEIN autofocus hier — sonst schluckt dieser Knoten den Fokus und die
        // Buttons sind per Fernbedienung nicht erreichbar. Key-Events erreichen
        // diesen Knoten trotzdem, weil er Vorfahre der fokussierten Buttons ist.
        onKeyEvent: (node, event) {
          // Android-Zurück NICHT hier abfangen (System poppt selbst -> ein Pop).
          if (event is KeyDownEvent) {
            final k = event.logicalKey;
            final wereHidden = !_controlsVisible;
            _showControls();
            // Waren die Elemente ausgeblendet, holt der erste Druck auf
            // Pfeil/OK sie nur zurück (Zurück/Esc wirken weiterhin sofort).
            if (wereHidden &&
                (k == LogicalKeyboardKey.arrowRight ||
                    k == LogicalKeyboardKey.arrowLeft ||
                    k == LogicalKeyboardKey.arrowUp ||
                    k == LogicalKeyboardKey.arrowDown ||
                    k == LogicalKeyboardKey.select ||
                    k == LogicalKeyboardKey.enter ||
                    k == LogicalKeyboardKey.gameButtonA)) {
              return KeyEventResult.handled;
            }
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
          body: Listener(
            onPointerDown: (_) => _showControls(),
            onPointerHover: (_) => _showControls(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _content(),
                // Bedienleiste oben — als Row für zuverlässige D-Pad-Navigation.
                Positioned(
                  left: 12,
                  right: 12,
                  top: 12,
                  child: _Fade(
                    visible: _controlsVisible,
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
                            if (_qualityAvailable) ...[
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
                ),
                Positioned(
                  left: 16,
                  bottom: 12,
                  child: _Fade(
                    visible: _controlsVisible,
                    child: Text(
                      'Garten · $_sourceLabel  ·  Zurück = beenden',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
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
        // Der Decoder meldet die echte Aufloesung erst nach dem ersten Keyframe
        // nach (z.B. 320x240 -> 2560x1440). Deshalb auf Aenderungen hoeren,
        // sonst bleibt das Seitenverhaeltnis auf dem Startwert stehen.
        return ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: _exo!,
          builder: (context, v, child) => Center(
            child: AspectRatio(
              aspectRatio: v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio,
              child: child,
            ),
          ),
          child: VideoPlayer(_exo!),
        );
      }
      return _Overlay(status: _status, error: false, onRetry: _retry);
    }
    if (_mkController != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Video(controller: _mkController!, fit: BoxFit.contain),
          if (!_playing)
            _Overlay(status: _status, error: false, onRetry: _retry),
        ],
      );
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
    final radius = BorderRadius.circular(14);
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
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: _focused ? 1 : 0),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            builder: (context, t, _) => Transform.scale(
              scale: 1 + 0.06 * t,
              child: Container(
                width: 54,
                height: 54,
                alignment: Alignment.center,
                decoration: _frostDeco(t, radius),
                child: Icon(widget.icon, color: _frostIcon(t), size: 26),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fokus = Milchglas: dunkle Grundfläche -> halbtransparent aufgehellt,
/// heller Rand + Glow. Gleiche Sprache wie die Detailseiten (nur bei Fokus).
BoxDecoration _frostDeco(double t, BorderRadius radius) => BoxDecoration(
      color: Color.lerp(Colors.black.withValues(alpha: 0.45),
          Colors.white.withValues(alpha: 0.55), t),
      borderRadius: radius,
      border: Border.all(
        color: Color.lerp(
            Colors.white24, Colors.white.withValues(alpha: 0.85), t)!,
        width: 1.6,
      ),
      boxShadow: t <= 0
          ? null
          : [
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.30 * t),
                blurRadius: 22 * t,
                spreadRadius: t,
              ),
            ],
    );

/// Icon/Text-Farbe: über der dunklen Fläche weiß, auf der hellen Milchglas-
/// Fläche dunkel — damit ohne Fokus wie mit Fokus gut lesbar.
Color _frostIcon(double t) =>
    Color.lerp(Colors.white, const Color(0xFF1A1C1A), t)!;

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
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: _focused ? 1 : 0),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            builder: (context, t, _) => Transform.scale(
              scale: 1 + 0.04 * t,
              child: Container(
                height: 54,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                alignment: Alignment.center,
                decoration: _frostDeco(t, radius),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, color: _frostIcon(t), size: 22),
                    const SizedBox(width: 8),
                    Text(
                      widget.label,
                      style: TextStyle(
                        color: _frostIcon(t),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Weich ein-/ausblenden; ausgeblendet ignoriert es Zeiger-Eingaben.
class _Fade extends StatelessWidget {
  final bool visible;
  final Widget child;
  const _Fade({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 350),
        child: child,
      ),
    );
  }
}

class _Overlay extends StatelessWidget {
  final String status;
  final bool error;
  final VoidCallback onRetry;
  const _Overlay({
    required this.status,
    required this.error,
    required this.onRetry,
  });

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
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.92),
                foregroundColor: const Color(0xFF1A1C1A),
              ),
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
