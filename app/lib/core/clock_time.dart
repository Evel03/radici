// Hora del día sin fecha, en hora de pared de Roma: la llegada de una sesión.
// Dart puro. Se escribe "HH:MM", como la mandan y la devuelven las Edge
// Functions (contrato docs/contracts/chef-api.md §3).

/// Hora del día de 00:00 a 23:59, en minutos desde la medianoche.
final class ClockTime implements Comparable<ClockTime> {
  const ClockTime(this.minutes)
    : assert(minutes >= 0 && minutes < minutesPerDay, 'Fuera del día');

  const ClockTime.hm(int hour, int minute) : this(hour * 60 + minute);

  /// Lee "HH:MM" (00:00 a 23:59). Lanza [FormatException] si no es una hora.
  factory ClockTime.parse(String value) {
    final time = tryParse(value);
    if (time == null) throw FormatException('Hora inválida', value);
    return time;
  }

  static const int minutesPerDay = 24 * 60;

  static final RegExp _pattern = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

  /// Como [ClockTime.parse], pero null si [value] no es un "HH:MM" válido.
  static ClockTime? tryParse(Object? value) {
    if (value is! String) return null;
    final match = _pattern.firstMatch(value);
    if (match == null) return null;
    return ClockTime.hm(int.parse(match.group(1)!), int.parse(match.group(2)!));
  }

  final int minutes;

  int get hour => minutes ~/ 60;
  int get minute => minutes % 60;

  /// La hora [delta] minutos después (o antes, si es negativo); null si cae
  /// fuera del día.
  ClockTime? plusMinutes(int delta) {
    final total = minutes + delta;
    return total < 0 || total >= minutesPerDay ? null : ClockTime(total);
  }

  /// "HH:MM".
  String toHhMm() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  @override
  int compareTo(ClockTime other) => minutes.compareTo(other.minutes);

  @override
  bool operator ==(Object other) =>
      other is ClockTime && other.minutes == minutes;

  @override
  int get hashCode => minutes.hashCode;

  @override
  String toString() => toHhMm();
}
