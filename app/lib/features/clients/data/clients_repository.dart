// Fichas de la cocinera en Supabase, para el directorio de «Nuova
// prenotazione». Las limita la RLS que ya existe (`clients` y `requests`: la
// cocinera o un colaborador suyo, con current_chef_id()); el filtro explícito
// por chef_id es para el índice. Se lee lo mínimo: nada de dirección, email,
// preferencias, notas de cocina, cuenta ni Stripe de la ficha, ni las
// restricciones, las notas o el contacto de sus pedidos.
//
// Ningún error se loguea: se traduce a [ClientsFailure] y el resto se
// descarta.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/clients/domain/chef_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Cuántas fichas se leen: sobra para la cocina de Evelyn.
const int clientsPageSize = 1000;

/// Columnas de la ficha y, embebido, su último pedido semanal (la consulta
/// filtra y ordena el embebido). `clients → requests` es la única FK entre
/// las dos tablas (`(client_id, chef_id)`), así que el embebido no es ambiguo.
const String chefClientColumns =
    'id, display_name, contact_phone, zone, adults, kids, status, '
    'requests(type, locale, adults, kids, days, meals, created_at)';

abstract interface class ClientsRepository {
  /// Las fichas de la cocinera, con su último pedido semanal. Lanza
  /// [ClientsFailure].
  Future<List<ChefClient>> fetchClients({required String chefId});
}

final clientsRepositoryProvider = Provider<ClientsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendClientsRepository()
      : SupabaseClientsRepository(client);
});

enum ClientsFailureKind {
  /// Sin conexión, error del servidor o una fila rota.
  unavailable,
}

class ClientsFailure implements Exception {
  const ClientsFailure(this.kind);

  final ClientsFailureKind kind;

  @override
  String toString() => 'ClientsFailure(${kind.name})';
}

class SupabaseClientsRepository implements ClientsRepository {
  SupabaseClientsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<ChefClient>> fetchClients({required String chefId}) async {
    try {
      final rows = await _client
          .from('clients')
          .select(chefClientColumns)
          .eq('chef_id', chefId)
          // Filtra los pedidos embebidos, no las fichas: una sin pedidos
          // semanales viene igual, con la lista vacía. Sin el filtro, el
          // último podía ser un evento (`extra`, que no describe la casa) o un
          // cambio sin hogar.
          .eq('requests.type', 'week')
          .order('created_at', referencedTable: 'requests', ascending: false)
          .limit(1, referencedTable: 'requests')
          // Ascendente (por defecto es descendente): con más fichas que el
          // límite, quedan afuera las últimas por nombre. El orden que se
          // muestra lo decide compareClientsForPicker.
          .order('display_name', ascending: true)
          .limit(clientsPageSize);
      return rows.map(ChefClient.fromJson).toList();
    } on Object {
      // PostgREST, red o una fila rota (FormatException): nada pasa al log.
      throw const ClientsFailure(ClientsFailureKind.unavailable);
    }
  }
}

class _NoBackendClientsRepository implements ClientsRepository {
  const _NoBackendClientsRepository();

  @override
  Future<List<ChefClient>> fetchClients({required String chefId}) =>
      Future.error(const ClientsFailure(ClientsFailureKind.unavailable));
}
