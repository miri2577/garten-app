import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Infos über eine verfügbare neue Version.
class UpdateInfo {
  final int versionCode;
  final String versionName;
  final String apkUrl;
  UpdateInfo(this.versionCode, this.versionName, this.apkUrl);
}

/// Selbst-Update über HiDrive (WebDAV).
///
/// GitHub Actions baut das APK und lädt `garten-app.apk` + `version.json` per
/// WebDAV auf HiDrive. Die App liest `version.json`, vergleicht mit ihrer
/// eigenen Build-Nummer und lädt bei Bedarf das neue APK und startet die
/// Installation (Nutzer bestätigt den System-Installationsdialog).
class Updater {
  // Zugang wird beim Build per --dart-define eingebacken (aus GitHub Secrets).
  static const _base = String.fromEnvironment('HIDRIVE_URL',
      defaultValue: 'https://webdav.hidrive.strato.com');
  static const _dir = String.fromEnvironment('HIDRIVE_DIR',
      defaultValue: '/users/miri2577/garten-app');
  static const _user = String.fromEnvironment('HIDRIVE_USER');
  static const _pass = String.fromEnvironment('HIDRIVE_PASS');

  static bool get configured => _user.isNotEmpty && _pass.isNotEmpty;

  /// Letzter Prüfstatus (nur für Diagnose in der UI).
  static String lastStatus = 'noch nicht geprüft';

  static Map<String, String> get _auth =>
      {'Authorization': 'Basic ${base64Encode(utf8.encode('$_user:$_pass'))}'};

  static String get _versionUrl => '$_base$_dir/version.json';
  static String _apkUrl(String name) => '$_base$_dir/$name';

  /// Aktuelle Build-Nummer der installierten App.
  static Future<int> localBuildNumber() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 0;
  }

  /// Prüft HiDrive auf eine neuere Version. Gibt null zurück, wenn aktuell oder
  /// nicht erreichbar.
  static Future<UpdateInfo?> check() async {
    if (!configured) {
      lastStatus = 'nicht konfiguriert (keine HiDrive-Creds im Build)';
      debugPrint('UPDATER: $lastStatus');
      return null;
    }
    try {
      debugPrint('UPDATER: GET $_versionUrl');
      final r = await http
          .get(Uri.parse(_versionUrl), headers: _auth)
          .timeout(const Duration(seconds: 12));
      debugPrint('UPDATER: HTTP ${r.statusCode}, body=${r.body}');
      if (r.statusCode != 200) {
        lastStatus = 'HTTP ${r.statusCode} von HiDrive';
        return null;
      }
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final remote = (j['versionCode'] as num).toInt();
      final local = await localBuildNumber();
      lastStatus = 'remote=$remote local=$local';
      debugPrint('UPDATER: $lastStatus');
      if (remote <= local) return null;
      final apk = (j['apk'] as String?) ?? 'garten-app.apk';
      return UpdateInfo(remote, (j['versionName'] ?? '').toString(), _apkUrl(apk));
    } catch (e) {
      lastStatus = 'Fehler: $e';
      debugPrint('UPDATER: $lastStatus');
      return null;
    }
  }

  /// Lädt das APK herunter (mit Fortschritt 0..1) und startet die Installation.
  static Future<String?> downloadAndInstall(
    String apkUrl, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final req = http.Request('GET', Uri.parse(apkUrl))..headers.addAll(_auth);
      final resp = await req.send();
      if (resp.statusCode != 200) return 'Download fehlgeschlagen (HTTP ${resp.statusCode})';

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/garten-app-update.apk');
      final sink = file.openWrite();
      final total = resp.contentLength ?? 0;
      int received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();

      final res = await OpenFilex.open(file.path,
          type: 'application/vnd.android.package-archive');
      if (res.type != ResultType.done) {
        return 'Installer konnte nicht geöffnet werden: ${res.message}';
      }
      return null; // Erfolg
    } catch (e) {
      return 'Fehler: $e';
    }
  }
}
