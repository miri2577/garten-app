import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:garten_app/garden_data.dart';
import 'package:garten_app/irrigation_data.dart';
import 'package:garten_app/irrigation_detail_screen.dart';
import 'package:garten_app/soil_detail_screen.dart';

/// Prüft, dass die Detailseiten in Handy-Hochformat, Handy-Querformat und
/// TV-Größe ohne Layout-Overflow rendern.
void main() {
  final sizes = <String, Size>{
    'Handy hochkant': const Size(360, 740),
    'Handy quer (klein)': const Size(740, 360),
    'Handy quer (groß)': const Size(915, 412),
    'Tablet quer': const Size(1024, 700),
    'Google TV (960x540)': const Size(960, 540),
    'TV FullHD (logisch)': const Size(1280, 720),
  };

  Future<void> pumpAt(WidgetTester tester, Size size, Widget child) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: child));
    await tester.pump(const Duration(milliseconds: 300));
  }

  sizes.forEach((name, size) {
    testWidgets('Bodenfeuchte-Detail rendert ohne Overflow · $name',
        (tester) async {
      await pumpAt(tester, size, SoilDetailScreen(data: demoSoilMoisture()));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Bewässerung-Detail rendert ohne Overflow · $name',
        (tester) async {
      await pumpAt(
          tester, size, IrrigationDetailScreen(controller: demoIrrigation()));
      expect(tester.takeException(), isNull);
    });
  });
}
