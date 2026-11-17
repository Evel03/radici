// Enlaces de la ficha de la sesión: Mapas según la plataforma (Apple Maps en
// un iPhone o una Mac, también /gestione/ en Safari; Google Maps en el resto)
// y el WhatsApp, en el idioma de la clienta, que en una sesión cancelada no
// nombra la fecha. El WhatsApp sale del teléfono de quien usa la app: si es un
// colaborador de la cocinera, escribe de parte de ella y no dice ser ella ni
// ser quien llega (lo elige sessionLinksProvider con ChefAccount.collaborator).
// Nunca lleva la dirección, las alergias, las notas, la zona ni el apellido.
// La prueba en el iPhone sigue haciendo falta: un test no ve qué plataforma
// reporta Flutter web en Safari.
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/application/session_links.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/l10n/app_localizations.dart';

import '../../../support/fakes.dart';
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

  /// El texto del WhatsApp de [session]; [onBehalf], como un colaborador.
  String whatsAppText(CookingSession session, {bool onBehalf = false}) =>
      sessionLinksFor(
        session,
        chefName: 'Evelyn',
        appleMaps: false,
        onBehalf: onBehalf,
      ).whatsApp!.queryParameters['text']!;

  group('WhatsApp de la cocinera: lo firma ella', () {
    test('de una sesión viva: el día y la hora, en el idioma de la clienta', () {
      expect(
        whatsAppText(buildSession()),
        'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
        'mercoledì 25 novembre, con arrivo alle 10:00.',
      );
      expect(
        whatsAppText(
          buildSession(name: 'Lucía Fernández', locale: ClientLocale.es),
        ),
        'Hola Lucía, soy Evelyn de Radici. Te escribo por la sesión del '
        'miércoles 25 de noviembre, con llegada a las 10:00.',
      );
      expect(
        whatsAppText(buildSession(name: 'Emma Clark', locale: ClientLocale.en)),
        "Hi Emma, this is Evelyn from Radici. I'm writing about the session on "
        'Wednesday, November 25, arriving at 10:00.',
      );
    });

    test('de una cancelada: el saludo del detalle del pedido, sin la fecha', () {
      expect(
        whatsAppText(buildSession(status: SessionStatus.cancelled)),
        'Ciao Giulia, sono Evelyn di Radici. Ho ricevuto la tua richiesta e ti '
        'scrivo per organizzarci.',
      );
      expect(
        whatsAppText(
          buildSession(
            status: SessionStatus.cancelled,
            name: 'Lucía Fernández',
            locale: ClientLocale.es,
          ),
        ),
        'Hola Lucía, soy Evelyn de Radici. Recibí tu solicitud y te escribo '
        'para organizarnos.',
      );
      expect(
        whatsAppText(
          buildSession(
            status: SessionStatus.cancelled,
            name: 'Emma Clark',
            locale: ClientLocale.en,
          ),
        ),
        "Hi Emma, this is Evelyn from Radici. I got your request and I'm "
        'writing to sort out the details.',
      );
    });
  });

  group('WhatsApp de un colaborador, desde su propio teléfono: escribe de parte de la cocinera', () {
    // Ni «sono Evelyn» ni «con arrivo alle…» como si llegara él: la que
    // llega es ella.
    test('de una sesión viva: el día y «Evelyn arriva alle…», en el idioma de la clienta', () {
      expect(
        whatsAppText(buildSession(), onBehalf: true),
        'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione di '
        'mercoledì 25 novembre: Evelyn arriva alle 10:00.',
      );
      expect(
        whatsAppText(
          buildSession(name: 'Lucía Fernández', locale: ClientLocale.es),
          onBehalf: true,
        ),
        'Hola Lucía, te escribo de parte de Evelyn de Radici por la sesión del '
        'miércoles 25 de noviembre: Evelyn llega a las 10:00.',
      );
      expect(
        whatsAppText(
          buildSession(name: 'Emma Clark', locale: ClientLocale.en),
          onBehalf: true,
        ),
        "Hi Emma, I'm writing on behalf of Evelyn from Radici about the session "
        'on Wednesday, November 25: Evelyn will arrive at 10:00.',
      );
    });

    test('de una cancelada: el saludo del detalle de parte de ella, sin la fecha', () {
      expect(
        whatsAppText(
          buildSession(status: SessionStatus.cancelled),
          onBehalf: true,
        ),
        'Ciao Giulia, ti scrivo da parte di Evelyn di Radici: abbiamo ricevuto '
        'la tua richiesta e vorremmo organizzarci con te.',
      );
      expect(
        whatsAppText(
          buildSession(
            status: SessionStatus.cancelled,
            name: 'Lucía Fernández',
            locale: ClientLocale.es,
          ),
          onBehalf: true,
        ),
        'Hola Lucía, te escribo de parte de Evelyn de Radici: recibimos tu '
        'solicitud y queremos organizarnos contigo.',
      );
      expect(
        whatsAppText(
          buildSession(
            status: SessionStatus.cancelled,
            name: 'Emma Clark',
            locale: ClientLocale.en,
          ),
          onBehalf: true,
        ),
        "Hi Emma, I'm writing on behalf of Evelyn from Radici: we got your "
        'request and would like to sort out the details with you.',
      );
    });

    test('llamar y «Come arrivare» no firman: son los mismos', () {
      for (final appleMaps in [false, true]) {
        final own = sessionLinksFor(
          buildSession(),
          chefName: 'Evelyn',
          appleMaps: appleMaps,
        );
        final onBehalf = sessionLinksFor(
          buildSession(),
          chefName: 'Evelyn',
          appleMaps: appleMaps,
          onBehalf: true,
        );
        expect(onBehalf.call, own.call);
        expect(onBehalf.directions, own.directions);
        expect(onBehalf.call.toString(), 'tel:+393331234567');
      }
      expect(
        sessionLinksFor(
          buildSession(),
          chefName: 'Evelyn',
          appleMaps: true,
          onBehalf: true,
        ).directions!.host,
        'maps.apple.com',
      );
    });
  });

  test('nunca la dirección, las alergias, las notas, la zona ni el apellido: cocinera o colaborador, viva o cancelada, en los tres idiomas', () {
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
        for (final onBehalf in [false, true]) {
          final text = whatsAppText(session, onBehalf: onBehalf);
          for (final secret in secrets) {
            expect(
              text,
              isNot(contains(secret)),
              reason: '${locale.name}, ${status.name}, onBehalf: $onBehalf',
            );
          }
        }
      }
    }
  });

  group('sessionLinksProvider: el mensaje lo elige ChefAccount.collaborator, fuera de la pantalla', () {
    /// El WhatsApp de la semana [n] de una reserva de 4 con la segunda
    /// cancelada, con la cuenta de la cocinera o de un colaborador suyo.
    Future<String> providerText({
      required bool collaborator,
      required int n,
    }) async {
      final container = ProviderContainer.test(
        overrides: [
          currentChefProvider.overrideWithValue(
            chefAccount.copyWith(collaborator: collaborator),
          ),
          sessionsRepositoryProvider.overrideWithValue(
            FakeSessionsRepository(
              buildBooking(statuses: {2: SessionStatus.cancelled}),
            ),
          ),
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

    test('la cocinera firma; un colaborador escribe de parte de ella, en una viva y en una cancelada', () async {
      expect(
        await providerText(collaborator: false, n: 1),
        'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
        'mercoledì 25 novembre, con arrivo alle 10:00.',
      );
      expect(
        await providerText(collaborator: true, n: 1),
        'Ciao Giulia, ti scrivo da parte di Evelyn di Radici per la sessione di '
        'mercoledì 25 novembre: Evelyn arriva alle 10:00.',
      );
      expect(
        await providerText(collaborator: false, n: 2),
        'Ciao Giulia, sono Evelyn di Radici. Ho ricevuto la tua richiesta e ti '
        'scrivo per organizzarci.',
      );
      expect(
        await providerText(collaborator: true, n: 2),
        'Ciao Giulia, ti scrivo da parte di Evelyn di Radici: abbiamo ricevuto '
        'la tua richiesta e vorremmo organizzarci con te.',
      );
    });
  });
}
