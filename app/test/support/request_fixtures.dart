// Pedidos y filas de ejemplo para los tests. Datos inventados.
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

const String testChefId = '11111111-1111-4111-8111-111111111111';
const String testClientId = '22222222-2222-4222-8222-222222222222';

const AppUser chefUser = AppUser(id: 'chef-user', email: 'evelyn@example.test');
const ChefAccount chefAccount = ChefAccount(
  chefId: testChefId,
  displayName: 'Evelyn',
);
const Account chefAccountData = Account(
  role: AccountRole.chef,
  chef: chefAccount,
);

/// "Ahora" de los tests: lunes 19/10/2026 a las 14:00 en Roma.
final DateTime testNow = DateTime.utc(2026, 10, 19, 12);

/// Fila de PostgREST como la devuelve `select(chefRequestColumns)`.
Map<String, dynamic> requestRow({
  String id = 'req-1',
  String status = 'new',
  String? seenAt,
  String? preferredDate = '2026-10-21',
  String? preferredSlot = 'morning',
  String createdAt = '2026-10-19T09:15:30.123456+00:00',
  String name = 'Giulia Rossi',
  String phone = '+39 333 123 4567',
  String email = 'giulia@example.test',
  String locale = 'it',
  String? clientStatus = 'prospect',
  // Semanas del pedido (requests.weeks): 1 en los pedidos anteriores al precio por semana.
  int weeks = 1,
  // Copia del contacto con que llegó el pedido (requests.contact); null en los de la app.
  Object? contact,
  Object? restrictions = const {
    'allergens': ['milk', 'gluten'],
    'diets': ['vegetarian'],
    'note': 'niente funghi',
  },
  // Respuesta a la pregunta de alergias (requests.no_allergies); null en los pedidos anteriores.
  Object? noAllergies,
  // Platos que eligió en la pestaña «Menù» de la web (requests.wishes), en orden.
  Object? wishes = const <Object>[],
  // Por defecto, una estimación de antes del precio por semana (servicio por
  // hora, sin autoPrice), con las claves de compra que se guardaban entonces.
  Object? estimate = const {
    'adultPortions': 10,
    'kidPortions': 10,
    'portions': 20,
    'recipes': 3,
    'cookMinutes': 180,
    'serviceCents': 7800,
    'groceriesEstCents': 6300,
    'preauthCents': 7245,
    'holdCents': 15045,
    'totalCents': 14100,
    'pricing': {'hourlyRateCents': 2200},
  },
}) => {
  'id': id,
  'chef_id': testChefId,
  'client_id': testClientId,
  'type': 'week',
  'status': status,
  'adults': 2,
  'kids': 2,
  'days': 5,
  'meals': ['dinner'],
  'weeks': weeks,
  'restrictions': restrictions,
  'no_allergies': noAllergies,
  'notes': 'Citofono: Rossi',
  'wishes': wishes,
  'preferred_date': preferredDate,
  'preferred_slot': preferredSlot,
  'locale': locale,
  'whatsapp_opt_in': true,
  'estimate': estimate,
  'source': 'web',
  'seen_at': seenAt,
  'created_at': createdAt,
  'contact': contact,
  'client': {
    'display_name': name,
    'contact_email': email,
    'contact_phone': phone,
    'zone': 'Città Alta',
    'status': clientStatus,
  },
};

/// Pedido armado a mano (sin pasar por JSON).
ChefRequest buildRequest({
  String id = 'req-1',
  RequestStatus status = RequestStatus.newRequest,
  DateTime? seenAt,
  CalendarDate? preferredDate,
  bool noDate = false,
  PreferredSlot? preferredSlot = PreferredSlot.morning,
  DateTime? createdAt,
  String name = 'Giulia Rossi',
  String? phone = '+39 333 123 4567',
  String? email = 'giulia@example.test',
  ClientLocale locale = ClientLocale.it,
  RequestRestrictions? restrictions,
  bool? noAllergies,
  // Por defecto, una estimación de antes del precio por semana (sin autoPrice).
  RequestEstimate? estimate = const RequestEstimate(
    portions: 20,
    recipes: 3,
    cookMinutes: 180,
    serviceCents: 7800,
  ),
  String chefId = testChefId,
  String clientId = testClientId,
  ClientStatus? clientStatus = ClientStatus.prospect,
  RequestType type = RequestType.week,
  int weeks = 1,
  int? days = 5,
  // Platos que eligió en la web (ids de recipes), en orden.
  List<String> wishes = const [],
}) => ChefRequest(
  id: id,
  chefId: chefId,
  clientId: clientId,
  type: type,
  status: status,
  adults: 2,
  kids: 2,
  days: days,
  meals: const [Meal.dinner],
  weeks: weeks,
  restrictions: restrictions,
  noAllergies: noAllergies,
  notes: 'Citofono: Rossi',
  wishes: wishes,
  preferredDate: noDate ? null : (preferredDate ?? CalendarDate(2026, 10, 21)),
  preferredSlot: preferredSlot,
  locale: locale,
  whatsappOptIn: true,
  estimate: estimate,
  source: RequestSource.web,
  seenAt: seenAt,
  createdAt: createdAt ?? DateTime.utc(2026, 10, 19, 9, 15),
  client: RequestClient(
    displayName: name,
    contactEmail: email,
    contactPhone: phone,
    zone: 'Città Alta',
    status: clientStatus,
  ),
);
