// Hoja «Confirmar reserva», desde un pedido de la bandeja, a mano (una ficha
// existente o una nueva) o «Rinnova» (ver BookingSource): las semanas (1 a 8)
// y sus fechas cada 7 días, la hora de llegada que sugiere el servidor (en una
// renovación, la copiada), los minutos de cocina (con tope de 300 en los
// pasos), el precio del servicio de toda la reserva y, a mano o al renovar,
// el hogar (adultos, niños, días y comidas) y el idioma de la clienta.
//
// La hoja espera su seed (bookingSeedProvider): toma el primero y no mira los
// siguientes, así no se rehace si el pedido cambia en la bandeja o el borrador
// se descarta al confirmar. Cada cambio de fechas, hora o minutos vuelve a
// pedir el dryRun a la Edge Function chef: el estado de cada semana (ok, un
// aviso o un choque). Con un choque no deja confirmar. La confirmación lleva
// una clave por hoja, la misma en todos sus envíos: el servidor no duplica la
// reserva. Si una confirmación se queda sin respuesta (pudo haberse
// guardado), la hoja no cambia hasta reintentarla con lo mismo; a mano o al
// renovar, si el reintento tampoco tiene respuesta, Evelyn la puede cerrar
// igual («Chiudi comunque»). Nada de esto se loguea.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/money.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';
import 'package:radici/features/bookings/application/booking_seed.dart';
import 'package:radici/features/bookings/application/new_client_form_controller.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/clients/application/client_directory_controller.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/application/renewed_bookings.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';

part 'confirm_booking_controller.freezed.dart';

/// Una hoja por fuente; se descarta al cerrarla (la próxima es otro intento,
/// con otra clave).
final confirmBookingProvider = NotifierProvider.autoDispose
    .family<ConfirmBookingController, ConfirmBookingState, BookingSource>(
      ConfirmBookingController.new,
    );

/// En qué punto está el seed de la hoja.
enum BookingSeedStatus {
  /// Todavía no llegó.
  loading,

  /// No se pudo leer (la pantalla reintenta el provider de la fuente).
  error,

  /// No está: el pedido o la ficha no existen, o el borrador ya no sirve.
  missing,

