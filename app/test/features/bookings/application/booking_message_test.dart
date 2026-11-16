// El WhatsApp de la reserva confirmada va en el idioma de la clienta
// (requests.locale), con las fechas y la hora: nunca la dirección, la zona,
// las notas ni las alergias.
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/application/booking_message.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/request_fixtures.dart';

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
    expect(
      text,
      'Ciao Giulia, sono Evelyn di Radici. Ti confermo le 4 sessioni di cucina, '
      'con arrivo alle 10:00:\n'
      '• lunedì 23 novembre\n'
      '• lunedì 30 novembre\n'
      '• lunedì 7 dicembre\n'
      '• lunedì 14 dicembre\n'
      'A presto!',
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
    expect(
      uri.queryParameters['text'],
      'Hola Lucía, soy Evelyn de Radici. Te confirmo la sesión de cocina del '
      'lunes, 23 de noviembre, con llegada a las 10:00. ¡Hasta pronto!',
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
      'sessions, arriving at 10:00:\n'
      '• Monday, November 23\n'
      '• Monday, November 30\n'
      'See you soon!',
    );
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
      ),
      isNull,
    );
  });
}
