// Reservas (contrato docs/contracts/chef-api.md §4): lo que la app manda a
// POST chef/bookings y lo que devuelve la Edge Function. Dart puro.
//
// Una reserva es un pedido aceptado más sus sesiones: de 1 a 8 semanas, una
// sesión confirmed por semana. Estos modelos llevan solo fechas, horas,
// minutos, centavos e ids: nada de la clienta (ni nombre, ni dirección, ni
// alergias).
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';

part 'booking.freezed.dart';

/// Estado de cada fecha según el servidor (`private.booking_day_checks`), en
/// orden de prioridad. Solo [busy] impide confirmar; los demás son avisos.
enum BookingDayStatus {
  /// Choca con otra sesión (la misma cuenta que `no_overlap`).
  busy,

  /// La fecha ya pasó: sirve para cargar lo ya hecho en Fase 0.
  past,

  /// Día bloqueado (puede ser justo el que se bloqueó por esta sesión).
  blocked,

  /// Ese día de la semana no tiene horario.
  closed,

  /// La compra empieza antes de la apertura o la cocina termina después del
  /// cierre.
  outside,

  ok;

  /// Solo un choque impide crear la reserva.
  bool get blocksBooking => this == busy;
}

/// Confirmar una reserva desde un pedido de la bandeja (POST chef/bookings).
@Freezed(fromJson: false, toJson: false)
abstract class BookingRequest with _$BookingRequest {
  const factory BookingRequest({
    required String requestId,

    /// De 1 a 8 fechas, una por semana (lunes a domingo) y en orden.
    required List<CalendarDate> dates,

    /// Llegada de todas las semanas. null solo en el dryRun: el servidor
    /// evalúa cada fecha con su llegada sugerida.
    ClockTime? start,

    /// Minutos de cocina de cada semana.
    required int cookMinutes,

    /// Porciones y compra estimada de cada semana (de la estimación).
    int? portions,
    int? groceriesEstCents,

    /// Precio del servicio de toda la reserva, que fija Evelyn. Obligatorio
    /// salvo en el dryRun: después ninguna ruta lo cambia.
    int? serviceTotalCents,

    /// Idempotencia: una por intento de confirmación, la misma en sus
    /// reintentos.
    String? requestKey,

    /// true: solo el estado de cada fecha, sin escribir nada.
    @Default(false) bool dryRun,
  }) = _BookingRequest;

  const BookingRequest._();

  /// El cuerpo JSON (camelCase, fechas "AAAA-MM-DD" y hora "HH:MM").
  Map<String, Object> toBody() => {
    'requestId': requestId,
    'dates': [for (final date in dates) date.toIso()],
    'start': ?start?.toHhMm(),
    'cookMinutes': cookMinutes,
    'portions': ?portions,
    'groceriesEstCents': ?groceriesEstCents,
    'serviceTotalCents': ?serviceTotalCents,
    'requestKey': ?requestKey,
    'dryRun': dryRun,
  };
}

/// Una semana de la reserva, como la devuelve el servidor.
@Freezed(fromJson: false, toJson: false)
abstract class BookingWeek with _$BookingWeek {
  const factory BookingWeek({
    required CalendarDate date,

    /// Llegada evaluada; null solo en un dryRun sin hora para un día sin
    /// horario.
    ClockTime? start,
    required int cookMinutes,
    required BookingDayStatus status,

    /// La primera llegada del día, la misma que ofrece el calendario de la
    /// web (apertura más la compra, a la media hora siguiente); null si ese
    /// día no tiene horario.
    ClockTime? suggestedStart,

    /// Parte del servicio de esa semana.
    required int serviceCents,

    /// null en el dryRun.
    String? sessionId,
  }) = _BookingWeek;
}

/// Respuesta de POST chef/bookings: 200 en el dryRun, 201 al crear (también en
/// un reintento, con [duplicate]).
@Freezed(fromJson: false, toJson: false)
abstract class BookingResult with _$BookingResult {
  const factory BookingResult({
    required bool dryRun,

    /// Un reintento de una reserva ya guardada: no se creó nada nuevo.
    required bool duplicate,
    String? requestId,
    String? clientId,

    /// En orden de fecha (en el dryRun, las pedidas).
    required List<BookingWeek> weeks,
  }) = _BookingResult;

  /// Lee el JSON de la respuesta. Lanza [FormatException] si no tiene la
  /// forma del contrato.
  factory BookingResult.fromResponse(Object? json) {
    if (json is! Map) throw const FormatException('Respuesta inválida');
    final dryRun = json['dryRun'];
    final duplicate = json['duplicate'];
    final requestId = json['requestId'];
    final clientId = json['clientId'];
    final weeks = json['weeks'];
    if (dryRun is! bool || duplicate is! bool || weeks is! List) {
      throw const FormatException('Respuesta inválida');
    }
    if ((requestId != null && requestId is! String) ||
        (clientId != null && clientId is! String)) {
      throw const FormatException('Respuesta inválida');
    }
    return BookingResult(
      dryRun: dryRun,
      duplicate: duplicate,
      requestId: requestId as String?,
      clientId: clientId as String?,
      weeks: [for (final week in weeks) _weekFrom(week)],
    );
  }
}

extension BookingResultMatch on BookingResult {
  /// Lo guardado tiene lo que se mandó en [sent]: las mismas fechas, la misma
  /// llegada, los mismos minutos y el mismo precio total. Un reintento
  /// ([BookingResult.duplicate]) devuelve lo que ya estaba guardado: desde un
  /// pedido, el servidor lo reconoce solo por las fechas y la hora (contrato
  /// §4), así que el precio o los minutos pueden ser otros (por ejemplo, si
  /// se confirmó desde otro dispositivo).
  bool matches(BookingRequest sent) {
    if (weeks.length != sent.dates.length) return false;
    var total = 0;
    for (final (i, week) in weeks.indexed) {
      if (week.date != sent.dates[i] ||
          week.start != sent.start ||
          week.cookMinutes != sent.cookMinutes) {
        return false;
      }
      total += week.serviceCents;
    }
    final price = sent.serviceTotalCents;
    return price == null || total == price;
  }
}

BookingWeek _weekFrom(Object? json) {
  if (json is! Map) throw const FormatException('Semana inválida');
  final date = json['date'];
  final cookMinutes = json['cookMinutes'];
  final serviceCents = json['serviceCents'];
  final sessionId = json['sessionId'];
  final status = BookingDayStatus.values
      .where((s) => s.name == json['status'])
      .firstOrNull;
  if (date is! String ||
      cookMinutes is! int ||
      serviceCents is! int ||
      status == null ||
      (sessionId != null && sessionId is! String)) {
    throw const FormatException('Semana inválida');
  }
  return BookingWeek(
    date: CalendarDate.parse(date),
    start: _timeOrNull(json['start']),
    cookMinutes: cookMinutes,
    status: status,
    suggestedStart: _timeOrNull(json['suggestedStart']),
    serviceCents: serviceCents,
    sessionId: sessionId as String?,
  );
}

/// "HH:MM" o null; cualquier otra cosa lanza [FormatException].
ClockTime? _timeOrNull(Object? value) =>
    value == null ? null : ClockTime.parse(value is String ? value : '');
