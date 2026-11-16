// Hoja «Confirmar reserva» desde un pedido de la bandeja: las semanas (1 a 8,
// prellenadas con requests.weeks) y sus fechas cada 7 días desde la
// preferida, la hora de llegada que sugiere el servidor, los minutos de cocina
// de la estimación (con tope de 300) y el precio del servicio de toda la
// reserva (el de la estimación, editable; vacío sin precio automático).
//
// Cada cambio de fechas, hora o minutos vuelve a pedir el dryRun a la Edge
// Function chef: el estado de cada semana (ok, un aviso o un choque). Con un
// choque no deja confirmar. La confirmación lleva una clave por intento (una
// por hoja), la misma en sus reintentos: el servidor no duplica la reserva.
// Si una confirmación se queda sin respuesta (pudo haberse guardado), la hoja
// no cambia hasta reintentarla con lo mismo: desde un pedido, el servidor
// reconoce el reintento por las fechas y la hora, y con otros datos diría que
// el pedido ya no está nuevo. Nada de esto se loguea.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/money.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';

part 'confirm_booking_controller.freezed.dart';

/// Genera la clave de idempotencia de cada intento (los tests la fijan).
final bookingRequestKeyProvider = Provider<String Function()>((ref) => uuidV4);

/// Una hoja por pedido; se descarta al cerrarla (la próxima es otro intento,
/// con otra clave).
final confirmBookingProvider = NotifierProvider.autoDispose
    .family<ConfirmBookingController, ConfirmBookingState, String>(
      ConfirmBookingController.new,
    );

/// El dryRun de las fechas que hay en la hoja.
enum BookingChecksStatus {
  /// No se pidió (fechas que no se pueden mandar).
  idle,
  loading,
  ready,

  /// No se pudo pedir: se puede confirmar igual (el servidor vuelve a
  /// comprobar) y reintentar.
  failed,
}

/// Por qué no se puede usar el precio escrito.
enum BookingPriceIssue {
  /// Vacío: falta escribirlo (sin precio automático, o lo borró).
  required,

  /// No es un importe ("560", "560,50"…).
  invalid,

  /// Más del tope (100.000 €).
  tooHigh,
}

/// Lo que impide confirmar y que Evelyn tiene que arreglar.
enum BookingBlockKind {
  /// Una fecha que no se puede mandar (misma semana, orden o muy lejos).
  date,

  /// Una semana choca con otra sesión.
  clash,

  /// Falta el precio o no se puede usar ([BookingPriceIssue]).
  price,
}

/// Lo primero que impide confirmar: [week] es la semana (desde 0) de
/// [BookingBlockKind.date] y [BookingBlockKind.clash]; null en el precio.
typedef BookingBlocker = ({BookingBlockKind kind, int? week});

/// Fallas después de las cuales la hoja no puede confirmar nada.
const Set<BookingFailureKind> _blockingFailures = {
  BookingFailureKind.requestNotNew,
  BookingFailureKind.notFound,
  BookingFailureKind.forbidden,
  BookingFailureKind.unauthorized,
};

@Freezed(toStringOverride: false)
abstract class ConfirmBookingState with _$ConfirmBookingState {
  const factory ConfirmBookingState({
    /// Hoy en Roma, al abrir la hoja.
    required CalendarDate today,

    /// 8 en un pedido semanal; 1 en una sesión extra.
    required int maxWeeks,

    /// Una fecha por semana, en orden.
    required List<CalendarDate> dates,

    /// Llegada de todas las semanas; null hasta el primer dryRun.
    ClockTime? start,

    /// La eligió Evelyn: deja de seguir a la sugerida.
    @Default(false) bool startEdited,

    /// La primera llegada de la primera fecha según el servidor.
    ClockTime? suggestedStart,
    required int cookMinutes,

    /// El precio que propone la hoja (null: sin precio automático).
    int? suggestedPriceCents,

    /// Lo que escribió Evelyn; vale solo con [priceEdited].
    @Default('') String priceText,
    @Default(false) bool priceEdited,
    @Default(BookingChecksStatus.idle) BookingChecksStatus checksStatus,

    /// El último dryRun, una entrada por semana.
    @Default(<BookingWeek>[]) List<BookingWeek> checks,

    /// Fechas, hora y minutos de [checks] (ver [inputKey]).
    String? checksKey,

    /// Se está mandando la confirmación.
    @Default(false) bool sending,

    /// La última confirmación que se mandó: la que se reintenta si se quedó
    /// sin respuesta ([retryPending]) y con la que se compara lo guardado
    /// ([savedDiffers]).
    BookingRequest? sent,

    /// La última falla (del dryRun o de la confirmación), o null.
    BookingFailure? failure,

    /// La reserva confirmada.
    BookingResult? result,
  }) = _ConfirmBookingState;

