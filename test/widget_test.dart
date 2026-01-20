// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:physical_visual_tester/main.dart';

void main() {
  testWidgets('App shows spike navigation', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    if (Platform.isWindows) {
      expect(find.text('Live Screen'), findsOneWidget);
      expect(find.text('Start Active Mode'), findsOneWidget);
    } else {
      expect(find.text('Physical Visual Tester'), findsOneWidget);
      expect(find.text('PVT Controls'), findsOneWidget);
      expect(find.text('Vision Spike (Camera + OCR)'), findsOneWidget);
      expect(find.text('Decision Spike (Ollama JSON)'), findsOneWidget);
      expect(find.text('HID Spike (Bluetooth Keyboard)'), findsOneWidget);
    }
  });
}
