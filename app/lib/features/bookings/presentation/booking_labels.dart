// Textos de la hoja «Conferma prenotazione» (también «Preparar
// presupuesto»): lo que dijo el servidor de cada semana, lo que impide mandar
// una fecha, las fallas, el reparto del precio y la barra de abajo (el precio
// que se va a confirmar o lo que impide confirmar). Solo presentación: los
// textos salen del ARB.
import 'package:radici/core/money.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/application/confirm_booking_controller.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/l10n/app_localizations.dart';

extension BookingLabels on AppLocalizations {
  String bookingDayStatus(BookingDayStatus status) => switch (status) {
    BookingDayStatus.ok => bookingStatusOk,
    BookingDayStatus.busy => bookingStatusBusy,
    BookingDayStatus.past => bookingStatusPast,
    BookingDayStatus.blocked => bookingStatusBlocked,
    BookingDayStatus.closed => bookingStatusClosed,
    BookingDayStatus.outside => bookingStatusOutside,
  };

  String bookingDateIssue(BookingDateIssue issue) => switch (issue) {
    BookingDateIssue.sameWeek => bookingDateSameWeek,
    BookingDateIssue.order => bookingDateOrder,
    BookingDateIssue.outOfRange => bookingDateOutOfRange,
  };

  /// El estado de un pedido como lo escribe la base (`accepted`…), con el
  /// texto de la bandeja; null si no es uno conocido.
  String? requestStatusLabel(String? status) => switch (status) {
    'new' => requestStatusNew,
    'quoted' => requestStatusQuoted,
    'accepted' => requestStatusAccepted,
    'declined' => requestStatusDeclined,
    'rejected' => requestStatusRejected,
    'expired' => requestStatusExpired,
    'resolved' => requestStatusResolved,
    _ => null,
  };

  /// Qué pasó y qué hacer; [formatDate] escribe la fecha del choque.
  String bookingFailure(
    BookingFailure failure, {
    required String Function(CalendarDate date) formatDate,
  }) {
    final date = failure.date;
    return switch (failure.kind) {
      BookingFailureKind.slotTaken when date != null => bookingErrorSlotTaken(
        formatDate(date),
      ),
      BookingFailureKind.weekTaken when date != null => bookingErrorWeekTaken(
        formatDate(date),
      ),
      BookingFailureKind.slotTaken ||
      BookingFailureKind.weekTaken ||
      BookingFailureKind.conflict => bookingErrorConflict,
      // Ya es una reserva: de otro dispositivo o de un intento anterior que
      // se quedó sin respuesta. Esta hoja no creó nada más.
      BookingFailureKind.requestNotNew
          when failure.requestStatus == 'accepted' =>
        bookingErrorAlreadyBooked,
      BookingFailureKind.requestNotNew => switch (requestStatusLabel(
        failure.requestStatus,
      )) {
        final status? => bookingErrorNotNew(status),
        null => rejectConflict,
      },
      BookingFailureKind.notFound => bookingErrorNotFound,
      BookingFailureKind.forbidden => bookingErrorForbidden,
      BookingFailureKind.unauthorized => bookingErrorUnauthorized,
      BookingFailureKind.invalid => bookingErrorInvalid,
      BookingFailureKind.unavailable => bookingErrorUnavailable,
      BookingFailureKind.quoteExists => bookingErrorQuoteExists,
      BookingFailureKind.requestNotQuotable => bookingErrorNotQuotable,
    };
  }

  /// La falla de la barra de la hoja [state]: a mano, los datos de la ficha
  /// nueva que el servidor rechaza (se corrigen en el formulario); a mano o
  /// al renovar, la ficha que ya no está; al preparar un presupuesto, uno que
  /// no se sabe si se creó; si no, [bookingFailure].
  String bookingFailureText(
    ConfirmBookingState state,
    BookingFailure failure, {
    required String Function(CalendarDate date) formatDate,
  }) {
    if (state.newClientRejected) return bookingErrorNewClientInvalid;
    if (state.createsRequest && failure.kind == BookingFailureKind.notFound) {
      return bookingErrorClientNotFound;
    }
    if (state.isQuote && failure.kind == BookingFailureKind.unavailable) {
      return quoteErrorCreateUnavailable;
    }
    return bookingFailure(failure, formatDate: formatDate);
  }

  /// Debajo del precio de un presupuesto de varias semanas, cuánto queda en
  /// cada una, exactamente como lo va a guardar la base
  /// ([splitServiceCents]): «= 140,00 € por semana» si se divide justo; si
  /// no, «Por semana: 166,67 € · 166,67 € · 166,66 €». null con una semana.
  String? quotePriceSplitText(
    int totalCents,
    int weeks, {
    required String locale,
  }) {
    if (weeks < 2) return null;
    final split = splitServiceCents(totalCents, weeks);
    if (split.toSet().length == 1) {
      return bookingPricePerWeek(formatCents(split.first, locale: locale));
    }
    return quotePriceSplit(
      [
        for (final cents in split)
          formatCents(cents, locale: locale).replaceAll(' ', ' '),
      ].join(' · '),
    );
  }

  /// La barra de abajo: lo que impide confirmar ([blocker], de
  /// [ConfirmBookingState.blocker]). Con más de una fecha, de qué semana.
  String bookingBlockerText(
    ConfirmBookingState state,
    BookingBlocker blocker, {
    required String locale,
  }) {
    final String problem;
    switch (blocker.kind) {
      case BookingBlockKind.price:
        return switch (state.priceIssue) {
          BookingPriceIssue.invalid => bookingBlockPriceInvalid,
          BookingPriceIssue.tooHigh => bookingBlockPriceTooHigh(
            formatCents(maxBookingCents, locale: locale),
          ),
          BookingPriceIssue.required || null => bookingBlockPriceMissing,
        };
      case BookingBlockKind.date:
        problem = bookingDateIssue(state.dateIssues[blocker.week!]!);
      case BookingBlockKind.clash:
        problem = bookingBlockClash;
    }
    return state.weeks > 1
        ? bookingWeekProblem(blocker.week! + 1, problem)
        : problem;
  }

  /// La barra de abajo: el precio del servicio que se va a confirmar (después
  /// ninguna ruta lo cambia), lo que queda por semana y la llegada:
  /// «Servizio 560,00 € · 140,00 € a settimana · arrivo 10:00». Vacío sin
  /// precio válido.
  String bookingSummary(ConfirmBookingState state, {required String locale}) {
    final cents = state.serviceTotalCents;
    if (cents == null) return '';
    final parts = [bookingSummaryService(formatCents(cents, locale: locale))];
    if (state.weeks > 1) {
      final share = weeklyShare(cents, state.weeks);
      final amount = formatCents(share.firstWeekCents, locale: locale);
      parts.add(
        share.even
            ? bookingSummaryPerWeek(amount)
            : bookingSummaryPerWeekApprox(amount),
      );
    }
    if (state.start case final start?) {
      parts.add(bookingSummaryArrival(start.toHhMm()));
    }
    return parts.join(' · ');
  }
}
