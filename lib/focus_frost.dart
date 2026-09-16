import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Wiederverwendbares fokussierbares Element mit Milchglas-Fokuszustand
/// (halbtransparent aufgehellt, Backdrop-Blur, feiner weißer Rand, heller Glow,
/// ruhige Animation, minimale Vergrößerung). Passt zum Dashboard-Look.
///
/// Für Elemente OHNE Platform-View (Video) — dort wären Blur/Scale problematisch.
class FocusFrost extends StatefulWidget {
  final Widget child;
  final VoidCallback? onSelect;
  final bool autofocus;
  final Color? color; // Grundfläche (unfokussiert)
  final double radius;
  final EdgeInsetsGeometry? padding;

  const FocusFrost({
    super.key,
    required this.child,
    this.onSelect,
    this.autofocus = false,
    this.color,
    this.radius = 18,
    this.padding,
  });

  @override
  State<FocusFrost> createState() => _FocusFrostState();
}

class _FocusFrostState extends State<FocusFrost> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final baseColor = widget.color ?? scheme.surfaceContainerHighest;
    final radius = BorderRadius.circular(widget.radius);

    Widget content = widget.child;
    if (widget.padding != null) {
      content = Padding(padding: widget.padding!, child: content);
    }

    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onSelect?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onSelect,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: _focused ? 1 : 0),
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          builder: (context, t, child) {
            // Dunkle Grundflächen (z.B. Buttons mit heller Schrift) nur dezent
            // und DECKEND aufhellen, damit der Text lesbar bleibt. Helle Karten
            // behalten den kräftigeren, halbtransparenten Milchglas-Look.
            final baseIsDark =
                ThemeData.estimateBrightnessForColor(baseColor) ==
                    Brightness.dark;
            final frostTarget = baseIsDark
                ? Color.lerp(baseColor, Colors.white, 0.22)!
                : Colors.white.withValues(alpha: 0.5);
            final surface = Color.lerp(baseColor, frostTarget, t)!;
            return Transform.scale(
              scale: 1 + 0.02 * t,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: t <= 0
                      ? null
                      : [
                          BoxShadow(
                            color: Colors.white.withValues(alpha: 0.22 * t),
                            blurRadius: 22 * t,
                            spreadRadius: t,
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.10 * t),
                            blurRadius: 16 * t,
                            offset: Offset(0, 4 * t),
                          ),
                        ],
                ),
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.28 * t),
                      width: 1.5,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: radius,
                    child: t <= 0.01
                        ? ColoredBox(color: surface, child: child)
                        : BackdropFilter(
                            filter:
                                ImageFilter.blur(sigmaX: 14 * t, sigmaY: 14 * t),
                            child: ColoredBox(color: surface, child: child),
                          ),
                  ),
                ),
              ),
            );
          },
          child: content,
        ),
      ),
    );
  }
}