  /// Llegó: la hoja está armada.
  ready,
}

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

    /// La hora de Roma al abrir la hoja (para la llegada de hoy que ya pasó;
    /// la medianoche, si no se sabe: ninguna llegada pasó).
    @Default(ClockTime(0)) ClockTime openedAt,

    /// Hasta que llega el seed, la hoja tiene valores de relleno y no deja
    /// confirmar.
    @Default(BookingSeedStatus.loading) BookingSeedStatus seedStatus,
    @Default(BookingSourceKind.request) BookingSourceKind kind,

    /// A quién es la reserva (el del seed: después de confirmar una ficha
    /// nueva el seed ya no está, y la pantalla final lo sigue necesitando).
    BookingParty? party,

    /// El pedido, desde un pedido (el resumen del encabezado).
    ChefRequest? request,

    /// A mano o al renovar: el hogar y el idioma de la clienta.
    BookingHousehold? household,
    @Default(ClientLocale.it) ClientLocale locale,

    /// «Rinnova», para el encabezado: el día de la última sesión viva de la
    /// reserva que se renueva, si su última semana se había movido y el
    /// teléfono del pedido renovado si no es el de la ficha.
    CalendarDate? renewedFrom,
    @Default(false) bool lastMoved,
    String? otherRequestPhone,

    /// 8 en un pedido semanal, a mano o al renovar; 1 en una sesión extra.
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

    /// Evelyn tocó los minutos: dejan de seguir al hogar.
    @Default(false) bool cookEdited,

    /// Evelyn tocó el hogar.
    @Default(false) bool householdEdited,

    /// Porciones y compra estimada de cada semana (van en el cuerpo).
    int? portions,
    int? groceriesEstCents,

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

    /// Un reintento de la confirmación tampoco tuvo respuesta.
    @Default(false) bool retryUnanswered,

    /// Evelyn eligió «Chiudi comunque»: la hoja ya no se retiene.
    @Default(false) bool leftAnyway,

    /// La reserva confirmada.
    BookingResult? result,
  }) = _ConfirmBookingState;

  const ConfirmBookingState._();

  int get weeks => dates.length;

  bool get isManual => kind == BookingSourceKind.manual;

  /// La hoja crea el pedido (a mano o «Rinnova»): el servidor reconoce un
  /// reintento solo por la clave de la hoja, así que mientras espera uno no
  /// se cierra, y un 404 es la ficha que ya no está.
  bool get createsRequest => kind != BookingSourceKind.request;

  List<BookingDateIssue?> get dateIssues =>
      bookingDateIssues(dates, today: today);

  bool get datesValid => dateIssues.every((issue) => issue == null);

  /// Fechas, hora y minutos: lo que decide el dryRun (el hogar y el idioma
  /// no).
  String get inputKey =>
      '${[for (final date in dates) date.toIso()].join(',')}'
      '|${start?.toHhMm() ?? '-'}|$cookMinutes';

  /// El dryRun terminó y es de lo que hay ahora en la hoja.
  bool get checksCurrent =>
      checksKey == inputKey &&
      (checksStatus == BookingChecksStatus.ready ||
          checksStatus == BookingChecksStatus.failed);

  /// El dryRun de lo que hay en la hoja todavía no volvió.
  bool get checking =>
      checksStatus == BookingChecksStatus.loading && !checksCurrent;

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

  /// El feriado de Bergamo de la semana [index], o null. El servidor no
  /// conoce los feriados (cuentan solo si Evelyn los bloqueó): lo avisa la
  /// hoja, sin impedir confirmar.
  ItalianHoliday? holidayFor(int index) =>
      index < weeks ? bergamoHolidayOn(dates[index]) : null;

  /// La semana [index] es hoy y su llegada ya pasó en Roma (con la hora de
  /// cuando se abrió la hoja). El servidor no lo marca como pasado.
  bool arrivalPassed(int index) {
    final arrival = start;
    return arrival != null &&
        index < weeks &&
        arrivalPassedToday(
          date: dates[index],
          start: arrival,
          today: today,
          now: openedAt,
        );
  }

  /// El servidor rechazó los datos de la ficha nueva (un 400 con campos
  /// `newClient.*`): se corrigen en el formulario, no en la hoja.
  bool get newClientRejected {
    final current = failure;
    return current != null &&
        current.kind == BookingFailureKind.invalid &&
        current.fields.any(
          (field) => field == 'newClient' || field.startsWith('newClient.'),
        );
  }

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

  /// La hoja ya no puede confirmar (el pedido cambió, la ficha no está, el
  /// servidor no acepta la ficha nueva o no hay permiso).
  bool get blocked =>
      newClientRejected ||
      (failure != null && _blockingFailures.contains(failure!.kind));

  /// Se mandó la confirmación y no hubo respuesta: pudo haber quedado
  /// guardada. Hasta reintentarla la hoja no cambia, y el reintento manda lo
  /// mismo ([sent]): desde un pedido el servidor lo reconoce por las fechas y
  /// la hora (contrato chef-api §4); a mano o al renovar, por la clave.
  bool get retryPending =>
      sent != null &&
      result == null &&
      failure?.kind == BookingFailureKind.unavailable;

  /// Nada se puede cambiar: se está mandando o se espera el reintento.
  bool get frozen => sending || retryPending;

  /// A mano o al renovar, mientras se manda o espera el reintento de una
  /// confirmación sin respuesta, la hoja no se cierra por ningún camino (la
  /// X, el atrás del sistema o el del navegador): otra hoja tendría otra
  /// clave y podría duplicar la reserva (y, con una ficha nueva, la ficha).
  /// Salvo que Evelyn elija «Chiudi comunque» ([canLeaveAnyway]).
  bool get holdsOpen => createsRequest && frozen && !leftAnyway;

  /// A mano o al renovar, el reintento tampoco tuvo respuesta (un corte
  /// largo o la función caída): sin una salida, la hoja quedaría abierta
  /// hasta que vuelva la red. Evelyn la puede cerrar, avisada de que la
  /// reserva pudo haber quedado guardada.
  bool get canLeaveAnyway =>
      createsRequest && retryPending && retryUnanswered && !leftAnyway;

  bool get canConfirm =>
      seedStatus == BookingSeedStatus.ready &&
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
      'ConfirmBookingState(${seedStatus.name}, weeks: $weeks, '
      'checks: ${checksStatus.name}, sending: $sending, '
      'failure: ${failure?.kind.name}, done: ${result != null})';
}

class ConfirmBookingController extends Notifier<ConfirmBookingState> {
  ConfirmBookingController(this.source);

  final BookingSource source;

  /// El primer seed: el destino del POST y la regla del precio.
  BookingSeed? _seed;

