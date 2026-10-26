// Inicio de sesión con código por email (Supabase Auth, OTP) y sesión.
// La sesión la persiste supabase_flutter (SharedPreferences en móvil,
// localStorage en la web) y se recupera sola al arrancar.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract interface class AuthRepository {
  /// Usuario de la sesión guardada, o null.
  AppUser? get currentUser;

  /// Emite el usuario cada vez que cambia la sesión (null al salir). Puede
  /// repetir el mismo usuario (por ejemplo al renovar el token).
  Stream<AppUser?> userChanges();

  /// Manda el código de acceso a [email], solo si ya tiene usuario (no crea
  /// cuentas). [locale] (it, es, en) es el idioma de la interfaz: si alguna
  /// vez se crea el usuario así, queda en `user_metadata.locale`, que usan la
  /// plantilla del email del código y el perfil. Lanza [AuthFailure].
  Future<void> sendEmailCode(String email, {String? locale});

  /// Verifica el código y abre la sesión. Lanza [AuthFailure].
  Future<void> verifyEmailCode({required String email, required String code});

  Future<void> signOut();
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const NoBackendAuthRepository()
      : SupabaseAuthRepository(client.auth);
});

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._auth);

  final GoTrueClient _auth;

  @override
  AppUser? get currentUser => _toAppUser(_auth.currentUser);

  @override
  Stream<AppUser?> userChanges() =>
      _auth.onAuthStateChange.map((state) => _toAppUser(state.session?.user));

  @override
  Future<void> sendEmailCode(String email, {String? locale}) async {
    try {
      // No crea usuarios: hasta el área de clientes (M2) solo entra quien ya
      // tiene uno (Evelyn, creada confirmada desde el panel y promovida con
      // promote_to_chef; contrato §8). Un email desconocido da otp_disabled
      // (notAllowed). En el proyecto también van apagadas las altas.
      // `data` (user_metadata.locale) solo se guarda al crear un usuario.
      await _auth.signInWithOtp(
        email: email,
        shouldCreateUser: false,
        data: {if (_supportedLocales.contains(locale)) 'locale': locale},
      );
    } on Object catch (error) {
      throw AuthFailure(authFailureKindOf(error));
    }
  }

  @override
  Future<void> verifyEmailCode({
    required String email,
    required String code,
  }) async {
    final AuthResponse response;
    try {
      response = await _auth.verifyOTP(
        email: email,
        token: code,
        type: OtpType.email,
      );
    } on Object catch (error) {
      throw AuthFailure(authFailureKindOf(error, verifying: true));
    }
    if (response.session == null) {
      throw const AuthFailure(AuthFailureKind.unknown);
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } on AuthException {
      // La sesión local se borra antes de avisar al servidor: si ese aviso
      // falla (sin conexión, token vencido), igual se salió en este equipo.
    }
  }

  static const Set<String> _supportedLocales = {'it', 'es', 'en'};

  static AppUser? _toAppUser(User? user) =>
      user == null ? null : AppUser(id: user.id, email: user.email);
}

/// Traduce los errores de Supabase Auth.
/// Códigos: https://supabase.com/docs/guides/auth/debugging/error-codes
AuthFailureKind authFailureKindOf(Object error, {bool verifying = false}) {
  if (error is AuthRetryableFetchException) return AuthFailureKind.network;
  if (error is! AuthException) return AuthFailureKind.unknown;
  switch (error.code) {
    case 'otp_expired':
      return AuthFailureKind.invalidCode;
    case 'over_email_send_rate_limit' || 'over_request_rate_limit':
      return AuthFailureKind.rateLimited;
    case 'signup_disabled' ||
        'otp_disabled' ||
        'email_provider_disabled' ||
        'user_banned':
      return AuthFailureKind.notAllowed;
    case 'email_address_invalid':
      return AuthFailureKind.invalidEmail;
  }
  return switch (error.statusCode) {
    '429' => AuthFailureKind.rateLimited,
    // Sin código (versiones viejas de GoTrue): al verificar, 401/403 es un
    // código incorrecto o vencido.
    '401' || '403' when verifying => AuthFailureKind.invalidCode,
    _ => AuthFailureKind.unknown,
  };
}

/// Sin Supabase configurado (dev sin backend): no hay sesión posible.
class NoBackendAuthRepository implements AuthRepository {
  const NoBackendAuthRepository();

  @override
  AppUser? get currentUser => null;

  @override
  Stream<AppUser?> userChanges() => const Stream.empty();

  @override
  Future<void> sendEmailCode(String email, {String? locale}) =>
      Future.error(const AuthFailure(AuthFailureKind.noBackend));

  @override
  Future<void> verifyEmailCode({
    required String email,
    required String code,
  }) => Future.error(const AuthFailure(AuthFailureKind.noBackend));

  @override
  Future<void> signOut() async {}
}
