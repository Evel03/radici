// La lista de ofertas y novedades de la cocina, en Supabase
// (public.marketing_contacts, contrato public-request §13). La limita la RLS
// (la cocinera o un colaborador suyo: current_chef_id()) y la base solo deja
// leer algunas columnas; el filtro por chef_id es para el índice. Se leen los
// pendientes y los confirmados; las bajas, no.
//
// Ningún error se loguea: se traduce a [MarketingContactsFailure].
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/marketing/domain/marketing_contact.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Cuántos contactos se leen: sobra para la cocina de Evelyn.
const int marketingContactsPageSize = 2000;

abstract interface class MarketingContactsRepository {
  /// Los pendientes y confirmados de la cocina, del más nuevo al más viejo.
  /// Lanza [MarketingContactsFailure].
  Future<List<MarketingContact>> fetchContacts({required String chefId});

  /// Da de baja [email] en la lista de la cocina (public.chef_marketing_withdraw:
  /// cuando la persona se lo pide a Evelyn). true si estaba; false si no (o ya
  /// estaba de baja). Lanza [MarketingContactsFailure].
  Future<bool> withdraw(String email);
}

final marketingContactsRepositoryProvider =
    Provider<MarketingContactsRepository>((ref) {
      final client = ref.watch(supabaseClientProvider);
      return client == null
          ? const _NoBackendMarketingContactsRepository()
          : SupabaseMarketingContactsRepository(client);
    });

class MarketingContactsFailure implements Exception {
  const MarketingContactsFailure();

  @override
  String toString() => 'MarketingContactsFailure';
}

class SupabaseMarketingContactsRepository
    implements MarketingContactsRepository {
  SupabaseMarketingContactsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<MarketingContact>> fetchContacts({required String chefId}) async {
    try {
      final rows = await _client
          .from('marketing_contacts')
          .select(MarketingContact.columns)
          .eq('chef_id', chefId)
          .inFilter('status', ['pending', 'confirmed'])
          .order('requested_at', ascending: false)
          .limit(marketingContactsPageSize);
      return rows.map(MarketingContact.fromJson).toList();
    } on Object {
      // PostgREST, red o una fila rota: nada pasa al log.
      throw const MarketingContactsFailure();
    }
  }

  @override
  Future<bool> withdraw(String email) async {
    try {
      final result = await _client.rpc<dynamic>(
        'chef_marketing_withdraw',
        params: {'p_email': email},
      );
      return result == true;
    } on Object {
      throw const MarketingContactsFailure();
    }
  }
}

class _NoBackendMarketingContactsRepository
    implements MarketingContactsRepository {
  const _NoBackendMarketingContactsRepository();

  @override
  Future<List<MarketingContact>> fetchContacts({required String chefId}) =>
      Future.error(const MarketingContactsFailure());

  @override
  Future<bool> withdraw(String email) =>
      Future.error(const MarketingContactsFailure());
}
