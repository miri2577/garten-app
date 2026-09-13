import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Zugangsdaten für Home Assistant. Werden in den App-Einstellungen gespeichert,
/// können aber für Entwicklungs-Builds per --dart-define vorbelegt werden:
///   flutter run --dart-define=HA_URL=https://ha.cavia-aperea.de --dart-define=HA_TOKEN=...
class HaConfig {
  final String baseUrl; // z.B. https://ha.cavia-aperea.de (ohne / am Ende)
  final String token; // Long-Lived Access Token
  final String cameraEntity; // z.B. camera.tapo_c520ws_hd_stream

  /// Direkter go2rtc-RTSP-Stream (glatt, latenzarm). Wenn gesetzt, wird er
  /// statt des HA-HLS-Streams abgespielt. Leer => Fallback auf HA-HLS.
  final String rtspUrl;

  /// go2rtc-HLS-Playlist (HD-Basis, src=garten). Auf Android wird die Kamera
  /// darüber mit ExoPlayer (video_player) abgespielt — HLS-Segmente beginnen
  /// mit einem Keyframe, was der TV-Decoder braucht. Die SD-Variante wird durch
  /// Ersetzen von src=garten -> src=garten_sd abgeleitet.
  ///
  /// HLS ist auf Android nur noch der Weg für die stumme Dashboard-Kachel und
  /// der Rückfall fürs Vollbild. Ton gibt es über HLS nicht: G.711 passt nicht
  /// in HLS, ffmpeg->AAC stotterte, und go2rtcs FLAC-Verpackung (`mp4=flac`)
  /// bringt den Android-FLAC-Decoder nach wenigen Sekunden zum Absturz.
  final String hlsUrl;

  /// Wunsch-Qualität: 'auto' (HD versuchen, bei Decoder-Fehler auf SD zurück),
  /// 'hd' (nur HD) oder 'sd' (nur SD).
  final String videoQuality;

  const HaConfig({
    required this.baseUrl,
    required this.token,
    this.cameraEntity = 'camera.tapo_c520ws_hd_stream',
    this.rtspUrl = 'rtsp://100.93.228.17:8554/garten',
    this.hlsUrl = 'http://100.93.228.17:1984/api/stream.m3u8?src=garten',
    this.videoQuality = 'auto',
  });

  /// RTSP-URL für eine konkrete Qualität ('hd' oder 'sd'), abgeleitet aus der
  /// Basis (…/garten bzw. …/garten_sd). Auf Android spielt das Vollbild diese
  /// URL mit ExoPlayer: H.264 + G.711/PCMA nativ — Ton ohne jede Umwandlung.
  String rtspUrlForQuality(String q) {
    final re = RegExp(r'/garten(_sd)?$');
    return rtspUrl.trim().replaceFirst(re, q == 'sd' ? '/garten_sd' : '/garten');
  }

  /// HLS-URL für eine konkrete Qualität ('hd' oder 'sd'), abgeleitet aus der Basis.
  String hlsUrlForQuality(String q) {
    final re = RegExp(r'src=garten(_sd)?');
    return hlsUrl.replaceFirst(re, q == 'sd' ? 'src=garten_sd' : 'src=garten');
  }

  bool get isComplete =>
      baseUrl.isNotEmpty && token.isNotEmpty && cameraEntity.isNotEmpty;

  bool get hasDirectStream => rtspUrl.trim().isNotEmpty;

  static const _defaultUrl =
      String.fromEnvironment('HA_URL', defaultValue: 'https://ha.cavia-aperea.de');
  static const _defaultToken = String.fromEnvironment('HA_TOKEN');
  static const _defaultEntity = String.fromEnvironment('HA_CAMERA',
      defaultValue: 'camera.tapo_c520ws_hd_stream');
  static const _defaultRtsp = String.fromEnvironment('HA_RTSP',
      defaultValue: 'rtsp://100.93.228.17:8554/garten');
  static const _defaultHls = String.fromEnvironment('HA_HLS',
      defaultValue: 'http://100.93.228.17:1984/api/stream.m3u8?src=garten');

  static const _kUrl = 'ha_url';
  static const _kToken = 'ha_token';
  static const _kEntity = 'ha_camera';
  static const _kRtsp = 'ha_rtsp';
  static const _kHls = 'ha_hls';
  static const _kQuality = 'ha_quality';

  static Future<HaConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final url = (prefs.getString(_kUrl) ?? _defaultUrl).trim();
    final token = (prefs.getString(_kToken) ?? _defaultToken).trim();
    final entity = (prefs.getString(_kEntity) ?? _defaultEntity).trim();
    final rtsp = (prefs.getString(_kRtsp) ?? _defaultRtsp).trim();
    final hls = (prefs.getString(_kHls) ?? _defaultHls).trim();
    final quality = (prefs.getString(_kQuality) ?? 'auto').trim();
    return HaConfig(
      baseUrl: _stripSlash(url),
      token: token,
      cameraEntity: entity,
      rtspUrl: rtsp,
      hlsUrl: hls,
      videoQuality: quality,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrl, _stripSlash(baseUrl.trim()));
    await prefs.setString(_kToken, token.trim());
    await prefs.setString(_kEntity, cameraEntity.trim());
    await prefs.setString(_kRtsp, rtspUrl.trim());
    await prefs.setString(_kHls, hlsUrl.trim());
    await prefs.setString(_kQuality, videoQuality.trim());
  }

  /// Nur die Qualitätswahl persistieren (für den Umschalter im Kamerabild).
  static Future<void> saveQuality(String q) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQuality, q);
  }

  /// Merkt sich, ob dieses Gerät HD (2K) nicht dekodieren kann. Dann startet der
  /// Auto-Modus direkt mit SD (spart den scheiternden HD-Versuch, der auf
  /// schwachen Decodern die Wiedergabe blockiert).
  static const _kHdUnsupported = 'ha_hd_unsupported';
  static Future<bool> hdUnsupported() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kHdUnsupported) ?? false;
  }

  static Future<void> setHdUnsupported() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHdUnsupported, true);
  }

  static String _stripSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  Uri get wsUri {
    final u = Uri.parse(baseUrl);
    final scheme = u.scheme == 'https' ? 'wss' : 'ws';
    return Uri(scheme: scheme, host: u.host, port: u.hasPort ? u.port : null, path: '/api/websocket');
  }
}

