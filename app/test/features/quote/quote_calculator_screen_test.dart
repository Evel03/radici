import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/features/quote/presentation/quote_calculator_screen.dart';

import '../../support/pump_app.dart';

const _nbsp = ' ';

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<IconButton>(find.byKey(ValueKey(key))).onPressed != null;

Future<void> _tap(WidgetTester tester, String key, {int times = 1}) async {
  for (var i = 0; i < times; i++) {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }
}

void main() {
  // Pantalla de teléfono (dp) para que todo el desglose entre sin scroll.
  const phone = Size(400, 1000);

  testWidgets('con la entrada por defecto muestra el desglose del vector 1', (
    tester,
  ) async {
    setSurfaceSize(tester, phone);
    await pumpLocalized(tester, const QuoteCalculatorScreen());

    expect(_textOf(tester, 'quote-adults-value'), '2');
    expect(_textOf(tester, 'quote-kids-value'), '2');
    expect(_textOf(tester, 'quote-days-value'), '5');
    expect(_textOf(tester, 'quote-portions'), '20');
    expect(_textOf(tester, 'quote-recipes'), '3');
    expect(_textOf(tester, 'quote-cook-minutes'), '180 min');
    expect(_textOf(tester, 'quote-service'), '78,00$_nbsp€');
    expect(_textOf(tester, 'quote-groceries'), '63,00$_nbsp€');
    expect(_textOf(tester, 'quote-hold'), '150,45$_nbsp€');
    expect(_textOf(tester, 'quote-total'), '141,00$_nbsp€');
  });

  testWidgets('tocar + en adultos actualiza el total', (tester) async {
    setSurfaceSize(tester, phone);
    await pumpLocalized(tester, const QuoteCalculatorScreen());

    await _tap(tester, 'quote-adults-increment');

    // 3 ad · 2 niños · 5 días · cena: servicio 78 € + spesa 82 €.
    expect(_textOf(tester, 'quote-adults-value'), '3');
    expect(_textOf(tester, 'quote-portions'), '25');
    expect(_textOf(tester, 'quote-total'), '160,00$_nbsp€');
  });

  testWidgets('elegir pranzo e cena duplica las comidas', (tester) async {
    setSurfaceSize(tester, phone);
    await pumpLocalized(tester, const QuoteCalculatorScreen());

    await tester.tap(find.byKey(const ValueKey('quote-meal-lunchAndDinner')));
    await tester.pumpAndSettle();

    // Vector 6.
    expect(_textOf(tester, 'quote-portions'), '40');
    expect(_textOf(tester, 'quote-total'), '237,00$_nbsp€');
  });

  testWidgets('los botones se deshabilitan en los límites', (tester) async {
    setSurfaceSize(tester, phone);
    await pumpLocalized(tester, const QuoteCalculatorScreen());

    // Días: 5 → 7 (máximo).
    expect(_enabled(tester, 'quote-days-increment'), isTrue);
    await _tap(tester, 'quote-days-increment', times: 2);
    expect(_textOf(tester, 'quote-days-value'), '7');
    expect(_enabled(tester, 'quote-days-increment'), isFalse);

    // Días: 7 → 1 (mínimo).
    await _tap(tester, 'quote-days-decrement', times: 6);
    expect(_textOf(tester, 'quote-days-value'), '1');
    expect(_enabled(tester, 'quote-days-decrement'), isFalse);
    expect(_enabled(tester, 'quote-days-increment'), isTrue);

    // Niños: 2 → 0.
    await _tap(tester, 'quote-kids-decrement', times: 2);
    expect(_enabled(tester, 'quote-kids-decrement'), isFalse);

    // Adultos: 2 → 1. Con 0 niños no se puede bajar a 0 personas.
    await _tap(tester, 'quote-adults-decrement');
    expect(_textOf(tester, 'quote-adults-value'), '1');
    expect(_enabled(tester, 'quote-adults-decrement'), isFalse);

    // Adultos hasta 30 (máximo).
    await _tap(tester, 'quote-adults-increment', times: 29);
    expect(_textOf(tester, 'quote-adults-value'), '30');
    expect(_enabled(tester, 'quote-adults-increment'), isFalse);
  });

  testWidgets('cumple las pautas de accesibilidad básicas', (tester) async {
    setSurfaceSize(tester, phone);
    final handle = tester.ensureSemantics();
    await pumpLocalized(tester, const QuoteCalculatorScreen());

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    // Los botones + y − se anuncian con el nombre del contador.
    expect(find.byTooltip('Adulti: aumenta'), findsOneWidget);
    expect(find.byTooltip('Giorni: diminuisci'), findsOneWidget);
    handle.dispose();
  });

  for (final locale in ['it', 'es', 'en']) {
    testWidgets('entra en un teléfono angosto sin desbordes ($locale)', (
      tester,
    ) async {
      setSurfaceSize(tester, const Size(320, 640));
      await pumpLocalized(
        tester,
        const QuoteCalculatorScreen(),
        locale: Locale(locale),
      );
      // Un overflow de layout haría fallar el test con una excepción.
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('quote-meal-plan')), findsOneWidget);
    });
  }
}
