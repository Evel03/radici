// Reglas de la hoja «Confirmar reserva»: las semanas y sus fechas, lo que
// impide mandar una fecha, los minutos de cocina, el precio que se propone y
// las horas de llegada; para una reserva a mano, además, el hogar y su
// estimación. Dart puro. Los límites son los de chef_create_booking
// (contrato docs/contracts/chef-api.md §4).
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/clients/domain/chef_client.dart';
import 'package:radici/features/quote/domain/quote.dart'
    show calcQuote, defaultPricing;
import 'package:radici/features/requests/domain/chef_request.dart';

/// Una reserva es de 1 a 8 semanas, con una sesión por semana.
const int maxBookingWeeks = 8;

/// Minutos de cocina: de a 30, de 30 a 360. Con la llegada sugerida de las
/// 9:00 (la apertura: sin compra desde el 19/11/2026), 360 minutos terminan a
/// las 15:00, el cierre de Evelyn.
const int bookingCookMinutesStep = 30;
const int minBookingCookMinutes = 30;
const int maxBookingCookMinutes = 360;

/// Si la estimación no trae minutos de cocina.
const int defaultBookingCookMinutes = 180;

/// Llegada si el servidor no sugiere ninguna (ese día no tiene horario): la
/// apertura de Evelyn, sin compra antes desde el 19/11/2026.
const ClockTime defaultBookingArrival = ClockTime.hm(9, 0);

/// Horas de llegada que se ofrecen: la sugerida y las siguientes.
const int arrivalOptionsCount = 5;
const int arrivalOptionsStepMinutes = 30;

/// El servidor acepta fechas a 366 días de hoy en Roma (también pasadas, para
/// cargar lo hecho en Fase 0); la hoja deja un día de margen.
const int bookingDateRangeDays = 365;

/// Tope de cualquier importe (MAX_CENTS del contrato): 100.000 €.
const int maxBookingCents = 10000000;

/// Semanas que puede tener la reserva de un pedido: solo uno semanal tiene
/// más de una.
int maxWeeksFor(RequestType type) =>
    type == RequestType.week ? maxBookingWeeks : 1;

/// Semanas con que empieza la hoja: las del pedido (`requests.weeks`).
int initialBookingWeeks(ChefRequest request) =>
    request.weeks.clamp(1, maxWeeksFor(request.type));

/// Primera fecha: la preferida del pedido; sin ella, mañana.
CalendarDate initialBookingDate(
  ChefRequest request, {
  required CalendarDate today,
}) => request.preferredDate ?? today.addDays(1);

/// Primera fecha de un presupuesto: la de la reserva ([initialBookingDate]),
/// pero nunca antes de mañana. Una preferida de hoy o que ya pasó (un pedido
/// atendido tarde) daría un presupuesto vencido al nacer: la clienta lo acepta
/// antes de la primera llegada.
CalendarDate initialQuoteDate(
  ChefRequest request, {
  required CalendarDate today,
}) {
  final first = initialBookingDate(request, today: today);
  final tomorrow = today.addDays(1);
  return first.isBefore(tomorrow) ? tomorrow : first;
}

/// [weeks] fechas, cada 7 días desde [first].
List<CalendarDate> weeklyDates(CalendarDate first, int weeks) => [
  for (var week = 0; week < weeks; week++) first.addDays(7 * week),
];

/// Cambia la cantidad de semanas a [weeks] (1 a 8): las que se suman van al
/// final, cada 7 días desde la última; si son menos, se sacan las últimas.
List<CalendarDate> resizeBookingWeeks(List<CalendarDate> dates, int weeks) {
  RangeError.checkValueInInterval(weeks, 1, maxBookingWeeks, 'weeks');
  if (weeks <= dates.length) return dates.sublist(0, weeks);
  final added = weeklyDates(dates.last, weeks - dates.length + 1).skip(1);
  return [...dates, ...added];
}