/// Ein Home-Assistant-Zustand (Entität).
class HaEntity {
  final String entityId;
  final String state;
  final Map<String, dynamic> attributes;

  HaEntity(this.entityId, this.state, this.attributes);

  factory HaEntity.fromJson(Map<String, dynamic> j) => HaEntity(
        j['entity_id'] as String,
        (j['state'] ?? '').toString(),
        (j['attributes'] as Map?)?.cast<String, dynamic>() ?? const {},
      );

  String get domain => entityId.split('.').first;
  String get friendlyName =>
      (attributes['friendly_name'] as String?) ?? entityId;
  String? get unit => attributes['unit_of_measurement'] as String?;
  bool get isUnavailable =>
      state.isEmpty || state == 'unknown' || state == 'unavailable';
}

/// Schlanker Home-Assistant-Client: REST für Zustände, WebSocket für die
/// signierte HLS-URL einer Kamera.
class HaClient {
  final HaConfig config;
  HaClient(this.config);

  /// Header für authentifizierte Bild-/Datenabrufe (z.B. Image.network).
  Map<String, String> get authHeaders => {
        'Authorization': 'Bearer ${config.token}',
      };

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer ${config.token}',
        'Content-Type': 'application/json',
      };

  /// Alle Zustände als Map entity_id -> HaEntity.
  Future<Map<String, HaEntity>> getStates() async {
    final r = await http
        .get(Uri.parse('${config.baseUrl}/api/states'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw 'HTTP ${r.statusCode} bei /api/states';
    }
    final list = jsonDecode(r.body) as List;
    final out = <String, HaEntity>{};
    for (final e in list) {
      final ent = HaEntity.fromJson(e as Map<String, dynamic>);
      out[ent.entityId] = ent;
    }
    return out;
  }

  /// URL für ein aktuelles Kamera-Standbild. `bust` erzwingt frisches Laden.
  String cameraSnapshotUrl(String entityId, {int? bust}) {
    final b = bust ?? DateTime.now().millisecondsSinceEpoch;
    return '${config.baseUrl}/api/camera_proxy/$entityId?_=$b';
  }

  /// Prüft die Verbindung (GET /api/) — liefert true bei gültigem Token.
  Future<bool> ping() async {
    try {
      final r = await http
          .get(Uri.parse('${config.baseUrl}/api/'), headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Zustand einer Entität, z.B. sensor.* — als geparstes JSON.
  Future<Map<String, dynamic>?> getState(String entityId) async {
    try {
      final r = await http
          .get(Uri.parse('${config.baseUrl}/api/states/$entityId'),
              headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        return jsonDecode(r.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Holt eine temporäre, signierte HLS-URL für eine Kamera-Entität über den
  /// WebSocket-Befehl `camera/stream`. Rückgabe: absolute URL zum master.m3u8.
  Future<String> getCameraHlsUrl(String entityId) async {
    final channel = WebSocketChannel.connect(config.wsUri);
    final completer = Completer<String>();
    int msgId = 1;
    late StreamSubscription sub;

    Timer timeout = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) {
        completer.completeError('Zeitüberschreitung bei camera/stream');
      }
    });

    sub = channel.stream.listen((raw) {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (msg['type']) {
        case 'auth_required':
          channel.sink.add(jsonEncode({'type': 'auth', 'access_token': config.token}));
          break;
        case 'auth_invalid':
          if (!completer.isCompleted) {
            completer.completeError('Token ungültig (auth_invalid)');
          }
          break;
        case 'auth_ok':
          channel.sink.add(jsonEncode({
            'id': msgId,
            'type': 'camera/stream',
            'entity_id': entityId,
          }));
          break;
        case 'result':
          if (msg['id'] == msgId) {
            if (msg['success'] == true && msg['result']?['url'] != null) {
              final path = msg['result']['url'] as String;
              final url = path.startsWith('http') ? path : '${config.baseUrl}$path';
              if (!completer.isCompleted) completer.complete(url);
            } else {
              if (!completer.isCompleted) {
                completer.completeError('camera/stream fehlgeschlagen: ${msg['error'] ?? msg}');
              }
            }
          }
          break;
      }
    }, onError: (e) {
      if (!completer.isCompleted) completer.completeError('WebSocket-Fehler: $e');
    }, onDone: () {
      if (!completer.isCompleted) {
        completer.completeError('WebSocket geschlossen, bevor die URL kam');
      }
    });

    try {
      return await completer.future;
    } finally {
      timeout.cancel();
      await sub.cancel();
      await channel.sink.close();
    }
  }
}
