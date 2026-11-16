// Textos de la hoja «Conferma prenotazione»: lo que dijo el servidor de cada
// semana, lo que impide mandar una fecha y las fallas. Solo presentación: los
// textos salen del ARB.
import 'package:radici/core/rome_time.dart';
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
    };
  }
}
