// Perfil del usuario (rol e idioma) y, si es del lado de la cocinera, la ficha
// de su cocina en `chefs`: la suya o, si es colaborador, la de la cocinera
// (`chef_members`, 20261116190000_chef_members.sql). Las políticas RLS dejan
// leer el propio perfil y la ficha de la propia cocina, y cambiar del perfil
// solo full_name, phone y locale (20261019100200_rls.sql).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/domain/sign_up_form.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// public.save_account_details rechazó campos (22023 invalid_account_details):
/// los nombres vienen en el detalle, nunca los valores.
class AccountDetailsRejected implements Exception {
  const AccountDetailsRejected(this.fields);

  final Set<SignUpField> fields;

  @override
  String toString() => 'AccountDetailsRejected(${fields.map((f) => f.name).join(', ')})';
}

abstract interface class AccountRepository {
  /// Lanza [AccountFailure].
  Future<Account> fetchAccount(String userId);

  /// Guarda [language] como idioma de la interfaz de [userId]
  /// (`profiles.locale`). Lanza [AccountFailure].
  Future<void> updateLanguage({
    required String userId,
    required AppLanguage language,
  });

  /// «Crear cuenta»: los datos de la cuenta de la sesión
  /// (public.save_account_details, auth.md §18), ya armados con
  /// [accountDetailsPayload]. Lanza [AccountDetailsRejected] con los campos
  /// que la base rechazó, o [AccountFailure].
  Future<void> saveAccountDetails(Map<String, Object?> details);
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
    Map<String, dynamic>? chef;
    try {
      profile = await _client
          .from('profiles')
          .select('role, locale')
          .eq('id', userId)
          .maybeSingle();
      if (profile?['role'] != 'chef') {
        return Account(
          role: AccountRole.client,
          client: const ClientAccount(),
          language: AppLanguage.fromCode(profile?['locale']),
        );
      }
      // La cocina la dice la base, con la misma función que las políticas:
      // la de la que es dueña o colaborador, o null.
      final currentChefId = await _client.rpc<Object?>('current_chef_id');
      if (currentChefId is String) {
        chef = await _client
            .from('chefs')
            .select('id, display_name, profile_id')
            .eq('id', currentChefId)
            .maybeSingle();
      }
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
      chef: ChefAccount(
        chefId: chefId,
        displayName: displayName,
        // La dueña es chefs.profile_id; cualquier otro es un colaborador.
        collaborator: chef?['profile_id'] != userId,
      ),
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

  @override
  Future<void> saveAccountDetails(Map<String, Object?> details) async {
    try {
      await _client.rpc<Object?>('save_account_details', params: {'p': details});
    } on PostgrestException catch (error) {
      if (error.code == '22023') {
        throw AccountDetailsRejected(fieldsFromDetail(error.details?.toString()));
      }
      throw const AccountFailure(AccountFailureKind.unavailable);
    } on Object {
      throw const AccountFailure(AccountFailureKind.unavailable);
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

  @override
  Future<void> saveAccountDetails(Map<String, Object?> details) =>
      Future.error(_failure);
}
