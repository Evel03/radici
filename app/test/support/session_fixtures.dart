// Sesiones de ejemplo para los tests. Datos inventados.
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import 'request_fixtures.dart';

/// Pedido de una reserva de ejemplo.
const String bookingRequestId = 'b0000000-0000-4000-8000-0000000000aa';

/// Las restricciones como llegan del formulario web: sin alérgenos ni dietas
/// (la web manda `allergens: []` y `diets: []`), la alergia solo en la nota,
/// y sin filas en `client_restrictions`. Así llegan casi todas las reservas
/// con alergias.
const RequestRestrictions webRestrictions = RequestRestrictions(
  note: 'Celiachia, noci',
);

/// Id de la sesión [n] (de 1 a 99).
String sessionId(int n) =>
    'd0000000-0000-4000-8000-0000000000${n.toString().padLeft(2, '0')}';

/// Fila de PostgREST como la devuelve `select(cookingSessionColumns)`.
/// [clientAnswers] son los pedidos de la clienta embebidos en la ficha
/// (`client.answers`: type, source, status, created_at, restrictions y
/// no_allergies).
Map<String, dynamic> sessionRow({
  String? id,
  String date = '2026-11-25',
  String startTime = '10:00:00',
  int cookMinutes = 180,
  int shopMinutes = 0,
  int gapMinutes = 30,
  String status = 'confirmed',
  String? requestId = bookingRequestId,
  String? address = 'Via Gombito 12, 24129 Bergamo',
  List<Map<String, Object?>> clientRestrictions = const [
    {'allergen': 'gluten', 'diet': null},
  ],
  List<Map<String, Object?>> clientAnswers = const [],
  Map<String, dynamic>? request,
}) => {
  'id': id ?? sessionId(1),
  'chef_id': testChefId,
  'client_id': testClientId,
  'request_id': requestId,
  'date': date,
  'start_time': startTime,
  'cook_minutes': cookMinutes,
  'shop_minutes': shopMinutes,
  'gap_minutes': gapMinutes,
  'portions': 20,
  'status': status,
  'service_cents': 14000,
  'cancelled_at': status == 'cancelled' ? '2026-11-20T10:00:00+00:00' : null,
  'cancel_reason': status == 'cancelled' ? 'client_cancelled' : null,
  'client': {
    'display_name': 'Famiglia Rossi',
    'contact_email': 'giulia@example.test',
    'contact_phone': '+39 333 999 0000',
    'zone': 'Città Alta',
    'address': address,
    'adults': 2,
    'kids': 2,
    'kitchen_notes': 'Forno a gas',
    'status': 'trial',
    'restrictions': clientRestrictions,
    'answers': clientAnswers,
  },
  'request': requestId == null
      ? null
      : request ??
            requestRow(
              id: requestId,
              status: 'accepted',
              weeks: 4,
              seenAt: '2026-10-19T12:00:00+00:00',
            ),
};