  /// La clave de esta hoja, un uuid de [newIdProvider] (los tests la fijan):
  /// la misma en todos sus envíos.
  late String _requestKey;

  /// Cada dryRun suma uno: solo vale la respuesta del último.
  int _checksSeq = 0;

  BookingsRepository get _repository => ref.read(bookingsRepositoryProvider);

  @override
  ConfirmBookingState build() {
    _requestKey = ref.read(newIdProvider)();
    _seed = null;
    _checksSeq = 0;
    final now = ref.read(clockProvider)();
    final today = romeToday(now);
    final wall = romeWallClock(now);
    final placeholder = ConfirmBookingState(
      today: today,
      openedAt: ClockTime.hm(wall.hour, wall.minute),
      kind: source.kind,
      maxWeeks: 1,
      dates: [today.addDays(1)],
      cookMinutes: defaultBookingCookMinutes,
    );
    // Escucharlo lo mantiene vivo mientras viva la hoja. La primera lectura
    // de un FutureProvider es siempre «cargando», aunque el pedido ya esté en
    // la bandeja: la hoja espera el primer valor.
    final seed = ref.listen(
      bookingSeedProvider(source),
      (_, next) => _onSeed(next),
    );
    return _adopt(seed.read(), placeholder);
  }

  void _onSeed(AsyncValue<BookingSeed?> next) {
    if (_seed != null) return;
    final adopted = _adopt(next, state);
    if (adopted != state) state = adopted;
  }

  /// El estado para [seed] mientras no se tomó ninguno: con el primer valor,
  /// la hoja armada y su primer dryRun.
  ConfirmBookingState _adopt(
    AsyncValue<BookingSeed?> seed,
    ConfirmBookingState current,
  ) {
    if (seed.isLoading) {
      return current.copyWith(seedStatus: BookingSeedStatus.loading);
    }
    if (seed.hasError) {
      return current.copyWith(seedStatus: BookingSeedStatus.error);
    }
    final value = seed.value;
    if (value == null) {
      return current.copyWith(seedStatus: BookingSeedStatus.missing);
    }
    _seed = value;
    final weeks = value.dates.length;
    if (value.initialFailure == null) {
      // El primer dryRun: sin hora, el servidor sugiere la llegada (con una
      // ya elegida, la lleva).
      scheduleMicrotask(() {
        if (ref.mounted) unawaited(_runChecks(adopt: !value.startEdited));
      });
    }
    return current.copyWith(
      seedStatus: BookingSeedStatus.ready,
      kind: value.kind,
      party: value.party,
      request: value.request,
      household: value.household,
      locale: value.locale,
      renewedFrom: value.renewedFrom,
      lastMoved: value.lastMoved,
      otherRequestPhone: value.otherRequestPhone,
      today: value.today,
      maxWeeks: value.maxWeeks,
      dates: value.dates,
      start: value.start,
      startEdited: value.startEdited,
      cookMinutes: value.cookMinutes,
      portions: value.portions,
      groceriesEstCents: value.groceriesEstCents,
      suggestedPriceCents: value.priceRule.suggestedFor(weeks),
      failure: value.initialFailure,
    );
  }

  /// Sin seed, mientras se manda, mientras espera su reintento o ya
  /// confirmada, la hoja no cambia: lo que se mandó es lo que vale.
  bool get _locked => _seed == null || state.frozen || state.result != null;

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
        suggestedPriceCents: _seed!.priceRule.suggestedFor(weeks),
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

  /// Media hora más ([direction] 1) o menos (-1) de cocina, de 30 a 300. Unos
  /// minutos copiados de más de 300 (una renovación) no suben, y bajan a 300.
  void stepCookMinutes(int direction) {
    if (direction > 0 && state.cookMinutes >= maxBookingCookMinutes) return;
    final minutes = steppedCookMinutes(state.cookMinutes, direction);
    if (_locked || minutes == state.cookMinutes) return;
    _edit(state.copyWith(cookMinutes: minutes, cookEdited: true));
    unawaited(_runChecks());
  }

  /// Uno más ([direction] 1) o uno menos (-1) de adultos, niños o días (a
  /// mano o al renovar).
  void stepHousehold(HouseholdCounter counter, int direction) {
    final household = state.household;
    if (_locked || household == null) return;
    final next = household.stepped(counter, direction);
    if (next != household) _setHousehold(next);
  }

