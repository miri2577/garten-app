import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'dashboard_screen.dart';
import 'deep_link.dart';
import 'ha_client.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// Beobachtet Routenwechsel, damit die Live-Kachel pausiert, wenn das Vollbild
/// darüber liegt (spart Dekodierleistung auf schwacher TV-Hardware).
final RouteObserver<PageRoute<dynamic>> routeObserver =
    RouteObserver<PageRoute<dynamic>>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await loadTheme();
  await initDeepLinks();
  runApp(const GartenApp());
}

class GartenApp extends StatelessWidget {
  const GartenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Garten',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: lightTheme,
          darkTheme: darkTheme,
          navigatorObservers: [routeObserver],
          home: const RootRouter(),
        );
      },
    );
  }
}

/// Wurzel: lädt die Konfiguration und zeigt entweder das Dashboard oder die
/// Einstellungen. Hält den Zustand, damit ein Speichern sauber umschaltet.
class RootRouter extends StatefulWidget {
  const RootRouter({super.key});

  @override
  State<RootRouter> createState() => _RootRouterState();
}

class _RootRouterState extends State<RootRouter> {
  HaConfig? _config;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await HaConfig.load();
    if (mounted) {
      setState(() {
        _config = cfg;
        _loading = false;
      });
    }
  }

  Future<void> _openSettings() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(config: _config!),
      ),
    );
    if (saved == true) {
      setState(() => _loading = true);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _config == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_config!.isComplete) {
      // Erststart ohne Zugangsdaten -> direkt Einstellungen anbieten.
      return SettingsScreen(
        config: _config!,
        onSaved: () async {
          setState(() => _loading = true);
          await _load();
        },
      );
    }
    // Neuer Schlüssel bei jeder Config -> Dashboard wird frisch aufgebaut.
    return DashboardScreen(
      key: ValueKey('${_config!.baseUrl}|${_config!.cameraEntity}'),
      config: _config!,
      onOpenSettings: _openSettings,
    );
  }
}