/// Sesión armada a mano (sin pasar por JSON): por defecto, una semana
/// confirmada de la reserva [bookingRequestId] (un pedido semanal, [type],
/// aceptado, [requestStatus], que llegó por la web, [requestSource]; una
/// reserva a mano es de la app) de la ficha [testClientId], el miércoles
/// 25/11/2026 a las 10:00, con 180 min de cocina y sin compra (`shop_minutes`
/// 0, como las sesiones creadas desde el 19/11/2026; las de antes guardan 45),
/// 20 porciones y 140 € de servicio. [estimate] es la del pedido embebido.
/// [lastAllergyAnswer] es la respuesta de su último pedido semanal de la web
/// que se reservó (la que toma una sesión semanal cuyo pedido no responde).
/// [wishes] son los platos que la clienta eligió en la web y [meals], las
/// comidas de cada día del pedido (por defecto, la cena).
CookingSession buildSession({
  int n = 1,
  String? id,
  String clientId = testClientId,
  CalendarDate? date,
  ClockTime start = const ClockTime.hm(10, 0),
  int cookMinutes = 180,
  int shopMinutes = 0,
  int gapMinutes = 30,
  int portions = 20,
  int serviceCents = 14000,
  SessionStatus status = SessionStatus.confirmed,
  String? requestId = bookingRequestId,
  String name = 'Giulia Rossi',
  String? phone = '+39 333 123 4567',
  String? address = 'Via Gombito 12, 24129 Bergamo',
  List<Allergen> clientAllergens = const [],
  List<Diet> clientDiets = const [],
  PastAllergyAnswer? lastAllergyAnswer,
  RequestRestrictions? restrictions,
  bool? noAllergies,
  ClientLocale locale = ClientLocale.it,
  int weeks = 4,
  RequestEstimate? estimate = legacyEstimate,
  String? cancelReason,
  RequestType type = RequestType.week,
  RequestStatus requestStatus = RequestStatus.accepted,
  RequestSource requestSource = RequestSource.web,
  List<String> wishes = const [],
  List<Meal> meals = const [Meal.dinner],
}) => CookingSession(
  id: id ?? sessionId(n),
  chefId: testChefId,
  clientId: clientId,
  requestId: requestId,
  date: date ?? CalendarDate(2026, 11, 25),
  start: start,
  cookMinutes: cookMinutes,
  shopMinutes: shopMinutes,
  gapMinutes: gapMinutes,
  portions: portions,
  status: status,
  serviceCents: serviceCents,
  cancelledAt: status == SessionStatus.cancelled
      ? DateTime.utc(2026, 11, 20, 10)
      : null,
  cancelReason: cancelReason,
  client: SessionClient(
    displayName: name,
    contactPhone: phone,
    zone: 'Città Alta',
    address: address,
    adults: 2,
    kids: 2,
    kitchenNotes: 'Forno a gas',
    status: ClientStatus.trial,
    allergens: clientAllergens,
    diets: clientDiets,
    lastAllergyAnswer: lastAllergyAnswer,
  ),
  request: requestId == null
      ? null
      : buildRequest(
          id: requestId,
          clientId: clientId,
          status: requestStatus,
          name: name,
          phone: phone,
          locale: locale,
          restrictions: restrictions,
          noAllergies: noAllergies,
          weeks: weeks,
          estimate: estimate,
          seenAt: DateTime.utc(2026, 10, 19, 12),
          type: type,
          source: requestSource,
          wishes: wishes,
          meals: meals,
        ),
);

/// Las [weeks] semanas de una reserva (el pedido [requestId] de la ficha
/// [clientId]), cada 7 días desde [first] (miércoles 25/11/2026), con ids
/// `sessionId(firstN)`, `sessionId(firstN + 1)`… [statuses] va por semana,
/// desde 1, y [serviceCents] es el servicio de cada semana. [address] null:
/// una reserva que llegó por la web (el formulario no pide la dirección).
/// [requestSource] app: una reserva cargada a mano. [estimate] es la del
/// pedido. [lastAllergyAnswer] y [wishes], los de buildSession.
List<CookingSession> buildBooking({
  int weeks = 4,
  CalendarDate? first,
  int firstN = 1,
  String requestId = bookingRequestId,
  String clientId = testClientId,
  Map<int, SessionStatus> statuses = const {},
  int portions = 20,
  int serviceCents = 14000,
  String name = 'Giulia Rossi',
  String? address = 'Via Gombito 12, 24129 Bergamo',
  List<Allergen> clientAllergens = const [],
  PastAllergyAnswer? lastAllergyAnswer,
  RequestRestrictions? restrictions,
  bool? noAllergies,
  ClientLocale locale = ClientLocale.it,
  RequestEstimate? estimate = legacyEstimate,
  RequestSource requestSource = RequestSource.web,
  List<String> wishes = const [],
}) {
  final start = first ?? CalendarDate(2026, 11, 25);
  return [
    for (var week = 1; week <= weeks; week++)
      buildSession(
        n: firstN + week - 1,
        requestId: requestId,
        clientId: clientId,
        date: start.addDays(7 * (week - 1)),
        status: statuses[week] ?? SessionStatus.confirmed,
        portions: portions,
        serviceCents: serviceCents,
        name: name,
        address: address,
        clientAllergens: clientAllergens,
        lastAllergyAnswer: lastAllergyAnswer,
        restrictions: restrictions,
        noAllergies: noAllergies,
        locale: locale,
        weeks: weeks,
        estimate: estimate,
        requestSource: requestSource,
        wishes: wishes,
      ),
  ];
}