  /// Suma o saca una comida (a mano o al renovar); la última no se saca.
  void toggleMeal(Meal meal) {
    final household = state.household;
    if (_locked || household == null) return;
    final next = household.withMeal(meal, !household.meals.contains(meal));
    if (next != household) _setHousehold(next);
  }

  /// El idioma de la clienta (a mano o al renovar). En una ficha nueva,
  /// también en el borrador: si Evelyn vuelve al formulario, lo ve.
  void setLocale(ClientLocale locale) {
    if (_locked || state.household == null || locale == state.locale) return;
    _edit(state.copyWith(locale: locale));
    if (source is NewClientBookingSource) {
      ref.read(newClientFormProvider.notifier).setLocale(locale);
    }
  }

  /// El hogar cambia la estimación (porciones y compra) y, mientras Evelyn no
  /// los toque, los minutos: eso vuelve a pedir el dryRun. En una ficha nueva
  /// se escribe también en el borrador.
  void _setHousehold(BookingHousehold household) {
    final estimate = manualBookingEstimate(household);
    final followCook = _seed!.cookFollowsHousehold && !state.cookEdited;
    final minutes = followCook ? estimate.cookMinutes : state.cookMinutes;
    final minutesChanged = minutes != state.cookMinutes;
    _edit(
      state.copyWith(
        household: household,
        householdEdited: true,
        portions: estimate.portions,
        groceriesEstCents: estimate.groceriesEstCents,
        cookMinutes: minutes,
      ),
    );
    if (source is NewClientBookingSource) {
      ref.read(newClientFormProvider.notifier).setHousehold(household);
    }
    if (minutesChanged) unawaited(_runChecks());
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
    final seed = _seed;
    if (!current.canConfirm || seed == null) return;
    final retrying = current.retryPending;
    final booking = retrying
        ? current.sent!
        : _booking(
            current,
            start: current.start,
            serviceTotalCents: current.serviceTotalCents,
            requestKey: _requestKey,
          );
    // La bandeja, la agenda y las reservas renovadas se actualizan aunque la
    // hoja se cierre mientras tanto.
    final inbox = ref.read(chefInboxProvider.notifier);
    final renewed = ref.read(renewedBookingsProvider.notifier);
    final refreshSessions = agendaSessionsRefresher(ref);
    final chefId = ref.read(currentChefProvider)?.chefId ?? '';
    final now = ref.read(clockProvider)().toUtc();
    state = current.copyWith(sending: true, failure: null, sent: booking);
    try {
      final result = await _repository.createBooking(booking);
      switch (seed.request) {
        case final request?:
          inbox.applyBooking(request.id, weeks: result.weeks.length);
        case null:
          // A mano o al renovar: la reserva está en «Prenotazioni» aunque la
          // relectura tarde o falle.
          final provisional = _provisionalRequest(
            seed,
            booking,
            result,
            chefId: chefId,
            now: now,
          );
          if (provisional != null) inbox.applyManualBooking(provisional);
      }
      // Renovada (también un reintento que el servidor reconoce): el
      // pendiente de Hoy desaparece aunque la agenda no se pueda volver a
      // leer.
      final renewedRequestId = seed.renewedRequestId;
      final firstWeek = result.weeks.firstOrNull;
      if (seed.kind == BookingSourceKind.renewal &&
          renewedRequestId != null &&
          firstWeek != null) {
        renewed.mark(renewedRequestId, firstWeek.date);
      }
      // Las sesiones nuevas aparecen en la agenda.
      if (refreshSessions != null) unawaited(refreshSessions());
      if (!ref.mounted) return;
      // La ficha nueva aparece en la próxima búsqueda; el borrador del flujo
      // se descarta (el atrás del navegador no vuelve a un formulario lleno).
      if (seed.newClient != null) ref.invalidate(clientDirectoryProvider);
      if (seed.kind == BookingSourceKind.manual) {
        ref.invalidate(newClientFormProvider);
      }
      state = state.copyWith(sending: false, result: result);
    } on BookingFailure catch (failure) {
      _afterBlockingFailure(failure, seed, inbox);
      if (!ref.mounted) return;
      state = state.copyWith(
        sending: false,
        failure: failure,
        retryUnanswered:
            retrying && failure.kind == BookingFailureKind.unavailable,
      );
      // Un choque: el dryRun marca la semana que choca.
      if (failure.kind == BookingFailureKind.slotTaken ||
          failure.kind == BookingFailureKind.weekTaken ||
          failure.kind == BookingFailureKind.conflict) {
        unawaited(_runChecks());
      }
    }
  }

