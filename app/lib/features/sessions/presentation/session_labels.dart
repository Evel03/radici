// Textos de las sesiones: el estado, las horas («Spesa dalle 09:15 · Arrivo
// 10:00 · fino alle 13:00»), los motivos de cancelación y las fallas de mover
// y cancelar. Solo presentación: los textos salen del ARB.
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Qué se estaba haciendo cuando falló (cambia el texto de «sin conexión»).
enum SessionOperation { move, cancel }

extension SessionLabels on AppLocalizations {
  String sessionStatus(SessionStatus status) => switch (status) {
    SessionStatus.held => sessionStatusHeld,
    SessionStatus.confirmed => sessionStatusConfirmed,
    SessionStatus.shoppingDone => sessionStatusShoppingDone,
    SessionStatus.cooked => sessionStatusCooked,
    SessionStatus.paid => sessionStatusPaid,
    SessionStatus.cancelled => sessionStatusCancelled,
  };

  /// «Spesa dalle 09:15 · Arrivo 10:00 · fino alle 13:00», de lo guardado en
  /// la sesión.
  String sessionTimesLine(CookingSession session) {
    final times = session.times;
    return sessionTimes(
      SessionTimes.hhmm(times.shopStart),
      SessionTimes.hhmm(times.arrival),
      SessionTimes.hhmm(times.end),
    );
  }

  String cancelReason(CancelReason reason) => switch (reason) {
    CancelReason.clientCancelled => cancelReasonClient,
    CancelReason.chefUnavailable => cancelReasonUnavailable,
    CancelReason.chefCancelled => cancelReasonOther,
  };

  /// El motivo guardado de una sesión cancelada, si es uno de la app; null
  /// si no (por ejemplo, un presupuesto vencido).
  String? cancelReasonOf(String? code) => switch (CancelReason.fromCode(code)) {
    final reason? => cancelReason(reason),
    null => null,
  };

  /// Qué pasó y qué hacer; [formatDate] escribe la fecha del choque.
  String sessionFailure(
    SessionFailure failure, {
    required SessionOperation operation,
    required String Function(CalendarDate date) formatDate,
  }) {
    final date = failure.date;
    return switch (failure.kind) {
      SessionFailureKind.slotTaken when date != null => sessionErrorSlotTaken(
        formatDate(date),
      ),
      SessionFailureKind.weekTaken when date != null => sessionErrorWeekTaken(
        formatDate(date),
      ),
      SessionFailureKind.notMovable => switch (failure.status) {
        final status? => sessionErrorNotMovable(sessionStatus(status)),
        null => sessionErrorNotMovableUnknown,
      },
      SessionFailureKind.invalidTransition => sessionErrorInvalidTransition,
      SessionFailureKind.hasPayments => cancelHasPaymentsBody(
        failure.sessionIds.isEmpty ? 1 : failure.sessionIds.length,
      ),
      SessionFailureKind.notFound => sessionErrorNotFound,
      SessionFailureKind.forbidden => sessionErrorForbidden,
      SessionFailureKind.unauthorized => bookingErrorUnauthorized,
      SessionFailureKind.invalid => bookingErrorInvalid,
      SessionFailureKind.slotTaken ||
      SessionFailureKind.weekTaken ||
      SessionFailureKind.conflict => sessionErrorConflict,
      SessionFailureKind.unavailable => switch (operation) {
        SessionOperation.move => sessionErrorMoveUnavailable,
        SessionOperation.cancel => sessionErrorCancelUnavailable,
      },
    };
  }
}
