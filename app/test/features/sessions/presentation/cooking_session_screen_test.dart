// Ficha de la sesión (/sessioni/:id) en la app: el día y las horas salidas de
// la sesión, «Settimana k di N» sin contar las canceladas, «Come arrivare»
// (Apple Maps en el iPhone, Google Maps en el resto; sin dirección, «Aggiungi
// indirizzo» la guarda en la ficha), WhatsApp en el idioma de la clienta (con
// la cuenta de un colaborador, de parte de la cocinera: «con arrivo di Evelyn
// alle…», también en una sesión de hoy cuya llegada ya pasó; sin la hora de
// llegada en una sesión de un día que ya pasó en Roma o cancelada), las
// alergias resaltadas (la nota del pedido, también sola como llega de la web,
// y, con gluten, la de contaminación cruzada; si el pedido semanal de la
// reserva no responde, como en una renovación, las del último pedido semanal
// de la web que se reservó, con la fecha de ese pedido, nunca en una sesión
// extra; sin ningún dato, como en una reserva a mano, o con solo una
// dieta, la advertencia «Allergie: nessun dato nell'app, chiedile») en el
// orden en que las lee el lector de pantalla, las semanas de la
// reserva, «Rinnova» al final de la última sesión viva de una reserva
// semanal (con «Ha già un'altra sessione…» si la ficha ya tiene otra
// después), y cancelar con confirmación, motivo y «anche le successive», con
// cada falla explicada (un 409 hasPayments dice cuáles están cobradas y qué
// se puede hacer, también si llega al tocar «Riprova»). Mientras espera al
// servidor, Sposta y Annulla quedan deshabilitados. Mover y cancelar quedan
// abajo: en el tercio inferior a 375×667. Abierta con un enlace directo (sola
// en la pila), la flecha de volver lleva a la Agenda.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/router.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/sessions/application/session_links.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/sessions/presentation/move_session_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/plain_text.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';
import '../../../support/text_input_guard.dart';

