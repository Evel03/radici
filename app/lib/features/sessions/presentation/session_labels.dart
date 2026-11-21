// Textos de las sesiones: el estado, las horas («Arrivo 10:00 · fino alle
// 13:00»), las fechas dentro de una frase, los motivos de cancelación y las
// fallas de mover y cancelar. Solo presentación: los textos salen del ARB.
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Qué se estaba haciendo cuando falló (cambia el texto de «sin conexión»).
enum SessionOperation { move, cancel }

/// Espacio que no corta.
const String _nbsp = '\u00a0';

/// Separador de los tramos en el ARB («Arrivo {arrival} · fino alle …»).
const String _timesSeparator = ' · ';

/// El mismo separador en lo que se muestra: el renglón se parte solo en su
/// espacio común, después del «·» (nunca deja un «·» al principio).
const String _breakSeparator = '$_nbsp· ';

extension SessionLabels on AppLocalizations {
  /// El estado como se muestra ([SessionStatus.shown]): una sesión vieja en
  /// shopping_done dice «Confermata», no que la cocinera hizo la compra.
  String sessionStatus(SessionStatus status) => switch (status) {
    SessionStatus.held => sessionStatusHeld,
    SessionStatus.confirmed ||
    SessionStatus.shoppingDone => sessionStatusConfirmed,
    SessionStatus.cooked => sessionStatusCooked,
    SessionStatus.paid => sessionStatusPaid,
    SessionStatus.cancelled => sessionStatusCancelled,
  };

  /// «Arrivo 10:00 · fino alle 13:00», de lo guardado en la sesión (la
  /// compra de una sesión de antes del 19/11/2026 no se muestra). Cada tramo
  /// va con espacios que no cortan: en un teléfono el renglón se parte
  /// después de un «·», nunca entre «fino alle» y la hora.
  String sessionTimesLine(CookingSession session) {
    final times = session.times;
    final line = sessionTimes(
      SessionTimes.hhmm(times.arrival),
      SessionTimes.hhmm(times.end),
    );
    return [
      for (final part in line.split(_timesSeparator))
        part.replaceAll(' ', _nbsp),
    ].join(_breakSeparator);
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
      // Una sesión vieja en shopping_done tampoco se mueve, pero se muestra
      // como confirmada: «è «Confermata»: non si può più spostare» no se
      // entendería.
      SessionFailureKind.notMovable => switch (failure.status?.shown) {
        final status? when status != SessionStatus.confirmed =>
          sessionErrorNotMovable(sessionStatus(status)),
        _ => sessionErrorNotMovableUnknown,
      },
      SessionFailureKind.invalidTransition => sessionErrorInvalidTransition,
      // La ficha lo explica con un diálogo (cuáles y qué hacer); esto es para
      // cuando no puede.
      SessionFailureKind.hasPayments => sessionErrorHasPayments,
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

/// Fechas de las sesiones en el idioma de la interfaz.
class SessionFormats {
  SessionFormats(BuildContext context)
    : _locale = Localizations.localeOf(context);

  final Locale _locale;

  /// Fecha corta dentro de una frase: «mer 2 dic», «Wed, Dec 2» y, en
  /// español, «mié 2 de dic» (sin la coma del formato de intl, que en una
  /// frase se lee como una pausa: «Mover al mié, 2 dic»). Fuera del español,
  /// la misma que RequestFormats.shortDate.
  String inText(CalendarDate date) {
    final format = _locale.languageCode == 'es'
        ? DateFormat("EEE d 'de' MMM", 'es')
        : DateFormat.MMMEd(_locale.toLanguageTag());
    return format.format(date.toDateTime());
  }

  /// Varias fechas de [inText] en un renglón: cada una con espacios que no
  /// cortan, separadas por «·» (el renglón se parte entre dos fechas, después
  /// del «·»).
  String listInText(Iterable<CalendarDate> dates) => [
    for (final date in dates) inText(date).replaceAll(' ', _nbsp),
  ].join(_breakSeparator);
}
