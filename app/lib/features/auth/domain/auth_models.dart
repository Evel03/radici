// Modelos de sesión y cuenta, sin dependencias de Supabase: los repositorios
// traducen sus tipos y errores a estos.
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/app_language.dart';

part 'auth_models.freezed.dart';

/// Usuario autenticado (auth.users).
@Freezed(toStringOverride: false)
abstract class AppUser with _$AppUser {
  const factory AppUser({required String id, String? email}) = _AppUser;

  const AppUser._();

  // Sin el email: nunca se loguean datos personales.
  @override
  String toString() => 'AppUser($id)';
}

/// `profiles.role`.
enum AccountRole { chef, client }

/// Ficha de la cocina con que trabaja el usuario (`public.chefs`): la suya o,
/// si es colaborador, la de la cocinera (`public.chef_members`).
@freezed
abstract class ChefAccount with _$ChefAccount {
  const factory ChefAccount({
    required String chefId,
    required String displayName,

    /// true si el usuario es un colaborador de la cocinera y no ella: ve y
    /// hace lo mismo; Impostazioni y el menú de la cuenta lo dicen
    /// («Colaborador de Evelyn», chefAccountTitle).
    @Default(false) bool collaborator,
  }) = _ChefAccount;
}

/// Lo que la app necesita saber del usuario después del login.
@freezed
abstract class Account with _$Account {
  const factory Account({
    required AccountRole role,
    ChefAccount? chef,

    /// Idioma de la interfaz (`profiles.locale`); null si el perfil no trae
    /// uno que esta versión conozca: entonces manda el dispositivo.
    AppLanguage? language,
  }) = _Account;
}

/// Por qué falló una operación de autenticación.
enum AuthFailureKind {
  /// El email no tiene un formato válido.
  invalidEmail,

  /// El código es incorrecto o venció.
  invalidCode,

  /// Demasiados pedidos de código seguidos.
  rateLimited,

  /// Sin conexión o el servidor no respondió.
  network,

  /// El proyecto no permite entrar con ese email (altas desactivadas, etc.).
  notAllowed,

  /// La app se compiló sin SUPABASE_URL ni clave.
  noBackend,

  /// No se obtuvo el token del captcha de Auth (Turnstile). Solo se da
  /// cuando Auth exige el captcha (captchaRequired): hasta PR11 el pedido
  /// sale sin token. Se reintenta con el mismo botón.
  captcha,

  /// Cualquier otro error.
  unknown,
}

class AuthFailure implements Exception {
  const AuthFailure(this.kind);

  final AuthFailureKind kind;

  @override
  String toString() => 'AuthFailure(${kind.name})';
}

/// Por qué no se pudo cargar la cuenta después del login.
enum AccountFailureKind {
  /// Sin conexión o error del servidor: se puede reintentar.
  unavailable,

  /// Rol `chef` sin cocina: ni dueña en `chefs` ni colaborador en
  /// `chef_members` (falta correr promote_to_chef completo, o salió de la
  /// lista de colaboradores).
  chefNotConfigured,
}

class AccountFailure implements Exception {
  const AccountFailure(this.kind);

  final AccountFailureKind kind;

  @override
  String toString() => 'AccountFailure(${kind.name})';
}

/// Misma regla que `isValidEmail` de public_request.ts.
bool isValidEmail(String email) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(email);

/// Largo del código que manda Supabase Auth (`otp_length`, 6 por defecto).
/// Se aceptan hasta 10 cifras por si se cambia la configuración del proyecto.
const int otpMinLength = 6;
const int otpMaxLength = 10;

/// Saca espacios y guiones que se cuelan al copiar el código del email.
String normalizeOtp(String raw) => raw.replaceAll(RegExp(r'[\s-]'), '');

bool isValidOtp(String code) =>
    RegExp('^\\d{$otpMinLength,$otpMaxLength}\$').hasMatch(code);
