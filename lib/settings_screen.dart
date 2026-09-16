import 'package:flutter/material.dart';

import 'ha_client.dart';

/// Eingabe von Home-Assistant-URL, Long-Lived-Token und Kamera-Entität.
class SettingsScreen extends StatefulWidget {
  final HaConfig config;

  /// Wird beim Erststart gesetzt (Screen ist dann direkt eingebettet, kein
  /// Navigator zum Zurückkehren). Sonst null -> es wird pop(true) benutzt.
  final Future<void> Function()? onSaved;

  const SettingsScreen({super.key, required this.config, this.onSaved});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _url =
      TextEditingController(text: widget.config.baseUrl);
  late final TextEditingController _token =
      TextEditingController(text: widget.config.token);
  late final TextEditingController _entity =
      TextEditingController(text: widget.config.cameraEntity);
  late final TextEditingController _rtsp =
      TextEditingController(text: widget.config.rtspUrl);

  bool _busy = false;
  String? _message;

  Future<void> _saveAndTest() async {
    setState(() {
      _busy = true;
      _message = 'Teste Verbindung …';
    });
    final cfg = HaConfig(
      baseUrl: _url.text.trim(),
      token: _token.text.trim(),
      cameraEntity: _entity.text.trim(),
      rtspUrl: _rtsp.text.trim(),
    );
    if (!cfg.isComplete) {
      setState(() {
        _busy = false;
        _message = 'Bitte URL, Token und Kamera-Entität ausfüllen.';
      });
      return;
    }
    final ok = await HaClient(cfg).ping();
    if (!ok) {
      setState(() {
        _busy = false;
        _message = 'Verbindung fehlgeschlagen — URL/Token prüfen.';
      });
      return;
    }
    await cfg.save();
    if (!mounted) return;
    if (widget.onSaved != null) {
      await widget.onSaved!();
    } else {
      Navigator.of(context).pop(true);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _entity.dispose();
    _rtsp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home Assistant verbinden')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              TextField(
                controller: _url,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Home-Assistant-URL',
                  hintText: 'https://ha.cavia-aperea.de',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _token,
                decoration: const InputDecoration(
                  labelText: 'Long-Lived Access Token',
                  hintText: 'aus HA: Profil → Sicherheit → Token erstellen',
                  border: OutlineInputBorder(),
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _entity,
                decoration: const InputDecoration(
                  labelText: 'Kamera-Entität (HA-Fallback)',
                  hintText: 'camera.tapo_c520ws_hd_stream',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _rtsp,
                decoration: const InputDecoration(
                  labelText: 'Direkter RTSP-Stream (glatt, go2rtc über Tailnet)',
                  hintText: 'rtsp://100.93.228.17:8554/garten  (leer = HA/HLS)',
                  helperText: 'Tailnet-IP des Pi · SD/mehr Glätte: …/garten_sd',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.inverseSurface,
                  foregroundColor:
                      Theme.of(context).colorScheme.onInverseSurface,
                ),
                onPressed: _busy ? null : _saveAndTest,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: const Text('Speichern & verbinden'),
              ),
              if (_message != null) ...[
                const SizedBox(height: 16),
                Text(_message!, style: const TextStyle(color: Colors.orangeAccent)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
