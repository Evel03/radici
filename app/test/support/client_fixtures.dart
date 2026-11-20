// Fichas de clientes de ejemplo para los tests. Datos inventados.
import 'package:radici/features/clients/domain/chef_client.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import 'request_fixtures.dart';

/// Una ficha como la arma ChefClient.fromJson.
ChefClient buildClient({
  String id = testClientId,
  String name = 'Chiara Rossi',
  String? phone = '+39 340 111 2233',
  String? zone = 'Città Alta',
  int adults = 2,
  int kids = 1,
  ClientStatus? status = ClientStatus.active,
  ClientLatestRequest? latestWeekly,
}) => ChefClient(
  id: id,
  displayName: name,
  contactPhone: phone,
  zone: zone,
  adults: adults,
  kids: kids,
  status: status,
  latestWeekly: latestWeekly,
);

/// El último pedido semanal de una ficha.
ClientLatestRequest buildLatestWeekly({
  RequestType type = RequestType.week,
  ClientLocale locale = ClientLocale.it,
  int? adults = 2,
  int? kids = 1,
  int? days = 5,
  List<Meal> meals = const [Meal.dinner],
  DateTime? createdAt,
}) => ClientLatestRequest(
  type: type,
  locale: locale,
  adults: adults,
  kids: kids,
  days: days,
  meals: meals,
  createdAt: createdAt ?? DateTime.utc(2026, 10, 15, 9),
);

/// Fila de PostgREST como la devuelve la consulta del directorio, con el
/// último pedido semanal embebido ([requests]: ninguno, por defecto).
Map<String, dynamic> clientRow({
  String id = testClientId,
  Object? name = 'Chiara Rossi',
  Object? phone = '+39 340 111 2233',
  Object? zone = 'Città Alta',
  Object? adults = 2,
  Object? kids = 1,
  Object? status = 'active',
  Object? requests = const <Object>[],
}) => {
  'id': id,
  'display_name': name,
  'contact_phone': phone,
  'zone': zone,
  'adults': adults,
  'kids': kids,
  'status': status,
  'requests': requests,
};

/// Un pedido embebido en [clientRow].
Map<String, dynamic> latestRequestRow({
  Object? type = 'week',
  Object? locale = 'es',
  Object? adults = 2,
  Object? kids = 2,
  Object? days = 4,
  Object? meals = const ['dinner', 'lunch'],
  Object? createdAt = '2026-11-15T09:30:00+00:00',
}) => {
  'type': type,
  'locale': locale,
  'adults': adults,
  'kids': kids,
  'days': days,
  'meals': meals,
  'created_at': createdAt,
};
