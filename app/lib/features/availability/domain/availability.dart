// Disponibilidad de la cocinera: su horario de cada semana
// (`availability_rules`) y los días que bloqueó (`availability_exceptions`,
// kind = 'blocked'). Dart puro. La web deja de ofrecer un día bloqueado:
// get_free_days ya los descuenta (free_slots.sql).
//
// La nota de un bloqueo es privada (la escribe Evelyn para ella: "ferie",
// "dal medico"…): nunca se loguea ni sale en toString.
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';

part 'availability.freezed.dart';

/// `dow` de Postgres (0 = domingo … 6 = sábado, como extract(dow)) a
/// [CalendarDate.weekday] (1 = lunes … 7 = domingo).
int weekdayFromDow(int dow) {
  RangeError.checkValueInInterval(dow, 0, 6, 'dow');
  return dow == 0 ? DateTime.sunday : dow;
}

/// [CalendarDate.weekday] (1 = lunes … 7 = domingo) a `dow` de Postgres.
int dowFromWeekday(int weekday) {
  RangeError.checkValueInInterval(weekday, 1, 7, 'weekday');
  return weekday % 7;
}

final RegExp _pgTime = RegExp(r'^(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?$');

/// Lee una hora `time` de Postgres ("09:00:00", "09:00" o "08:45:30.5") como
/// tiempo desde la medianoche. Las fracciones de segundo se descartan.
/// Lanza [FormatException] si no es una hora.
Duration parsePgTime(String value) {
  final match = _pgTime.firstMatch(value);
  if (match == null) throw FormatException('Hora inválida', value);
  final hours = int.parse(match.group(1)!);
  final minutes = int.parse(match.group(2)!);
  final seconds = int.parse(match.group(3) ?? '0');
  final duration = Duration(hours: hours, minutes: minutes, seconds: seconds);
  if (minutes > 59 || seconds > 59 || duration > const Duration(hours: 24)) {
    throw FormatException('Hora inexistente', value);
  }
  return duration;
}

/// Columnas que la app lee de `availability_rules`.
const String availabilityRuleColumns = 'dow, start_time, end_time';

/// Columnas que la app lee de `availability_exceptions`.
const String blockedDayColumns = 'id, date, note';

/// Largo máximo de la nota de un bloqueo (el campo de la app lo limita).
const int maxNoteLength = 200;

/// Nota de un bloqueo sin espacios de más; null si queda vacía.
String? normalizeNote(String? note) {
  final trimmed = note?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Una franja del horario semanal, en hora de Roma.
@Freezed(fromJson: false, toJson: false)
abstract class AvailabilityRule with _$AvailabilityRule {
  const factory AvailabilityRule({
    /// 1 = lunes … 7 = domingo.
    required int weekday,

    /// Desde la medianoche.
    required Duration start,
    required Duration end,
  }) = _AvailabilityRule;

  const AvailabilityRule._();

  /// Una fila de `availability_rules` seleccionada con
  /// [availabilityRuleColumns]. Lanza [FormatException] si está rota.
  factory AvailabilityRule.fromJson(Map<String, dynamic> json) {
    final dow = json['dow'];
    final start = json['start_time'];
    final end = json['end_time'];
    if (dow is! int || dow < 0 || dow > 6 || start is! String || end is! String) {
      throw const FormatException('Fila de availability_rules inválida');
    }
    return AvailabilityRule(
      weekday: weekdayFromDow(dow),
      start: parsePgTime(start),
      end: parsePgTime(end),
    );
  }
}

/// Un día bloqueado. [id] es el de la fila; es null mientras se guarda (o si
/// lo bloqueó otro dispositivo y todavía no se leyó).
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class BlockedDay with _$BlockedDay {
  const factory BlockedDay({
    String? id,
    required CalendarDate date,

    /// Privada: nunca se loguea.
    String? note,
  }) = _BlockedDay;

  const BlockedDay._();

  /// Una fila de `availability_exceptions` seleccionada con
  /// [blockedDayColumns]. Lanza [FormatException] si está rota.
  factory BlockedDay.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final date = json['date'];
    final note = json['note'];
    if (id is! String || id.isEmpty || date is! String) {
      throw const FormatException('Fila de availability_exceptions inválida');
    }
    return BlockedDay(
      id: id,
      date: CalendarDate.parse(date),
      note: normalizeNote(note is String ? note : null),
    );
  }

  @override
  String toString() => 'BlockedDay($id, ${date.toIso()})';
}

/// Lo que la app sabe de la disponibilidad: el horario semanal y los días
/// bloqueados desde [blockedDaysFrom].
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class AvailabilitySnapshot with _$AvailabilitySnapshot {
  const factory AvailabilitySnapshot({
    @Default(<AvailabilityRule>[]) List<AvailabilityRule> rules,
    @Default(<CalendarDate, BlockedDay>{}) Map<CalendarDate, BlockedDay> blocked,
  }) = _AvailabilitySnapshot;

  const AvailabilitySnapshot._();

  /// Sin horario ni bloqueos (sin sesión de cocinera).
  static const AvailabilitySnapshot empty = AvailabilitySnapshot();

  /// Franjas del día [weekday] (1 = lunes), por hora de inicio.
  List<AvailabilityRule> rulesFor(int weekday) =>
      rules.where((r) => r.weekday == weekday).toList()
        ..sort((a, b) => a.start.compareTo(b.start));

  /// [day] tiene horario (la web lo podría ofrecer si no está bloqueado).
  bool worksOn(CalendarDate day) => rules.any((r) => r.weekday == day.weekday);

  @override
  String toString() =>
      'AvailabilitySnapshot(${rules.length} reglas, ${blocked.length} bloqueos)';
}

