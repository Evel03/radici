// El WhatsApp de la reserva confirmada va en el idioma de la clienta
// (requests.locale), con las fechas y la hora: nunca la dirección, la zona,
// las notas ni las alergias. Sale del teléfono de quien confirma: si es un
// colaborador de la cocinera, escribe de parte de ella y no dice ser ella.
// En una renovación, a la ficha (no al contacto del pedido renovado).
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/application/booking_message.dart';
import 'package:radici/features/bookings/application/booking_seed.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/bookings/domain/renewal.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/l10n/app_localizations.dart';

import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

BookingResult _booked(List<CalendarDate> dates) => BookingResult(
  dryRun: false,
  duplicate: false,
  requestId: 'req-1',
  clientId: testClientId,
  weeks: [
    for (final (i, date) in dates.indexed)
      BookingWeek(
        date: date,
        start: const ClockTime.hm(10, 0),
        cookMinutes: 240,
        status: BookingDayStatus.ok,
        suggestedStart: const ClockTime.hm(10, 0),
        serviceCents: 14000,
        sessionId: 'session-$i',
      ),
  ],
);

void main() {
  final monday = CalendarDate(2026, 11, 23);

  setUpAll(initializeDateFormatting);

  test('clienta italiana, 4 semanas: una fecha por línea y la hora', () {
    final uri = bookingWhatsAppUri(
      request: buildRequest(
        restrictions: const RequestRestrictions(note: 'niente funghi'),
      ),
      result: _booked(weeklyDates(monday, 4)),
      chefName: 'Evelyn',
    )!;
    expect(uri.host, 'wa.me');
    expect(uri.path, '/393331234567');
    final text = uri.queryParameters['text']!;
    // La hora va después de la lista: «alle 10:00:» antes de la lista se
    // leía raro.
    expect(
      text,
      'Ciao Giulia, sono Evelyn di Radici. Ti confermo le 4 sessioni di cucina:\n'
      '• lunedì 23 novembre\n'
      '• lunedì 30 novembre\n'
      '• lunedì 7 dicembre\n'
      '• lunedì 14 dicembre\n'
      'Arrivo alle 10:00. A presto!',
    );
    // Ni la nota de alergias, ni las notas (el portero), ni la zona.
    for (final secret in ['funghi', 'Citofono', 'Città Alta', 'Rossi']) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
  });

  test('clienta hispanohablante, una sola semana: en español aunque la app esté en italiano', () {
    final uri = bookingWhatsAppUri(
      request: buildRequest(
        name: 'Lucía Fernández',
        phone: '+34 612 345 678',
        locale: ClientLocale.es,
      ),
      result: _booked([monday]),
      chefName: 'Evelyn',
    )!;
    expect(uri.path, '/34612345678');
    // En prosa, sin la coma de intl («del lunes, 23 de noviembre»).
    expect(
      uri.queryParameters['text'],
      'Hola Lucía, soy Evelyn de Radici. Te confirmo la sesión de cocina del '
      'lunes 23 de noviembre, con llegada a las 10:00. ¡Hasta pronto!',
    );
  });

  test('clienta hispanohablante, varias semanas', () {
    final uri = bookingWhatsAppUri(
      request: buildRequest(
        name: 'Lucía Fernández',
        phone: '+34 612 345 678',
        locale: ClientLocale.es,
      ),
      result: _booked(weeklyDates(monday, 2)),
      chefName: 'Evelyn',
    )!;
    expect(
      uri.queryParameters['text'],
      'Hola Lucía, soy Evelyn de Radici. Te confirmo las 2 sesiones de cocina:\n'
      '• lunes 23 de noviembre\n'
      '• lunes 30 de noviembre\n'
      'Llego a las 10:00. ¡Hasta pronto!',
    );
  });

  test('en inglés', () {
    final uri = bookingWhatsAppUri(
      request: buildRequest(name: 'Emma Clark', locale: ClientLocale.en),
      result: _booked(weeklyDates(monday, 2)),
      chefName: 'Evelyn',
    )!;
    expect(
      uri.queryParameters['text'],
      "Hi Emma, this is Evelyn from Radici. I'm confirming your 2 cooking "
      'sessions:\n'
      '• Monday, November 23\n'
      '• Monday, November 30\n'
      "I'll arrive at 10:00. See you soon!",
    );
  });

  test('clienta italiana, una sola semana', () {
    final uri = bookingWhatsAppUri(
      request: buildRequest(),
      result: _booked([monday]),
      chefName: 'Evelyn',
    )!;
    expect(
      uri.queryParameters['text'],
      'Ciao Giulia, sono Evelyn di Radici. Ti confermo la sessione di cucina '
      'di lunedì 23 novembre, con arrivo alle 10:00. A presto!',
    );
  });

  test('en inglés, una sola semana', () {
    final uri = bookingWhatsAppUri(
      request: buildRequest(name: 'Emma Clark', locale: ClientLocale.en),
      result: _booked([monday]),
      chefName: 'Evelyn',
    )!;
    expect(
      uri.queryParameters['text'],
      "Hi Emma, this is Evelyn from Radici. I'm confirming your cooking "
      'session on Monday, November 23, arriving at 10:00. See you soon!',
    );
  });

  group('un colaborador de la cocinera, desde su propio teléfono: escribe de parte de ella', () {
    // Ni «sono Evelyn» ni «Arrivo alle…»: la que llega es ella.
    String message({
      required String name,
      required ClientLocale locale,
      required int weeks,
    }) {
      final uri = bookingWhatsAppUri(
        request: buildRequest(name: name, locale: locale),
        result: _booked(weeklyDates(monday, weeks)),
        chefName: 'Evelyn',
        onBehalf: true,
      )!;
      expect(uri.path, '/393331234567');
      return uri.queryParameters['text']!;
    }

    test('clienta italiana, una semana y varias', () {
      expect(
        message(name: 'Giulia Rossi', locale: ClientLocale.it, weeks: 1),
        'Ciao Giulia, ti scrivo da parte di Evelyn di Radici. Ti confermiamo '
        'la sessione di cucina di lunedì 23 novembre, con arrivo alle 10:00. '
        'A presto!',
      );
      expect(
        message(name: 'Giulia Rossi', locale: ClientLocale.it, weeks: 3),
        'Ciao Giulia, ti scrivo da parte di Evelyn di Radici. Ti confermiamo '
        'le 3 sessioni di cucina:\n'
        '• lunedì 23 novembre\n'
        '• lunedì 30 novembre\n'
        '• lunedì 7 dicembre\n'
        'Evelyn arriva alle 10:00. A presto!',
      );
    });

    test('clienta hispanohablante, una semana y varias', () {
      expect(
        message(name: 'Lucía Fernández', locale: ClientLocale.es, weeks: 1),
        'Hola Lucía, te escribo de parte de Evelyn de Radici. Te confirmamos '
        'la sesión de cocina del lunes 23 de noviembre, con llegada a las '
        '10:00. ¡Hasta pronto!',
      );
      expect(
        message(name: 'Lucía Fernández', locale: ClientLocale.es, weeks: 2),
        'Hola Lucía, te escribo de parte de Evelyn de Radici. Te confirmamos '
        'las 2 sesiones de cocina:\n'
        '• lunes 23 de noviembre\n'
        '• lunes 30 de noviembre\n'
        'Evelyn llega a las 10:00. ¡Hasta pronto!',
      );
    });

    test('en inglés, una semana y varias', () {
      expect(
        message(name: 'Emma Clark', locale: ClientLocale.en, weeks: 1),
        "Hi Emma, I'm writing on behalf of Evelyn from Radici. We're "
        'confirming your cooking session on Monday, November 23, with Evelyn '
        'arriving at 10:00. See you soon!',
      );
      expect(
        message(name: 'Emma Clark', locale: ClientLocale.en, weeks: 2),
        "Hi Emma, I'm writing on behalf of Evelyn from Radici. We're "
        'confirming your 2 cooking sessions:\n'
        '• Monday, November 23\n'
        '• Monday, November 30\n'
        'Evelyn will arrive at 10:00. See you soon!',
      );
    });
  });

  test('nunca la dirección ni las alergias: cocinera o colaborador, una semana o varias, en los tres idiomas', () {
    // Un pedido con todo: alérgenos, dieta, la nota de alergias, las notas
    // (el portero) y la zona, lo más parecido a una dirección que tiene.
    const restrictions = RequestRestrictions(
      allergens: [Allergen.milk, Allergen.gluten],
      diets: [Diet.vegetarian],
      note: 'niente funghi',
    );
    for (final locale in ClientLocale.values) {
      final l10n = lookupAppLocalizations(Locale(locale.name));
      final secrets = [
        'funghi',
        l10n.allergenMilk,
        l10n.allergenGluten,
        l10n.dietVegetarian,
        'Citofono',
        'Città Alta',
        'Rossi',
      ];
      for (final onBehalf in [false, true]) {
        for (final weeks in [1, 4]) {
          final text = bookingWhatsAppUri(
            request: buildRequest(
              locale: locale,
              restrictions: restrictions,
              noAllergies: false,
            ),
            result: _booked(weeklyDates(monday, weeks)),
            chefName: 'Evelyn',
            onBehalf: onBehalf,
          )!.queryParameters['text']!;
          for (final secret in secrets) {
            expect(
              text,
              isNot(contains(secret)),
              reason: '${locale.name}, onBehalf: $onBehalf, $weeks semanas',
            );
          }
        }
      }
    }
  });

  group('para quien dice la hoja (bookingWhatsAppUriFor)', () {
    test('una ficha nueva con «333 123 4567» y en español', () {
      final uri = bookingWhatsAppUriFor(
        party: const BookingParty(
          displayName: 'Giulia Rossi',
          phoneText: '333 123 4567',
          phoneE164: '+393331234567',
        ),
        locale: ClientLocale.es,
        result: _booked(weeklyDates(monday, 4)),
        chefName: 'Evelyn',
      )!;
      expect(uri.host, 'wa.me');
      expect(uri.path, '/393331234567');
      expect(
        uri.queryParameters['text'],
        startsWith(
          'Hola Giulia, soy Evelyn de Radici. Te confirmo las 4 sesiones de cocina:',
        ),
      );
    });

    test('sin teléfono, null', () {
      expect(
        bookingWhatsAppUriFor(
          party: const BookingParty(displayName: 'Giulia Rossi'),
          locale: ClientLocale.it,
          result: _booked([monday]),
          chefName: 'Evelyn',
        ),
        isNull,
      );
    });

    test('un colaborador escribe de parte de ella', () {
      final text = bookingWhatsAppUriFor(
        party: const BookingParty(
          displayName: 'Chiara Rossi',
          phoneE164: '+393401112233',
        ),
        locale: ClientLocale.it,
        result: _booked([monday]),
        chefName: 'Evelyn',
        onBehalf: true,
      )!.queryParameters['text']!;
      expect(
        text,
        startsWith('Ciao Chiara, ti scrivo da parte di Evelyn di Radici.'),
      );
    });

    test('una renovación: el nombre y el teléfono de la ficha (no los del contacto del pedido renovado) y el idioma del pedido', () {
      final booking = [
        for (final session in buildBooking(locale: ClientLocale.es))
          session.copyWith(
            request: session.request!.copyWith(
              client: session.request!.client.copyWith(
                displayName: 'Giuly Bianchi',
                contactPhone: '+34 612 345 678',
              ),
            ),
          ),
      ];
      final seed = BookingSeed.renewal(renewalPlan(booking)!, today: monday);
      final uri = bookingWhatsAppUriFor(
        party: seed.party,
        locale: seed.locale,
        result: _booked(seed.dates),
        chefName: 'Evelyn',
      )!;
      expect(uri.path, '/393331234567');
      expect(
        uri.queryParameters['text'],
        startsWith(
          'Hola Giulia, soy Evelyn de Radici. Te confirmo las 4 sesiones de cocina:',
        ),
      );
    });

    test('desde un pedido, el destinatario y el idioma son los del pedido', () {
      final request = buildRequest(locale: ClientLocale.en);
      expect(
        bookingWhatsAppUri(
          request: request,
          result: _booked([monday]),
          chefName: 'Evelyn',
        ),
        bookingWhatsAppUriFor(
          party: BookingParty.fromRequest(request),
          locale: ClientLocale.en,
          result: _booked([monday]),
          chefName: 'Evelyn',
        ),
      );
    });
  });

  test('sin un teléfono válido no hay WhatsApp', () {
    expect(
      bookingWhatsAppUri(
        request: buildRequest(phone: '612 345 678'),
        result: _booked([monday]),
        chefName: 'Evelyn',
      ),
      isNull,
    );
    expect(
      bookingWhatsAppUri(
        request: buildRequest(phone: null),
        result: _booked([monday]),
        chefName: 'Evelyn',
        onBehalf: true,
      ),
      isNull,
    );
  });
}
