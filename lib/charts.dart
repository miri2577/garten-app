import 'package:flutter/material.dart';

import 'garden_data.dart';

/// Kleine Verlaufslinie für die Dashboard-Kachel.
class Sparkline extends StatelessWidget {
  final List<int> data; // 0..100
  final Color color;
  final double height;
  const Sparkline({
    super.key,
    required this.data,
    required this.color,
    this.height = 34,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _SparkPainter(data, color)),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<int> data;
  final Color color;
  _SparkPainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final path = Path();
    final fill = Path();
    double x(int i) => i / (data.length - 1) * size.width;
    double y(int v) => size.height - (v.clamp(0, 100) / 100) * size.height;

    path.moveTo(x(0), y(data[0]));
    fill.moveTo(x(0), size.height);
    fill.lineTo(x(0), y(data[0]));
    for (var i = 1; i < data.length; i++) {
      // weiche Kurve über Kontrollpunkte in der Mitte
      final px = x(i - 1), py = y(data[i - 1]);
      final cx = x(i), cy = y(data[i]);
      final mx = (px + cx) / 2;
      path.cubicTo(mx, py, mx, cy, cx, cy);
      fill.cubicTo(mx, py, mx, cy, cx, cy);
    }
    fill.lineTo(x(data.length - 1), size.height);
    fill.close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.data != data || old.color != color;
}

/// Größeres Verlaufsdiagramm mit Statusbändern (trocken/optimal/feucht),
/// Rasterlinien und Zeitachse — für die Detailseite.
class MoistureChart extends StatelessWidget {
  final List<int> data; // 0..100
  final bool weekly; // false = 24 h, true = 7 Tage
  final Color lineColor;
  const MoistureChart({
    super.key,
    required this.data,
    required this.weekly,
    required this.lineColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      painter: _ChartPainter(
        data: data,
        weekly: weekly,
        lineColor: lineColor,
        gridColor: scheme.outlineVariant,
        labelColor: scheme.onSurfaceVariant,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<int> data;
  final bool weekly;
  final Color lineColor;
  final Color gridColor;
  final Color labelColor;
  _ChartPainter({
    required this.data,
    required this.weekly,
    required this.lineColor,
    required this.gridColor,
    required this.labelColor,
  });

  static const double padL = 40, padR = 12, padT = 10, padB = 26;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(padL, padT, size.width - padR, size.height - padB);

    double y(num v) => rect.bottom - (v.clamp(0, 100) / 100) * rect.height;
    double x(int i) =>
        rect.left + (data.length < 2 ? 0 : i / (data.length - 1) * rect.width);

    // Statusbänder (sehr dezent)
    void band(int lo, int hi, MoistureStatus st) {
      canvas.drawRect(
        Rect.fromLTRB(rect.left, y(hi), rect.right, y(lo)),
        Paint()..color = st.color.withValues(alpha: 0.08),
      );
    }

    band(0, 30, MoistureStatus.dry);
    band(30, 60, MoistureStatus.optimal);
    band(60, 100, MoistureStatus.wet);

    // Rasterlinien + Y-Beschriftung bei 0/30/60/100
    final grid = Paint()
      ..color = gridColor.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (final v in [0, 30, 60, 100]) {
      final yy = y(v);
      canvas.drawLine(Offset(rect.left, yy), Offset(rect.right, yy), grid);
      _text(canvas, '$v', Offset(4, yy - 8), labelColor, 12);
    }

    // Zeitachse (Start/Mitte/Ende)
    final n = data.length;
    final labels = weekly
        ? ['vor 7 T', 'vor 3 T', 'heute']
        : ['vor 24 h', 'vor 12 h', 'jetzt'];
    final xs = [x(0), x((n - 1) ~/ 2), x(n - 1)];
    for (var i = 0; i < 3; i++) {
      _text(canvas, labels[i], Offset(xs[i] - (i == 0 ? 0 : (i == 2 ? 44 : 24)),
          size.height - padB + 6), labelColor, 12);
    }

    if (data.length < 2) return;

    // Fläche unter der Linie
    final fill = Path()..moveTo(x(0), rect.bottom);
    fill.lineTo(x(0), y(data[0]));
    final line = Path()..moveTo(x(0), y(data[0]));
    for (var i = 1; i < data.length; i++) {
      final mx = (x(i - 1) + x(i)) / 2;
      line.cubicTo(mx, y(data[i - 1]), mx, y(data[i]), x(i), y(data[i]));
      fill.cubicTo(mx, y(data[i - 1]), mx, y(data[i]), x(i), y(data[i]));
    }
    fill.lineTo(x(data.length - 1), rect.bottom);
    fill.close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            lineColor.withValues(alpha: 0.20),
            lineColor.withValues(alpha: 0.0),
          ],
        ).createShader(rect),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // aktueller Punkt
    canvas.drawCircle(Offset(x(data.length - 1), y(data.last)), 4.5,
        Paint()..color = lineColor);
  }

  void _text(Canvas c, String s, Offset o, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.data != data || old.weekly != weekly || old.lineColor != lineColor;
}