  const ConfirmBookingState._();

  int get weeks => dates.length;

  List<BookingDateIssue?> get dateIssues =>
      bookingDateIssues(dates, today: today);

  bool get datesValid => dateIssues.every((issue) => issue == null);

  /// Fechas, hora y minutos: lo que decide el dryRun.
  String get inputKey =>
      '${[for (final date in dates) date.toIso()].join(',')}'
      '|${start?.toHhMm() ?? '-'}|$cookMinutes';

  /// El dryRun terminó y es de lo que hay ahora en la hoja.
  bool get checksCurrent =>
      checksKey == inputKey &&
      (checksStatus == BookingChecksStatus.ready ||
          checksStatus == BookingChecksStatus.failed);

  /// Lo que dijo el servidor de la semana [index], si es de lo que hay ahora.
  BookingWeek? checkFor(int index) =>
      checksCurrent &&
          checksStatus == BookingChecksStatus.ready &&
          index < checks.length
      ? checks[index]
      : null;

  /// Alguna semana choca con otra sesión.
  bool get hasClash =>
      checksCurrent &&
      checksStatus == BookingChecksStatus.ready &&
      checks.any((week) => week.status.blocksBooking);

  BookingPriceIssue? get priceIssue {
    if (!priceEdited) {
      return suggestedPriceCents == null ? BookingPriceIssue.required : null;
    }
    if (priceText.trim().isEmpty) return BookingPriceIssue.required;
    final cents = parseEuroCents(priceText);
    if (cents == null) return BookingPriceIssue.invalid;
    return cents > maxBookingCents ? BookingPriceIssue.tooHigh : null;
  }

  /// El precio del servicio de toda la reserva, en centavos; null si no se
  /// puede usar ([priceIssue]).
  int? get serviceTotalCents {
    if (priceIssue != null) return null;
    return priceEdited ? parseEuroCents(priceText) : suggestedPriceCents;
  }

  /// La hoja ya no puede confirmar (el pedido cambió o no hay permiso).
  bool get blocked =>
      failure != null && _blockingFailures.contains(failure!.kind);

  /// Se mandó la confirmación y no hubo respuesta: pudo haber quedado
  /// guardada. Hasta reintentarla la hoja no cambia, y el reintento manda lo
  /// mismo ([sent]). Desde un pedido el servidor reconoce el reintento solo
  /// por las fechas y la hora (contrato chef-api §4): con otros datos diría
  /// que el pedido ya no está nuevo aunque la reserva exista, y un precio
  /// distinto se perdería sin aviso.
  bool get retryPending =>
      sent != null &&
      result == null &&
      failure?.kind == BookingFailureKind.unavailable;

  /// Nada se puede cambiar: se está mandando o se espera el reintento.
  bool get frozen => sending || retryPending;

  bool get canConfirm =>
      result == null &&
      !sending &&
      !blocked &&
      datesValid &&
      start != null &&
      priceIssue == null &&
      checksCurrent &&
      !hasClash;

  /// Lo primero que impide confirmar y que Evelyn tiene que arreglar, en el
  /// orden de la hoja: una fecha que no se puede mandar, una semana que choca
  /// o el precio. La barra de abajo lo dice, porque en un teléfono la causa
  /// puede quedar fuera de la vista. null si no hay (también mientras el
  /// dryRun no volvió).
  BookingBlocker? get blocker {
    final date = dateIssues.indexWhere((issue) => issue != null);
    if (date >= 0) return (kind: BookingBlockKind.date, week: date);
    if (hasClash) {
      return (
        kind: BookingBlockKind.clash,
        week: checks.indexWhere((week) => week.status.blocksBooking),
      );
    }
    if (priceIssue != null) return (kind: BookingBlockKind.price, week: null);
    return null;
  }

  /// Ya estaba confirmada (un reintento) pero lo guardado no es lo que tenía
  /// la hoja: otro precio, otras fechas, otra hora u otros minutos (por
  /// ejemplo, se confirmó desde otro dispositivo con las mismas fechas y
  /// hora). Vale lo guardado.
  bool get savedDiffers {
    final saved = result;
    final mine = sent;
    return saved != null &&
        saved.duplicate &&
        mine != null &&
        !saved.matches(mine);
  }

  @override
  String toString() =>
      'ConfirmBookingState(weeks: $weeks, checks: ${checksStatus.name}, '
      'sending: $sending, failure: ${failure?.kind.name}, '
      'done: ${result != null})';
}

class ConfirmBookingController extends Notifier<ConfirmBookingState> {
  ConfirmBookingController(this.requestId);

  final String requestId;

  ChefRequest? _request;

  /// La clave de este intento: la misma en todos sus reintentos.
  late String _requestKey;

  /// Cada dryRun suma uno: solo vale la respuesta del último.
  int _checksSeq = 0;

