// Textos de la hoja «Conferma prenotazione» en italiano: cada estado de una
// semana, cada falla y la barra de abajo (el precio que se confirma o lo que
// impide confirmar). arb_keys_test vigila que las claves existan; esto, qué
// texto sale en cada caso.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/application/confirm_booking_controller.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/bookings/presentation/booking_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// intl separa el número del € con un espacio duro.
const String _nbsp = ' ';

void main() {
  late AppLocalizations it;
  final monday = CalendarDate(2026, 11, 23);

  setUpAll(() async {
    it = await AppLocalizations.delegate.load(const Locale('it'));
  });

  /// Una hoja de [weeks] semanas desde [monday], a las 10:00, con 560 €
  /// propuestos (o lo que se cambie).
  ConfirmBookingState sheet({
    int weeks = 4,
    int? suggested = 56000,
    ClockTime? start = const ClockTime.hm(10, 0),
  }) => ConfirmBookingState(
    today: CalendarDate(2026, 10, 19),
    maxWeeks: maxBookingWeeks,
    dates: weeklyDates(monday, weeks),
    start: start,
    cookMinutes: 180,
    suggestedPriceCents: suggested,
  );

  /// [state] con el dryRun de lo que tiene, con [statuses] por semana.
  ConfirmBookingState checked(
    ConfirmBookingState state,
    List<BookingDayStatus> statuses,
  ) {
    final next = state.copyWith(
      checksStatus: BookingChecksStatus.ready,
      checks: [
        for (final (i, status) in statuses.indexed)
          BookingWeek(
            date: state.dates[i],
            start: state.start,
            cookMinutes: state.cookMinutes,
            status: status,
            serviceCents: 0,
          ),
      ],
    );
    return next.copyWith(checksKey: next.inputKey);
  }

  test('cada estado de una semana', () {
    expect(
      {for (final s in BookingDayStatus.values) s: it.bookingDayStatus(s)},
      {
        BookingDayStatus.busy: "Si sovrappone a un'altra sessione",
        BookingDayStatus.past: 'Data passata',
        BookingDayStatus.blocked: 'Giorno bloccato',
        BookingDayStatus.closed: 'Non lavori quel giorno',
        BookingDayStatus.outside: 'Fuori dal tuo orario',
        BookingDayStatus.ok: 'Libero',
      },
    );
  });

  test('cada falla, con la fecha o el estado cuando los hay', () {
    String text(BookingFailure failure) =>
        it.bookingFailure(failure, formatDate: (date) => date.toIso());
    final date = CalendarDate(2026, 11, 30);
    expect(
      text(BookingFailure(BookingFailureKind.slotTaken, date: date)),
      "La settimana del 2026-11-30 si sovrappone a un'altra sessione: non è "
      "stato creato nulla. Cambia quella data o l'ora.",
    );
    expect(
      text(BookingFailure(BookingFailureKind.weekTaken, date: date)),
      'La settimana del 2026-11-30 ha già una sessione di questa '
      'prenotazione: non è stato creato nulla.',
    );
    // Sin fecha (no debería pasar), el choque genérico.
    for (final kind in [
      BookingFailureKind.slotTaken,
      BookingFailureKind.weekTaken,
      BookingFailureKind.conflict,
    ]) {
      expect(
        text(BookingFailure(kind)),
        'Non è stato possibile confermare per una sovrapposizione: controlla '
        'le date e riprova.',
        reason: kind.name,
      );
    }
    // Ya es una reserva (otro dispositivo, o un intento sin respuesta).
    expect(
      text(
        const BookingFailure(
          BookingFailureKind.requestNotNew,
          requestStatus: 'accepted',
        ),
      ),
      'Questa richiesta è già una prenotazione (in Prenotazioni): non è stato '
      "creato nient'altro.",
    );
    expect(
      text(
        const BookingFailure(
          BookingFailureKind.requestNotNew,
          requestStatus: 'rejected',
        ),
      ),
      'Questa richiesta è già «Rifiutata»: non è stato creato nulla.',
    );
    expect(
      text(const BookingFailure(BookingFailureKind.requestNotNew)),
      'La richiesta è cambiata nel frattempo: controlla il suo stato.',
    );
    expect(
      text(const BookingFailure(BookingFailureKind.notFound)),
      'Questa richiesta non esiste più.',
    );
    expect(
      text(const BookingFailure(BookingFailureKind.forbidden)),
      'Il tuo account non può confermare prenotazioni.',
    );
    // Sin «sessione»: en esta hoja es una sesión de cocina.
    expect(
      text(const BookingFailure(BookingFailureKind.unauthorized)),
      "L'accesso è scaduto: esci e rientra.",
    );
    expect(
      text(const BookingFailure(BookingFailureKind.invalid)),
      'Alcuni dati non sono validi: controllali e riprova.',
    );
    expect(
      text(const BookingFailure(BookingFailureKind.unavailable)),
      'Non è stato possibile confermare. Controlla la connessione e riprova '
      'con gli stessi dati: se era già confermata, non si duplica.',
    );
  });

  group('barra de abajo', () {
    test('el precio que se confirma, lo que queda por semana y la llegada', () {
      expect(
        it.bookingSummary(sheet(), locale: 'it'),
        'Servizio 560,00$_nbsp€ · 140,00$_nbsp€ a settimana · arrivo 10:00',
      );
      // Una división que no es exacta: aproximada.
      expect(
        it.bookingSummary(
          sheet(weeks: 3).copyWith(priceText: '500', priceEdited: true),
          locale: 'it',
        ),
        'Servizio 500,00$_nbsp€ · ≈ 166,67$_nbsp€ a settimana · arrivo 10:00',
      );
      // Una sola semana: sin «a settimana»; sin hora todavía: sin llegada.
      expect(
        it.bookingSummary(sheet(weeks: 1, suggested: 15000), locale: 'it'),
        'Servizio 150,00$_nbsp€ · arrivo 10:00',
      );
      expect(
        it.bookingSummary(sheet(start: null), locale: 'it'),
        'Servizio 560,00$_nbsp€ · 140,00$_nbsp€ a settimana',
      );
      expect(it.bookingSummary(sheet(suggested: null), locale: 'it'), isEmpty);
    });

    test('lo que impide confirmar: el precio', () {
      String blocker(ConfirmBookingState state) =>
          it.bookingBlockerText(state, state.blocker!, locale: 'it');
      expect(blocker(sheet(suggested: null)), 'Manca il prezzo del servizio.');
      expect(
        blocker(sheet().copyWith(priceText: '56,0,5', priceEdited: true)),
        'Il prezzo non è un importo valido.',
      );
      expect(
        blocker(sheet().copyWith(priceText: '100.001', priceEdited: true)),
        'Il prezzo supera il massimo di 100.000,00$_nbsp€.',
      );
    });

    test('lo que impide confirmar: una semana que choca o una fecha que no se puede mandar', () {
      String blocker(ConfirmBookingState state) =>
          it.bookingBlockerText(state, state.blocker!, locale: 'it');
      final eight = sheet(weeks: 8);
      expect(
        blocker(
          checked(eight, [
            for (var i = 0; i < 8; i++)
              i == 5 ? BookingDayStatus.busy : BookingDayStatus.ok,
          ]),
        ),
        "Settimana 6 · Si sovrappone a un'altra sessione: cambia quella data "
        "o l'ora.",
      );
      // Con una sola fecha no se nombra la semana.
      expect(
        blocker(checked(sheet(weeks: 1), [BookingDayStatus.busy])),
        "Si sovrappone a un'altra sessione: cambia quella data o l'ora.",
      );
      expect(
        blocker(
          sheet().copyWith(
            dates: [monday, monday.addDays(2), ...weeklyDates(monday, 4).skip(2)],
          ),
        ),
        'Settimana 2 · Stessa settimana della data precedente: una sessione '
        'a settimana.',
      );
    });
  });
}
