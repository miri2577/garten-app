import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Globaler Hell/Dunkel-Umschalter, von der App-Wurzel beobachtet.
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.dark);

const seedColor = Color(0xFF3B7A57); // Gartengrün
const _kThemeKey = 'theme_mode';

ThemeData lightTheme = ThemeData(
  useMaterial3: true,
  colorScheme:
      ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.light),
);

ThemeData darkTheme = ThemeData(
  useMaterial3: true,
  colorScheme:
      ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.dark),
);

Future<void> loadTheme() async {
  final prefs = await SharedPreferences.getInstance();
  final v = prefs.getString(_kThemeKey);
  themeNotifier.value = v == 'light' ? ThemeMode.light : ThemeMode.dark;
}

Future<void> toggleTheme() async {
  final next =
      themeNotifier.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
  themeNotifier.value = next;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kThemeKey, next == ThemeMode.light ? 'light' : 'dark');
}
