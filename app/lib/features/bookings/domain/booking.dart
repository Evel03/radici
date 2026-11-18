// Reservas (contrato docs/contracts/chef-api.md §4): lo que la app manda a
// POST chef/bookings y lo que devuelve la Edge Function. Dart puro.
//
// Una reserva es un pedido aceptado más sus sesiones: de 1 a 8 semanas, una
// sesión confirmed por semana. Se confirma desde un pedido de la bandeja o a
// mano, para una ficha existente (clientId) o una nueva (newClient). Fuera de
// la ficha nueva (nombre, teléfono, zona y dirección, que toString no
// muestra), estos modelos llevan solo fechas, horas, minutos, centavos,
// personas e ids. Nunca alergias: una reserva a mano no las guarda (falta el
// consentimiento de salud, M2).
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/quote/domain/quote.dart'
    show QuoteInput, QuoteLimits, QuoteType;
import 'package:radici/features/requests/domain/chef_request.dart'
    show ClientLocale, Meal, RequestType;

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

/// Los contadores del hogar de una reserva a mano.
enum HouseholdCounter { adults, kids, days }

/// El hogar de una reserva a mano (`household` del contrato): adultos y niños
/// de 0 a 30, al menos una persona, días de 1 a 7 y comidas. Desde un pedido
/// no se manda (vale el del pedido).
@Freezed(fromJson: false, toJson: false)
abstract class BookingHousehold with _$BookingHousehold {
  const factory BookingHousehold({
    required int adults,
    required int kids,

    /// Días de comidas de cada semana.
    required int days,

    /// Almuerzo, cena o las dos; nunca vacía (ver [withMeal]).
    required List<Meal> meals,
  }) = _BookingHousehold;

  const BookingHousehold._();

  /// Lleva cualquier valor leído (de una ficha o de un pedido) a los límites
  /// del contrato: adultos y niños de 0 a 30 (si suman 0, un adulto), días de
  /// 1 a 7 y, sin comidas, cena.
  factory BookingHousehold.clamped({
    required int adults,
    required int kids,
    required int days,
    required Iterable<Meal> meals,
  }) {
    final grownUps = adults.clamp(0, QuoteLimits.maxPeople);
    final children = kids.clamp(0, QuoteLimits.maxPeople);
    final known = [
      for (final meal in Meal.values)
        if (meals.contains(meal)) meal,
    ];
    return BookingHousehold(
      adults: grownUps + children == 0 ? 1 : grownUps,
      kids: children,
      days: days.clamp(1, QuoteLimits.maxDays),
      meals: known.isEmpty ? const [Meal.dinner] : known,
    );
  }

  int valueOf(HouseholdCounter counter) => switch (counter) {
    HouseholdCounter.adults => adults,
    HouseholdCounter.kids => kids,
    HouseholdCounter.days => days,
  };

  bool canIncrement(HouseholdCounter counter) => switch (counter) {
    HouseholdCounter.adults => adults < QuoteLimits.maxPeople,
    HouseholdCounter.kids => kids < QuoteLimits.maxPeople,
    HouseholdCounter.days => days < QuoteLimits.maxDays,
  };

  /// Queda al menos una persona y un día.
  bool canDecrement(HouseholdCounter counter) => switch (counter) {
    HouseholdCounter.adults => adults > 0 && adults + kids > 1,
    HouseholdCounter.kids => kids > 0 && adults + kids > 1,
    HouseholdCounter.days => days > 1,
  };

  /// Uno más ([direction] 1) o uno menos (-1) de [counter]; el mismo hogar si
  /// no se puede.
  BookingHousehold stepped(HouseholdCounter counter, int direction) {
    if (direction > 0 && !canIncrement(counter)) return this;
    if (direction < 0 && !canDecrement(counter)) return this;
    final step = direction.sign;
    return switch (counter) {
      HouseholdCounter.adults => copyWith(adults: adults + step),
      HouseholdCounter.kids => copyWith(kids: kids + step),
      HouseholdCounter.days => copyWith(days: days + step),
    };
  }