/// Cambia la fecha de la semana [index] a [date]. La primera mueve toda la
/// reserva los mismos días (cada semana conserva su distancia a la primera);
/// cualquier otra cambia solo la suya.
List<CalendarDate> changeBookingDate(
  List<CalendarDate> dates,
  int index,
  CalendarDate date,
) {
  RangeError.checkValidIndex(index, dates, 'index');
  if (index > 0) return [...dates]..[index] = date;
  final shift = dates.first.daysUntil(date);
  return [for (final day in dates) day.addDays(shift)];
}

/// Lo que impide mandar una fecha (como valida chef_create_booking).
enum BookingDateIssue {
  /// A más de [bookingDateRangeDays] de hoy.
  outOfRange,

  /// En la misma semana (lunes a domingo) que la anterior: una sesión por
  /// semana.
  sameWeek,

  /// Antes que la anterior.
  order,
}

/// Lo que impide mandar cada fecha de [dates], en orden; null si está bien.
List<BookingDateIssue?> bookingDateIssues(
  List<CalendarDate> dates, {
  required CalendarDate today,
}) => [
  for (var i = 0; i < dates.length; i++)
    if (today.daysUntil(dates[i]).abs() > bookingDateRangeDays)
      BookingDateIssue.outOfRange
    else if (i > 0 && dates[i].startOfWeek == dates[i - 1].startOfWeek)
      BookingDateIssue.sameWeek
    else if (i > 0 && dates[i].isBefore(dates[i - 1]))
      BookingDateIssue.order
    else
      null,
];

/// Minutos de cocina que propone la hoja: los de la estimación (de cada
/// semana), entre 30 y el tope de 360.
int suggestedCookMinutes(int? estimateMinutes) =>
    (estimateMinutes ?? defaultBookingCookMinutes).clamp(
      minBookingCookMinutes,
      maxBookingCookMinutes,
    );

/// Un paso de los minutos de cocina: [direction] 1 suma y -1 resta media
/// hora. Un valor fuera de la grilla de 30 pasa al múltiplo siguiente o al
/// anterior. Siempre entre 30 y 360.
int steppedCookMinutes(int minutes, int direction) {
  final offGrid = minutes % bookingCookMinutesStep;
  final int next;
  if (offGrid == 0) {
    next = minutes + direction * bookingCookMinutesStep;
  } else {
    next = direction > 0
        ? minutes - offGrid + bookingCookMinutesStep
        : minutes - offGrid;
  }
  return next.clamp(minBookingCookMinutes, maxBookingCookMinutes);
}

/// Precio del servicio de [weeks] semanas que propone la hoja, en centavos.
/// null si no hay precio automático (más personas que el tope o una sesión
/// extra) o si la estimación no guardó las tarifas por semana: Evelyn lo
/// escribe.
/// - Con las mismas semanas que la estimación: su precio, el que vio la
///   clienta.
/// - Con otras: la tarifa por semana guardada (la de descuento desde las
///   semanas que diga) por las semanas.
int? suggestedServiceCents(RequestEstimate? estimate, {required int weeks}) {
  if (estimate == null || !estimate.hasAutoPrice) return null;
  final saved = estimate.serviceCents;
  if (weeks == (estimate.weeks ?? 1) && saved != null) return saved;
  final rate = estimate.weeklyRateCents;
  final discounted = estimate.weeklyRateDiscountedCents;
  final discountFrom = estimate.weeklyDiscountMinWeeks;
  if (rate == null || discounted == null || discountFrom == null) return null;
  // La misma regla que calcQuote (quote.ts y su copia Dart): el descuento vale
  // desde discountFrom semanas, incluida (4 semanas son 560 €, no 600 €).
  return (weeks >= discountFrom ? discounted : rate) * weeks;
}

/// Parte del servicio de cada semana al repartir [totalCents] en [weeks]
/// semanas, como split_cents: los centavos que sobran van a las primeras.
/// [firstWeekCents] es la de la primera; [even], si todas son iguales.
({int firstWeekCents, bool even}) weeklyShare(int totalCents, int weeks) => (
  firstWeekCents: (totalCents + weeks - 1) ~/ weeks,
  even: totalCents % weeks == 0,
);

