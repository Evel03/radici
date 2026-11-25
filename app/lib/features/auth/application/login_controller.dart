// Login con código por email en dos pasos: email → código (8 cifras en
// producción; se aceptan de 6 a 10).
// Al verificar el código, Supabase abre la sesión y SessionController (que
// escucha los cambios de sesión) lleva a la cocinera a su área.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/captcha/captcha_service.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';

part 'login_controller.freezed.dart';

enum LoginStep { email, code }

enum _CaptchaOutcome { token, skipped, failed }

@Freezed(toStringOverride: false)
abstract class LoginState with _$LoginState {
  const factory LoginState({
    @Default(LoginStep.email) LoginStep step,

    /// Email al que se mandó el código (normalizado).
    @Default('') String email,

    /// Hay un pedido al servidor en curso.
    @Default(false) bool busy,

    /// Error a mostrar, o null.
    AuthFailureKind? error,

    /// Se acaba de mandar otro código (para confirmarlo en pantalla).
    @Default(false) bool codeResent,

    /// Idioma de la interfaz al pedir el código (para el email del código).
    String? locale,
  }) = _LoginState;

  const LoginState._();

  @override
  String toString() => 'LoginState(${step.name}, busy: $busy, error: $error)';
}

/// Se descarta al salir de la pantalla: el próximo login empieza de cero.
final loginControllerProvider =
    NotifierProvider.autoDispose<LoginController, LoginState>(
      LoginController.new,
    );

class LoginController extends Notifier<LoginState> {
  @override
  LoginState build() => const LoginState();

  AuthRepository get _auth => ref.read(authRepositoryProvider);

  /// Pide un token de captcha para un pedido de código (uno por envío: sirve
  /// una sola vez). Devuelve el token; o, si no se pudo y Auth todavía no lo
  /// exige, [_CaptchaOutcome.skipped] (fail-open, ver captcha_service.dart); o
  /// [_CaptchaOutcome.failed] si no se pudo y es obligatorio. Nunca lanza ni
  /// registra nada: el token y el motivo del fallo no se loguean.
  Future<(_CaptchaOutcome, String?)> _captcha(String? locale) async {
    String? token;
    try {
      token = await ref.read(captchaServiceProvider).token(locale: locale);
    } on Object {
      token = null;
    }
    if (token != null) return (_CaptchaOutcome.token, token);
    return ref.read(captchaRequiredProvider)
        ? (_CaptchaOutcome.failed, null)
        : (_CaptchaOutcome.skipped, null);
  }

  /// Paso 1: valida el email y pide el código. [locale] es el idioma de la
  /// interfaz (it, es, en): el email del código llega en ese idioma.
  Future<void> submitEmail(String rawEmail, {String? locale}) async {
    if (state.busy) return;
    final email = rawEmail.trim().toLowerCase();
    if (!isValidEmail(email)) {
      state = state.copyWith(error: AuthFailureKind.invalidEmail);
      return;
    }
    state = state.copyWith(busy: true, error: null, codeResent: false);
    try {
      final (outcome, captchaToken) = await _captcha(locale);
      if (!ref.mounted) return;
      if (outcome == _CaptchaOutcome.failed) {
        state = state.copyWith(busy: false, error: AuthFailureKind.captcha);
        return;
      }
      await _auth.sendEmailCode(email, locale: locale, captchaToken: captchaToken);
      if (!ref.mounted) return;
      state = LoginState(step: LoginStep.code, email: email, locale: locale);
    } on AuthFailure catch (failure) {
      if (!ref.mounted) return;
      state = state.copyWith(busy: false, error: failure.kind);
    }
  }

  /// Paso 2: verifica el código. Si es correcto, la sesión se abre y el
  /// router saca al usuario de esta pantalla.
  Future<void> submitCode(String rawCode) async {
    if (state.busy || state.step != LoginStep.code) return;
    final code = normalizeOtp(rawCode);
    if (!isValidOtp(code)) {
      state = state.copyWith(error: AuthFailureKind.invalidCode);
      return;
    }
    state = state.copyWith(busy: true, error: null, codeResent: false);
    try {
      await _auth.verifyEmailCode(email: state.email, code: code);
      if (!ref.mounted) return;
      state = state.copyWith(busy: false);
    } on AuthFailure catch (failure) {
      if (!ref.mounted) return;
      state = state.copyWith(busy: false, error: failure.kind);
    }
  }

  /// Manda otro código al mismo email.
  Future<void> resendCode() async {
    if (state.busy || state.step != LoginStep.code) return;
    state = state.copyWith(busy: true, error: null, codeResent: false);
    try {
      final (outcome, captchaToken) = await _captcha(state.locale);
      if (!ref.mounted) return;
      if (outcome == _CaptchaOutcome.failed) {
        state = state.copyWith(busy: false, error: AuthFailureKind.captcha);
        return;
      }
      await _auth.sendEmailCode(state.email, locale: state.locale, captchaToken: captchaToken);
      if (!ref.mounted) return;
      state = state.copyWith(busy: false, codeResent: true);
    } on AuthFailure catch (failure) {
      if (!ref.mounted) return;
      state = state.copyWith(busy: false, error: failure.kind);
    }
  }

  /// Vuelve al paso del email (para corregirlo).
  void changeEmail() {
    if (state.busy) return;
    state = LoginState(email: state.email, locale: state.locale);
  }
}
