// Rol del usuario y, si es cocinera, su ficha en `chefs`. Las políticas RLS
// de M1 dejan leer el propio perfil y la propia ficha.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mestolo/core/supabase_client.dart';
import 'package:mestolo/features/auth/domain/auth_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract interface class AccountRepository {
  /// Lanza [AccountFailure].
  Future<Account> fetchAccount(String userId);
}

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendAccountRepository()
      : SupabaseAccountRepository(client);
});

class SupabaseAccountRepository implements AccountRepository {
  SupabaseAccountRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Account> fetchAccount(String userId) async {
    final Map<String, dynamic>? profile;
    final Map<String, dynamic>? chef;
    try {
      profile = await _client
          .from('profiles')
          .select('role')
          .eq('id', userId)
          .maybeSingle();
      if (profile?['role'] != 'chef') {
        return const Account(role: AccountRole.client);
      }
      chef = await _client
          .from('chefs')
          .select('id, display_name')
          .eq('profile_id', userId)
          .maybeSingle();
    } on Object {
      throw const AccountFailure(AccountFailureKind.unavailable);
    }

    final chefId = chef?['id'];
    final displayName = chef?['display_name'];
    if (chefId is! String || displayName is! String) {
      throw const AccountFailure(AccountFailureKind.chefNotConfigured);
    }
    return Account(
      role: AccountRole.chef,
      chef: ChefAccount(chefId: chefId, displayName: displayName),
    );
  }
}

class _NoBackendAccountRepository implements AccountRepository {
  const _NoBackendAccountRepository();

  @override
  Future<Account> fetchAccount(String userId) =>
      Future.error(const AccountFailure(AccountFailureKind.unavailable));
}
