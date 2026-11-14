// El logotipo en texto: nombre y rótulo de los ARB, un solo nodo para los
// lectores de pantalla y las proporciones del manual (el rótulo, cerca del
// 79 % del filete), medidas con la fuente de verdad (Cinzel empaquetada).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/brand.dart';
import 'package:radici/core/radici_logo.dart';

import '../support/pump_app.dart';

void main() {
  setUpAll(() async {
    // En los tests las fuentes del pubspec no se cargan solas.
    final cinzel = FontLoader(brandDisplayFont)
      ..addFont(rootBundle.load(brandMarkFontAsset));
    await cinzel.load();
  });

  testWidgets('nombre y rótulo, y un solo nodo para lectores de pantalla', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpLocalized(
      tester,
      const Scaffold(body: Center(child: RadiciLogo())),
    );

    expect(find.text('Radici'), findsOneWidget);
    expect(find.text('CUCINA PRIVATA'), findsOneWidget);
    expect(find.bySemanticsLabel('Radici, Cucina privata'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('el rótulo es más angosto que el filete, como en el manual', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const Scaffold(body: Center(child: RadiciLogo(size: 40))),
    );
    final rule = tester.getSize(find.byKey(const ValueKey('logo-rule'))).width;
    final name = tester.getSize(find.byKey(const ValueKey('logo-name'))).width;
    final tagline = tester
        .getSize(find.byKey(const ValueKey('logo-tagline')))
        .width;
    // Sin el espaciado que Flutter deja después de la última letra.
    const tagSpacing = 40 * 0.27 * 0.26;
    final ratio = (tagline - tagSpacing) / rule;
    expect(
      ratio,
      inInclusiveRange(0.72, 0.86),
      reason: 'rótulo / filete = $ratio',
    );
    // El filete sobresale apenas del nombre (un 12 % del cuerpo a cada lado).
    expect(rule - name, closeTo(40 * 0.12 * 2 + 40 * 0.07, 0.01));
  });

  testWidgets('no se engrosa con el texto en negrita del sistema', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const MediaQuery(
        data: MediaQueryData(boldText: true),
        child: Scaffold(body: Center(child: RadiciLogo())),
      ),
    );
    for (final key in ['logo-name', 'logo-tagline']) {
      final text = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(RichText),
        ),
      );
      expect(text.text.style?.fontWeight, FontWeight.w500, reason: key);
    }
  });

  testWidgets('no crece con el tamaño de letra del sistema', (tester) async {
    await pumpLocalized(
      tester,
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Scaffold(body: Center(child: RadiciLogo(size: 40))),
      ),
    );
    final scaled = tester
        .getSize(find.byKey(const ValueKey('logo-rule')))
        .width;
    await pumpLocalized(
      tester,
      const Scaffold(body: Center(child: RadiciLogo(size: 40))),
    );
    final normal = tester
        .getSize(find.byKey(const ValueKey('logo-rule')))
        .width;
    expect(scaled, normal);
  });
}
