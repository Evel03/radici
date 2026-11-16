// Sesiones de ejemplo para los tests. Datos inventados.
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import 'request_fixtures.dart';

/// Pedido de una reserva de ejemplo.
const String bookingRequestId = 'b0000000-0000-4000-8000-0000000000aa';

/// Id de la sesión [n] (de 1 a 99).
String sessionId(int n) =>
    'd0000000-0000-4000-8000-0000000000${n.toString().padLeft(2, '0')}';

/// Fila de PostgREST como la devuelve `select(cookingSessionColumns)`.
Map<String, dynamic> sessionRow({
  String? id,
  String date = '2026-11-25',
  String startTime = '10:00:00',
  int cookMinutes = 180,
  int shopMinutes = 45,
  int gapMinutes = 30,
  String status = 'confirmed',
  String? requestId = bookingRequestId,
  String? address = 'Via Gombito 12, 24129 Bergamo',
  List<Map<String, Object?>> clientRestrictions = const [
    {'allergen': 'gluten', 'diet': null},
  ],
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
  'groceries_est_cents': 6300,
  'groceries_actual_cents': null,
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
/// confirmada de la reserva [bookingRequestId], el miércoles 25/11/2026 a
/// las 10:00, con 45 min de compra y 180 de cocina.
CookingSession buildSession({
  int n = 1,
  String? id,
  CalendarDate? date,
  ClockTime start = const ClockTime.hm(10, 0),
  int cookMinutes = 180,
  int shopMinutes = 45,
  int gapMinutes = 30,
  SessionStatus status = SessionStatus.confirmed,
  String? requestId = bookingRequestId,
  String name = 'Giulia Rossi',
  String? phone = '+39 333 123 4567',
  String? address = 'Via Gombito 12, 24129 Bergamo',
  List<Allergen> clientAllergens = const [],
  RequestRestrictions? restrictions,
  bool? noAllergies,
  ClientLocale locale = ClientLocale.it,
  int weeks = 4,
  String? cancelReason,
}) => CookingSession(
  id: id ?? sessionId(n),
  chefId: testChefId,
  clientId: testClientId,
  requestId: requestId,
  date: date ?? CalendarDate(2026, 11, 25),
  start: start,
  cookMinutes: cookMinutes,
  shopMinutes: shopMinutes,
  gapMinutes: gapMinutes,
  portions: 20,
  status: status,
  serviceCents: 14000,
  groceriesEstCents: 6300,
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
  ),
  request: requestId == null
      ? null
      : buildRequest(
          id: requestId,
          status: RequestStatus.accepted,
          name: name,
          phone: phone,
          locale: locale,
          restrictions: restrictions,
          noAllergies: noAllergies,
          weeks: weeks,
          seenAt: DateTime.utc(2026, 10, 19, 12),
        ),
);

/// Las [weeks] semanas de una reserva, cada 7 días desde [first] (miércoles
/// 25/11/2026), con ids `sessionId(1)`, `sessionId(2)`…
List<CookingSession> buildBooking({
  int weeks = 4,
  CalendarDate? first,
  Map<int, SessionStatus> statuses = const {},
  String name = 'Giulia Rossi',
  List<Allergen> clientAllergens = const [],
  RequestRestrictions? restrictions,
  ClientLocale locale = ClientLocale.it,
}) {
  final start = first ?? CalendarDate(2026, 11, 25);
  return [
    for (var week = 1; week <= weeks; week++)
      buildSession(
        n: week,
        date: start.addDays(7 * (week - 1)),
        status: statuses[week] ?? SessionStatus.confirmed,
        name: name,
        clientAllergens: clientAllergens,
        restrictions: restrictions,
        locale: locale,
        weeks: weeks,
      ),
  ];
}
