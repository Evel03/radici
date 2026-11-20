// Mover y cancelar semanas en la Edge Function `chef` (contrato
// docs/contracts/chef-api.md §5 y §6): lo que la app manda y lo que devuelve.
// Dart puro. Solo fechas, horas, minutos, ids y códigos: nada de la clienta.
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/domain/booking.dart'
    show BookingDayStatus;

export 'package:radici/features/bookings/domain/booking.dart'
    show BookingDayStatus;

part 'session_api.freezed.dart';

/// Motivos de cancelación de la Edge Function (`CANCEL_REASONS`): siempre uno
/// de estos códigos, nunca texto libre (la clienta con cuenta puede leer su
/// sesión).
enum CancelReason {
  /// Por defecto.
  chefCancelled('chef_cancelled'),

  /// Lo pidió la clienta.
  clientCancelled('client_cancelled'),

  /// Evelyn no puede ir.
  chefUnavailable('chef_unavailable');

  const CancelReason(this.code);

  final String code;

  static CancelReason? fromCode(Object? value) =>
      values.where((reason) => reason.code == value).firstOrNull;
}

/// POST chef/sessions/move: mover una semana (solo held o confirmed). La
/// compra y el margen guardados no cambian.
@Freezed(fromJson: false, toJson: false)
abstract class MoveSessionRequest with _$MoveSessionRequest {
  const factory MoveSessionRequest({
    required String sessionId,
    required CalendarDate date,

    /// null: la hora guardada.
    ClockTime? start,

    /// null: los minutos guardados.
    int? cookMinutes,

    /// true: solo el chequeo, sin mover nada.
    @Default(false) bool dryRun,
  }) = _MoveSessionRequest;

  const MoveSessionRequest._();

  Map<String, Object> toBody() => {
    'sessionId': sessionId,
    'date': date.toIso(),
    'start': ?start?.toHhMm(),
    'cookMinutes': ?cookMinutes,
    'dryRun': dryRun,
  };
}

/// Respuesta 200 de POST chef/sessions/move.
@Freezed(fromJson: false, toJson: false)
abstract class MoveSessionResult with _$MoveSessionResult {
  const factory MoveSessionResult({
    required bool dryRun,
    required String sessionId,
    String? requestId,
    required CalendarDate date,
    required ClockTime start,
    required int cookMinutes,

    /// Como en las reservas, sin contar la sesión que se mueve. Solo busy
    /// impide moverla; los demás son avisos.
    required BookingDayStatus status,

    /// La primera llegada de ese día (la de la web); null sin horario.
    ClockTime? suggestedStart,

    /// Esa semana ya tiene otra sesión viva de la misma reserva (una por
    /// semana): la app ofrece pasarla al final de la reserva.
    required bool weekTaken,
  }) = _MoveSessionResult;

  /// Lee el JSON de la respuesta. Lanza [FormatException] si no tiene la
  /// forma del contrato.
  factory MoveSessionResult.fromResponse(Object? json) {
    if (json is! Map) throw const FormatException('Respuesta inválida');
    final dryRun = json['dryRun'];
    final sessionId = json['sessionId'];
    final requestId = json['requestId'];
    final date = json['date'];
    final start = ClockTime.tryParse(json['start']);
    final cookMinutes = json['cookMinutes'];
    final status = BookingDayStatus.values
        .where((s) => s.name == json['status'])
        .firstOrNull;
    final suggested = json['suggestedStart'];
    final weekTaken = json['weekTaken'];
    if (dryRun is! bool ||
        sessionId is! String ||
        (requestId != null && requestId is! String) ||
        date is! String ||
        start == null ||
        cookMinutes is! int ||
        status == null ||
        (suggested != null && ClockTime.tryParse(suggested) == null) ||
        weekTaken is! bool) {
      throw const FormatException('Respuesta inválida');
    }
    return MoveSessionResult(
      dryRun: dryRun,
      sessionId: sessionId,
      requestId: requestId as String?,
      date: CalendarDate.parse(date),
      start: start,
      cookMinutes: cookMinutes,
      status: status,
      suggestedStart: ClockTime.tryParse(suggested),
      weekTaken: weekTaken,
    );
  }
}

/// POST chef/sessions/cancel: cancelar semanas, todo o nada.
@Freezed(fromJson: false, toJson: false)
abstract class CancelSessionsRequest with _$CancelSessionsRequest {
  const factory CancelSessionsRequest({
    /// De 1 a 100, sin repetir.
    required List<String> sessionIds,
    @Default(CancelReason.chefCancelled) CancelReason reason,

    /// true: también las semanas ya cobradas (para registrar la devolución,
    /// que llega con los cobros). Sin esto, una cobrada da 409 hasPayments.
    @Default(false) bool allowWithPayments,
  }) = _CancelSessionsRequest;

  const CancelSessionsRequest._();

  Map<String, Object> toBody() => {
    'sessionIds': [
      ...{...sessionIds},
    ],
    'reason': reason.code,
    'allowWithPayments': allowWithPayments,
  };
}

/// Respuesta 200 de POST chef/sessions/cancel.
@Freezed(fromJson: false, toJson: false)
abstract class CancelSessionsResult with _$CancelSessionsResult {
  const factory CancelSessionsResult({
    required List<String> cancelled,
    required List<String> alreadyCancelled,

    /// Las de la lista con algún cobro: esperan su devolución.
    required List<String> withPayments,
    required bool hadPayments,
  }) = _CancelSessionsResult;

  const CancelSessionsResult._();

  /// Lee el JSON de la respuesta. Lanza [FormatException] si no tiene la
  /// forma del contrato.
  factory CancelSessionsResult.fromResponse(Object? json) {
    if (json is! Map) throw const FormatException('Respuesta inválida');
    final cancelled = _ids(json['cancelled']);
    final already = _ids(json['alreadyCancelled']);
    final withPayments = _ids(json['withPayments']);
    final hadPayments = json['hadPayments'];
    if (cancelled == null ||
        already == null ||
        withPayments == null ||
        hadPayments is! bool) {
      throw const FormatException('Respuesta inválida');
    }
    return CancelSessionsResult(
      cancelled: cancelled,
      alreadyCancelled: already,
      withPayments: withPayments,
      hadPayments: hadPayments,
    );
  }

  /// Las que quedaron canceladas: ahora o antes.
  Set<String> get allCancelled => {...cancelled, ...alreadyCancelled};
}

List<String>? _ids(Object? value) {
  if (value is! List || value.any((id) => id is! String)) return null;
  return value.cast<String>().toList();
}