void main() {
  Finder byKey(String key) => find.byKey(ValueKey(key));

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(byKey(key)).data!;

  VoidCallback? onPressedOf(WidgetTester tester, String key) =>
      tester.widget<ButtonStyleButton>(byKey(key)).onPressed;

  Finder snackBarAction(String label) =>
      find.descendant(of: find.byType(SnackBar), matching: find.text(label));

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
  /// [appleMaps] null: la regla de la plataforma, sin reemplazo. [accounts],
  /// la cuenta con que se entra (por defecto, la de Evelyn). [clock], "ahora"
  /// (por defecto, testNow: el 19/10/2026, antes de toda la reserva).
  Future<ChefApp> openSession(
    WidgetTester tester, {
    int n = 2,
    FakeSessionsRepository? sessions,
    FakeAccountRepository? accounts,
    Size size = const Size(400, 900),
    Locale locale = const Locale('it', 'IT'),
    bool? appleMaps = false,
    DateTime Function()? clock,
  }) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      sessions: sessions ?? FakeSessionsRepository(buildBooking()),
      accounts: accounts,
      location: '/sessioni/${sessionId(n)}',
      size: size,
      deviceLocales: [locale],
      clock: clock,
      overrides: [
        if (appleMaps != null) appleMapsProvider.overrideWithValue(appleMaps),
      ],
    );
    expect(find.byType(CookingSessionScreen), findsOneWidget);
    return app;
  }

  /// Cancela desde la ficha abierta, con «anche le successive» si
  /// [following].
  Future<void> cancelFromSheet(
    WidgetTester tester, {
    bool following = false,
  }) async {
    await tester.tap(byKey('session-cancel'));
    await tester.pumpAndSettle();
    if (following) {
      // En un teléfono queda debajo: el diálogo se desplaza.
      await tester.ensureVisible(byKey('cancel-session-following'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('cancel-session-following'));
      await tester.pumpAndSettle();
    }
    await tester.tap(byKey('cancel-session-confirm'));
    await tester.pumpAndSettle();
  }

  testWidgets('el día, «Settimana k di N» y las horas que salen de la sesión', (
    tester,
  ) async {
    await openSession(tester);

    expect(find.widgetWithText(AppBar, 'Giulia Rossi'), findsOneWidget);
    expect(textOf(tester, 'session-date'), 'mercoledì 2 dicembre 2026');
    expect(textOf(tester, 'session-week'), 'Settimana 2 di 4');
    expect(
      plainSpaces(textOf(tester, 'session-times')),
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

  // /gestione/#/sessioni/<id> pegado a mano (o un enlace futuro) deja la ficha
  // sola en la pila: sin nada debajo, no tenía cómo volver ni barra.
  group('abierta con un enlace directo', () {
    testWidgets('la flecha de volver lleva a la Agenda, con la barra', (
      tester,
    ) async {
      await openSession(tester);
      final back = byKey('session-back');
      expect(back.hitTestable(), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);

      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(byKey('chef-nav-bar').hitTestable(), findsOneWidget);
    });

    testWidgets(
      'también al cerrar con la X la hoja «Sposta» abierta con un enlace',
      (tester) async {
        await pumpChefApp(
          tester,
          requests: FakeChefRequestsRepository(const []),
          sessions: FakeSessionsRepository(buildBooking()),
          location: '/sessioni/${sessionId(2)}/sposta?data=2026-12-03',
        );
        expect(find.byType(MoveSessionScreen), findsOneWidget);
        await tester.tap(byKey('move-close'));
        await tester.pumpAndSettle();
        expect(find.byType(CookingSessionScreen), findsOneWidget);

        await tester.tap(byKey('session-back'));
        await tester.pumpAndSettle();
        expect(find.byType(AgendaScreen), findsOneWidget);
      },
    );
  });

  testWidgets(
    'abierta desde la Agenda, la flecha de siempre: vuelve al día elegido',
    (tester) async {
      await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        sessions: FakeSessionsRepository(
          buildBooking(first: CalendarDate(2026, 10, 21)),
        ),
        location: '/agenda',
        // Alto: el día y su sesión a la vista sin desplazar.
        size: const Size(400, 2000),
      );
      await tester.tap(byKey('agenda-day-2026-10-21'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('session-${sessionId(1)}'));
      await tester.pumpAndSettle();
      expect(find.byType(CookingSessionScreen), findsOneWidget);
      expect(byKey('session-back'), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(AgendaScreen), findsOneWidget);
      expect(find.text('mercoledì 21 ottobre 2026'), findsOneWidget);
    },
  );

  testWidgets('«Come arrivare» abre la dirección en Google Maps', (
    tester,
  ) async {
    final app = await openSession(tester);
    expect(tester.widget(byKey('session-directions')), isA<FilledButton>());
    await tester.tap(byKey('session-directions'));
    await tester.pumpAndSettle();
    expect(
      app.launcher.launched.single.toString(),
      'https://www.google.com/maps/dir/?api=1&destination=Via%20Gombito%2012%2C%2024129%20Bergamo',
    );
  });

  testWidgets(
    'en el iPhone (también /gestione/ en Safari) «Come arrivare» va a Apple Maps',
    (tester) async {
      // Sin reemplazar appleMapsProvider: la regla de la plataforma.
      final app = await openSession(tester, appleMaps: null);
      await tester.tap(byKey('session-directions'));
      await tester.pumpAndSettle();
      expect(
        app.launcher.launched.single.toString(),
        'https://maps.apple.com/?daddr=Via%20Gombito%2012%2C%2024129%20Bergamo',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
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
    'de un día que ya pasó en Roma, el WhatsApp nombra la sesión por su fecha, sin la hora de llegada',
    (tester) async {
      final app = await openSession(
        tester,
        // 00:30 del jueves 3/12/2026 en Roma (en UTC, todavía el 2/12): la
        // semana 2 fue ayer.
        clock: () => DateTime.utc(2026, 12, 2, 23, 30),
      );
      await tester.tap(byKey('session-whatsapp'));
      await tester.pumpAndSettle();

      expect(
        app.launcher.launched.single.queryParameters['text'],
        'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
        'mercoledì 2 dicembre.',
      );
    },
  );

  // Un colaborador lo manda desde su propio teléfono: el mensaje no dice
  // «sono Evelyn» ni que llega él.
  group('con la cuenta de un colaborador, el WhatsApp escribe de parte de la cocinera', () {
    FakeAccountRepository collaborator() => FakeAccountRepository(
      chefAccountData.copyWith(chef: chefAccount.copyWith(collaborator: true)),
    );

    testWidgets('en una sesión viva, con la fecha y «con arrivo di Evelyn…»', (
      tester,
    ) async {
      final app = await openSession(
        tester,
        accounts: collaborator(),
        sessions: FakeSessionsRepository(
          buildBooking(restrictions: webRestrictions),
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
        'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione di '
        'mercoledì 2 dicembre, con arrivo di Evelyn alle 10:00.',
      );
      expect(text, isNot(contains('Gombito')));
      expect(text, isNot(contains('Celiachia')));
    });

    // En una sesión de hoy que no está cancelada, cocinada ni cobrada, la hora
    // de llegada va aunque ya haya pasado (la regla mira el día, no la hora):
    // el mensaje describe el horario y no dice que Evelyn va a llegar.
    testWidgets(
      'en una sesión de hoy cuya llegada ya pasó, «con arrivo di Evelyn alle 10:00» y no «Evelyn arriva»',
      (tester) async {
        final app = await openSession(
          tester,
          accounts: collaborator(),
          // 12:00 del miércoles 2/12/2026 en Roma (hora de invierno, UTC+1):
          // la semana 2 es hoy y su llegada, a las 10:00, fue hace dos horas.
          clock: () => DateTime.utc(2026, 12, 2, 11),
        );
        await tester.tap(byKey('session-whatsapp'));
        await tester.pumpAndSettle();

        final text = app.launcher.launched.single.queryParameters['text']!;
        expect(
          text,
          'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione di '
          'mercoledì 2 dicembre, con arrivo di Evelyn alle 10:00.',
        );
        expect(text, isNot(contains('Evelyn arriva')));
      },
    );

    testWidgets(
      'en una cancelada, de parte de ella con la fecha, sin la hora de llegada',
      (tester) async {
        final app = await openSession(
          tester,
          accounts: collaborator(),
          sessions: FakeSessionsRepository(
            buildBooking(statuses: {2: SessionStatus.cancelled}),
          ),
        );
        expect(byKey('session-status'), findsOneWidget);
        await tester.tap(byKey('session-whatsapp'));
        await tester.pumpAndSettle();

        expect(
          app.launcher.launched.single.queryParameters['text'],
          'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione di '
          'mercoledì 2 dicembre.',
        );
      },
    );
  });

  group('sin dirección (las reservas que llegan por la web)', () {
    FakeSessionsRepository webBooking() => FakeSessionsRepository(
      buildBooking(address: null, restrictions: webRestrictions),
    );

    testWidgets(
      'WhatsApp pasa a ser el principal y en lugar de «Come arrivare» va «Aggiungi indirizzo»',
      (tester) async {
        await openSession(tester, sessions: webBooking());
        expect(byKey('session-directions'), findsNothing);
        expect(tester.widget(byKey('session-whatsapp')), isA<FilledButton>());
        expect(onPressedOf(tester, 'session-whatsapp'), isNotNull);
        expect(onPressedOf(tester, 'session-add-address'), isNotNull);
        expect(
          textOf(tester, 'session-no-address'),
          'Nessun indirizzo nella scheda: chiedilo alla cliente e aggiungilo.',
        );
      },
    );

    testWidgets(
      '«Aggiungi indirizzo» la guarda en la ficha y «Come arrivare» la abre',
      (tester) async {
        final app = await openSession(tester, sessions: webBooking());
        await tester.tap(byKey('session-add-address'));
        await tester.pumpAndSettle();

        expect(byKey('client-address-dialog'), findsOneWidget);
        // Letra de 16 px o más: con menos, iOS agranda la página.
        expectReadableInputs(tester);
        // Con el foco ya puesto: no le pide autocompletar al navegador
        // (Safari ofrecería la dirección de Evelyn).
        await expectNoBrowserAutofill(
          tester,
          byKey('client-address-field'),
          tap: false,
        );
        // Vacío no se guarda.
        expect(onPressedOf(tester, 'client-address-save'), isNull);
        await tester.enterText(
          byKey('client-address-field'),
          '  Via Pignolo 5,\n  Bergamo ',
        );
        await tester.pump();
        await tester.tap(byKey('client-address-save'));
        await tester.pumpAndSettle();

        // En una línea y sin espacios de más.
        expect(app.sessions.addressUpdates, [
          (testClientId, 'Via Pignolo 5, Bergamo'),
        ]);
        expect(byKey('client-address-dialog'), findsNothing);
        expect(find.text('Indirizzo salvato.'), findsOneWidget);
        expect(byKey('session-add-address'), findsNothing);
        expect(byKey('session-no-address'), findsNothing);
        expect(tester.widget(byKey('session-directions')), isA<FilledButton>());
        await tester.tap(byKey('session-directions'));
        await tester.pumpAndSettle();
        expect(
          app.launcher.launched.single.toString(),
          'https://www.google.com/maps/dir/?api=1&destination=Via%20Pignolo%205%2C%20Bergamo',
        );
      },
    );

    testWidgets(
      'si no se puede guardar, el diálogo queda abierto con lo escrito y se puede reintentar',
      (tester) async {
        final sessions = webBooking()
          ..addressFailure = const SessionFailure(
            SessionFailureKind.unavailable,
          );
        await openSession(tester, sessions: sessions);
        await tester.tap(byKey('session-add-address'));
        await tester.pumpAndSettle();
        await tester.enterText(byKey('client-address-field'), 'Via Pignolo 5');
        await tester.pump();
        await tester.tap(byKey('client-address-save'));
        await tester.pumpAndSettle();

        expect(byKey('client-address-dialog'), findsOneWidget);
        expect(
          textOf(tester, 'client-address-failed'),
          "Non è stato possibile salvare l'indirizzo. Controlla la connessione e riprova.",
        );
        expect(
          tester
              .widget<TextField>(byKey('client-address-field'))
              .controller!
              .text,
          'Via Pignolo 5',
        );

        sessions.addressFailure = null;
        await tester.tap(byKey('client-address-save'));
        await tester.pumpAndSettle();
        expect(byKey('client-address-dialog'), findsNothing);
        expect(byKey('session-directions'), findsOneWidget);
      },
    );

    testWidgets('«Annulla» en el diálogo no guarda nada', (tester) async {
      final app = await openSession(tester, sessions: webBooking());
      await tester.tap(byKey('session-add-address'));
      await tester.pumpAndSettle();
      await tester.enterText(byKey('client-address-field'), 'Via Pignolo 5');
      await tester.tap(byKey('client-address-cancel'));
      await tester.pumpAndSettle();
      expect(app.sessions.addressUpdates, isEmpty);
      expect(byKey('session-add-address'), findsOneWidget);
    });
  });

  testWidgets(
    'con dirección se puede corregir: el diálogo la trae y sin cambios no se guarda',
    (tester) async {
      final app = await openSession(tester);
      await reveal(tester, byKey('session-edit-address'));
      await tester.tap(byKey('session-edit-address'));
      await tester.pumpAndSettle();

      expect(find.text('Modifica indirizzo'), findsWidgets);
      expect(onPressedOf(tester, 'client-address-save'), isNull);
      await tester.enterText(
        byKey('client-address-field'),
        'Via Gombito 14, 24129 Bergamo',
      );
      await tester.pump();
      await tester.tap(byKey('client-address-save'));
      await tester.pumpAndSettle();
      expect(app.sessions.addressUpdates.single.$2, 'Via Gombito 14, 24129 Bergamo');
      expect(
        tester.widget<SelectableText>(byKey('session-address')).data,
        'Via Gombito 14, 24129 Bergamo',
      );
    },
  );

  group('alergias', () {
    testWidgets(
      'resaltadas: la nota del pedido y, con gluten, la contaminación cruzada',
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
        expect(
          textOf(tester, 'session-cross-contamination'),
          startsWith('Glutine (celiachia): evita la contaminazione crociata.'),
        );
      },
    );

    testWidgets(
      'como llegan de la web (solo la nota): la nota resaltada, nunca «Nessun dato»',
      (tester) async {
        await openSession(
          tester,
          sessions: FakeSessionsRepository(
            buildBooking(restrictions: webRestrictions),
          ),
        );
        expect(textOf(tester, 'session-allergy-note'), 'Celiachia, noci');
        expect(find.text('Nota della richiesta'), findsOneWidget);
        expect(byKey('session-allergies-unknown'), findsNothing);
        expect(byKey('session-no-allergies'), findsNothing);
        expect(byKey('session-allergens'), findsNothing);
        // Sin gluten guardado no hay nota de contaminación cruzada: la nota
        // resaltada es la única señal.
        expect(byKey('session-cross-contamination'), findsNothing);
      },
    );

    testWidgets('«nadie tiene» si el pedido lo confirmó', (tester) async {
      await openSession(
        tester,
        sessions: FakeSessionsRepository(buildBooking(noAllergies: true)),
      );
      expect(
        textOf(tester, 'session-no-allergies'),
        'Ha confermato che nessuno ha allergie, intolleranze alimentari o celiachia.',
      );
      expect(byKey('session-allergies-unknown'), findsNothing);
      expect(byKey('session-cross-contamination'), findsNothing);
    });

    testWidgets('sin respuesta, que pregunte antes de cocinar', (tester) async {
      await openSession(tester);
      expect(
        textOf(tester, 'session-allergies-unknown'),
        "Allergie: nessun dato nell'app, chiedile",
      );
      expect(byKey('session-no-allergies'), findsNothing);
      expect(byKey('session-cross-contamination'), findsNothing);
    });

    /// Sin ningún dato de alergias: [text] en el `Text` de siempre, dentro de
    /// la caja de advertencia (el ícono de aviso y el fondo de error), y nunca
    /// «nadie tiene».
    void expectNoDataWarning(WidgetTester tester, String text) {
      final box = byKey('session-allergies-unknown-box');
      expect(
        find.descendant(of: box, matching: byKey('session-allergies-unknown')),
        findsOneWidget,
      );
      expect(textOf(tester, 'session-allergies-unknown'), text);
      expect(
        find.descendant(
          of: box,
          matching: find.byIcon(Icons.warning_amber_rounded),
        ),
        findsOneWidget,
      );
      expect(
        (tester.widget<DecoratedBox>(box).decoration as BoxDecoration).color,
        Theme.of(tester.element(box)).colorScheme.errorContainer,
      );
      expect(byKey('session-no-allergies'), findsNothing);
    }

    testWidgets(
      "una reserva a mano (ningún dato de alergias): «Allergie: nessun dato nell'app, chiedile» resaltado como advertencia",
      (tester) async {
        // Pedido de la app, sin restricciones ni respuesta a la pregunta, y la
        // ficha sin client_restrictions.
        await openSession(
          tester,
          sessions: FakeSessionsRepository(
            buildBooking(requestSource: RequestSource.app),
          ),
        );
        expectNoDataWarning(tester, "Allergie: nessun dato nell'app, chiedile");
        expect(byKey('session-allergens'), findsNothing);
        expect(byKey('session-allergy-note'), findsNothing);
      },
    );

    testWidgets(
      'una reserva a mano, en español: «Alergias: sin datos en la app, pregúntale»',
      (tester) async {
        await openSession(
          tester,
          locale: const Locale('es'),
          sessions: FakeSessionsRepository(
            buildBooking(requestSource: RequestSource.app),
          ),
        );
        expectNoDataWarning(tester, 'Alergias: sin datos en la app, pregúntale');
      },
    );

    testWidgets(
      'una renovación (pedido de la app, sin respuesta): la nota de su último pedido semanal de la web que se reservó, con la fecha de ese pedido, y no la advertencia',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await openSession(
          tester,
          sessions: FakeSessionsRepository(
            buildBooking(
              requestSource: RequestSource.app,
              lastAllergyAnswer: PastAllergyAnswer(
                requestedAt: DateTime.utc(2026, 10, 19, 9, 15),
                restrictions: webRestrictions,
                noAllergies: false,
              ),
            ),
          ),
        );
        expect(
          textOf(tester, 'session-allergies-earlier'),
          'Secondo la sua richiesta (19 ott 2026)',
        );
        expect(textOf(tester, 'session-allergy-note'), 'Celiachia, noci');
        expect(byKey('session-allergies-unknown'), findsNothing);
        expect(byKey('session-no-allergies'), findsNothing);

        // La fecha es un nodo propio, entre el título y la nota.
        final labels = [
          for (final node in tester.semantics.simulatedAccessibilityTraversal())
            node.getSemanticsData().label,
        ];
        final title = labels.indexOf('Allergie e diete');
        final earlier = labels.indexOf(
          'Secondo la sua richiesta (19 ott 2026)',
        );
        final note = labels.indexWhere(
          (l) => l.startsWith('Nota della richiesta') && l.contains('noci'),
        );
        expect(
          title >= 0 && title < earlier && earlier < note,
          isTrue,
          reason: labels.join(' | '),
        );
        semantics.dispose();
      },
    );

    testWidgets(
      '«nadie tiene» de su último pedido, con la fecha (el día de Roma), en español',
      (tester) async {
        await openSession(
          tester,
          locale: const Locale('es'),
          sessions: FakeSessionsRepository(
            buildBooking(
              requestSource: RequestSource.app,
              // 23:30 UTC del 18/11: en Roma ya es el 19.
              lastAllergyAnswer: PastAllergyAnswer(
                requestedAt: DateTime.utc(2026, 11, 18, 23, 30),
                noAllergies: true,
              ),
            ),
          ),
        );
        expect(
          textOf(tester, 'session-allergies-earlier'),
          'Según su solicitud del 19 nov 2026',
        );
        expect(
          textOf(tester, 'session-no-allergies'),
          'Confirmó que nadie tiene alergias, intolerancias alimentarias ni celiaquía.',
        );
        expect(byKey('session-allergies-unknown'), findsNothing);
      },
    );

    testWidgets(
      'una sesión extra a mano: la advertencia, aunque la clienta haya respondido en un pedido semanal (los que comen pueden ser otros)',
      (tester) async {
        await openSession(
          tester,
          n: 1,
          sessions: FakeSessionsRepository([
            buildSession(
              type: RequestType.extra,
              requestSource: RequestSource.app,
              weeks: 1,
              lastAllergyAnswer: PastAllergyAnswer(
                requestedAt: DateTime.utc(2026, 10, 19, 9, 15),
                noAllergies: true,
              ),
            ),
          ]),
        );
        expectNoDataWarning(tester, "Allergie: nessun dato nell'app, chiedile");
        expect(byKey('session-allergies-earlier'), findsNothing);
      },
    );

    testWidgets(
      'si el pedido de la reserva responde, vale el suyo, sin fecha',
      (tester) async {
        await openSession(
          tester,
          sessions: FakeSessionsRepository(
            buildBooking(
              noAllergies: true,
              lastAllergyAnswer: PastAllergyAnswer(
                requestedAt: DateTime.utc(2026, 10, 19, 9, 15),
                restrictions: webRestrictions,
              ),
            ),
          ),
        );
        expect(byKey('session-no-allergies'), findsOneWidget);
        expect(byKey('session-allergies-earlier'), findsNothing);
        expect(byKey('session-allergy-note'), findsNothing);
      },
    );

    testWidgets('solo una dieta: la advertencia de preguntar, y la dieta', (
      tester,
    ) async {
      await openSession(
        tester,
        sessions: FakeSessionsRepository(
          buildBooking(
            restrictions: const RequestRestrictions(diets: [Diet.vegetarian]),
          ),
        ),
      );
      expectNoDataWarning(tester, "Allergie: nessun dato nell'app, chiedile");
      expect(
        find.descendant(
          of: byKey('session-diets'),
          matching: find.text('Vegetariana'),
        ),
        findsOneWidget,
      );
      expect(byKey('session-allergies-earlier'), findsNothing);
    });

    testWidgets(
      'el lector de pantalla las lee en el orden en que se ven: el título solo y después cada cosa',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await openSession(
          tester,
          locale: const Locale('es'),
          sessions: FakeSessionsRepository(
            buildBooking(
              address: null,
              clientAllergens: const [Allergen.gluten],
              restrictions: const RequestRestrictions(
                allergens: [Allergen.milk],
                note: 'El niño es celíaco',
              ),
            ),
          ),
        );

        final nodes = tester.semantics.simulatedAccessibilityTraversal();
        // Lo que lee el lector de pantalla: con lo que se fundió en cada nodo
        // (los alérgenos, en el de su etiqueta).
        final labels = [
          for (final node in nodes) node.getSemanticsData().label,
        ];
        int indexOf(bool Function(String label) test) {
          final index = labels.indexWhere(test);
          expect(index, isNonNegative, reason: labels.join(' | '));
          return index;
        }

        final buttons = [
          indexOf((l) => l == 'WhatsApp'),
          indexOf((l) => l == 'Llamar'),
          indexOf((l) => l == 'Agregar dirección'),
        ];
        final noAddress = indexOf((l) => l.startsWith('Sin dirección'));
        final title = indexOf((l) => l == 'Alergias y dietas');
        final chips = indexOf(
          (l) =>
              l.startsWith('Alérgenos que evitar') &&
              l.contains('Gluten') &&
              l.contains('Leche'),
        );
        final note = indexOf(
          (l) => l.startsWith('Nota de la solicitud') && l.contains('celíaco'),
        );
        final crossContamination = indexOf(
          (l) => l.startsWith('Gluten (celiaquía)'),
        );
        // «Sin dirección», debajo de los botones, se lee después de ellos; la
        // contaminación cruzada, abajo de todo, al final.
        expect(
          buttons.every((index) => index < noAddress) &&
              noAddress < title &&
              title < chips &&
              chips < note &&
              note < crossContamination,
          isTrue,
          reason: labels.join(' | '),
        );
        // El título es un encabezado, dice solo el título y no tiene hijos:
        // en /gestione/ un encabezado con hijos no sale como encabezado
        // (<h2>), sino como un grupo con nombre.
        expect(
          nodes.elementAt(title),
          isSemantics(label: 'Alergias y dietas', isHeader: true),
        );
        expect(nodes.elementAt(title).childrenCount, 0);
        semantics.dispose();
      },
    );

    testWidgets(
      'sin datos, el aviso es un nodo propio después del título (no parte del encabezado)',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await openSession(tester, locale: const Locale('es'));
        expect(
          tester.semantics.simulatedAccessibilityTraversal(),
          containsAllInOrder(<Matcher>[
            isSemantics(label: 'Alergias y dietas', isHeader: true),
            // Un solo nodo con el texto: el ícono de aviso no se lee.
            isSemantics(
              label: 'Alergias: sin datos en la app, pregúntale',
              isHeader: false,
            ),
          ]),
        );
        semantics.dispose();
      },
    );
  });

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

  // Decisión 3: en la última sesión viva de una reserva semanal, al final de
  // la ficha (el día de cocinar, «Come arrivare» y las alergias van primero).
  group('«Rinnova»', () {
    /// Otra reserva de la misma ficha, del 23/12 al 13/1.
    List<CookingSession> renewal() => buildBooking(
      first: CalendarDate(2026, 12, 23),
      firstN: 10,
      requestId: 'renovacion',
    );

    String location(ChefApp app) =>
        app.container.read(routerProvider).state.uri.toString();

    testWidgets('en la última semana, al final (después de «Settimane», no antes de «Come arrivare»); abre la hoja de la renovación', (
      tester,
    ) async {
      // Alto: toda la ficha construida y a la vista.
      final app = await openSession(tester, n: 4, size: const Size(400, 2400));
      final row = byKey('session-last-of-booking');
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.text("È l'ultima sessione della prenotazione."),
        ),
        findsOneWidget,
      );
      expect(byKey('session-later-session'), findsNothing);
      final top = tester.getTopLeft(row).dy;
      expect(
        top,
        greaterThanOrEqualTo(
          tester.getBottomLeft(byKey('session-week-${sessionId(4)}')).dy,
        ),
      );
      expect(top, greaterThan(tester.getBottomLeft(byKey('session-directions')).dy));
      final renew = byKey('session-renew');
      expect(find.descendant(of: renew, matching: find.text('Rinnova')), findsOneWidget);
      expect(tester.getSize(renew).height, greaterThanOrEqualTo(48));

      await tester.tap(renew);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Rinnova prenotazione'), findsOneWidget);
      expect(location(app), '/sessioni/${sessionId(4)}/rinnova');
      // Al cerrarla, la ficha.
      await tester.tap(byKey('booking-close'));
      await tester.pumpAndSettle();
      expect(find.byType(CookingSessionScreen), findsOneWidget);
    });

    testWidgets('con una sola semana, después de los datos de la clienta', (
      tester,
    ) async {
      await openSession(
        tester,
        n: 1,
        sessions: FakeSessionsRepository(buildBooking(weeks: 1)),
        size: const Size(400, 2400),
      );
      expect(byKey('session-week-${sessionId(1)}'), findsNothing);
      expect(
        tester.getTopLeft(byKey('session-last-of-booking')).dy,
        greaterThanOrEqualTo(
          tester.getBottomLeft(byKey('session-request-notes')).dy,
        ),
      );
      expect(byKey('session-renew'), findsOneWidget);
    });

    testWidgets('también en la última ya cocinada, que no tiene la barra de abajo', (
      tester,
    ) async {
      await openSession(
        tester,
        n: 4,
        sessions: FakeSessionsRepository(
          buildBooking(statuses: {4: SessionStatus.cooked}),
        ),
      );
      expect(byKey('session-move'), findsNothing);
      await reveal(tester, byKey('session-renew'));
      expect(byKey('session-renew'), findsOneWidget);
    });

    testWidgets('con una sesión posterior de la misma ficha en la agenda, el botón sigue y dice «Ha già un\'altra sessione: …»', (
      tester,
    ) async {
      await openSession(
        tester,
        n: 4,
        sessions: FakeSessionsRepository([...buildBooking(), ...renewal()]),
      );
      await reveal(tester, byKey('session-renew'));
      expect(
        plainSpaces(textOf(tester, 'session-later-session')),
        "Ha già un'altra sessione: mer 23 dic.",
      );
      expect(byKey('session-renew'), findsOneWidget);
    });

    testWidgets('con la agenda cargando, el botón está y la línea no; cuando llega, la línea', (
      tester,
    ) async {
      final sessions = FakeSessionsRepository([...buildBooking(), ...renewal()])
        ..pendingAgendaFetch = Completer<void>();
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        sessions: sessions,
        settle: false,
      );
      // Hoy se abre con la agenda cargando (su rueda no se asienta).
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      app.go('/sessioni/${sessionId(4)}');
      await tester.pumpAndSettle();
      await reveal(tester, byKey('session-renew'));
      expect(byKey('session-renew'), findsOneWidget);
      expect(byKey('session-later-session'), findsNothing);

      sessions.pendingAgendaFetch!.complete();
      await tester.pumpAndSettle();
      await reveal(tester, byKey('session-later-session'));
      expect(byKey('session-later-session'), findsOneWidget);
    });

    testWidgets('no está en otra semana, en una semana cancelada ni en una sesión extra', (
      tester,
    ) async {
      final sessions = FakeSessionsRepository([
        ...buildBooking(statuses: {4: SessionStatus.cancelled}),
        buildSession(
          n: 7,
          requestId: 'extra',
          type: RequestType.extra,
          weeks: 1,
          date: CalendarDate(2026, 12, 30),
        ),
      ]);
      final app = await openSession(tester, n: 2, sessions: sessions, size: const Size(400, 2400));
      expect(byKey('session-last-of-booking'), findsNothing);
      for (final n in [4, 7]) {
        app.go('/sessioni/${sessionId(n)}');
        await tester.pumpAndSettle();
        expect(find.byType(CookingSessionScreen), findsOneWidget);
        expect(byKey('session-last-of-booking'), findsNothing, reason: 'sesión $n');
      }
      // Con la última cancelada, la última viva es la del 9/12.
      app.go('/sessioni/${sessionId(3)}');
      await tester.pumpAndSettle();
      expect(byKey('session-last-of-booking'), findsOneWidget);
    });
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
        // No promete que la web vuelva a ofrecer el día: no siempre pasa.
        expect(
          textOf(tester, 'cancel-session-body'),
          "Una sessione annullata non si può riattivare. Se c'è posto nel tuo "
          'orario e il giorno non è bloccato, il sito torna a offrirlo in 1 o '
          '2 minuti.',
        );
        // El motivo por defecto es el neutro.
        expect(find.text('Altro motivo'), findsOneWidget);
        expect(find.text('Annulla la sessione'), findsOneWidget);
        await tester.tap(byKey('cancel-reason-client_cancelled'));
        await tester.tap(byKey('cancel-session-following'));
        await tester.pumpAndSettle();
        expect(find.text('Annulla anche le 2 successive'), findsOneWidget);
        expect(find.text('Annulla 3 sessioni'), findsOneWidget);
        expect(
          textOf(tester, 'cancel-session-body'),
          contains('i giorni non sono bloccati, il sito torna a offrirli'),
        );

        await tester.tap(byKey('cancel-session-confirm'));
        await tester.pumpAndSettle();

        final call = app.sessions.cancelCalls.single;
        expect(call.sessionIds, [sessionId(2), sessionId(3), sessionId(4)]);
        expect(call.reason, CancelReason.clientCancelled);
        expect(call.allowWithPayments, isFalse);
        expect(find.text('3 sessioni annullate.'), findsOneWidget);
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
      'mientras espera al servidor, Sposta y Annulla quedan deshabilitados',
      (tester) async {
        final sessions = FakeSessionsRepository(buildBooking())
          ..pendingCancel = Completer<void>();
        await openSession(tester, sessions: sessions);
        await tester.tap(byKey('session-cancel'));
        await tester.pumpAndSettle();
        await tester.tap(byKey('cancel-session-confirm'));
        // El indicador nunca se asienta: cuadros sueltos.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(byKey('session-busy'), findsOneWidget);
        expect(onPressedOf(tester, 'session-cancel'), isNull);
        expect(onPressedOf(tester, 'session-move'), isNull);
        // Un segundo toque no abre otra confirmación ni manda otro pedido.
        await tester.tap(byKey('session-cancel'), warnIfMissed: false);
        await tester.pump();
        expect(byKey('cancel-session-dialog'), findsNothing);
        expect(sessions.cancelCalls, hasLength(1));

        sessions.pendingCancel!.complete();
        await tester.pumpAndSettle();
        expect(byKey('session-busy'), findsNothing);
        expect(textOf(tester, 'session-status'), 'Annullata · Altro motivo');
      },
    );

    testWidgets(
      'una semana cobrada (409 hasPayments): dice cuál, no se canceló nada y ofrece pasarla al final',
      (tester) async {
        final sessions = FakeSessionsRepository(buildBooking())
          ..paid.add(sessionId(2));
        final app = await openSession(tester, sessions: sessions);
        await cancelFromSheet(tester);

        expect(byKey('has-payments-dialog'), findsOneWidget);
        expect(find.text('Settimana già pagata'), findsOneWidget);
        expect(
          plainSpaces(textOf(tester, 'has-payments-paid')),
          'La settimana di mer 2 dic è già pagata: non è stato annullato niente.',
        );
        expect(
          textOf(tester, 'has-payments-next'),
          "Per ora una settimana pagata non si può annullare dall'app: puoi "
          'passarla alla fine della prenotazione (mer 23 dic) e l\'incasso '
          'resta su quella settimana.',
        );
        expect(byKey('has-payments-cancel-unpaid'), findsNothing);
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
      'con «anche le successive» y la de la ficha cobrada: no la pasa al final (quedaría después de las que se querían cancelar); cancela las no cobradas',
      (tester) async {
        final sessions = FakeSessionsRepository(buildBooking())
          ..paid.add(sessionId(2));
        await openSession(tester, sessions: sessions);
        await cancelFromSheet(tester, following: true);

        expect(byKey('has-payments-dialog'), findsOneWidget);
        expect(
          plainSpaces(textOf(tester, 'has-payments-paid')),
          'La settimana di mer 2 dic è già pagata: non è stato annullato niente.',
        );
        expect(
          textOf(tester, 'has-payments-next'),
          "Per ora una settimana pagata non si può annullare dall'app: puoi "
          'annullare solo le 2 non pagate.',
        );
        expect(byKey('has-payments-move-to-end'), findsNothing);

        await tester.tap(byKey('has-payments-cancel-unpaid'));
        await tester.pumpAndSettle();

        expect(sessions.cancelCalls.last.sessionIds, [
          sessionId(3),
          sessionId(4),
        ]);
        expect(sessions.cancelCalls.last.reason, CancelReason.chefCancelled);
        expect(find.text('2 sessioni annullate.'), findsOneWidget);
        expect(
          sessions.sessions[sessionId(2)]!.status,
          SessionStatus.confirmed,
        );
        expect(
          sessions.sessions[sessionId(3)]!.status,
          SessionStatus.cancelled,
        );
        expect(
          sessions.sessions[sessionId(4)]!.status,
          SessionStatus.cancelled,
        );
        // La ficha sigue en la cobrada, ahora la última viva.
        expect(textOf(tester, 'session-week'), 'Settimana 2 di 2');
        expect(byKey('session-cancel'), findsOneWidget);
      },
    );

    testWidgets(
      'si la cobrada es una de las siguientes, dice cuál (no «questa») y cancela las demás',
      (tester) async {
        final sessions = FakeSessionsRepository(buildBooking())
          ..paid.add(sessionId(3));
        await openSession(tester, sessions: sessions);
        await cancelFromSheet(tester, following: true);

        expect(
          plainSpaces(textOf(tester, 'has-payments-paid')),
          'La settimana di mer 9 dic è già pagata: non è stato annullato niente.',
        );
        expect(textOf(tester, 'has-payments-next'), contains('le 2 non pagate'));
        expect(byKey('has-payments-move-to-end'), findsNothing);
        expect(find.text('Annulla le 2 non pagate'), findsOneWidget);

        await tester.tap(byKey('has-payments-cancel-unpaid'));
        await tester.pumpAndSettle();
        expect(sessions.cancelCalls.last.sessionIds, [
          sessionId(2),
          sessionId(4),
        ]);
        expect(
          sessions.sessions[sessionId(3)]!.status,
          SessionStatus.confirmed,
        );
        expect(
          textOf(tester, 'session-status'),
          'Annullata · Altro motivo',
        );
      },
    );

    testWidgets('varias cobradas: las nombra todas', (tester) async {
      final sessions = FakeSessionsRepository(buildBooking())
        ..paid.addAll([sessionId(3), sessionId(4)]);
      await openSession(tester, sessions: sessions);
      await cancelFromSheet(tester, following: true);

      expect(find.text('Settimane già pagate'), findsOneWidget);
      expect(
        plainSpaces(textOf(tester, 'has-payments-paid')),
        '2 settimane sono già pagate (mer 9 dic · mer 16 dic): non è stato '
        'annullato niente.',
      );
      expect(find.text('Annulla quella non pagata'), findsOneWidget);
    });

    testWidgets(
      'la última semana cobrada: sin nada que ofrecer, solo «Chiudi»',
      (tester) async {
        final sessions = FakeSessionsRepository(buildBooking())
          ..paid.add(sessionId(4));
        await openSession(tester, n: 4, sessions: sessions);
        await cancelFromSheet(tester);

        expect(
          textOf(tester, 'has-payments-next'),
          "Per ora una settimana pagata non si può annullare dall'app.",
        );
        expect(byKey('has-payments-move-to-end'), findsNothing);
        expect(byKey('has-payments-cancel-unpaid'), findsNothing);
        await tester.tap(byKey('has-payments-close'));
        await tester.pumpAndSettle();
        expect(byKey('has-payments-dialog'), findsNothing);
        expect(sessions.cancelCalls, hasLength(1));
      },
    );

    testWidgets(
      'si otra ya está cocinada (otro dispositivo), lo dice y la ficha se actualiza',
      (tester) async {
        final sessions = FakeSessionsRepository(buildBooking());
        await openSession(tester, sessions: sessions);
        sessions.sessions[sessionId(2)] = sessions.sessions[sessionId(2)]!
            .copyWith(status: SessionStatus.cooked);

        await cancelFromSheet(tester);

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
      await cancelFromSheet(tester);

      expect(
        find.textContaining('Non è stato possibile annullarla.'),
        findsOneWidget,
      );
      expect(byKey('session-cancel'), findsOneWidget);
      sessions.cancelFailure = null;
      await tester.tap(snackBarAction('Riprova'));
      await tester.pumpAndSettle();
      expect(sessions.cancelCalls, hasLength(2));
      expect(textOf(tester, 'session-status'), 'Annullata · Altro motivo');
    });

    testWidgets(
      'si al tocar «Riprova» la semana resulta cobrada, el aviso lo explica igual',
      (tester) async {
        final sessions = FakeSessionsRepository(buildBooking())
          ..cancelFailure = const SessionFailure(
            SessionFailureKind.unavailable,
          );
        await openSession(tester, sessions: sessions);
        await cancelFromSheet(tester);
        expect(byKey('has-payments-dialog'), findsNothing);

        // Vuelve la red; mientras tanto se registró un cobro de esa semana.
        sessions
          ..cancelFailure = null
          ..paid.add(sessionId(2));
        await tester.tap(snackBarAction('Riprova'));
        await tester.pumpAndSettle();

        expect(sessions.cancelCalls, hasLength(2));
        expect(
          sessions.cancelCalls.map((call) => call.allowWithPayments),
          [false, false],
        );
        expect(byKey('has-payments-dialog'), findsOneWidget);
        expect(
          plainSpaces(textOf(tester, 'has-payments-paid')),
          'La settimana di mer 2 dic è già pagata: non è stato annullato niente.',
        );
        expect(byKey('has-payments-move-to-end'), findsOneWidget);
        expect(
          sessions.sessions[sessionId(2)]!.status,
          SessionStatus.confirmed,
        );
      },
    );
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

      testWidgets(
        'a 375×667 sin dirección: los botones de 48 dp, el diálogo de la dirección y el de las cobradas sin desbordes (${locale.languageCode})',
        (tester) async {
          final sessions = FakeSessionsRepository(
            buildBooking(address: null, restrictions: webRestrictions),
          )..paid.add(sessionId(3));
          await openSession(
            tester,
            size: const Size(375, 667),
            locale: locale,
            sessions: sessions,
          );
          for (final key in [
            'session-whatsapp',
            'session-call',
            'session-add-address',
          ]) {
            expect(
              tester.getSize(byKey(key)).height,
              greaterThanOrEqualTo(48),
              reason: key,
            );
          }
          await tester.tap(byKey('session-add-address'));
          await tester.pumpAndSettle();
          expectReadableInputs(tester);
          expect(tester.takeException(), isNull);
          await tester.tap(byKey('client-address-cancel'));
          await tester.pumpAndSettle();

          await cancelFromSheet(tester, following: true);
          expect(byKey('has-payments-dialog'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  });
}
