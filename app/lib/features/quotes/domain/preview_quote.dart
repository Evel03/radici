// El presupuesto en la foto del envío del menú de la semana 1
// (`menu_sends.snapshot.quote`, SPEC 5.8; quote_snapshot.ts): la versión que
// sale, cada semana con su fecha, su llegada y su precio, el total y las horas
// que tiene la clienta para aceptarlo desde que sale, sin pasar la llegada de
// la primera semana. La vista previa lo muestra arriba del mensaje: es lo que
// va a ver la clienta. Dart puro; centavos enteros y horas de Roma.
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';

part 'preview_quote.freezed.dart';

/// Semanas de un presupuesto: de 1 a 8, como chef_create_quote.
const int maxQuoteWeeks = 8;

/// Tope de un importe (MAX_CENTS de chef_api.ts): 100.000 €.
const int maxQuoteCents = 10000000;

/// Tope del plazo en horas, para leer con cuidado (como QUOTE_MAX_HOLD_HOURS
/// de quote_snapshot.ts: chef_settings.quote_hold_hours solo exige más de 0).
const int maxQuoteHoldHours = 24 * 366;

/// Versión de un presupuesto (`quotes.version`, un smallint desde 1).
const int maxQuoteVersion = 32767;

/// Una semana en la foto del envío: la fecha y la llegada (Roma) y el
/// servicio de esa semana.
typedef QuoteLine = ({CalendarDate date, ClockTime start, int serviceCents});

/// El presupuesto que va en la foto de un envío (`menu_sends.snapshot.quote`,
/// quote_snapshot.ts): la versión que sale, las semanas con su precio, el
/// total y las horas que tiene la clienta para aceptarlo desde que sale. Lo
/// que ve la clienta: sale de ahí.
@Freezed(fromJson: false, toJson: false)
abstract class PreviewQuote with _$PreviewQuote {
  const factory PreviewQuote({
    required int version,
    required List<QuoteLine> weeks,
    required int holdHours,
  }) = _PreviewQuote;

  const PreviewQuote._();

  int get totalCents =>
      weeks.fold<int>(0, (sum, week) => sum + week.serviceCents);

  /// El bloque `quote` de la foto, como lo lee readSnapshotQuote: null si no
  /// tiene o si no cierra (el total que no es la suma, semanas fuera de
  /// orden, `firstStart` que no es la primera llegada…): nunca un precio o un
  /// plazo a medias.
  static PreviewQuote? tryParse(Object? json) {
    if (json is! Map) return null;
    final version = json['version'];
    final total = json['totalCents'];
    final holdHours = json['holdHours'];
    final firstStart = json['firstStart'];
    final raw = json['weeks'];
    if (version is! int ||
        version < 1 ||
        version > maxQuoteVersion ||
        !_isCents(total) ||
        holdHours is! int ||
        holdHours < 1 ||
        holdHours > maxQuoteHoldHours ||
        firstStart is! String ||
        raw is! List ||
        raw.isEmpty ||
        raw.length > maxQuoteWeeks) {
      return null;
    }
    final weeks = <QuoteLine>[];
    for (final item in raw) {
      if (item is! Map) return null;
      final date = _dateOrNull(item['date']);
      final start = ClockTime.tryParse(item['start']);
      final cents = item['serviceCents'];
      if (date == null || start == null || !_isCents(cents)) return null;
      final line = (date: date, start: start, serviceCents: cents as int);
      if (weeks.isNotEmpty && _compareLines(line, weeks.last) < 0) return null;
      weeks.add(line);
    }
    final first = weeks.first;
    if (firstStart != '${first.date.toIso()}T${first.start.toHhMm()}') {
      return null;
    }
    final quote = PreviewQuote(
      version: version,
      weeks: weeks,
      holdHours: holdHours,
    );
    return quote.totalCents == total ? quote : null;
  }

  /// Hasta cuándo puede aceptarlo si sale en [now] ([quoteDeadline]).
  QuoteDeadline deadlineAt(DateTime now) => quoteDeadline(
    holdHours: holdHours,
    firstDate: weeks.first.date,
    firstStart: weeks.first.start,
    now: now,
  );
}

/// Hasta cuándo puede aceptar el presupuesto la clienta si sale ahora.
sealed class QuoteDeadline {
  const QuoteDeadline();
}

/// [hours] horas desde que sale.
final class QuoteDeadlineHours extends QuoteDeadline {
  const QuoteDeadlineHours(this.hours);

  final int hours;

  @override
  bool operator ==(Object other) =>
      other is QuoteDeadlineHours && other.hours == hours;

  @override
  int get hashCode => hours.hashCode;
}

/// Antes de la llegada de la primera semana ([date] a las [start], Roma): el
/// plazo nunca la pasa.
final class QuoteDeadlineFirstArrival extends QuoteDeadline {
  const QuoteDeadlineFirstArrival(this.date, this.start);

  final CalendarDate date;
  final ClockTime start;

  @override
  bool operator ==(Object other) =>
      other is QuoteDeadlineFirstArrival &&
      other.date == date &&
      other.start == start;

  @override
  int get hashCode => Object.hash(date, start);
}

/// El plazo de un presupuesto que sale en [now], como lo fija
/// chef_complete_menu_send (`least(now() + quote_hold_hours, primera
/// llegada)`) y lo dice el mensaje (quoteDeadline de quote_snapshot.ts):
/// [holdHours] horas si alcanzan antes de la primera llegada; si no, esa
/// llegada.
QuoteDeadline quoteDeadline({
  required int holdHours,
  required CalendarDate firstDate,
  required ClockTime firstStart,
  required DateTime now,
}) {
  final arrival = romeInstant(firstDate, firstStart.minutes);
  return now.add(Duration(hours: holdHours)).isAfter(arrival)
      ? QuoteDeadlineFirstArrival(firstDate, firstStart)
      : QuoteDeadlineHours(holdHours);
}

// ---------------------------------------------------------------------
// Lectura
// ---------------------------------------------------------------------

bool _isCents(Object? value) =>
    value is int && value >= 0 && value <= maxQuoteCents;

CalendarDate? _dateOrNull(Object? value) {
  if (value is! String) return null;
  try {
    return CalendarDate.parse(value);
  } on FormatException {
    return null;
  }
}

int _compareLines(QuoteLine a, QuoteLine b) {
  final byDate = a.date.compareTo(b.date);
  return byDate != 0 ? byDate : a.start.compareTo(b.start);
}