/// El servicio de cada semana al repartir [totalCents] en [weeks] semanas,
/// exactamente como `private.split_cents` (la usan chef_create_booking,
/// chef_create_quote y chef_update_quote): partes que difieren como mucho en
/// un centavo, los que sobran van a las primeras y la suma es el total (500 €
/// en 3 son 166,67 + 166,67 + 166,66). Solo enteros. Lanza [RangeError] con
/// un total negativo o fuera de 1 a 100 semanas, como la base.
List<int> splitServiceCents(int totalCents, int weeks) {
  RangeError.checkNotNegative(totalCents, 'totalCents');
  RangeError.checkValueInInterval(weeks, 1, 100, 'weeks');
  final base = totalCents ~/ weeks;
  final rest = totalCents % weeks;
  return [
    for (var week = 0; week < weeks; week++) base + (week < rest ? 1 : 0),
  ];
}

/// Semanas con que empieza una reserva a mano: un mes.
const int defaultManualBookingWeeks = 4;

/// El hogar con que empieza una ficha nueva: el de la calculadora
/// (QuoteDraft.initial).
const BookingHousehold defaultManualHousehold = BookingHousehold(
  adults: 2,
  kids: 2,
  days: 5,
  meals: [Meal.dinner],
);

/// Minutos de cocina (con el tope de la hoja) y porciones de cada semana de
/// una reserva a mano, de la copia Dart de calcQuote con las tarifas por
/// defecto. Es una vista previa: el precio lo escribe Evelyn (sin compra: la
/// hace el cliente).
({int cookMinutes, int portions}) manualBookingEstimate(
  BookingHousehold household,
) {
  final quote = calcQuote(household.toQuoteInput(), defaultPricing);
  return (
    cookMinutes: suggestedCookMinutes(quote.cookMinutes),
    portions: quote.portions,
  );
}

/// El hogar de una reserva a mano para una ficha: el de su último pedido
/// semanal si trae adultos, niños, días y comidas (nunca el de un evento, que
/// no describe la casa, ni el de un cambio sin hogar); si no, los adultos y
/// niños de la ficha con 5 días y cena. Siempre dentro de los límites del
/// contrato: `clients` solo exige >= 0, y más de 30 daría un 400.
BookingHousehold householdFor({
  ClientLatestRequest? latestWeekly,
  required int fichaAdults,
  required int fichaKids,
}) {
  final latest = latestWeekly;
  if (latest != null &&
      latest.type == RequestType.week &&
      latest.adults != null &&
      latest.kids != null &&
      latest.days != null &&
      latest.meals.isNotEmpty) {
    return BookingHousehold.clamped(
      adults: latest.adults!,
      kids: latest.kids!,
      days: latest.days!,
      meals: latest.meals,
    );
  }
  return BookingHousehold.clamped(
    adults: fichaAdults,
    kids: fichaKids,
    days: defaultManualHousehold.days,
    meals: defaultManualHousehold.meals,
  );
}

/// La fecha es hoy y la llegada [start] ya pasó en Roma ([now]). El servidor
/// marca `past` solo una fecha anterior a hoy; la hoja lo avisa.
bool arrivalPassedToday({
  required CalendarDate date,
  required ClockTime start,
  required CalendarDate today,
  required ClockTime now,
}) => date == today && start.compareTo(now) < 0;

/// Horas de llegada que ofrece la hoja: la sugerida por el servidor (o la de
/// por defecto) y las siguientes de media hora en media hora, sin pasar la
/// medianoche; más [selected] (elegida con «Otra hora»), si no está, en orden.
List<ClockTime> arrivalOptions({ClockTime? suggested, ClockTime? selected}) {
  final base = suggested ?? defaultBookingArrival;
  final options = <ClockTime>{
    for (var i = 0; i < arrivalOptionsCount; i++)
      ?base.plusMinutes(i * arrivalOptionsStepMinutes),
    ?selected,
  };
  return options.toList()..sort();
}