  /// Las comidas en el orden del contrato (`lunch`, `dinner`), sin repetir.
  List<Meal> get canonicalMeals => [
    for (final meal in Meal.values)
      if (meals.contains(meal)) meal,
  ];

  /// Con [meal] ([on]) o sin ella. Nunca deja las comidas vacías: sacar la
  /// única devuelve el mismo hogar.
  BookingHousehold withMeal(Meal meal, bool on) {
    final current = canonicalMeals;
    if (on == current.contains(meal)) return this;
    final next = [
      for (final m in Meal.values)
        if (m == meal ? on : current.contains(m)) m,
    ];
    return next.isEmpty ? this : copyWith(meals: next);
  }

  /// `household` del cuerpo.
  Map<String, Object> toJson() => {
    'adults': adults,
    'kids': kids,
    'days': days,
    'meals': [for (final meal in canonicalMeals) meal.name],
  };

  /// La entrada de calcQuote (la copia Dart, como vista previa).
  QuoteInput toQuoteInput({int weeks = 1}) => QuoteInput(
    type: QuoteType.week,
    adults: adults,
    kids: kids,
    days: days,
    meals: canonicalMeals.length,
    weeks: weeks,
  );
}

/// La ficha nueva de una reserva a mano (`newClient` del contrato): el nombre
/// y, si los hay, el teléfono en E.164, la zona y la dirección. Sin
/// restricciones ni alergias. Va igual en el dryRun y al confirmar: el
/// servidor la valida también en el dryRun.
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class NewClientData with _$NewClientData {
  const factory NewClientData({
    required String name,
    String? phone,
    String? zone,
    String? address,
  }) = _NewClientData;

  const NewClientData._();

  /// `newClient` del cuerpo, sin las claves vacías.
  Map<String, Object> toJson() => {
    'name': name,
    'phone': ?phone,
    'zone': ?zone,
    'address': ?address,
  };

  @override
  String toString() => 'NewClientData(<oculto>)';
}

/// Confirmar una reserva (POST chef/bookings), para una sola clienta: un
/// pedido de la bandeja ([requestId]), una ficha existente ([clientId]) o una
/// nueva ([newClient]). A mano van además [type], [household] y [locale].
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class BookingRequest with _$BookingRequest {
  @Assert(
    '(requestId == null ? 0 : 1) + (clientId == null ? 0 : 1) + '
        '(newClient == null ? 0 : 1) == 1',
    'Una sola clienta: requestId, clientId o newClient',
  )
  @Assert(
    'requestId != null || (type != null && household != null && locale != null)',
    'A mano van type, household y locale',
  )
  const factory BookingRequest({
    String? requestId,
    String? clientId,
    NewClientData? newClient,

    /// A mano, siempre `week` (desde un pedido vale el del pedido).
    RequestType? type,
    BookingHousehold? household,

    /// Idioma de la clienta (sus mensajes de WhatsApp).
    ClientLocale? locale,

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

    /// Idempotencia: una por hoja, la misma en todos sus envíos (obligatoria
    /// al confirmar a mano).
    String? requestKey,

    /// true: solo el estado de cada fecha, sin escribir nada.
    @Default(false) bool dryRun,
  }) = _BookingRequest;

  const BookingRequest._();

  /// El cuerpo JSON (camelCase, fechas "AAAA-MM-DD" y hora "HH:MM"). Desde un
  /// pedido, sin type, household ni locale.
  Map<String, Object> toBody() => {
    'requestId': ?requestId,
    'clientId': ?clientId,
    'newClient': ?newClient?.toJson(),
    if (requestId == null) ...{
      'type': type!.name,
      'household': household!.toJson(),
      'locale': locale!.name,
    },
    'dates': [for (final date in dates) date.toIso()],
    'start': ?start?.toHhMm(),
    'cookMinutes': cookMinutes,
    'portions': ?portions,
    'groceriesEstCents': ?groceriesEstCents,
    'serviceTotalCents': ?serviceTotalCents,
    'requestKey': ?requestKey,
    'dryRun': dryRun,
  };

  /// Sin la clienta: solo cuántas fechas y si es un dryRun.
  @override
  String toString() =>
      'BookingRequest(dates: ${dates.length}, dryRun: $dryRun)';
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
