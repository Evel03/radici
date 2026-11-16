import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/quote/presentation/quote_calculator_screen.dart';

import '../../support/pump_app.dart';

/// Espacio duro: el formato de moneda lo pone entre el importe y el €.
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
  const phone = Size(400, 1100);

  testWidgets('con la entrada por defecto muestra el precio por semana del vector 1', (
    tester,
  ) async {
    setSurfaceSize(tester, phone);
    await pumpLocalized(tester, const QuoteCalculatorScreen());

    expect(_textOf(tester, 'quote-adults-value'), '2');
    expect(_textOf(tester, 'quote-kids-value'), '2');
    expect(_textOf(tester, 'quote-days-value'), '5');
    expect(_textOf(tester, 'quote-weeks-value'), '1');
    expect(_textOf(tester, 'quote-portions'), '20');
    expect(_textOf(tester, 'quote-recipes'), '3');
    expect(_textOf(tester, 'quote-groceries'), '63,00$_nbsp€');
    expect(_textOf(tester, 'quote-total'), '150,00$_nbsp€');
    expect(find.text('Prezzo del servizio'), findsOneWidget);
    // Con una semana no se repite el precio por semana, ni hay ahorro.
    expect(find.byKey(const ValueKey('quote-weekly')), findsNothing);
    expect(find.byKey(const ValueKey('quote-savings')), findsNothing);
    // El pago se acuerda con Evelyn: ya no se muestra una retención en la tarjeta.
    expect(find.byKey(const ValueKey('quote-hold')), findsNothing);
    expect(
      _textOf(tester, 'quote-footnote'),
      contains('fino a 5 persone'),
    );
    expect(_textOf(tester, 'quote-footnote'), contains('140,00$_nbsp€'));
  });

  testWidgets('no muestra el tiempo de cocina, como la web', (tester) async {
    setSurfaceSize(tester, phone);
    await pumpLocalized(tester, const QuoteCalculatorScreen());

    // Vector 1: 180 min de cocina. El motor los usa para los horarios, pero el
    // cliente no los ve (sí Evelyn, en el detalle del pedido).
    expect(find.text('Tempo in cucina'), findsNothing);
    expect(find.text('180 min'), findsNothing);
    expect(find.byKey(const ValueKey('quote-cook-minutes')), findsNothing);
  });

  testWidgets('4 semanas: el total, el precio por semana con descuento y el ahorro', (
    tester,
  ) async {
    setSurfaceSize(tester, phone);
    await pumpLocalized(tester, const QuoteCalculatorScreen());

    await _tap(tester, 'quote-weeks-increment', times: 3);

    expect(_textOf(tester, 'quote-weeks-value'), '4');
    expect(find.text('Prezzo per 4 settimane'), findsOneWidget);
    expect(_textOf(tester, 'quote-total'), '560,00$_nbsp€');
    expect(_textOf(tester, 'quote-weekly'), '140,00$_nbsp€');
    expect(_textOf(tester, 'quote-savings'), '40,00$_nbsp€');
    // La compra sigue siendo de una semana.
    expect(_textOf(tester, 'quote-groceries'), '63,00$_nbsp€');
  });

  testWidgets('los días y las comidas no cambian el servicio, sí la compra', (
    tester,
  ) async {
    setSurfaceSize(tester, phone);
    await pumpLocalized(tester, const QuoteCalculatorScreen());

    await tester.tap(find.byKey(const ValueKey('quote-meal-lunchAndDinner')));
    await tester.pumpAndSettle();

    // Como el vector 12, con una semana.
    expect(_textOf(tester, 'quote-portions'), '40');
    expect(_textOf(tester, 'quote-groceries'), '126,00$_nbsp€');
    expect(_textOf(tester, 'quote-total'), '150,00$_nbsp€');
  });

  testWidgets('con 6 personas el precio lo prepara Evelyn', (tester) async {
    setSurfaceSize(tester, phone);
    await pumpLocalized(tester, const QuoteCalculatorScreen());

    await _tap(tester, 'quote-adults-increment');
    // 3 adultos y 2 niños: todavía con precio.
    expect(_textOf(tester, 'quote-total'), '150,00$_nbsp€');
    expect(_textOf(tester, 'quote-groceries'), '82,00$_nbsp€');

    await _tap(tester, 'quote-kids-increment');
    expect(find.byKey(const ValueKey('quote-total')), findsNothing);
    expect(
      _textOf(tester, 'quote-no-auto-price'),
      'Per più di 5 persone il prezzo del servizio te lo prepara Evelyn.',
    );
    // La compra estimada se sigue viendo.
    expect(_textOf(tester, 'quote-groceries'), '94,50$_nbsp€');
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

    // Semanas: de 1 (mínimo) a 8 (máximo).
    expect(_enabled(tester, 'quote-weeks-decrement'), isFalse);
    await _tap(tester, 'quote-weeks-increment', times: 7);
    expect(_textOf(tester, 'quote-weeks-value'), '8');
    expect(_enabled(tester, 'quote-weeks-increment'), isFalse);

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
    expect(find.byTooltip('Giorni a settimana: diminuisci'), findsOneWidget);
    expect(find.byTooltip('Settimane: aumenta'), findsOneWidget);
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
