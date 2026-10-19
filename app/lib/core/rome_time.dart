// Fechas y horas de negocio en Europe/Rome (CLAUDE.md), sin depender de la
// zona horaria del dispositivo ni de una base de datos de husos.
//
// Italia sigue la regla de la UE desde 1996: horario de verano (UTC+2) desde
// el último domingo de marzo a la 01:00 UTC hasta el último domingo de
// octubre a la 01:00 UTC; el resto del año, UTC+1. Si la UE deja de cambiar la
// hora, se ajusta acá (y en `romeToday` de public_request.ts, que usa Intl).

/// Fecha de calendario sin hora ni zona (una columna `date` de Postgres).
///
/// Los días se cuentan en UTC internamente, así sumar días nunca cruza un
/// cambio de hora.
final class CalendarDate implements Comparable<CalendarDate> {
  CalendarDate(int year, int month, int day)
    : _utc = DateTime.utc(year, month, day);

  CalendarDate._(this._utc);

  /// Los campos de fecha de [dateTime] tal cual (sin convertir de zona).
  factory CalendarDate.fromDateTime(DateTime dateTime) =>
      CalendarDate(dateTime.year, dateTime.month, dateTime.day);

  /// Lee "AAAA-MM-DD". Lanza [FormatException] si no es una fecha real.
  factory CalendarDate.parse(String iso) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso);
    if (match == null) throw FormatException('Fecha inválida', iso);
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final date = CalendarDate(year, month, day);
    // DateTime normaliza el 30 de febrero al 2 de marzo: se rechaza.
    if (date.year != year || date.month != month || date.day != day) {
      throw FormatException('Fecha inexistente', iso);
    }
    return date;
  }

  final DateTime _utc;

  int get year => _utc.year;
  int get month => _utc.month;
  int get day => _utc.day;

  /// 1 = lunes … 7 = domingo (ISO 8601, como [DateTime.weekday]).
  int get weekday => _utc.weekday;

  CalendarDate addDays(int days) =>
      CalendarDate._(DateTime.utc(year, month, day + days));

  /// Primer día del mes de esta fecha.
  CalendarDate get firstOfMonth => CalendarDate(year, month, 1);

  /// Lunes de la semana de esta fecha (la semana empieza el lunes en Italia).
  CalendarDate get startOfWeek => addDays(1 - weekday);

  /// Mismo día del mes desplazado [months] meses (si no existe, el último).
  CalendarDate addMonths(int months) {
    final target = DateTime.utc(year, month + months, 1);
    final lastDay = DateTime.utc(target.year, target.month + 1, 0).day;
    return CalendarDate(target.year, target.month, day.clamp(1, lastDay));
  }

  bool isSameMonth(CalendarDate other) =>
      year == other.year && month == other.month;

  /// Días entre esta fecha y [other] (positivo si [other] es posterior).
  int daysUntil(CalendarDate other) => other._utc.difference(_utc).inDays;

  /// Medianoche de esta fecha como `DateTime` local, para formatear con intl.
  DateTime toDateTime() => DateTime(year, month, day);

  /// "AAAA-MM-DD".
  String toIso() =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  bool isBefore(CalendarDate other) => compareTo(other) < 0;
  bool isAfter(CalendarDate other) => compareTo(other) > 0;

  @override
  int compareTo(CalendarDate other) => _utc.compareTo(other._utc);

  @override
  bool operator ==(Object other) => other is CalendarDate && other._utc == _utc;

  @override
  int get hashCode => _utc.hashCode;

  @override
  String toString() => toIso();
}

/// Último domingo de [month] de [year], a las 01:00 UTC (cambio de hora UE).
DateTime _euSwitchInstant(int year, int month) {
  final lastDay = DateTime.utc(year, month + 1, 0);
  final lastSunday = lastDay.day - (lastDay.weekday % 7);
  return DateTime.utc(year, month, lastSunday, 1);
}

/// Diferencia de Europe/Rome con UTC en el instante [instant].
Duration romeUtcOffset(DateTime instant) {
  final utc = instant.toUtc();
  final summerStart = _euSwitchInstant(utc.year, 3);
  final summerEnd = _euSwitchInstant(utc.year, 10);
  final isSummer = !utc.isBefore(summerStart) && utc.isBefore(summerEnd);
  return Duration(hours: isSummer ? 2 : 1);
}

/// Hora de pared de Roma para [instant]: un `DateTime` cuyos campos (año, mes,
/// día, hora, minuto) son los que marca un reloj en Roma. Es solo para
/// mostrar: no representa el instante (es "UTC" de mentira).
DateTime romeWallClock(DateTime instant) {
  final utc = instant.toUtc();
  return utc.add(romeUtcOffset(utc));
}

/// Fecha de hoy en Europe/Rome.
CalendarDate romeToday(DateTime now) =>
    CalendarDate.fromDateTime(romeWallClock(now));
