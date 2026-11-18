// «Nuova cliente»: el formulario de una ficha nueva. Sin nombre, «Continua»
// deshabilitado y la barra dice por qué (con «Vedi»); el teléfono (también
// pegado del iPhone) con su error después de «Continua»; el teléfono que ya
// es de una ficha, con la oferta en la barra (también con el teclado
// abierto); el directorio cargando o con error; el borrador que sobrevive al
// volver al elegir; los textos más largos que el servidor; ningún
// autocompletar; y, a 375×667, la acción principal en el tercio inferior.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/router.dart';
import 'package:radici/features/bookings/presentation/confirm_booking_screen.dart';
import 'package:radici/features/bookings/presentation/new_booking_client_screen.dart';
import 'package:radici/features/bookings/presentation/new_client_screen.dart';
import 'package:radici/features/clients/data/clients_repository.dart';

import '../../../support/chef_app.dart';
import '../../../support/client_fixtures.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/text_input_guard.dart';

void main() {
  final chiara = buildClient(
    id: 'c-chiara',
    name: 'Chiara Rossi',
    phone: '333 123 4567',
    zone: 'Loreto',
  );

  Finder byKey(String key) => find.byKey(ValueKey(key));
  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(byKey(key)).data!;
  String fieldText(WidgetTester tester, String key) =>
      tester.widget<TextField>(byKey(key)).controller!.text;
  bool focused(WidgetTester tester, String key) =>
      tester.widget<TextField>(byKey(key)).focusNode!.hasFocus;

  /// «Prenotazioni» → «Nuova prenotazione» → «Nuova cliente».
  Future<ChefApp> openForm(
    WidgetTester tester, {
    FakeClientsRepository? clients,
    Size size = const Size(400, 900),
    FakeChefRequestsRepository? requests,
  }) async {
    final app = await pumpChefApp(
      tester,
      requests: requests ?? FakeChefRequestsRepository(const []),
      clients: clients ?? FakeClientsRepository([chiara]),
      location: '/richieste',
      size: size,
    );
    await tester.tap(byKey('inbox-tab-bookings'));
    await tester.pumpAndSettle();
    await tester.tap(byKey('inbox-new-booking'));
    await tester.pumpAndSettle();
    await tester.tap(byKey('new-booking-new-client'));
    await tester.pumpAndSettle();
    expect(find.byType(NewClientScreen), findsOneWidget);
    return app;
  }

  Future<void> type(WidgetTester tester, String key, String text) async {
    await tester.ensureVisible(byKey(key));
    await tester.pumpAndSettle();
    await tester.enterText(byKey(key), text);
    await tester.pumpAndSettle();
  }

  /// Baja hasta los chips del idioma (el final del formulario).
  Future<void> scrollToLocale(WidgetTester tester) async {
    await tester.ensureVisible(byKey('new-client-locale-en'));
    await tester.pumpAndSettle();
  }

  testWidgets('el formulario: los campos en orden, contadores en 2 y 2, idioma en italiano', (tester) async {
    await openForm(tester);
    expect(find.widgetWithText(AppBar, 'Nuova cliente'), findsOneWidget);
    expect(find.text('Nome e cognome'), findsOneWidget);
    expect(find.text('Telefono (per WhatsApp)'), findsOneWidget);
    expect(
      find.text('Facoltativo. Se non è italiano, con il prefisso: +34…'),
      findsOneWidget,
    );
    expect(find.text('Zona (facoltativa)'), findsOneWidget);
    expect(find.text('Indirizzo (facoltativo)'), findsOneWidget);
    expect(textOf(tester, 'new-client-adults-value'), '2');
    expect(textOf(tester, 'new-client-kids-value'), '2');
    for (final key in [
      'new-client-adults-increment',
      'new-client-adults-decrement',
      'new-client-kids-increment',
      'new-client-kids-decrement',
    ]) {
      expect(tester.getSize(byKey(key)).height, greaterThanOrEqualTo(48), reason: key);
      expect(tester.getSize(byKey(key)).width, greaterThanOrEqualTo(48), reason: key);
    }
    expect(find.text('Lingua dei messaggi WhatsApp'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(byKey('new-client-locale-it')).selected, isTrue);
    await scrollToLocale(tester);
    await tester.tap(byKey('new-client-locale-es'));
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(byKey('new-client-locale-es')).selected, isTrue);
    expect(tester.widget<ChoiceChip>(byKey('new-client-locale-it')).selected, isFalse);
    expect(
      tester.widget<TextField>(byKey('new-client-phone')).keyboardType,
      TextInputType.phone,
    );
    expectReadableInputs(tester);
  });

  testWidgets('ningún campo le pide autocompletar al navegador (Safari ofrecería el teléfono o la dirección de Evelyn)', (tester) async {
    await openForm(tester);
    for (final key in [
      'new-client-name',
      'new-client-phone',
      'new-client-zone',
      'new-client-address',
    ]) {
      await expectNoBrowserAutofill(tester, byKey(key));
    }
  });

  group('sin nombre', () {
    testWidgets('«Continua» deshabilitado y la barra dice por qué', (tester) async {
      await openForm(tester);
      expect(
        tester.widget<FilledButton>(byKey('new-client-continue')).onPressed,
        isNull,
      );
      expect(textOf(tester, 'new-client-blocker'), 'Scrivi il nome per continuare.');
      expect(byKey('new-client-blocker-show'), findsOneWidget);
      await type(tester, 'new-client-name', 'Giulia Rossi');
      expect(byKey('new-client-blocker'), findsNothing);
      expect(
        tester.widget<FilledButton>(byKey('new-client-continue')).onPressed,
        isNotNull,
      );
    });

    testWidgets('a 375×667, con el nombre fuera de la vista, «Vedi» lo trae y le da el foco', (tester) async {
      await openForm(tester, size: const Size(375, 667));
      await scrollToLocale(tester);
      expect(byKey('new-client-name').hitTestable(), findsNothing);
      await tester.tap(byKey('new-client-blocker-show'));
      await tester.pumpAndSettle();
      expect(byKey('new-client-name').hitTestable(), findsOneWidget);
      expect(focused(tester, 'new-client-name'), isTrue);
    });
  });

  group('teléfono inválido', () {
    testWidgets('el error aparece después de «Continua» (lector de pantalla incluido) y la barra lo dice', (tester) async {
      final semantics = tester.ensureSemantics();
      await openForm(tester);
      await type(tester, 'new-client-name', 'Giulia Rossi');
      await type(tester, 'new-client-phone', '612 345 678');
      expect(byKey('new-client-phone-error'), findsNothing);

      await tester.tap(byKey('new-client-continue'));
      await tester.pumpAndSettle();
      expect(find.byType(NewClientScreen), findsOneWidget, reason: 'no avanza');
      expect(
        textOf(tester, 'new-client-phone-error'),
        'Numero non valido: scrivilo con il prefisso, es. +34 612 345 678.',
      );
      expect(
        tester.getSemantics(byKey('new-client-phone-error')),
        isSemantics(isLiveRegion: true),
      );
      expect(textOf(tester, 'new-client-blocker'), 'Il numero di telefono non è valido.');
      expect(
        tester.widget<FilledButton>(byKey('new-client-continue')).onPressed,
        isNull,
      );

      // Se corrige mientras se escribe.
      await type(tester, 'new-client-phone', '+34 612 345 678');
      expect(byKey('new-client-phone-error'), findsNothing);
      expect(byKey('new-client-blocker'), findsNothing);
      semantics.dispose();
    });

    testWidgets('a 375×667, después de bajar hasta el idioma, «Vedi» trae el teléfono con el foco', (tester) async {
      await openForm(tester, size: const Size(375, 667));
      await type(tester, 'new-client-name', 'Giulia Rossi');
      await type(tester, 'new-client-phone', '612 345 678');
      await scrollToLocale(tester);
      await tester.tap(byKey('new-client-continue'));
      await tester.pumpAndSettle();
      expect(byKey('new-client-phone').hitTestable(), findsNothing);
      await tester.tap(byKey('new-client-blocker-show'));
      await tester.pumpAndSettle();
      expect(byKey('new-client-phone').hitTestable(), findsOneWidget);
      expect(focused(tester, 'new-client-phone'), isTrue);
    });
  });

  group('el teléfono ya es de una ficha', () {
    testWidgets('la tarjeta (anunciada) y la barra con «Usa la scheda di Chiara Rossi» y «Crea una scheda nuova»', (tester) async {
      final semantics = tester.ensureSemantics();
      await openForm(tester);
      await type(tester, 'new-client-phone', '+39 333 1234567');
      expect(
        textOf(tester, 'new-client-phone-taken-text'),
        'Questo numero è già nella scheda di Chiara Rossi. Se è lei, usa la sua '
        'scheda con il pulsante qui sotto: quello che scrivi qui non la cambia.',
      );
      expect(
        tester.getSemantics(byKey('new-client-phone-taken-text')),
        isSemantics(isLiveRegion: true),
      );
      expect(
        find.widgetWithText(FilledButton, 'Usa la scheda di Chiara Rossi'),
        findsOneWidget,
      );
      expect(byKey('new-client-create-anyway'), findsOneWidget);
      expect(byKey('new-client-continue'), findsNothing);
      // Sin nombre, crear otra ficha sigue deshabilitado. El motivo va debajo
      // de ese botón, con su propio texto: arriba de «Usa la scheda…» (que no
      // necesita el nombre) contradecía a la acción principal.
      expect(
        tester.widget<OutlinedButton>(byKey('new-client-create-anyway')).onPressed,
        isNull,
      );
      expect(
        textOf(tester, 'new-client-blocker'),
        'Per creare una scheda nuova, scrivi il nome.',
      );
      expect(
        tester.getRect(byKey('new-client-blocker')).top,
        greaterThanOrEqualTo(tester.getRect(byKey('new-client-create-anyway')).bottom),
      );
      await tester.tap(byKey('new-client-blocker-show'));
      await tester.pumpAndSettle();
      expect(focused(tester, 'new-client-name'), isTrue);
      semantics.dispose();
    });

    testWidgets('lo que impide crear otra ficha va debajo de «Crea una scheda nuova»: un nombre largo', (tester) async {
      await openForm(tester);
      await type(tester, 'new-client-name', '${'a' * 40}${'\u{1F600}' * 40}');
      await type(tester, 'new-client-phone', '333 123 4567');
      await tester.tap(byKey('new-client-create-anyway'));
      await tester.pumpAndSettle();
      expect(find.byType(NewClientScreen), findsOneWidget);
      expect(textOf(tester, 'new-client-blocker'), 'Testo troppo lungo: accorcialo.');
      expect(
        tester.getRect(byKey('new-client-blocker')).top,
        greaterThanOrEqualTo(tester.getRect(byKey('new-client-create-anyway')).bottom),
      );
      expect(
        tester.widget<FilledButton>(byKey('new-client-use-existing')).onPressed,
        isNotNull,
      );
    });

    for (final (label, pasted) in [
      ('entre U+202A y U+202C', '\u202a+39 333 123 4567\u202c'),
      ('con U+200E', '\u200e+39 333 123 4567'),
    ]) {
      testWidgets('un número pegado $label es válido y encuentra la ficha', (tester) async {
        await openForm(tester);
        await type(tester, 'new-client-name', 'Giulia');
        await type(tester, 'new-client-phone', pasted);
        expect(byKey('new-client-phone-taken'), findsOneWidget);
        expect(byKey('new-client-phone-error'), findsNothing);
      });
    }

    testWidgets('«Usa la scheda…» abre su hoja con los adultos tocados y saca el formulario de la pila', (tester) async {
      final app = await openForm(tester);
      await tester.tap(byKey('new-client-adults-increment'));
      await tester.pumpAndSettle();
      await type(tester, 'new-client-phone', '333 123 4567');
      await tester.tap(byKey('new-client-use-existing'));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      expect(
        app.container
            .read(routerProvider).state.uri
            .toString(),
        '/richieste/nuova/prenota?cliente=c-chiara&modulo=1',
      );
      expect(find.text('Chiara Rossi'), findsOneWidget);
      await tester.ensureVisible(byKey('booking-adults-value'));
      expect(textOf(tester, 'booking-adults-value'), '3');
      // La ficha no cambió.
      expect(app.clients.clients.single, chiara);

      await tester.tap(byKey('booking-close'));
      await tester.pumpAndSettle();
      expect(find.byType(NewClientScreen), findsNothing);
      expect(find.byType(NewBookingClientScreen), findsOneWidget);
    });

    testWidgets('«Crea una scheda nuova» abre la hoja de una ficha nueva', (tester) async {
      await openForm(tester);
      await type(tester, 'new-client-name', 'Chiara Bianchi');
      await type(tester, 'new-client-phone', '333 123 4567');
      await tester.tap(byKey('new-client-create-anyway'));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmBookingScreen), findsOneWidget);
      expect(find.text('Chiara Bianchi'), findsOneWidget);
      expect(
        textOf(tester, 'booking-new-client-note'),
        'Scheda nuova: si crea quando confermi.',
      );
    });

    testWidgets('a 375×667 con el teclado abierto y el foco en el teléfono, «Usa la scheda…» queda a la vista en la barra', (tester) async {
      await openForm(tester, size: const Size(375, 667));
      await type(tester, 'new-client-phone', '333 123 4567');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      final useExisting = byKey('new-client-use-existing');
      expect(useExisting.hitTestable(), findsOneWidget);
      expect(tester.getRect(useExisting).bottom, lessThanOrEqualTo(667 - 300));
      expect(tester.takeException(), isNull);
    });
  });

  group('el directorio', () {
    testWidgets('cargando: «Sto controllando…»; cuando llega, la barra cambia', (tester) async {
      // Las fichas tardan en llegar: el elegir gira y el formulario se abre
      // igual.
      final clients = FakeClientsRepository([chiara])
        ..pendingFetch = Completer<void>();
      await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository(const []),
        clients: clients,
        location: '/richieste',
      );
      await tester.tap(byKey('inbox-tab-bookings'));
      await tester.pumpAndSettle();
      Future<void> frames() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }

      await tester.tap(byKey('inbox-new-booking'));
      await frames();
      await tester.tap(byKey('new-booking-new-client'));
      await frames();
      await tester.enterText(byKey('new-client-phone'), '333 123 4567');
      await frames();
      expect(
        textOf(tester, 'new-client-phone-checking'),
        'Sto controllando se il numero è già di una cliente…',
      );
      expect(byKey('new-client-use-existing'), findsNothing);
      clients.pendingFetch!.complete();
      await tester.pumpAndSettle();
      expect(byKey('new-client-phone-checking'), findsNothing);
      expect(byKey('new-client-use-existing'), findsOneWidget);
    });

    testWidgets('con error: lo dice, deja continuar y «Riprova» lo vuelve a leer', (tester) async {
      final clients = FakeClientsRepository([chiara])
        ..fetchFailure = const ClientsFailure(ClientsFailureKind.unavailable);
      await openForm(tester, clients: clients);
      await type(tester, 'new-client-name', 'Giulia');
      await type(tester, 'new-client-phone', '333 123 4567');
      expect(
        textOf(tester, 'new-client-phone-unchecked'),
        'Non è stato possibile controllare se il numero è già di una cliente.',
      );
      expect(
        tester.widget<FilledButton>(byKey('new-client-continue')).onPressed,
        isNotNull,
      );
      clients.fetchFailure = null;
      await tester.tap(byKey('new-client-phone-retry'));
      await tester.pumpAndSettle();
      expect(byKey('new-client-phone-unchecked'), findsNothing);
      expect(byKey('new-client-use-existing'), findsOneWidget);
    });
  });

  testWidgets('volver al elegir y tocar otra vez «Nuova cliente»: lo escrito sigue ahí', (tester) async {
    await openForm(tester);
    await type(tester, 'new-client-name', 'Giulia Rossi');
    await type(tester, 'new-client-phone', '347 000 1111');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NewBookingClientScreen), findsOneWidget);
    await tester.tap(byKey('new-booking-new-client'));
    await tester.pumpAndSettle();
    expect(fieldText(tester, 'new-client-name'), 'Giulia Rossi');
    expect(fieldText(tester, 'new-client-phone'), '347 000 1111');
  });

  testWidgets('un nombre largo con emojis pasa el límite del servidor: lo dice al tocar «Continua»', (tester) async {
    await openForm(tester);
    await type(tester, 'new-client-name', '${'a' * 40}${'\u{1F600}' * 40}');
    await tester.tap(byKey('new-client-continue'));
    await tester.pumpAndSettle();
    expect(find.byType(NewClientScreen), findsOneWidget);
    expect(find.text('Testo troppo lungo: accorcialo.'), findsWidgets);
    expect(textOf(tester, 'new-client-blocker'), 'Testo troppo lungo: accorcialo.');
  });

  testWidgets('«Continua» con nombre y teléfono abre la hoja de la ficha nueva', (tester) async {
    await openForm(tester);
    await type(tester, 'new-client-name', 'Giulia Rossi');
    await type(tester, 'new-client-phone', '347 000 1111');
    await tester.tap(byKey('new-client-continue'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmBookingScreen), findsOneWidget);
    expect(find.text('Giulia Rossi'), findsOneWidget);
    expect(textOf(tester, 'booking-subtitle'), '347 000 1111');
  });

  group('a 375×667', () {
    testWidgets('«Continua» en el tercio inferior y, con el teclado, por encima de él', (tester) async {
      await openForm(tester, size: const Size(375, 667));
      final next = byKey('new-client-continue');
      expect(next.hitTestable(), findsOneWidget);
      expect(tester.getCenter(next).dy, greaterThan(667 * 2 / 3));
      expect(tester.getSize(next).height, greaterThanOrEqualTo(48));
      await tester.tap(byKey('new-client-name'));
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(next.hitTestable(), findsOneWidget);
      expect(tester.getRect(next).bottom, lessThanOrEqualTo(667 - 300));
      expectReadableInputs(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('con el teclado y el aviso de pedido nuevo arriba, «Continua» sigue a la vista', (tester) async {
      final app = await openForm(tester, size: const Size(375, 667));
      await tester.tap(byKey('new-client-name'));
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      app.requests.insertFromRealtime(
        buildRequest(id: 'web-new', name: 'Marco Bianchi'),
      );
      await tester.pumpAndSettle();
      expect(byKey('new-request-banner'), findsOneWidget);
      final next = byKey('new-client-continue');
      expect(next.hitTestable(), findsOneWidget);
      expect(tester.getRect(next).bottom, lessThanOrEqualTo(667 - 300));
      expect(tester.takeException(), isNull);
    });
  });
}
