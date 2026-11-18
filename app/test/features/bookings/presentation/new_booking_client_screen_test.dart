// «Nuova prenotazione», elegir la clienta (a pantalla completa, con X): los
// estados de la lista, la búsqueda por nombre o teléfono (también pegado del
// iPhone), la línea de los prospectos y su orden, «Nuova cliente» con lo que
// se buscó, el borrador que vive mientras el elegir esté abierto, ningún
// autocompletar y, a 375×667, «Nuova cliente» en el tercio inferior también
// con el teclado.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/router.dart';
import 'package:radici/features/bookings/presentation/confirm_booking_screen.dart';
import 'package:radici/features/bookings/presentation/new_booking_client_screen.dart';
import 'package:radici/features/bookings/presentation/new_client_screen.dart';
import 'package:radici/features/clients/data/clients_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/client_fixtures.dart';
import '../../../support/fakes.dart';
import '../../../support/text_input_guard.dart';

void main() {
  final chiara = buildClient(
    id: 'c-chiara',
    name: 'Chiara Rossi',
    phone: '340 111 2233',
    zone: 'Loreto',
  );
  final damico = buildClient(
    id: 'c-damico',
    name: "Anna D'Amico",
    phone: null,
    zone: 'Redona',
  );
  final giulia = buildClient(
    id: 'c-giulia',
    name: 'Giulia Bianchi',
    phone: '+39 333 123 4567',
    zone: null,
  );

  Finder byKey(String key) => find.byKey(ValueKey(key));
  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(byKey(key)).data!;

  /// La bandeja en «Prenotazioni» y el elegir abierto desde su botón.
  Future<ChefApp> openPicker(
    WidgetTester tester, {
    FakeClientsRepository? clients,
    Size size = const Size(400, 900),
    bool settle = true,
    Locale locale = const Locale('it', 'IT'),
  }) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      clients: clients ?? FakeClientsRepository([chiara, damico, giulia]),
      location: '/richieste',
      size: size,
      deviceLocales: [locale],
    );
    await tester.tap(byKey('inbox-tab-bookings'));
    await tester.pumpAndSettle();
    await tester.tap(byKey('inbox-new-booking'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
    return app;
  }

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(byKey('client-search'), text);
    await tester.pumpAndSettle();
  }

  List<String> listedIds(WidgetTester tester) => [
    for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
      if (tile.key case ValueKey<String>(:final value)
          when value.startsWith('client-'))
        value.substring('client-'.length),
  ];

  String location(ChefApp app) => app.container
      .read(routerProvider).state.uri
      .toString();

  group('estados de la lista', () {
    testWidgets('cargando: la rueda; «Nuova cliente» se puede tocar igual', (tester) async {
      final clients = FakeClientsRepository([chiara])
        ..pendingFetch = Completer<void>();
      await openPicker(tester, clients: clients, settle: false);
      expect(byKey('client-picker-loading'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(byKey('new-booking-new-client')).onPressed,
        isNotNull,
      );
      clients.pendingFetch!.complete();
      await tester.pumpAndSettle();
      expect(byKey('client-c-chiara'), findsOneWidget);
    });

    testWidgets('con error: el mensaje y «Riprova» la vuelve a leer', (tester) async {
      final clients = FakeClientsRepository([chiara])
        ..fetchFailure = const ClientsFailure(ClientsFailureKind.unavailable);
      await openPicker(tester, clients: clients);
      expect(
        textOf(tester, 'load-error'),
        'Impossibile caricare le schede delle clienti. Controlla la connessione e riprova.',
      );
      expect(byKey('new-booking-new-client').hitTestable(), findsOneWidget);

      clients.fetchFailure = null;
      await tester.tap(byKey('load-error-retry'));
      await tester.pumpAndSettle();
      expect(byKey('client-c-chiara'), findsOneWidget);
    });

    testWidgets('sin fichas: lo dice y la acción es «Nuova cliente» de abajo', (tester) async {
      await openPicker(tester, clients: FakeClientsRepository());
      expect(
        textOf(tester, 'client-picker-empty'),
        'Non hai ancora schede di clienti: crea la prima con «Nuova cliente».',
      );
      expect(byKey('new-booking-new-client').hitTestable(), findsOneWidget);
    });

    testWidgets('sin resultados: lo dice y ofrece borrar la búsqueda', (tester) async {
      await openPicker(tester);
      await search(tester, 'zzz');
      expect(
        textOf(tester, 'client-picker-no-matches'),
        'Nessuna scheda con «zzz». Se è una cliente nuova, creala con «Nuova cliente».',
      );
      await tester.tap(byKey('client-picker-no-matches-clear'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(byKey('client-search')).controller!.text,
        isEmpty,
      );
      expect(listedIds(tester), hasLength(3));
    });

    testWidgets('resultados: nombre, teléfono como está guardado y zona, sin lo que falte', (tester) async {
      await openPicker(tester);
      expect(listedIds(tester), ['c-damico', 'c-chiara', 'c-giulia']);
      expect(
        find.descendant(
          of: byKey('client-c-chiara'),
          matching: find.text('340 111 2233 · Loreto'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: byKey('client-c-damico'), matching: find.text('Redona')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: byKey('client-c-giulia'),
          matching: find.text('+39 333 123 4567'),
        ),
        findsOneWidget,
      );
      expect(tester.getSize(byKey('client-c-chiara')).height, greaterThanOrEqualTo(48));
    });
  });

  group('búsqueda', () {
    testWidgets('por nombre, también con el apóstrofo del iPhone', (tester) async {
      await openPicker(tester);
      await search(tester, 'chi ros');
      expect(listedIds(tester), ['c-chiara']);
      await search(tester, 'd\u2019amico');
      expect(listedIds(tester), ['c-damico']);
    });

    testWidgets('por teléfono, también pegado entre marcas invisibles', (tester) async {
      await openPicker(tester);
      await search(tester, '340 111');
      expect(listedIds(tester), ['c-chiara']);
      await search(tester, '\u202a+39 333 123 4567\u202c');
      expect(listedIds(tester), ['c-giulia']);
    });

    testWidgets('«Cancella la ricerca» la borra', (tester) async {
      await openPicker(tester);
      expect(byKey('client-search-clear'), findsNothing);
      await search(tester, 'chiara');
      expect(listedIds(tester), ['c-chiara']);
      expect(
        tester.widget<IconButton>(byKey('client-search-clear')).tooltip,
        'Cancella la ricerca',
      );
      expect(
        tester.getSize(byKey('client-search-clear')).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(byKey('client-search-clear'));
      await tester.pumpAndSettle();
      expect(listedIds(tester), hasLength(3));
    });

    testWidgets('un prospecto lo dice («Non ancora cliente · richiesta del …») y va después de la ficha con el mismo nombre', (tester) async {
      final twin = buildClient(
        id: 'a-twin',
        name: 'Chiara Rossi',
        phone: '340 111 2233',
        zone: 'Loreto',
        status: ClientStatus.prospect,
        latestWeekly: buildLatestWeekly(createdAt: DateTime.utc(2026, 11, 15, 9)),
      );
      final lonely = buildClient(
        id: 'b-lonely',
        name: 'Bea Neri',
        status: ClientStatus.prospect,
      );
      await openPicker(
        tester,
        clients: FakeClientsRepository([twin, chiara, lonely]),
      );
      await search(tester, 'chiara');
      expect(listedIds(tester), ['c-chiara', 'a-twin']);
      expect(
        textOf(tester, 'client-a-twin-prospect'),
        'Non ancora cliente · richiesta del 15/11',
      );
      expect(byKey('client-c-chiara-prospect'), findsNothing);
      expect(tester.widget<ListTile>(byKey('client-a-twin')).isThreeLine, isTrue);
      await search(tester, 'bea');
      expect(textOf(tester, 'client-b-lonely-prospect'), 'Non ancora cliente');
    });

    testWidgets('en inglés, «Not a client yet · requested 11/15»', (tester) async {
      final twin = buildClient(
        id: 'a-twin',
        name: 'Chiara Rossi',
        status: ClientStatus.prospect,
        latestWeekly: buildLatestWeekly(createdAt: DateTime.utc(2026, 11, 15, 9)),
      );
      await openPicker(
        tester,
        clients: FakeClientsRepository([twin]),
        locale: const Locale('en'),
      );
      expect(
        textOf(tester, 'client-a-twin-prospect'),
        'Not a client yet · requested 11/15',
      );
    });
  });

  testWidgets('tocar una ficha abre su hoja (solo el id en la URL)', (tester) async {
    final app = await openPicker(tester);
    await tester.tap(byKey('client-c-chiara'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmBookingScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Nuova prenotazione'), findsOneWidget);
    expect(find.text('Chiara Rossi'), findsOneWidget);
    expect(location(app), '/richieste/nuova/prenota?cliente=c-chiara');
  });

  group('«Nuova cliente»', () {
    String fieldText(WidgetTester tester, String key) =>
        tester.widget<TextField>(byKey(key)).controller!.text;

    testWidgets('con un nombre buscado lo prellena en el nombre', (tester) async {
      await openPicker(tester);
      await search(tester, 'Giulia');
      await tester.tap(byKey('new-booking-new-client'));
      await tester.pumpAndSettle();
      expect(find.byType(NewClientScreen), findsOneWidget);
      expect(fieldText(tester, 'new-client-name'), 'Giulia');
      expect(fieldText(tester, 'new-client-phone'), isEmpty);
    });

    testWidgets('con un número buscado lo prellena en el teléfono, nunca en el nombre', (tester) async {
      await openPicker(tester);
      await search(tester, '333 12');
      await tester.tap(byKey('new-booking-new-client'));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 'new-client-phone'), '333 12');
      expect(fieldText(tester, 'new-client-name'), isEmpty);
    });

    testWidgets('si el borrador ya tiene algo, no lo pisa; la X lo descarta', (tester) async {
      await openPicker(tester);
      await tester.tap(byKey('new-booking-new-client'));
      await tester.pumpAndSettle();
      await tester.enterText(byKey('new-client-name'), 'Marta Neri');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(NewBookingClientScreen), findsOneWidget);

      await search(tester, 'Giulia');
      await tester.tap(byKey('new-booking-new-client'));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 'new-client-name'), 'Marta Neri');

      // La X del elegir vuelve a «Prenotazioni» y descarta el borrador.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(byKey('new-booking-close'));
      await tester.pumpAndSettle();
      expect(find.byType(NewBookingClientScreen), findsNothing);
      expect(find.byType(InboxScreen), findsOneWidget);
      expect(byKey('inbox-new-booking').hitTestable(), findsOneWidget);

      await tester.tap(byKey('inbox-new-booking'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('new-booking-new-client'));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 'new-client-name'), isEmpty);
    });
  });

  testWidgets('el buscador no le pide autocompletar al navegador y no tiene autofoco; letra de 16 px', (tester) async {
    await openPicker(tester);
    expect(
      tester.widget<TextField>(byKey('client-search')).autofocus,
      isFalse,
      reason: 'el teclado taparía la lista',
    );
    expectReadableInputs(tester);
    await expectNoBrowserAutofill(tester, byKey('client-search'));
    expect(
      tester.widget<TextField>(byKey('client-search')).autocorrect,
      isFalse,
      reason: 'iOS cambiaría el apellido buscado y no encontraría la ficha',
    );
  });

  testWidgets('el buscador conserva su nombre para el lector de pantalla también con texto', (tester) async {
    final semantics = tester.ensureSemantics();
    await openPicker(tester);
    await search(tester, 'chiara');
    expect(
      tester.getSemantics(
        find.descendant(
          of: byKey('client-search'),
          matching: find.byType(EditableText),
        ),
      ),
      containsSemantics(label: 'Nome o telefono', value: 'chiara', isTextField: true),
    );
    semantics.dispose();
  });

  testWidgets('a 375×667 «Nuova cliente» queda en el tercio inferior y, con el teclado, por encima de él', (tester) async {
    await openPicker(tester, size: const Size(375, 667));
    final newClient = byKey('new-booking-new-client');
    expect(newClient.hitTestable(), findsOneWidget);
    expect(tester.getCenter(newClient).dy, greaterThan(667 * 2 / 3));
    expect(tester.getSize(newClient).height, greaterThanOrEqualTo(48));
    expect(
      tester.getSize(byKey('new-booking-close')).height,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(byKey('client-search'));
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(newClient.hitTestable(), findsOneWidget);
    expect(tester.getRect(newClient).bottom, lessThanOrEqualTo(667 - 300));
    expectReadableInputs(tester);
    expect(tester.takeException(), isNull);
  });
}
