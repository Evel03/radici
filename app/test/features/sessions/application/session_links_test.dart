// Enlaces de la ficha de la sesión: Mapas según la plataforma (Apple Maps en
// un iPhone o una Mac, también /gestione/ en Safari; Google Maps en el resto)
// y el WhatsApp, que en una sesión cancelada no nombra la fecha. La prueba en
// el iPhone sigue haciendo falta: un test no ve qué plataforma reporta Flutter
// web en Safari.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/application/session_links.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

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

  group('WhatsApp', () {
    test('de una sesión viva: el día y la hora, en el idioma de la clienta', () {
      final links = sessionLinksFor(
        buildSession(locale: ClientLocale.it),
        chefName: 'Evelyn',
        appleMaps: false,
      );
      expect(
        links.whatsApp!.queryParameters['text'],
        'Ciao Giulia, sono Evelyn di Radici. Ti scrivo per la sessione di '
        'mercoledì 25 novembre, con arrivo alle 10:00.',
      );
    });

    test('de una cancelada: el saludo de siempre, sin la fecha', () {
      final links = sessionLinksFor(
        buildSession(status: SessionStatus.cancelled),
        chefName: 'Evelyn',
        appleMaps: false,
      );
      final text = links.whatsApp!.queryParameters['text']!;
      expect(text, startsWith('Ciao Giulia, sono Evelyn di Radici.'));
      expect(text, isNot(contains('25 novembre')));
      expect(text, isNot(contains('10:00')));
    });

    test('nunca la dirección ni las alergias', () {
      final links = sessionLinksFor(
        buildSession(restrictions: webRestrictions),
        chefName: 'Evelyn',
        appleMaps: true,
      );
      final text = links.whatsApp!.queryParameters['text']!;
      expect(text, isNot(contains('Gombito')));
      expect(text, isNot(contains('Celiachia')));
      expect(links.directions!.host, 'maps.apple.com');
      expect(links.call.toString(), 'tel:+393331234567');
    });
  });
}
