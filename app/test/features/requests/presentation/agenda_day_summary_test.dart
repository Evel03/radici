// El cartel de un día del mes de la agenda: con el mouse encima (después de
// un momento) o apretando la celda un rato, el resumen de sus sesiones y de
// los pedidos que lo preferían, debajo de la celda (arriba si abajo no entra)
// sin taparla. Se cierra al salir, solo unos segundos después de soltar o al
// tocar otra cosa; no atrapa el mouse, pero sí el dedo (tocarlo lo cierra sin
// tocar lo que tapa), y tocar la celda la sigue eligiendo. Nada de alergias,
// dirección, teléfono ni notas; el lector de pantalla lo lee en la celda; en
// el tema oscuro, con sus colores. "Hoy": lunes 19/10/2026 (testNow). La
// reserva de prueba: miércoles 21/10, 28/10, 4/11 y 11/11, con un pedido
// nuevo el 21/10.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/theme.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/agenda_day_summary_tooltip.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/plain_text.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  final wednesday = CalendarDate(2026, 10, 21);

  Finder byKey(String key) => find.byKey(ValueKey(key));
  Finder day(String iso) => byKey('agenda-day-$iso');
  Finder summaryOf(String iso) => byKey('agenda-day-summary-$iso');

  /// Cualquier cartel abierto.
  final anySummary = find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        RegExp(r'^agenda-day-summary-\d{4}-\d{2}-\d{2}$')
            .hasMatch((widget.key! as ValueKey<String>).value),
    description: 'un cartel de la agenda',
  );

  /// La reserva, con las alergias como llegan de la web (en la nota del
  /// pedido) y gluten en la ficha, que tiene la dirección, el teléfono y las
  /// notas de la cocina.
  List<CookingSession> booking() => buildBooking(
    first: wednesday,
    restrictions: webRestrictions,
    clientAllergens: const [Allergen.gluten],
  );

  /// La reserva aceptada (con su fecha preferida, el 21/10) y un pedido nuevo
  /// el mismo día.
  FakeChefRequestsRepository sampleRequests() => FakeChefRequestsRepository([
    buildRequest(
      id: bookingRequestId,
      name: 'Giulia Rossi',
      preferredDate: wednesday,
      status: RequestStatus.accepted,
      weeks: 4,
    ),
    buildRequest(id: 'nuovo', name: 'Marco Bianchi', preferredDate: wednesday),
  ]);

  Future<ChefApp> openAgenda(
    WidgetTester tester, {
    FakeSessionsRepository? sessions,
    FakeChefRequestsRepository? requests,
    Size size = const Size(400, 900),
  }) async {
    final app = await pumpChefApp(
      tester,
      requests: requests ?? sampleRequests(),
      sessions: sessions ?? FakeSessionsRepository(booking()),
      location: '/agenda',
      size: size,
    );
    expect(find.byType(AgendaScreen), findsOneWidget);
    return app;
  }

  /// Un mouse, todavía sobre la barra de arriba (sin cartel).
  Future<TestGesture> mouse(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    return gesture;
  }

  /// Deja el mouse sobre [cell] hasta que se abra su cartel.
  Future<void> hover(
    WidgetTester tester,
    TestGesture gesture,
    Finder cell,
  ) async {
    await gesture.moveTo(tester.getCenter(cell));
    await tester.pump(agendaSummaryHoverDelay);
    await tester.pumpAndSettle();
  }

  /// Los textos del cartel de [iso], en orden y con espacios comunes.
  List<String> texts(WidgetTester tester, String iso) => [
    for (final text in tester.widgetList<Text>(
      find.descendant(of: summaryOf(iso), matching: find.byType(Text)),
    ))
      plainSpaces(text.data ?? ''),
  ];

  /// El día elegido es [title] (el título de su tarjeta).
  void expectSelected(String title) {
    expect(find.text(title), findsOneWidget, reason: 'día elegido: $title');
  }

  const giulia21 =
      '10:00–13:00 · Settimana 1 di 4 · 4 persone · Confermata · Città Alta';

  testWidgets(
    'con el mouse encima, después de un momento, el resumen del día debajo de la celda, sin taparla ni elegirla; al salir se cierra',
    (tester) async {
      await openAgenda(tester);
      final gesture = await mouse(tester);

      await gesture.moveTo(tester.getCenter(day('2026-10-21')));
      await tester.pump(
        agendaSummaryHoverDelay - const Duration(milliseconds: 50),
      );
      expect(anySummary, findsNothing, reason: 'no se abre al pasar');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      final card = summaryOf('2026-10-21');
      expect(card, findsOneWidget);
      // Primero la sesión, después el pedido.
      expect(texts(tester, '2026-10-21'), [
        'Giulia Rossi',
        giulia21,
        'Marco Bianchi',
        'Settimana di pasti · Nuova',
      ]);
      final cell = tester.getRect(day('2026-10-21'));
      expect(tester.getRect(card).top, greaterThanOrEqualTo(cell.bottom));
      expectSelected('lunedì 19 ottobre 2026');

      await gesture.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(anySummary, findsNothing);
    },
  );

  testWidgets('un día sin sesiones ni pedidos no tiene cartel', (tester) async {
    await openAgenda(tester);
    final gesture = await mouse(tester);

    await hover(tester, gesture, day('2026-10-22'));
    expect(anySummary, findsNothing);
  });

  testWidgets(
    'el cartel no atrapa el mouse: al bajar a la celda de abajo, que tapa, se abre enseguida el de esa',
    (tester) async {
      await openAgenda(tester);
      final gesture = await mouse(tester);
      await hover(tester, gesture, day('2026-10-21'));
      expect(
        tester
            .getRect(summaryOf('2026-10-21'))
            .contains(tester.getCenter(day('2026-10-28'))),
        isTrue,
        reason: 'el cartel del 21 tapa la celda del 28',
      );

      await gesture.moveTo(tester.getCenter(day('2026-10-28')));
      await tester.pumpAndSettle();
      expect(summaryOf('2026-10-21'), findsNothing);
      expect(summaryOf('2026-10-28'), findsOneWidget);
      expect(texts(tester, '2026-10-28'), [
        'Giulia Rossi',
        '10:00–13:00 · Settimana 2 di 4 · 4 persone · Confermata · Città Alta',
      ]);
    },
  );

  testWidgets('si abajo no entra, va arriba de la celda, también sin taparla', (
    tester,
  ) async {
    // Lunes 26/10: la última semana de octubre, al pie de una pantalla baja
    // (y a la izquierda, lejos del botón flotante).
    await openAgenda(
      tester,
      size: const Size(400, 560),
      sessions: FakeSessionsRepository([
        ...booking(),
        buildSession(
          n: 9,
          requestId: 'lunedi',
          name: 'Sara Colombo',
          date: CalendarDate(2026, 10, 26),
          weeks: 1,
        ),
      ]),
    );
    final gesture = await mouse(tester);
    await hover(tester, gesture, day('2026-10-26'));

    final cell = tester.getRect(day('2026-10-26'));
    final card = tester.getRect(summaryOf('2026-10-26'));
    expect(card.bottom, lessThanOrEqualTo(cell.top));
  });

  testWidgets(
    'en el teléfono: apretar la celda un rato muestra el cartel sin elegir el día; se cierra solo o al tocar otra cosa, y tocarla la elige sin cartel',
    (tester) async {
      await openAgenda(tester);

      await tester.longPress(day('2026-10-21'));
      await tester.pumpAndSettle();
      expect(summaryOf('2026-10-21'), findsOneWidget);
      expect(texts(tester, '2026-10-21').take(2), ['Giulia Rossi', giulia21]);
      expectSelected('lunedì 19 ottobre 2026');

      // Queda lo necesario para leerlo y se cierra solo.
      await tester.pump(agendaSummaryTouchDelay - const Duration(seconds: 1));
      expect(summaryOf('2026-10-21'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(anySummary, findsNothing);

      // Tocar otro día lo cierra (y elige ese día).
      await tester.longPress(day('2026-10-21'));
      await tester.pumpAndSettle();
      expect(summaryOf('2026-10-21'), findsOneWidget);
      await tester.tap(day('2026-10-22'));
      await tester.pumpAndSettle();
      expect(anySummary, findsNothing);
      expectSelected('giovedì 22 ottobre 2026');

      // Un toque elige el día, como siempre, sin cartel.
      await tester.tap(day('2026-10-21'));
      await tester.pumpAndSettle();
      expectSelected('mercoledì 21 ottobre 2026');
      expect(anySummary, findsNothing);
    },
  );

  testWidgets(
    'en el teléfono, tocar el cartel lo cierra sin tocar lo que tapa: ni la celda de abajo ni «Blocca questo giorno»',
    (tester) async {
      final app = await openAgenda(tester);

      // El del 21 tapa la celda del 28: tocarlo ahí no elige el 28.
      await tester.longPress(day('2026-10-21'));
      await tester.pumpAndSettle();
      final below = tester.getCenter(day('2026-10-28'));
      expect(
        tester.getRect(summaryOf('2026-10-21')).contains(below),
        isTrue,
        reason: 'el cartel del 21 tapa la celda del 28',
      );
      await tester.tapAt(below);
      await tester.pumpAndSettle();
      expect(anySummary, findsNothing);
      expectSelected('lunedì 19 ottobre 2026');

      // El del 28 (la última fila) cae sobre la tarjeta del día elegido y tapa
      // parte de «Blocca questo giorno»: tocarlo ahí no bloquea el 19.
      await tester.longPress(day('2026-10-28'));
      await tester.pumpAndSettle();
      final covered = tester
          .getRect(summaryOf('2026-10-28'))
          .intersect(tester.getRect(byKey('availability-block-2026-10-19')));
      expect(
        covered.isEmpty,
        isFalse,
        reason: 'el cartel del 28 tapa parte de «Blocca questo giorno»',
      );
      await tester.tapAt(covered.center);
      await tester.pumpAndSettle();
      expect(anySummary, findsNothing);
      expect(app.availability.blockCalls, isEmpty);
      expectSelected('lunedì 19 ottobre 2026');
    },
  );

  testWidgets(
    'tocado con el dedo y después con el mouse encima, el cartel vuelve a no atrapar el mouse',
    (tester) async {
      await openAgenda(tester);
      await tester.longPress(day('2026-10-21'));
      await tester.pumpAndSettle();
      expect(summaryOf('2026-10-21'), findsOneWidget);

      final gesture = await mouse(tester);
      await hover(tester, gesture, day('2026-10-21'));
      await gesture.moveTo(tester.getCenter(day('2026-10-28')));
      await tester.pumpAndSettle();
      expect(summaryOf('2026-10-21'), findsNothing);
      expect(summaryOf('2026-10-28'), findsOneWidget);
    },
  );

  testWidgets('con más de 4: las sesiones primero y «e altre N»', (
    tester,
  ) async {
    final friday = CalendarDate(2026, 10, 23);
    await openAgenda(
      tester,
      sessions: FakeSessionsRepository([
        for (var n = 1; n <= 3; n++)
          buildSession(
            n: n,
            requestId: 'pedido-$n',
            name: 'Cliente $n',
            date: friday,
            start: ClockTime.hm(7 + 3 * n, 0),
            cookMinutes: 120,
            weeks: 1,
          ),
      ]),
      requests: FakeChefRequestsRepository([
        for (final id in ['a', 'b', 'c'])
          buildRequest(
            id: id,
            name: 'Richiedente $id',
            preferredDate: friday,
            preferredSlot: null,
          ),
      ]),
    );
    final gesture = await mouse(tester);

    await hover(tester, gesture, day('2026-10-23'));
    expect(texts(tester, '2026-10-23'), [
      'Cliente 1',
      '10:00–12:00 · 4 persone · Confermata · Città Alta',
      'Cliente 2',
      '13:00–15:00 · 4 persone · Confermata · Città Alta',
      'Cliente 3',
      '16:00–18:00 · 4 persone · Confermata · Città Alta',
      'Richiedente a',
      'Settimana di pasti · Nuova',
      'e altre 2',
    ]);
  });

  testWidgets(
    'el lector de pantalla lee el resumen en la celda, después de su etiqueta (que no cambia); el cartel abierto no agrega nada',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await openAgenda(tester);

      final data = tester.getSemantics(day('2026-10-21')).getSemanticsData();
      expect(
        data.label,
        matches(RegExp(r'21 ottobre 2026, 1 sessione, 1 richiesta$')),
      );
      expect(
        plainSpaces(data.hint),
        'Giulia Rossi, $giulia21; Marco Bianchi, Settimana di pasti · Nuova',
      );
      expect(
        tester.getSemantics(day('2026-10-22')).getSemanticsData().hint,
        isEmpty,
      );

      final gesture = await mouse(tester);
      await hover(tester, gesture, day('2026-10-21'));
      expect(summaryOf('2026-10-21'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Giulia|Marco')), findsNothing);
      semantics.dispose();
    },
  );

  testWidgets(
    'nada de alergias, dirección, teléfono, email ni notas: ni en el cartel ni en lo que lee el lector de pantalla',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await openAgenda(tester);
      final gesture = await mouse(tester);
      await hover(tester, gesture, day('2026-10-21'));

      final shown = [
        ...texts(tester, '2026-10-21'),
        plainSpaces(
          tester.getSemantics(day('2026-10-21')).getSemanticsData().hint,
        ),
      ].join('\n');
      expect(shown, contains('Giulia Rossi'));
      for (final hidden in [
        'Celiachia',
        'noci',
        'Glutine',
        'Via Gombito',
        '333',
        'example.test',
        'Citofono',
        'Forno a gas',
      ]) {
        expect(shown, isNot(contains(hidden)), reason: hidden);
      }
      semantics.dispose();
    },
  );

  testWidgets(
    'en el tema oscuro, el cartel va con los colores del tema, como las tarjetas',
    (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await openAgenda(tester);
      final gesture = await mouse(tester);
      await hover(tester, gesture, day('2026-10-21'));

      final dark = buildDarkTheme();
      expect(
        tester.widget<Material>(summaryOf('2026-10-21')).color,
        dark.cardTheme.color,
      );
      final name = tester.widget<Text>(
        find.descendant(
          of: summaryOf('2026-10-21'),
          matching: find.text('Giulia Rossi'),
        ),
      );
      expect(name.style?.color, dark.colorScheme.onSurface);
      final line = tester.widget<Text>(
        byKey('agenda-day-summary-session-${sessionId(1)}-line'),
      );
      expect(line.style?.color, dark.colorScheme.onSurfaceVariant);
    },
  );
}
