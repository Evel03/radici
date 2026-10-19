// Pedidos y filas de ejemplo para los tests. Datos inventados.
import 'package:mestolo/core/rome_time.dart';
import 'package:mestolo/features/auth/domain/auth_models.dart';
import 'package:mestolo/features/requests/domain/chef_request.dart';

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
  Object? restrictions = const {
    'allergens': ['milk', 'gluten'],
    'diets': ['vegetarian'],
    'note': 'niente funghi',
  },
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
  'restrictions': restrictions,
  'notes': 'Citofono: Rossi',
  'preferred_date': preferredDate,
  'preferred_slot': preferredSlot,
  'locale': locale,
  'whatsapp_opt_in': true,
  'estimate': estimate,
  'source': 'web',
  'seen_at': seenAt,
  'created_at': createdAt,
  'client': {
    'display_name': name,
    'contact_email': email,
    'contact_phone': phone,
    'zone': 'Città Alta',
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
  RequestEstimate? estimate = const RequestEstimate(
    portions: 20,
    recipes: 3,
    cookMinutes: 180,
    serviceCents: 7800,
    groceriesEstCents: 6300,
    totalCents: 14100,
  ),
  String chefId = testChefId,
}) => ChefRequest(
  id: id,
  chefId: chefId,
  clientId: testClientId,
  type: RequestType.week,
  status: status,
  adults: 2,
  kids: 2,
  days: 5,
  meals: const [Meal.dinner],
  restrictions: restrictions,
  notes: 'Citofono: Rossi',
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
  ),
);
