import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Zuletzt empfangener, noch nicht verarbeiteter Deep Link
/// (z.B. `garten://camera` vom TV-Launcher). Der Verbraucher setzt den Wert
/// nach dem Verarbeiten auf null zurück.
final ValueNotifier<String?> deepLinkNotifier = ValueNotifier<String?>(null);

const _channel = MethodChannel('de.cavia.garten_app/deeplink');

/// Vor runApp aufrufen: holt den Start-Link und lauscht auf spätere Links
/// (App läuft schon, Android liefert onNewIntent).
Future<void> initDeepLinks() async {
  if (kIsWeb || !Platform.isAndroid) return;
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'link') {
      deepLinkNotifier.value = call.arguments as String?;
    }
  });
  try {
    final initial = await _channel.invokeMethod<String>('getInitialLink');
    if (initial != null && initial.isNotEmpty) deepLinkNotifier.value = initial;
  } catch (_) {
    // Kein natives Gegenstück (z.B. alter Build) -> ohne Deep Links weiter.
  }
}

/// `garten://camera` -> true. Host statt Pfad, weil `garten://camera` vom
/// Uri-Parser als Host gelesen wird.
bool isCameraLink(String? link) {
  if (link == null) return false;
  final u = Uri.tryParse(link);
  return u != null && u.scheme == 'garten' && u.host == 'camera';
}
