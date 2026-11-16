// Ficha de la sesión (/sessioni/:id) en la app: el día y las horas salidas de
// la sesión, «Settimana k di N» sin contar las canceladas, «Come arrivare»
// (Apple Maps en el iPhone, Google Maps en el resto), WhatsApp en el idioma de
// la clienta, las alergias resaltadas (la nota del pedido y, con gluten, la de
// contaminación cruzada), las semanas de la reserva, y cancelar con
// confirmación, motivo y «anche le successive», con cada falla explicada
// (también un 409 hasPayments, que ofrece pasarla al final de la reserva).
// Mover y cancelar quedan abajo: en el tercio inferior a 375×667.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/application/session_links.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/sessions/presentation/move_session_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/session_fixtures.dart';

void main() {
  Finder byKey(String key) => find.byKey(ValueKey(key));

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(byKey(key)).data!;

  /// Desplaza la ficha hasta que [finder] se construya y se vea (la lista
  /// construye solo lo que está cerca de la pantalla).
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      // El de la lista (el primero): los textos seleccionables tienen el suyo.
      scrollable: find
          .descendant(
            of: byKey('session-detail'),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  /// La ficha de la semana [n] de una reserva de 4 (25/11, 2/12, 9/12 y 16/12).
  Future<ChefApp> openSession(
    WidgetTester tester, {
    int n = 2,
    FakeSessionsRepository? sessions,
    Size size = const Size(400, 900),
    Locale locale = const Locale('it', 'IT'),
    bool appleMaps = false,
  }) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      sessions: sessions ?? FakeSessionsRepository(buildBooking()),
      location: '/sessioni/${sessionId(n)}',
      size: size,
      deviceLocales: [locale],
      overrides: [appleMapsProvider.overrideWithValue(appleMaps)],
    );
    expect(find.byType(CookingSessionScreen), findsOneWidget);
    return app;
  }

  testWidgets('el día, «Settimana k di N» y las horas que salen de la sesión', (
    tester,
  ) async {
    await openSession(tester);

    expect(find.widgetWithText(AppBar, 'Giulia Rossi'), findsOneWidget);
    expect(textOf(tester, 'session-date'), 'mercoledì 2 dicembre 2026');
    expect(textOf(tester, 'session-week'), 'Settimana 2 di 4');
    expect(
      textOf(tester, 'session-times'),
      'Spesa dalle 09:15 · Arrivo 10:00 · fino alle 13:00',
    );
    // Confirmada: sin etiqueta de estado.
    expect(byKey('session-status'), findsNothing);
    await reveal(tester, byKey('session-request-notes'));
    expect(
      tester.widget<SelectableText>(byKey('session-address')).data,
      'Via Gombito 12, 24129 Bergamo',
    );
    expect(textOf(tester, 'session-kitchen-notes'), 'Forno a gas');
    expect(textOf(tester, 'session-request-notes'), 'Citofono: Rossi');
    expect(
      textOf(tester, 'session-request'),
      'Settimana di pasti · 4 settimane · 4 persone · 5 giorni · Cena',
    );
  });

  testWidgets(
    '«Settimana k di N» no cuenta las canceladas, y la lista de semanas las muestra',
    (tester) async {
      await openSession(
        tester,
        n: 3,
        sessions: FakeSessionsRepository(
          buildBooking(statuses: {2: SessionStatus.cancelled}),
        ),
      );

      expect(textOf(tester, 'session-week'), 'Settimana 2 di 3');
      final week2 = byKey('session-week-${sessionId(2)}');
      await reveal(tester, byKey('session-week-${sessionId(4)}'));
      expect(
        find.descendant(of: week2, matching: find.text('mer 2 dic')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: week2, matching: find.text('10:00 · Annullata')),
        findsOneWidget,
      );
      expect(
        tester.widget<ListTile>(byKey('session-week-${sessionId(3)}')).selected,
        isTrue,
      );

      // Otra semana abre su ficha en lugar de esta.
      await tester.tap(byKey('session-week-${sessionId(4)}'));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'session-week'), 'Settimana 3 di 3');
      expect(textOf(tester, 'session-date'), 'mercoledì 16 dicembre 2026');
    },
  );

  testWidgets(
    '«Come arrivare» abre la dirección en Google Maps; en el iPhone, en Apple Maps',
    (tester) async {
      final app = await openSession(tester);
      await tester.tap(byKey('session-directions'));
      await tester.pumpAndSettle();
      expect(
        app.launcher.launched.single.toString(),
        'https://www.google.com/maps/dir/?api=1&destination=Via%20Gombito%2012%2C%2024129%20Bergamo',
      );
    },
  );

  testWidgets('en el iPhone «Come arrivare» va a Apple Maps', (tester) async {
    final app = await openSession(tester, appleMaps: true);
    await tester.tap(byKey('session-directions'));
    await tester.pumpAndSettle();
    expect(
      app.launcher.launched.single.toString(),
      'https://maps.apple.com/?daddr=Via%20Gombito%2012%2C%2024129%20Bergamo',
    );
  });

  testWidgets(
    'sin dirección en la ficha, «Come arrivare» queda deshabilitado y lo dice',
    (tester) async {
      final booking = [
        for (final session in buildBooking())
          session.copyWith(client: session.client.copyWith(address: null)),
      ];
      await openSession(tester, sessions: FakeSessionsRepository(booking));
      expect(
        tester.widget<ButtonStyleButton>(byKey('session-directions')).onPressed,
        isNull,
      );
      expect(
        textOf(tester, 'session-no-address'),
        'Nessun indirizzo nella scheda: chiedilo alla cliente.',
      );
    },
  );

  testWidgets(
    'WhatsApp en el idioma de la clienta, con la fecha y la hora (sin dirección ni alergias)',
    (tester) async {
      final app = await openSession(
        tester,
        sessions: FakeSessionsRepository(
          buildBooking(
            locale: ClientLocale.es,
            restrictions: const RequestRestrictions(note: 'Celiaca'),
          ),
        ),
      );
      await tester.tap(byKey('session-whatsapp'));
      await tester.pumpAndSettle();

      final uri = app.launcher.launched.single;
      expect(uri.host, 'wa.me');
      expect(uri.path, '/393331234567');
      final text = uri.queryParameters['text']!;
      expect(
        text,
        'Hola Giulia, soy Evelyn de Radici. Te escribo por la sesión del '
        'miércoles 2 de diciembre, con llegada a las 10:00.',
      );
      expect(text, isNot(contains('Gombito')));
      expect(text, isNot(contains('Celiaca')));

      await tester.tap(byKey('session-call'));
      await tester.pumpAndSettle();
      expect(app.launcher.launched.last.toString(), 'tel:+393331234567');
    },
  );

  testWidgets(
    'las alergias resaltadas: la nota del pedido y, con gluten, la contaminación cruzada',
    (tester) async {
      await openSession(
        tester,
        sessions: FakeSessionsRepository(
          buildBooking(
            clientAllergens: const [Allergen.gluten],
            restrictions: const RequestRestrictions(
              allergens: [Allergen.milk],
              note: 'Il bambino è celiaco: anche le tracce',
            ),
          ),
        ),
      );

      expect(
        find.descendant(
          of: byKey('session-allergens'),
          matching: find.text('Glutine'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: byKey('session-allergens'),
          matching: find.text('Latte e derivati'),
        ),
        findsOneWidget,
      );
      expect(find.text('Nota della richiesta'), findsOneWidget);
      expect(
        textOf(tester, 'session-allergy-note'),
        'Il bambino è celiaco: anche le tracce',
      );
      expect(byKey('session-cross-contamination'), findsOneWidget);
    },
  );

  testWidgets(
    'sin alergias: «nadie tiene» si lo confirmó; si no, que pregunte',
    (tester) async {
      await openSession(tester);
      expect(byKey('session-allergies-unknown'), findsOneWidget);
      expect(byKey('session-cross-contamination'), findsNothing);
    },
  );

  testWidgets('una cancelada dice el motivo y no ofrece mover ni cancelar', (
    tester,
  ) async {
    final booking = buildBooking();
    booking[1] = booking[1].copyWith(
      status: SessionStatus.cancelled,
      cancelReason: 'client_cancelled',
    );
    await openSession(tester, sessions: FakeSessionsRepository(booking));
    expect(
      textOf(tester, 'session-status'),
      "Annullata · L'ha chiesto la cliente",
    );
    expect(byKey('session-week'), findsNothing);
    expect(byKey('session-move'), findsNothing);
    expect(byKey('session-cancel'), findsNothing);
  });

  testWidgets(
    'una cocinada no se mueve ni se cancela; una con la compra hecha se cancela pero no se mueve',
    (tester) async {
      await openSession(
        tester,
        n: 1,
        sessions: FakeSessionsRepository(
          buildBooking(
            statuses: {1: SessionStatus.cooked, 2: SessionStatus.shoppingDone},
          ),
        ),
      );
      expect(textOf(tester, 'session-status'), 'Cucinata');
      expect(byKey('session-move'), findsNothing);
      expect(byKey('session-cancel'), findsNothing);

      final week2 = byKey('session-week-${sessionId(2)}');
      await reveal(tester, week2);
      await tester.tap(week2);
      await tester.pumpAndSettle();
      expect(textOf(tester, 'session-status'), 'Spesa fatta');
      expect(byKey('session-move'), findsNothing);
      expect(byKey('session-cancel'), findsOneWidget);
    },
  );

  testWidgets('si no se pudo leer, «Riprova»', (tester) async {
    final sessions = FakeSessionsRepository(buildBooking())
      ..fetchFailure = const SessionFailure(SessionFailureKind.unavailable);
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      sessions: sessions,
      location: '/sessioni/${sessionId(2)}',
    );
    expect(
      find.text(
        'Impossibile caricare la sessione. Controlla la connessione e riprova.',
      ),
      findsOneWidget,
    );
    sessions.fetchFailure = null;
    await tester.tap(byKey('load-error-retry'));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'session-week'), 'Settimana 2 di 4');
  });

  testWidgets('una que no existe lo dice', (tester) async {
    await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      sessions: FakeSessionsRepository(buildBooking()),
      location: '/sessioni/nope',
    );
    expect(byKey('session-not-found'), findsOneWidget);
    expect(byKey('session-move'), findsNothing);
  });

  group('cancelar', () {
    testWidgets(
      'con confirmación, motivo y «anche le successive»: canceladas y el aviso',
      (tester) async {
        final app = await openSession(tester);
        await tester.tap(byKey('session-cancel'));
        await tester.pumpAndSettle();

        expect(byKey('cancel-session-dialog'), findsOneWidget);
        expect(
          find.text('Annullare la sessione di mer 2 dic?'),
          findsOneWidget,
        );
        // El motivo por defecto es el neutro.
        expect(find.text('Altro motivo'), findsOneWidget);
        expect(find.text('Annulla la sessione'), findsOneWidget);
        await tester.tap(byKey('cancel-reason-client_cancelled'));
        await tester.tap(byKey('cancel-session-following'));
        await tester.pumpAndSettle();
        expect(find.text('Annulla anche le 2 successive'), findsOneWidget);
        expect(find.text('Annulla 3 sessioni'), findsOneWidget);

        await tester.tap(byKey('cancel-session-confirm'));
        await tester.pumpAndSettle();

        final call = app.sessions.cancelCalls.single;
        expect(call.sessionIds, [sessionId(2), sessionId(3), sessionId(4)]);
        expect(call.reason, CancelReason.clientCancelled);
        expect(call.allowWithPayments, isFalse);
        expect(
          find.text(
            '3 sessioni annullate: in 1 o 2 minuti il sito torna a offrire quei giorni.',
          ),
          findsOneWidget,
        );
        expect(
          textOf(tester, 'session-status'),
          "Annullata · L'ha chiesto la cliente",
        );
        expect(byKey('session-cancel'), findsNothing);
      },
    );

    testWidgets('«Indietro» no cancela nada', (tester) async {
      final app = await openSession(tester);
      await tester.tap(byKey('session-cancel'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('cancel-session-keep'));
      await tester.pumpAndSettle();
      expect(app.sessions.cancelCalls, isEmpty);
      expect(byKey('session-cancel'), findsOneWidget);
    });

    testWidgets(
      'una semana cobrada (409 hasPayments): no se canceló nada y ofrece pasarla al final',
      (tester) async {
        final sessions = FakeSessionsRepository(buildBooking())
          ..paid.add(sessionId(2));
        final app = await openSession(tester, sessions: sessions);
        await tester.tap(byKey('session-cancel'));
        await tester.pumpAndSettle();
        await tester.tap(byKey('cancel-session-confirm'));
        await tester.pumpAndSettle();

        expect(byKey('has-payments-dialog'), findsOneWidget);
        expect(find.text('Settimana già pagata'), findsOneWidget);
        expect(
          find.textContaining(
            'Questa settimana è già pagata: non è stato annullato niente.',
          ),
          findsOneWidget,
        );
        expect(
          sessions.sessions[sessionId(2)]!.status,
          SessionStatus.confirmed,
        );

        await tester.tap(byKey('has-payments-move-to-end'));
        await tester.pumpAndSettle();
        // La hoja «Sposta» con la semana después de la última (16/12 + 7).
        expect(find.byType(MoveSessionScreen), findsOneWidget);
        expect(find.text('mercoledì 23 dicembre 2026'), findsOneWidget);
        expect(app.sessions.checks.last.date, CalendarDate(2026, 12, 23));
        await tester.tap(byKey('move-confirm'));
        await tester.pumpAndSettle();
        expect(find.byType(CookingSessionScreen), findsOneWidget);
        expect(textOf(tester, 'session-date'), 'mercoledì 23 dicembre 2026');
        expect(textOf(tester, 'session-week'), 'Settimana 4 di 4');
      },
    );

    testWidgets(
      'si otra ya está cocinada (otro dispositivo), lo dice y la ficha se actualiza',
      (tester) async {
        final sessions = FakeSessionsRepository(buildBooking());
        await openSession(tester, sessions: sessions);
        sessions.sessions[sessionId(2)] = sessions.sessions[sessionId(2)]!
            .copyWith(status: SessionStatus.cooked);

        await tester.tap(byKey('session-cancel'));
        await tester.pumpAndSettle();
        await tester.tap(byKey('cancel-session-confirm'));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Una delle sessioni è già cucinata o pagata: non ne è stata annullata nessuna.',
          ),
          findsOneWidget,
        );
        expect(textOf(tester, 'session-status'), 'Cucinata');
        expect(byKey('session-cancel'), findsNothing);
      },
    );

    testWidgets('sin conexión: el aviso con «Riprova», que la cancela', (
      tester,
    ) async {
      final sessions = FakeSessionsRepository(buildBooking())
        ..cancelFailure = const SessionFailure(SessionFailureKind.unavailable);
      await openSession(tester, sessions: sessions);
      await tester.tap(byKey('session-cancel'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('cancel-session-confirm'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Non è stato possibile annullarla.'),
        findsOneWidget,
      );
      expect(byKey('session-cancel'), findsOneWidget);
      sessions.cancelFailure = null;
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Riprova'),
        ),
      );
      await tester.pumpAndSettle();
      expect(sessions.cancelCalls, hasLength(2));
      expect(textOf(tester, 'session-status'), 'Annullata · Altro motivo');
    });
  });

  group('teléfono', () {
    testWidgets(
      'a 375×667, Sposta y Annulla quedan abajo, en el tercio inferior',
      (tester) async {
        await openSession(tester, size: const Size(375, 667));
        for (final key in ['session-move', 'session-cancel']) {
          final rect = tester.getRect(byKey(key));
          expect(rect.center.dy, greaterThan(667 * 2 / 3), reason: key);
          expect(rect.height, greaterThanOrEqualTo(48), reason: key);
        }
        expect(
          tester.getSize(byKey('session-directions')).height,
          greaterThanOrEqualTo(48),
        );
      },
    );

    for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
      testWidgets('a 375×667 sin desbordes (${locale.languageCode})', (
        tester,
      ) async {
        await openSession(
          tester,
          size: const Size(375, 667),
          locale: locale,
          sessions: FakeSessionsRepository(
            buildBooking(
              clientAllergens: const [Allergen.gluten, Allergen.milk],
              restrictions: const RequestRestrictions(
                diets: [Diet.vegetarian],
                note: 'Niente funghi, il bambino è celiaco',
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.drag(byKey('session-detail'), const Offset(0, -2000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(byKey('session-cancel'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