  /// «Chiudi comunque» ([ConfirmBookingState.canLeaveAnyway]): la hoja deja de
  /// retenerse y la pantalla la cierra. Nada más cambia.
  void leaveAnyway() {
    if (!state.canLeaveAnyway) return;
    state = state.copyWith(leftAnyway: true);
  }

  /// El cuerpo del POST para lo que hay en [current] según el destino del
  /// seed: el pedido, la ficha (a mano o «Rinnova») o la ficha nueva; sin
  /// pedido, con el hogar y el idioma.
  BookingRequest _booking(
    ConfirmBookingState current, {
    ClockTime? start,
    int? serviceTotalCents,
    String? requestKey,
    bool dryRun = false,
  }) {
    final seed = _seed!;
    final manual = seed.request == null;
    return BookingRequest(
      requestId: seed.request?.id,
      clientId: seed.clientId,
      newClient: seed.newClient,
      type: manual ? RequestType.week : null,
      household: manual ? current.household : null,
      locale: manual ? current.locale : null,
      dates: current.dates,
      start: start,
      cookMinutes: current.cookMinutes,
      portions: current.portions,
      groceriesEstCents: current.groceriesEstCents,
      serviceTotalCents: serviceTotalCents,
      requestKey: requestKey,
      dryRun: dryRun,
    );
  }

  /// El pedido que crea una reserva a mano o una renovación, con lo que la
  /// hoja ya sabe, hasta que la bandeja lo relea. null si la respuesta no
  /// trae los ids.
  ChefRequest? _provisionalRequest(
    BookingSeed seed,
    BookingRequest booking,
    BookingResult result, {
    required String chefId,
    required DateTime now,
  }) {
    final requestId = result.requestId;
    final clientId = result.clientId ?? seed.clientId;
    final household = booking.household;
    if (requestId == null || clientId == null || household == null) {
      return null;
    }
    final status = seed.clientStatus;
    return ChefRequest(
      id: requestId,
      chefId: chefId,
      clientId: clientId,
      type: RequestType.week,
      status: RequestStatus.accepted,
      adults: household.adults,
      kids: household.kids,
      days: household.days,
      meals: household.canonicalMeals,
      weeks: result.weeks.length,
      locale: booking.locale ?? ClientLocale.it,
      source: RequestSource.app,
      seenAt: now,
      createdAt: now,
      client: RequestClient(
        displayName: seed.party.displayName,
        contactPhone: seed.newClient?.phone ?? seed.party.phoneText,
        zone: seed.party.zone,
        // Una ficha nueva nace trial y un prospecto pasa a trial, como en la
        // base; las demás no cambian.
        status: status == null || status == ClientStatus.prospect
            ? ClientStatus.trial
            : status,
      ),
    );
  }

  /// Con una falla que bloquea, lo que hay que volver a leer: el pedido
  /// (cambió en otro dispositivo) o, a mano o al renovar, el directorio (la
  /// ficha ya no está). [inbox] se toma antes de esperar al servidor: la hoja
  /// puede cerrarse mientras tanto.
  void _afterBlockingFailure(
    BookingFailure failure,
    BookingSeed seed,
    ChefInboxController inbox,
  ) {
    final kind = failure.kind;
    if (kind != BookingFailureKind.requestNotNew &&
        kind != BookingFailureKind.notFound) {
      return;
    }
    if (seed.request case final request?) {
      unawaited(inbox.reload(request.id));
    } else if (kind == BookingFailureKind.notFound && ref.mounted) {
      ref.invalidate(clientDirectoryProvider);
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
    final seed = _seed;
    final current = state;
    if (seed == null || current.blocked || current.result != null) return;
    if (!current.datesValid) {
      state = current.copyWith(
        checksStatus: BookingChecksStatus.idle,
        checks: const [],
        checksKey: null,
      );
      return;
    }
    final sentStart = adopt || current.start == null ? null : current.start;
    final inbox = ref.read(chefInboxProvider.notifier);
    state = current.copyWith(checksStatus: BookingChecksStatus.loading);
    try {
      final result = await _repository.createBooking(
        _booking(current, start: sentStart, dryRun: true),
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
      final rejected = state.copyWith(failure: failure).newClientRejected;
      if (_blockingFailures.contains(failure.kind) || rejected) {
        _afterBlockingFailure(failure, seed, inbox);
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