  BookingsRepository get _repository => ref.read(bookingsRepositoryProvider);

  @override
  ConfirmBookingState build() {
    _requestKey = ref.read(bookingRequestKeyProvider)();
    final today = romeToday(ref.read(clockProvider)());
    // Se lee una vez: la hoja no se rehace si el pedido cambia en la bandeja
    // (por ejemplo, al marcarlo visto). La pantalla la abre con el pedido ya
    // cargado.
    final request = ref.read(chefRequestProvider(requestId)).value;
    _request = request;
    if (request == null) {
      return ConfirmBookingState(
        today: today,
        maxWeeks: 1,
        dates: [today.addDays(1)],
        cookMinutes: defaultBookingCookMinutes,
        failure: const BookingFailure(BookingFailureKind.notFound),
      );
    }

    final weeks = initialBookingWeeks(request);
    final initial = ConfirmBookingState(
      today: today,
      maxWeeks: maxWeeksFor(request.type),
      dates: weeklyDates(initialBookingDate(request, today: today), weeks),
      cookMinutes: suggestedCookMinutes(request.estimate?.cookMinutes),
      suggestedPriceCents: suggestedServiceCents(
        request.estimate,
        weeks: weeks,
      ),
    );
    if (!request.canConfirmBooking) {
      // Ya no es un pedido nuevo: ni se pregunta al servidor.
      return initial.copyWith(
        failure: BookingFailure(
          BookingFailureKind.requestNotNew,
          requestStatus: _statusName(request.status),
        ),
      );
    }
    // El primer dryRun, sin hora: el servidor sugiere la llegada.
    scheduleMicrotask(() {
      if (ref.mounted) unawaited(_runChecks(adopt: true));
    });
    return initial;
  }

  /// Mientras se manda la confirmación, mientras espera su reintento o ya
  /// confirmada, la hoja no cambia: lo que se mandó es lo que vale.
  bool get _locked => state.frozen || state.result != null;

  /// Cantidad de semanas (1 a [ConfirmBookingState.maxWeeks]); fuera de eso no
  /// hace nada.
  void setWeeks(int weeks) {
    final current = state;
    if (_locked ||
        weeks < 1 ||
        weeks > current.maxWeeks ||
        weeks == current.weeks) {
      return;
    }
    _edit(
      current.copyWith(
        dates: resizeBookingWeeks(current.dates, weeks),
        // El precio sigue a las semanas mientras Evelyn no lo escriba.
        suggestedPriceCents: suggestedServiceCents(
          _request?.estimate,
          weeks: weeks,
        ),
      ),
    );
    unawaited(_runChecks(adopt: _followsSuggestion));
  }

  /// La fecha de la semana [index]: la primera mueve toda la reserva.
  void setDate(int index, CalendarDate date) {
    final current = state;
    if (_locked || index < 0 || index >= current.weeks) return;
    _edit(
      current.copyWith(dates: changeBookingDate(current.dates, index, date)),
    );
    unawaited(_runChecks(adopt: _followsSuggestion && index == 0));
  }

  /// La hora de llegada que eligió Evelyn.
  void setStart(ClockTime start) {
    if (_locked || (start == state.start && state.startEdited)) return;
    _edit(state.copyWith(start: start, startEdited: true));
    unawaited(_runChecks());
  }

  /// Media hora más ([direction] 1) o menos (-1) de cocina, de 30 a 300.
  void stepCookMinutes(int direction) {
    final minutes = steppedCookMinutes(state.cookMinutes, direction);
    if (_locked || minutes == state.cookMinutes) return;
    _edit(state.copyWith(cookMinutes: minutes));
    unawaited(_runChecks());
  }

  /// El precio que escribió Evelyn (el del servicio de toda la reserva).
  void setPriceText(String text) {
    if (_locked || (state.priceEdited && text == state.priceText)) return;
    _edit(state.copyWith(priceText: text, priceEdited: true));
  }

  /// Vuelve a pedir el dryRun (después de una falla).
  void retryChecks() {
    if (_locked) return;
    unawaited(_runChecks(adopt: _followsSuggestion));
  }

