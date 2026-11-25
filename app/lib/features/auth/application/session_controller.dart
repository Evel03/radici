// Estado de la sesión: quién entró y qué área le toca. El router redirige
// según este estado; las pantallas de la cocinera leen su chef_id de acá.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';

part 'session_controller.freezed.dart';

// En las sesiones con cuenta cargada, `language` es el idioma del perfil al
// cargarla. El idioma vigente (que la cocinera puede cambiar después) lo
// lleva languageControllerProvider.
@freezed
sealed class SessionState with _$SessionState {
  /// Sin sesión.
  const factory SessionState.signedOut() = SignedOut;

  /// Hay sesión y se está leyendo el rol.
  const factory SessionState.loading(AppUser user) = SessionLoading;

  /// Cocinera: ve la bandeja y la agenda.
  const factory SessionState.chef(
    AppUser user,
    ChefAccount chef, {
    AppLanguage? language,
  }) = ChefSession;

  /// Cualquier otro usuario: la clienta (área en preparación).
  const factory SessionState.client(
    AppUser user,
    ClientAccount client, {
    AppLanguage? language,
  }) = ClientSession;

  /// Hay sesión pero no se pudo leer la cuenta.
  const factory SessionState.failed(AppUser user, AccountFailureKind kind) =
      SessionFailed;
}

final sessionControllerProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);

/// Ficha de la cocinera con sesión abierta, o null.
final currentChefProvider = Provider<ChefAccount?>(
  (ref) => switch (ref.watch(sessionControllerProvider)) {
    ChefSession(:final chef) => chef,
    _ => null,
  },
);

/// Usuario de [session], o null sin sesión.
AppUser? sessionUserOf(SessionState session) => switch (session) {
  SignedOut() => null,
  SessionLoading(:final user) ||
  ChefSession(:final user) ||
  ClientSession(:final user) ||
  SessionFailed(:final user) => user,
};

class SessionController extends Notifier<SessionState> {
  /// Cada lectura de cuenta lleva un número: si el usuario cambia mientras
  /// tanto, el resultado viejo se descarta.
  int _generation = 0;

  @override
  SessionState build() {
    final auth = ref.watch(authRepositoryProvider);
    final subscription = auth.userChanges().listen(
      _onUserChanged,
      // Un error al renovar el token no cierra la sesión acá: si la sesión
      // termina, Supabase emite signedOut (usuario null).
      onError: (Object _) {},
    );
    ref.onDispose(subscription.cancel);

    final user = auth.currentUser;
    if (user == null) return const SessionState.signedOut();
    // No se puede cambiar el estado durante build: se carga apenas termina.
    // El número se toma ya: si antes sale (signOut) o cambia el usuario, esta
    // carga queda vieja y se descarta.
    final generation = ++_generation;
    scheduleMicrotask(() => unawaited(_loadAccount(user, generation)));
    return SessionState.loading(user);
  }

  /// Usuario de la sesión actual, o null.
  AppUser? get _currentUser => sessionUserOf(state);

  void _onUserChanged(AppUser? user) {
    if (!ref.mounted) return;
    if (user == null) {
      _generation++;
      state = const SessionState.signedOut();
      return;
    }
    // Mismo usuario (token renovado, sesión inicial repetida): nada cambia.
    if (user.id == _currentUser?.id) return;
    state = SessionState.loading(user);
    unawaited(_loadAccount(user, ++_generation));
  }

  Future<void> _loadAccount(AppUser user, int generation) async {
    SessionState next;
    try {
      final account = await ref
          .read(accountRepositoryProvider)
          .fetchAccount(user.id);
      final chef = account.chef;
      next = account.role == AccountRole.chef && chef != null
          ? SessionState.chef(user, chef, language: account.language)
          : SessionState.client(
              user,
              account.client ?? const ClientAccount(),
              language: account.language,
            );
    } on AccountFailure catch (failure) {
      next = SessionState.failed(user, failure.kind);
    } on Object {
      next = SessionState.failed(user, AccountFailureKind.unavailable);
    }
    if (!ref.mounted || generation != _generation) return;
    state = next;
  }

  /// Vuelve a leer la cuenta después de un error.
  Future<void> retry() async {
    final user = _currentUser;
    if (user == null) return;
    state = SessionState.loading(user);
    await _loadAccount(user, ++_generation);
  }

  Future<void> signOut() async {
    _generation++;
    state = const SessionState.signedOut();
    await ref.read(authRepositoryProvider).signOut();
  }
}
