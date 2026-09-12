import 'package:flutter_test/flutter_test.dart';

import 'package:garten_app/ha_client.dart';

void main() {
  test('HaConfig erkennt unvollständige Konfiguration', () {
    const empty = HaConfig(baseUrl: '', token: '');
    expect(empty.isComplete, isFalse);

    const full = HaConfig(
      baseUrl: 'https://ha.cavia-aperea.de',
      token: 'abc',
      cameraEntity: 'camera.tapo_c520ws_hd_stream',
    );
    expect(full.isComplete, isTrue);
  });

  test('wsUri leitet wss aus https ab', () {
    const cfg = HaConfig(baseUrl: 'https://ha.cavia-aperea.de', token: 'x');
    expect(cfg.wsUri.scheme, 'wss');
    expect(cfg.wsUri.path, '/api/websocket');
  });
}
