// Perfil del usuario (rol e idioma) y, si es cocinera, su ficha en `chefs`.
// Las políticas RLS de M1 dejan leer el propio perfil y la propia ficha, y
// cambiar del perfil solo full_name, phone y locale (20261019100200_rls.sql).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract interface class AccountRepository {
  /// Lanza [AccountFailure].
  Future<Account> fetchAccount(String userId);

  /// Guarda [language] como idioma de la interfaz de [userId]
  /// (`profiles.locale`). Lanza [AccountFailure].
  Future<void> updateLanguage({
    required String userId,
    required AppLanguage language,
  });
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
          .select('role, locale')
          .eq('id', userId)
          .maybeSingle();
      if (profile?['role'] != 'chef') {
        return Account(
          role: AccountRole.client,
          language: AppLanguage.fromCode(profile?['locale']),
        );
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
      language: AppLanguage.fromCode(profile?['locale']),
    );
  }

  @override
  Future<void> updateLanguage({
    required String userId,
    required AppLanguage language,
  }) async {
    final List<Map<String, dynamic>> updated;
    try {
      updated = await _client
          .from('profiles')
          .update({'locale': language.code})
          .eq('id', userId)
          .select('locale');
    } on Object {
      throw const AccountFailure(AccountFailureKind.unavailable);
    }
    // Sin filas: el perfil no existe o RLS no lo deja tocar.
    if (updated.isEmpty) {
      throw const AccountFailure(AccountFailureKind.unavailable);
    }

    // El email con el código de acceso sale en el idioma de
    // `user_metadata.locale` (supabase/templates/login_code.html), que solo
    // se fija al crear el usuario: se actualiza también. Si falla, el perfil
    // ya quedó guardado y la interfaz no depende de esto: no se revierte.
    try {
      await _client.auth.updateUser(
        UserAttributes(data: {'locale': language.code}),
      );
    } on Object {
      // Sin efecto en la interfaz: el próximo email del código puede llegar
      // en el idioma anterior.
    }
  }
}

class _NoBackendAccountRepository implements AccountRepository {
  const _NoBackendAccountRepository();

  static const _failure = AccountFailure(AccountFailureKind.unavailable);

  @override
  Future<Account> fetchAccount(String userId) => Future.error(_failure);

  @override
  Future<void> updateLanguage({
    required String userId,
    required AppLanguage language,
  }) => Future.error(_failure);
}
