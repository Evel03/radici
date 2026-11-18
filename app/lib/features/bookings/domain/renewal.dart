// «Rinnova» (decisión 2 del plan): de las sesiones de una reserva semanal
// sale lo que propone la hoja «Rinnova prenotazione», una reserva a mano para
// la misma ficha (clientId). Dart puro.
//
// - Se puede renovar si el pedido embebido está aceptado, es semanal y hay al
//   menos una sesión viva. La última viva manda: la primera fecha es esa
//   + 7 días (mismo día de la semana) y se copian su llegada, sus minutos
//   (tal cual: el contrato admite hasta 720), sus porciones y su compra.
// - Las semanas y el precio cuentan todas las sesiones de la reserva, también
//   las canceladas: es lo que se reservó y se acordó (split_cents suma el
//   total exacto).
// - El hogar (ajustado a los límites del contrato) y el idioma son los del
//   pedido renovado; su estimación sirve para el precio de otra cantidad de
//   semanas.
//
// Lleva la sesión, con los datos de la clienta: toString no los muestra.
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/phone.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';

/// Lo que propone «Rinnova» para una reserva.
final class RenewalPlan {
  const RenewalPlan({
    required this.last,
    required this.clientId,
    required this.weeks,
    required this.firstDate,
    required this.start,
    required this.cookMinutes,
    required this.serviceTotalCents,
    required this.portions,
    required this.groceriesEstCents,
    required this.household,
    required this.locale,
    this.estimate,
    this.lastDiffers = false,
    this.otherRequestPhone,
  });

  /// La última sesión viva de la reserva que se renueva.
  final CookingSession last;

  /// La ficha de la reserva: la renovación va con clientId.
  final String clientId;

  /// Las de la reserva (también las canceladas), de 1 a 8.
  final int weeks;

  /// La última viva + 7 días.
  final CalendarDate firstDate;
  final ClockTime start;
  final int cookMinutes;

  /// La suma del servicio de todas las sesiones, también las canceladas.
  final int serviceTotalCents;
  final int portions;
  final int groceriesEstCents;
  final BookingHousehold household;
  final ClientLocale locale;

  /// La del pedido renovado: con sus tarifas se propone el precio de otra
  /// cantidad de semanas ([renewalPriceFor]).
  final RequestEstimate? estimate;

  /// El día de la semana y la hora de la última viva no son los de más de la
  /// mitad de las vivas de la reserva: alguna semana se movió (o se reservó
  /// así). El día y la hora de la renovación salen igual de la última. Las
  /// sesiones no guardan cuál se movió (con dos semanas distintas no se puede
  /// saber), así que el encabezado no dice que fue la última.
  final bool lastDiffers;

  /// El teléfono del pedido renovado, como lo escribió la clienta, si no es
  /// el de la ficha (la web no cambia una ficha que ya existe). El WhatsApp y
  /// las sesiones nuevas usan el de la ficha.
  final String? otherRequestPhone;

  /// Una fecha por semana, cada 7 días desde [firstDate].
  List<CalendarDate> get dates => weeklyDates(firstDate, weeks);

  /// Sin datos de la clienta.
  @override
  String toString() => 'RenewalPlan(${last.id}, weeks: $weeks)';
}

/// Lo que propone «Rinnova» para la reserva de [booking] (todas sus
/// sesiones, también las canceladas); null si no se puede renovar: una
/// sesión extra, sin pedido, un pedido que no es una reserva semanal o una
/// reserva sin sesiones vivas.
RenewalPlan? renewalPlan(Iterable<CookingSession> booking) {
  final live = [
    for (final session in booking)
      if (session.isLive) session,
  ]..sort(compareSessions);
  if (live.isEmpty) return null;
  final last = live.last;
  final request = last.request;
  if (last.requestId == null ||
      request == null ||
      !request.isBooking ||
      request.type != RequestType.week) {
    return null;
  }
  final sessions = [
    for (final session in booking)
      if (session.requestId == last.requestId) session,
  ];
  final ofBooking = [
    for (final session in live)
      if (session.requestId == last.requestId) session,
  ];
  return RenewalPlan(
    last: last,
    clientId: last.clientId,
    weeks: sessions.length.clamp(1, maxBookingWeeks),
    firstDate: last.date.addDays(7),
    start: last.start,
    cookMinutes: last.cookMinutes,
    serviceTotalCents: sessions.fold(0, (sum, s) => sum + s.serviceCents),
    portions: last.portions,
    groceriesEstCents: last.groceriesEstCents,
    household: _householdOf(request, last.client),
    locale: request.locale,
    estimate: request.estimate,
    lastDiffers: _lastDiffers(ofBooking),
    otherRequestPhone: _otherPhone(request, last.client),
  );
}

/// La última de [live] (las sesiones vivas de una reserva, en orden) no tiene
/// el día de la semana y la hora de más de la mitad de ellas.
bool _lastDiffers(List<CookingSession> live) {
  final last = live.last;
  final same = live
      .where(
        (session) =>
            session.date.weekday == last.date.weekday &&
            session.start == last.start,
      )
      .length;
  return same * 2 <= live.length;
}

/// El precio de [weeks] semanas de una renovación mientras Evelyn no lo
/// escriba: con las mismas semanas, el total original; con otras, el de las
/// tarifas de [estimate] solo si el total original es el que dan esas tarifas
/// (respeta el mínimo del descuento: 560 € en 4 semanas pasa a 300 € en 2).
/// Si no (una reserva a mano, un precio acordado distinto o sin tarifas),
/// null: lo escribe Evelyn. Repartir el total por semana cobraría de menos
/// sin aviso (280 € en vez de 300 €), y el precio no se cambia después.
int? renewalPriceFor({
  required int originalTotal,
  required int originalWeeks,
  required int weeks,
  RequestEstimate? estimate,
}) {
  if (weeks == originalWeeks) return originalTotal;
  if (estimate == null ||
      suggestedServiceCents(estimate, weeks: originalWeeks) != originalTotal) {
    return null;
  }
  return suggestedServiceCents(estimate, weeks: weeks);
}

/// El hogar del pedido renovado; si le falta algo, los adultos y niños de la
/// ficha (sin el dato, los valores por defecto de `clients`: 1 y 0) con 5
/// días y cena. Siempre dentro de los límites del contrato.
BookingHousehold _householdOf(ChefRequest request, SessionClient client) {
  final adults = request.adults;
  final kids = request.kids;
  final days = request.days;
  if (adults != null &&
      kids != null &&
      days != null &&
      request.meals.isNotEmpty) {
    return BookingHousehold.clamped(
      adults: adults,
      kids: kids,
      days: days,
      meals: request.meals,
    );
  }
  return BookingHousehold.clamped(
    adults: client.adults ?? 1,
    kids: client.kids ?? 0,
    days: defaultManualHousehold.days,
    meals: defaultManualHousehold.meals,
  );
}

/// El teléfono del pedido (con el contacto que llegó de la web) si no es el
/// de la ficha; null si es el mismo (escrito de otra forma también) o si no
/// tiene.
String? _otherPhone(ChefRequest request, SessionClient client) {
  final phone = request.client.contactPhone?.trim();
  if (phone == null || phone.isEmpty) return null;
  final mine = client.contactPhone?.trim();
  final same =
      (phoneFromInput(phone) ?? phone) ==
      (mine == null ? null : phoneFromInput(mine) ?? mine);
  return same ? null : phone;
}
