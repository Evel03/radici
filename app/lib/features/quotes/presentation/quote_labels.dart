// Textos del presupuesto de un pedido: su estado (cuándo salió, hasta cuándo
// puede aceptarlo la clienta, qué pasó), por qué no se pudo cambiar el precio
// o retirarlo y, en la vista previa del menú de la semana 1, hasta cuándo lo
// puede aceptar si sale ahora. Fechas y horas en hora de Roma. Solo
// presentación: los textos salen del ARB.
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
  /// mandarlo…», «La clienta lo aceptó el…»… [formats] escribe las fechas y
  /// las horas (Roma).
  String quoteStateText(
    RequestQuote quote,
    QuoteStatus status,
    RequestFormats formats,
  ) {
    String date(DateTime instant) => formats.instantDayMonth(instant);
    String time(DateTime instant) => formats.instantTime(instant);
    final closed = quote.closedOn(status);
    return switch (status) {
      QuoteStatus.draft => switch (quote.holdUntil) {
        final hold? => quoteStateDraft(date(hold), time(hold)),
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
      ),
      QuoteStatus.expired when closed != null =>
        quote.wasSent
            ? quoteStateExpired(date(closed), time(closed))
            : quoteStateDraftExpired(date(closed), time(closed)),
      // Cerrado sin la fecha (no debería pasar): el estado del pedido.
      QuoteStatus.accepted => requestStatusAccepted,
      QuoteStatus.declined => requestStatusDeclined,
      QuoteStatus.withdrawn => quoteErrorClosed,
      QuoteStatus.expired => requestStatusExpired,
    };
  }

  /// Hasta cuándo puede aceptarlo la clienta (mandado y a tiempo); null si
  /// no aplica.
  String? quoteValidUntilText(
    RequestQuote quote,
    QuoteStatus status,
    RequestFormats formats,
  ) {
    final hold = quote.holdUntil;
    if (hold == null ||
        !(status == QuoteStatus.sent ||
            status == QuoteStatus.changesRequested)) {
      return null;
    }
    return quoteValidUntil(
      formats.instantDayMonth(hold),
      formats.instantTime(hold),
    );
  }

  /// Hasta cuándo puede aceptarlo si sale ahora ([deadline]): las horas, o
  /// la llegada de la primera semana si es antes.
  String quoteDeadlineText(QuoteDeadline deadline, RequestFormats formats) =>
      switch (deadline) {
        QuoteDeadlineHours(:final hours) => menuSendQuoteDeadlineHours(hours),
        QuoteDeadlineFirstArrival(:final date, :final start) =>
          menuSendQuoteDeadlineFirst(formats.shortDate(date), start.toHhMm()),
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
