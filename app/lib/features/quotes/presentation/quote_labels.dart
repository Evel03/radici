// Textos del presupuesto de un pedido: su estado (cuándo salió, hasta cuándo
// puede aceptarlo la clienta o, si no puede hasta que se lo manden de nuevo,
// hasta cuándo hay que reenviarlo; qué pasó), por qué no se pudo cambiar el
// precio o retirarlo y, en la vista previa del menú de la semana 1, hasta
// cuándo lo puede aceptar si sale ahora. Con una sola semana hablan de una
// fecha. Fechas y horas en hora de Roma. Solo presentación: los textos salen
// del ARB.
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/quotes/data/quotes_repository.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Qué se estaba haciendo con el presupuesto cuando falló.
enum QuoteOperation { changePrice, withdraw }

extension QuoteLabels on AppLocalizations {
  /// El renglón del estado de [quote] en [status]: «Borrador sin mandar…»,
  /// «Mandado el 22/11 a las 14:32 (versión 2).», «Lo cambiaste después de
  /// mandarlo…», «La clienta lo aceptó el…»… Vencido después de que la
  /// clienta pidió cambios no dice «sin respuesta»: dice que no le llegó la
  /// versión con los cambios. [formats] escribe las fechas y las horas (Roma).
  String quoteStateText(
    RequestQuote quote,
    QuoteStatus status,
    RequestFormats formats,
  ) {
    String date(DateTime instant) => formats.instantDayMonth(instant);
    String time(DateTime instant) => formats.instantTime(instant);
    final closed = quote.closedOn(status);
    final weeks = quote.weekCountFor(status);
    return switch (status) {
      QuoteStatus.draft => switch (quote.holdUntil) {
        final hold? => quoteStateDraft(date(hold), time(hold), weeks),
        null => quoteStateDraftShort,
      },
      QuoteStatus.sent ||
      QuoteStatus.changesRequested ||
      QuoteStatus.changed => switch (quote.lastSentOn) {
        final sent? => quoteStateSent(quote.version, date(sent), time(sent)),
        null => quoteStateChanged,
      },
      QuoteStatus.accepted when closed != null => quoteStateAccepted(
        date(closed),
        time(closed),
      ),
      QuoteStatus.declined when closed != null => quoteStateDeclined(
        date(closed),
        time(closed),
      ),
      QuoteStatus.withdrawn when closed != null => quoteStateWithdrawn(
        date(closed),
        time(closed),
        weeks,
      ),
      QuoteStatus.expired when closed != null =>
        !quote.wasSent
            ? quoteStateDraftExpired(date(closed), time(closed), weeks)
            // La clienta contestó: pidió cambios y le tocaba a Evelyn.
            : quote.changesRequested
            ? quoteStateExpiredChanges(date(closed), time(closed), weeks)
            : quoteStateExpired(date(closed), time(closed), weeks),
      // Cerrado sin la fecha (no debería pasar): el estado del pedido.
      QuoteStatus.accepted => requestStatusAccepted,
      QuoteStatus.declined => requestStatusDeclined,
      QuoteStatus.withdrawn => quoteErrorClosed,
      QuoteStatus.expired => requestStatusExpired,
    };
  }

  /// Hasta cuándo puede aceptarlo la clienta: solo mandado, a tiempo y sin
  /// novedades ([QuoteStatus.sent]). Con cambios pedidos o cambiado no lo
  /// puede aceptar hasta recibirlo de nuevo ([quoteExpiresUnlessResentText]).
  /// null si no aplica.
  String? quoteValidUntilText(
    RequestQuote quote,
    QuoteStatus status,
    RequestFormats formats,
  ) {
    final hold = quote.holdUntil;
    if (hold == null || status != QuoteStatus.sent) return null;
    return quoteValidUntil(
      formats.instantDayMonth(hold),
      formats.instantTime(hold),
    );
  }

  /// Con cambios pedidos o cambiado después de mandarlo, la clienta no lo
  /// puede aceptar, pero el plazo sigue corriendo: si Evelyn no se lo manda
  /// de nuevo antes, vence y las fechas se liberan. Para Evelyn, con la hora
  /// de Roma. null en los demás estados.
  String? quoteExpiresUnlessResentText(
    RequestQuote quote,
    QuoteStatus status,
    RequestFormats formats,
  ) {
    final hold = quote.holdUntil;
    if (hold == null ||
        !(status == QuoteStatus.changesRequested ||
            status == QuoteStatus.changed)) {
      return null;
    }
    return quoteExpiresUnlessResent(
      formats.instantDayMonth(hold),
      formats.instantTime(hold),
      quote.weekCountFor(status),
    );
  }

  /// Hasta cuándo puede aceptarlo si sale ahora ([deadline]): las horas, o
  /// la llegada de la primera semana si es antes. [weeks]: las del
  /// presupuesto (con una, «la fecha»).
  String quoteDeadlineText(
    QuoteDeadline deadline,
    RequestFormats formats, {
    required int weeks,
  }) => switch (deadline) {
    QuoteDeadlineHours(:final hours) => menuSendQuoteDeadlineHours(
      hours,
      weeks,
    ),
    QuoteDeadlineFirstArrival(:final date, :final start) =>
      menuSendQuoteDeadlineFirst(
        formats.shortDate(date),
        start.toHhMm(),
        weeks,
      ),
  };

  /// Por qué no se pudo cambiar el precio o retirarlo.
  String quoteFailure(
    QuoteFailure failure, {
    required QuoteOperation operation,
  }) => switch (failure.kind) {
    QuoteFailureKind.closed => quoteErrorClosed,
    QuoteFailureKind.empty => quoteNoWeeks,
    QuoteFailureKind.notFound => quoteErrorNotFound,
    QuoteFailureKind.forbidden => quoteErrorForbidden,
    QuoteFailureKind.unauthorized => bookingErrorUnauthorized,
    QuoteFailureKind.invalid => bookingErrorInvalid,
    QuoteFailureKind.conflict => quoteErrorConflict,
    QuoteFailureKind.unavailable => switch (operation) {
      QuoteOperation.changePrice => quoteErrorPriceUnavailable,
      QuoteOperation.withdraw => quoteErrorWithdrawUnavailable,
    },
  };

  /// Una semana del presupuesto: el título («Semana 1 · lun 30 nov», o solo
  /// la fecha con una sola semana).
  String quoteWeekTitle(
    int week,
    int weeks,
    CalendarDate date,
    RequestFormats formats,
  ) => weeks > 1
      ? bookingWeekTitle(week, formats.shortDate(date))
      : formats.shortDate(date);
}