/// Desde qué día se leen los bloqueos: el lunes de la primera semana del mes
/// de [today] (el primer día que muestra el calendario del mes).
CalendarDate blockedDaysFrom(CalendarDate today) =>
    today.firstOfMonth.startOfWeek;

/// Estado de un día para la cocinera.
enum DayStatus {
  /// Ya pasó (hoy no: todavía se puede bloquear).
  past,

  /// Bloqueado: la web no lo ofrece.
  blocked,

  /// Sin horario ese día de la semana.
  closed,

  /// Con horario y sin bloquear: la web lo ofrece si queda lugar.
  open,
}

/// Estado de [day]. Prioridad: pasado > bloqueado > sin horario > abierto.
DayStatus dayStatus(
  CalendarDate day, {
  required CalendarDate today,
  required AvailabilitySnapshot availability,
}) {
  if (day.isBefore(today)) return DayStatus.past;
  if (availability.blocked.containsKey(day)) return DayStatus.blocked;
  if (!availability.worksOn(day)) return DayStatus.closed;
  return DayStatus.open;
}

/// Largo máximo de un rango (un año, contando los dos extremos).
const int maxRangeDays = 366;

/// Los días de [first] a [last], los dos incluidos. Lanza [ArgumentError] si
/// [last] es anterior a [first] o si son más de [maxRangeDays] días.
List<CalendarDate> datesInRange(CalendarDate first, CalendarDate last) {
  if (last.isBefore(first)) {
    throw ArgumentError.value(last, 'last', 'Anterior al primer día');
  }
  final count = first.daysUntil(last) + 1;
  if (count > maxRangeDays) {
    throw ArgumentError.value(last, 'last', 'Más de $maxRangeDays días');
  }
  return [for (var i = 0; i < count; i++) first.addDays(i)];
}

/// Resumen de un rango para bloquearlo o desbloquearlo.
final class RangeSummary {
  const RangeSummary({
    required this.dates,
    required this.working,
    required this.toBlock,
    required this.alreadyBlocked,
  });

  /// Todos los días del rango.
  final List<CalendarDate> dates;

  /// Cuántos tienen horario (bloqueados o no).
  final int working;

  /// Los que faltan bloquear: todos, también los fines de semana (por si
  /// mañana Evelyn suma el sábado).
  final List<CalendarDate> toBlock;

  /// Los que ya estaban bloqueados.
  final List<CalendarDate> alreadyBlocked;

  int get total => dates.length;
}

/// Resume el rango de [first] a [last] (ver [datesInRange]).
RangeSummary summarizeRange(
  CalendarDate first,
  CalendarDate last,
  AvailabilitySnapshot snapshot,
) {
  final dates = datesInRange(first, last);
  return RangeSummary(
    dates: dates,
    working: dates.where(snapshot.worksOn).length,
    toBlock: [
      for (final d in dates)
        if (!snapshot.blocked.containsKey(d)) d,
    ],
    alreadyBlocked: [
      for (final d in dates)
        if (snapshot.blocked.containsKey(d)) d,
    ],
  );
}

/// Lo que la agenda muestra de un día: estado, feriado, horario, la nota si
/// está bloqueado, cuántos pedidos activos lo preferían y cuántas sesiones
/// tiene (bloquearlo no las cancela).
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class AgendaDayAvailability with _$AgendaDayAvailability {
  const factory AgendaDayAvailability({
    required CalendarDate day,
    required DayStatus status,
    ItalianHoliday? holiday,

    /// El bloqueo, si el día está bloqueado (con la nota, privada).
    BlockedDay? blocked,

    /// Las franjas de ese día de la semana, por hora de inicio.
    @Default(<AvailabilityRule>[]) List<AvailabilityRule> hours,
    @Default(0) int requestCount,

    /// Sesiones vivas de ese día.
    @Default(0) int sessionCount,
  }) = _AgendaDayAvailability;

  const AgendaDayAvailability._();

  /// La nota del bloqueo. Privada.
  String? get note => blocked?.note;

  /// La tarjeta ofrece "Bloquear" solo en un día abierto (un rango bloquea
  /// también los días sin horario).
  bool get canBlock => status == DayStatus.open;

  bool get canUnblock => status == DayStatus.blocked;

  @override
  String toString() =>
      'AgendaDayAvailability(${day.toIso()}, ${status.name})';
}

/// Arma [AgendaDayAvailability] para [day], con hoy en Roma, los pedidos
/// activos que lo preferían y sus sesiones.
AgendaDayAvailability agendaDayAvailability({
  required CalendarDate day,
  required CalendarDate today,
  required AvailabilitySnapshot snapshot,
  int requestsThatDay = 0,
  int sessionsThatDay = 0,
}) {
  final status = dayStatus(day, today: today, availability: snapshot);
  return AgendaDayAvailability(
    day: day,
    status: status,
    holiday: bergamoHolidayOn(day),
    blocked: status == DayStatus.blocked ? snapshot.blocked[day] : null,
    hours: snapshot.rulesFor(day.weekday),
    requestCount: requestsThatDay,
    sessionCount: sessionsThatDay,
  );
}
