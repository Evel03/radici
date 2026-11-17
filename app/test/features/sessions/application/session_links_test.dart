// Enlaces de la ficha de la sesión: Mapas según la plataforma (Apple Maps en
// un iPhone o una Mac, también /gestione/ en Safari; Google Maps en el resto)
// y el WhatsApp, en el idioma de la clienta. La hora de llegada va solo en una
// sesión que no está cancelada, cocinada ni cobrada, de hoy en adelante (el
// día de Roma); en las demás, el mensaje nombra la sesión por su fecha, sin la
// hora. El WhatsApp sale del teléfono de quien usa la app: si es un
// colaborador de la cocinera, escribe de parte de ella y no dice ser ella ni
// ser quien llega. sessionLinksProvider elige con ChefAccount.collaborator y
// con el día de hoy de romeTodayProvider, que cambia a la medianoche de Roma.
// Nunca lleva la dirección, las alergias, las notas, la zona ni el apellido.
// La prueba en el iPhone sigue haciendo falta: un test no ve qué plataforma
// reporta Flutter web en Safari.
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/application/session_links.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/l10n/app_localizations.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  setUpAll(initializeDateFormatting);

  test('Apple Maps en iOS y macOS; Google Maps en el resto', () {
    try {
      for (final (platform, apple) in const [
        (TargetPlatform.iOS, true),
        (TargetPlatform.macOS, true),
        (TargetPlatform.android, false),
        (TargetPlatform.windows, false),
        (TargetPlatform.linux, false),
        (TargetPlatform.fuchsia, false),
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        // Sin reemplazar el provider: la regla de verdad.
        final container = ProviderContainer.test();
        expect(container.read(appleMapsProvider), apple, reason: platform.name);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // La sesión de ejemplo es del miércoles 25/11/2026, con llegada a las 10:00.
  final dayBefore = CalendarDate(2026, 11, 24);
  final sessionDay = CalendarDate(2026, 11, 25);
  final dayAfter = CalendarDate(2026, 11, 26);

  /// El texto del WhatsApp de [session] con [today] como el día de hoy en
  /// Roma; [onBehalf], como un colaborador.
  String whatsAppText(
    CookingSession session, {
    required bool onBehalf,
    required CalendarDate today,
  }) => sessionLinksFor(
    session,
    chefName: 'Evelyn',
    appleMaps: false,
    onBehalf: onBehalf,
    today: today,
  ).whatsApp!.queryParameters['text']!;

  /// La sesión del miércoles 25/11/2026 a las 10:00 con [status], de una
  /// clienta que habla [locale]: Giulia Rossi, Lucía Fernández o Emma Clark.
  CookingSession sessionIn(ClientLocale locale, SessionStatus status) =>
      buildSession(
        status: status,
        locale: locale,
        name: switch (locale) {
          ClientLocale.it => 'Giulia Rossi',
          ClientLocale.es => 'Lucía Fernández',
          ClientLocale.en => 'Emma Clark',
        },
      );

  /// El WhatsApp de esa sesión, de la cocinera o de un colaborador
  /// ([onBehalf]), con la hora de llegada ([arrival]) o sin ella.
  String expected(
    ClientLocale locale, {
    required bool onBehalf,
    required bool arrival,
  }) => switch ((locale, onBehalf, arrival)) {
    (ClientLocale.it, false, true) =>
      'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
          'mercoledì 25 novembre, con arrivo alle 10:00.',
    // Ni «sono Evelyn» ni «con arrivo alle…» como si llegara él: la que
    // llega es ella. Como el de la cocinera, describe el horario («con
    // arrivo di Evelyn…», no «Evelyn arriva…»): vale también pasada la hora.
    (ClientLocale.it, true, true) =>
      'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione '
          'di mercoledì 25 novembre, con arrivo di Evelyn alle 10:00.',
    (ClientLocale.it, false, false) =>
      'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
          'mercoledì 25 novembre.',
    (ClientLocale.it, true, false) =>
      'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione '
          'di mercoledì 25 novembre.',
    (ClientLocale.es, false, true) =>
      'Hola Lucía, soy Evelyn de Radici. Te escribo por la sesión del '
          'miércoles 25 de noviembre, con llegada a las 10:00.',
    (ClientLocale.es, true, true) =>
      'Hola Lucía, te escribo de parte de Evelyn de Radici por la sesión '
          'del miércoles 25 de noviembre, con llegada de Evelyn a las 10:00.',
    (ClientLocale.es, false, false) =>
      'Hola Lucía, soy Evelyn de Radici. Te escribo por la sesión del '
          'miércoles 25 de noviembre.',
    (ClientLocale.es, true, false) =>
      'Hola Lucía, te escribo de parte de Evelyn de Radici por la sesión '
          'del miércoles 25 de noviembre.',
    (ClientLocale.en, false, true) =>
      "Hi Emma, this is Evelyn from Radici. I'm writing about the session "
          'on Wednesday, November 25, arriving at 10:00.',
    (ClientLocale.en, true, true) =>
      "Hi Emma, I'm writing on behalf of Evelyn from Radici about the "
          'session on Wednesday, November 25, with Evelyn arriving at 10:00.',
    (ClientLocale.en, false, false) =>
      "Hi Emma, this is Evelyn from Radici. I'm writing about the session "
          'on Wednesday, November 25.',
    (ClientLocale.en, true, false) =>
      "Hi Emma, I'm writing on behalf of Evelyn from Radici about the "
          'session on Wednesday, November 25.',
  };

  group('WhatsApp: con la hora de llegada solo si la sesión no está cancelada, cocinada ni cobrada y es de hoy en adelante (el día de Roma)', () {
    // Lo firma la cocinera; un colaborador, desde su propio teléfono,
    // escribe de parte de ella. Siempre en el idioma de la clienta.
    final cases = [
      (
        name: 'futura y confirmada',
        status: SessionStatus.confirmed,
        today: dayBefore,
        arrival: true,
      ),
      (
        name: 'futura y retenida (un presupuesto enviado)',
        status: SessionStatus.held,
        today: dayBefore,
        arrival: true,
      ),
      (
        name: 'de hoy y confirmada',
        status: SessionStatus.confirmed,
        today: sessionDay,
        arrival: true,
      ),
      (
        name: 'de hoy, con la compra hecha',
        status: SessionStatus.shoppingDone,
        today: sessionDay,
        arrival: true,
      ),
      (
        name: 'de ayer y confirmada',
        status: SessionStatus.confirmed,
        today: dayAfter,
        arrival: false,
      ),
      (
        name: 'de la semana pasada, con la compra hecha',
        status: SessionStatus.shoppingDone,
        today: CalendarDate(2026, 12, 2),
        arrival: false,
      ),
      (
        name: 'cocinada, el mismo día',
        status: SessionStatus.cooked,
        today: sessionDay,
        arrival: false,
      ),
      (
        name: 'cobrada, el mismo día',
        status: SessionStatus.paid,
        today: sessionDay,
        arrival: false,
      ),
      // Ya no el saludo del detalle del pedido («Ho ricevuto la tua
      // richiesta…»): es una sesión, y la nombra por su fecha.
      (
        name: 'cancelada (y futura)',
        status: SessionStatus.cancelled,
        today: dayBefore,
        arrival: false,
      ),
    ];
    for (final c in cases) {
      test(
        '${c.name}: ${c.arrival ? 'con' : 'sin'} la hora de llegada, de la cocinera y de un colaborador, en italiano, español e inglés',
        () {
          for (final locale in ClientLocale.values) {
            for (final onBehalf in [false, true]) {
              expect(
                whatsAppText(
                  sessionIn(locale, c.status),
                  onBehalf: onBehalf,
                  today: c.today,
                ),
                expected(locale, onBehalf: onBehalf, arrival: c.arrival),
                reason: '${locale.name}, onBehalf: $onBehalf',
              );
            }
          }
        },
      );
    }
  });

  test(
    'llamar y «Come arrivare» no firman ni dependen del día: son los mismos',
    () {
      for (final appleMaps in [false, true]) {
        SessionLinks links({
          required bool onBehalf,
          required CalendarDate today,
        }) => sessionLinksFor(
          buildSession(),
          chefName: 'Evelyn',
          appleMaps: appleMaps,
          onBehalf: onBehalf,
          today: today,
        );
        final own = links(onBehalf: false, today: dayBefore);
        for (final other in [
          links(onBehalf: true, today: dayBefore),
          links(onBehalf: false, today: dayAfter),
          links(onBehalf: true, today: dayAfter),
        ]) {
          expect(other.call, own.call);
          expect(other.directions, own.directions);
        }
        expect(own.call.toString(), 'tel:+393331234567');
        expect(
          own.directions!.host,
          appleMaps ? 'maps.apple.com' : 'www.google.com',
        );
      }
    },
  );

  test('nunca la dirección, las alergias, las notas, la zona ni el apellido: cocinera o colaborador, con la hora de llegada o sin ella, en todos los estados y en los tres idiomas', () {
    // Una sesión con todo: la dirección de la ficha, sus alérgenos, los del
    // pedido, la dieta, la nota de alergias, las notas de la cocina y del
    // pedido (el portero) y la zona.
    for (final locale in ClientLocale.values) {
      final l10n = lookupAppLocalizations(Locale(locale.name));
      final secrets = [
        'Gombito',
        '24129',
        'Celiachia',
        'noci',
        l10n.allergenGluten,
        l10n.allergenMilk,
        l10n.dietVegetarian,
        'Forno a gas',
        'Citofono',
        'Città Alta',
        'Rossi',
      ];
      for (final status in SessionStatus.values) {
        final session = buildSession(
          status: status,
          locale: locale,
          clientAllergens: const [Allergen.gluten],
          restrictions: const RequestRestrictions(
            allergens: [Allergen.milk],
            diets: [Diet.vegetarian],
            note: 'Celiachia, noci',
          ),
          noAllergies: false,
        );
        for (final today in [dayBefore, sessionDay, dayAfter]) {
          for (final onBehalf in [false, true]) {
            final text = whatsAppText(
              session,
              onBehalf: onBehalf,
              today: today,
            );
            for (final secret in secrets) {
              expect(
                text,
                isNot(contains(secret)),
                reason:
                    '${locale.name}, ${status.name}, hoy $today, '
                    'onBehalf: $onBehalf',
              );
            }
          }
        }
      }
    }
  });

  group('sessionLinksProvider: el mensaje lo eligen ChefAccount.collaborator y el día de hoy en Roma, fuera de la pantalla', () {
    /// Una reserva de 4 semanas desde el miércoles 25/11/2026, con la
    /// segunda (el 2/12) cancelada.
    FakeSessionsRepository booking() => FakeSessionsRepository(
      buildBooking(statuses: {2: SessionStatus.cancelled}),
    );

    /// El WhatsApp de la semana [n], con la cuenta de la cocinera o de un
    /// colaborador suyo, el lunes 19/10/2026 (antes de toda la reserva).
    Future<String> providerText({
      required bool collaborator,
      required int n,
    }) async {
      final container = ProviderContainer.test(
        overrides: [
          clockProvider.overrideWithValue(() => testNow),
          currentChefProvider.overrideWithValue(
            chefAccount.copyWith(collaborator: collaborator),
          ),
          sessionsRepositoryProvider.overrideWithValue(booking()),
          appleMapsProvider.overrideWithValue(false),
        ],
      );
      final id = sessionId(n);
      container.listen(sessionDetailProvider(id), (_, _) {});
      await container.read(sessionDetailProvider(id).future);
      return container
          .read(sessionLinksProvider(id))!
          .whatsApp!
          .queryParameters['text']!;
    }

    test('la cocinera firma y un colaborador escribe de parte de ella; en la cancelada, sin la hora de llegada', () async {
      expect(
        await providerText(collaborator: false, n: 1),
        'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
        'mercoledì 25 novembre, con arrivo alle 10:00.',
      );
      expect(
        await providerText(collaborator: true, n: 1),
        'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione di '
        'mercoledì 25 novembre, con arrivo di Evelyn alle 10:00.',
      );
      expect(
        await providerText(collaborator: false, n: 2),
        'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
        'mercoledì 2 dicembre.',
      );
      expect(
        await providerText(collaborator: true, n: 2),
        'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione di '
        'mercoledì 2 dicembre.',
      );
    });

    testWidgets(
      'el día de hoy es el de Roma: a su medianoche, la ficha abierta deja de anunciar la llegada de la sesión de ese día',
      (tester) async {
        // 23:59:30 del miércoles 25/11/2026 en Roma (hora de invierno,
        // UTC+1): el día de la primera semana, con llegada a las 10:00.
        var now = DateTime.utc(2026, 11, 25, 22, 59, 30);
        // Sin ProviderContainer.test: los Timer se cancelan antes de que el
        // test termine (testWidgets falla si queda alguno pendiente).
        final container = ProviderContainer(
          retry: noRetry,
          overrides: [
            clockProvider.overrideWithValue(() => now),
            currentChefProvider.overrideWithValue(chefAccount),
            sessionsRepositoryProvider.overrideWithValue(booking()),
            appleMapsProvider.overrideWithValue(false),
          ],
        );
        final id = sessionId(1);
        container.listen(sessionLinksProvider(id), (_, _) {});
        await container.read(sessionDetailProvider(id).future);
        String text() => container
            .read(sessionLinksProvider(id))!
            .whatsApp!
            .queryParameters['text']!;

        Future<void> elapse(Duration duration) async {
          now = now.add(duration);
          await tester.pump(duration);
        }

        expect(container.read(romeTodayProvider), sessionDay);
        expect(
          text(),
          'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
          'mercoledì 25 novembre, con arrivo alle 10:00.',
        );

        await elapse(const Duration(seconds: 29));
        expect(text(), contains('con arrivo alle 10:00'));

        // La medianoche en Roma; en UTC todavía son las 23:00 del 25/11.
        await elapse(const Duration(seconds: 1));
        expect(now, DateTime.utc(2026, 11, 25, 23));
        expect(container.read(romeTodayProvider), dayAfter);
        expect(
          text(),
          'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
          'mercoledì 25 novembre.',
        );
        container.dispose();
      },
    );
  });
}