  /// Confirma la reserva. No hace nada si no se puede ([canConfirm]): entre
  /// otras cosas, mientras se está mandando. Si falla, queda en
  /// [ConfirmBookingState.failure] y se puede reintentar: con la misma clave
  /// y, si se quedó sin respuesta, con lo mismo que se mandó.
  Future<void> confirm() async {
    final current = state;
    final request = _request;
    if (!current.canConfirm || request == null) return;
    final booking = current.retryPending
        ? current.sent!
        : BookingRequest(
            requestId: request.id,
            dates: current.dates,
            start: current.start,
            cookMinutes: current.cookMinutes,
            portions: request.estimate?.portions,
            groceriesEstCents: request.estimate?.groceriesEstCents,
            serviceTotalCents: current.serviceTotalCents,
            requestKey: _requestKey,
          );
    // La bandeja y la agenda se actualizan aunque la hoja se cierre mientras
    // tanto.
    final inbox = ref.read(chefInboxProvider.notifier);
    final refreshSessions = agendaSessionsRefresher(ref);
    state = current.copyWith(sending: true, failure: null, sent: booking);
    try {
      final result = await _repository.createBooking(booking);
      inbox.applyBooking(request.id, weeks: result.weeks.length);
      // Las sesiones nuevas aparecen en la agenda.
      if (refreshSessions != null) unawaited(refreshSessions());
      if (!ref.mounted) return;
      state = state.copyWith(sending: false, result: result);
    } on BookingFailure catch (failure) {
      if (failure.kind == BookingFailureKind.requestNotNew ||
          failure.kind == BookingFailureKind.notFound) {
        unawaited(inbox.reload(request.id));
      }
      if (!ref.mounted) return;
      state = state.copyWith(sending: false, failure: failure);
      // Un choque: el dryRun marca la semana que choca.
      if (failure.kind == BookingFailureKind.slotTaken ||
          failure.kind == BookingFailureKind.weekTaken ||
          failure.kind == BookingFailureKind.conflict) {
        unawaited(_runChecks());
      }
    }
  }

  /// La hora sigue a la sugerida mientras Evelyn no elija otra.
  bool get _followsSuggestion => !state.startEdited;

  /// Un cambio de Evelyn: una falla de un intento anterior ya no vale (salvo
  /// las que impiden confirmar).
  void _edit(ConfirmBookingState next) {
    state = next.blocked || next.failure == null
        ? next
        : next.copyWith(failure: null);
  }

  /// Pide el dryRun de lo que hay en la hoja. Con [adopt], sin hora: el
  /// servidor evalúa cada fecha con su llegada sugerida, y la hoja la toma
  /// (si Evelyn no eligió otra). Si alguna semana se evaluó con otra hora,
  /// vuelve a pedirlo con la de la hoja.
  Future<void> _runChecks({bool adopt = false}) async {
    final seq = ++_checksSeq;
    final request = _request;
    final current = state;
    if (request == null || current.blocked || current.result != null) return;
    if (!current.datesValid) {
      state = current.copyWith(
        checksStatus: BookingChecksStatus.idle,
        checks: const [],
        checksKey: null,
      );
      return;
    }
    final sentStart = adopt || current.start == null ? null : current.start;
    state = current.copyWith(checksStatus: BookingChecksStatus.loading);
    try {
      final result = await _repository.createBooking(
        BookingRequest(
          requestId: request.id,
          dates: current.dates,
          start: sentStart,
          cookMinutes: current.cookMinutes,
          portions: request.estimate?.portions,
          groceriesEstCents: request.estimate?.groceriesEstCents,
          dryRun: true,
        ),
      );
      if (!ref.mounted || seq != _checksSeq) return;
      final suggested = result.weeks.firstOrNull?.suggestedStart;
      var start = state.start;
      if (sentStart == null && !state.startEdited) {
        start = suggested ?? start ?? defaultBookingArrival;
      }
      final evaluatedAt =
          sentStart ??
          (result.weeks.every((week) => week.start == start) ? start : null);
      final next = state.copyWith(start: start, suggestedStart: suggested);
      if (evaluatedAt != start) {
        // Se evaluó con otra hora (un día sin horario o fechas de distintos
        // días): otra vuelta con la de la hoja.
        state = next;
        unawaited(_runChecks());
        return;
      }
      state = next.copyWith(
        checks: result.weeks,
        checksStatus: BookingChecksStatus.ready,
        checksKey: next.inputKey,
      );
    } on BookingFailure catch (failure) {
      if (!ref.mounted || seq != _checksSeq) return;
      if (_blockingFailures.contains(failure.kind)) {
        if (failure.kind == BookingFailureKind.requestNotNew ||
            failure.kind == BookingFailureKind.notFound) {
          unawaited(ref.read(chefInboxProvider.notifier).reload(request.id));
        }
        state = state.copyWith(
          failure: failure,
          checksStatus: BookingChecksStatus.idle,
          checks: const [],
        );
        return;
      }
      // Sin respuesta: la llegada por defecto, y se puede confirmar igual.
      final next = state.copyWith(start: state.start ?? defaultBookingArrival);
      state = next.copyWith(
        checksStatus: BookingChecksStatus.failed,
        checks: const [],
        checksKey: next.inputKey,
      );
    }
  }
}

/// El estado del pedido como lo escribe la base (`new`, `accepted`…).
String _statusName(RequestStatus status) =>
    status == RequestStatus.newRequest ? 'new' : status.name;
