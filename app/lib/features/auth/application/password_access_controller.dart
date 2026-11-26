// Acceso de las clientas con contraseña (/app/ y la app nativa; /gestione/
// sigue solo con el código): entrar, «Crea account», «Password dimenticata?»
// y «Reinvia l'email». Cada pedido lleva un token nuevo del captcha de Auth.
// El alta, la recuperación y el reenvío confirman siempre con el mismo aviso,
// exista o no la cuenta: la pantalla nunca dice si un email tiene cuenta (Auth
// responde igual en los dos casos).
//
// Al entrar, Supabase abre la sesión y SessionController lleva a la clienta a
// su área (o a la cocina a la suya, en la app nativa).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/features/auth/application/auth_captcha.dart';
import 'package:radici/features/auth/application/auth_link_error.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';

part 'password_access_controller.freezed.dart';

/// Qué formulario se ve: entrar, crear la cuenta o pedir una contraseña nueva.
enum AccessView { signIn, signUp, forgot }

/// Lo que se acaba de mandar, para confirmarlo en pantalla.
enum AccessNotice {
  /// «Crea account»: el link para confirmar el email y elegir la contraseña.
  signUpSent,

  /// «Password dimenticata?»: el link para elegir una contraseña nueva.
  resetSent,
}

@Freezed(toStringOverride: false)
abstract class PasswordAccessState with _$PasswordAccessState {
  const factory PasswordAccessState({
    @Default(AccessView.signIn) AccessView view,

    /// Email del último envío (normalizado): lo usa «Reinvia l'email» y
    /// queda escrito al cambiar de formulario.
    @Default('') String email,

    /// Hay un pedido al servidor en curso.
    @Default(false) bool busy,

    /// Error a mostrar, o null.
    AuthFailureKind? error,

    /// Con el error del captcha: el código del motivo (diagnóstico); «auth»
    /// si lo rechazó Auth. Null en los demás.
    String? errorDetail,

    /// Lo que se acaba de mandar (el alta o la recuperación), o null.
    AccessNotice? notice,

    /// Se acaba de mandar otra vez el mismo email.
    @Default(false) bool resent,
  }) = _PasswordAccessState;

  const PasswordAccessState._();

  // Sin el email: nunca se loguean datos personales.
  @override
  String toString() =>
      'PasswordAccessState(${view.name}, busy: $busy, error: $error, notice: $notice)';
}

/// Se descarta al salir de la pantalla: el próximo acceso empieza de cero.
final passwordAccessControllerProvider =
    NotifierProvider.autoDispose<PasswordAccessController, PasswordAccessState>(
      PasswordAccessController.new,
    );

class PasswordAccessController extends Notifier<PasswordAccessState> {
  @override
  PasswordAccessState build() => const PasswordAccessState();

  AuthRepository get _auth => ref.read(authRepositoryProvider);

  /// Cambia de formulario. [email] (lo escrito en el formulario de antes)
  /// queda escrito en el nuevo.
  void show(AccessView view, {String? email}) {
    if (state.busy) return;
    state = PasswordAccessState(
      view: view,
      email: email == null ? state.email : _normalize(email),
    );
  }

  /// Entra con email y contraseña.
  Future<void> signIn(String rawEmail, String password, {String? locale}) async {
    if (state.busy) return;
    final email = _normalize(rawEmail);
    if (!isValidEmail(email)) {
      _fail(AuthFailureKind.invalidEmail);
      return;
    }
    if (password.isEmpty) {
      _fail(AuthFailureKind.passwordRequired);
      return;
    }
    await _send(
      locale,
      (captchaToken) => _auth.signInWithPassword(
        email: email,
        password: password,
        captchaToken: captchaToken,
      ),
      // La sesión ya se abrió: el router saca a la persona de esta pantalla.
      () => state.copyWith(busy: false, email: email),
    );
  }

  /// «Crea account»: el link para confirmar el email y elegir la contraseña.
  Future<void> signUp(String rawEmail, {String? locale}) async {
    if (state.busy) return;
    final email = _normalize(rawEmail);
    if (!isValidEmail(email)) {
      _fail(AuthFailureKind.invalidEmail);
      return;
    }
    await _send(
      locale,
      (captchaToken) =>
          _auth.signUp(email: email, locale: locale, captchaToken: captchaToken),
      () => PasswordAccessState(
        view: AccessView.signUp,
        email: email,
        notice: AccessNotice.signUpSent,
      ),
    );
  }

  /// «Password dimenticata?»: el link para elegir una contraseña nueva.
  Future<void> requestReset(String rawEmail, {String? locale}) async {
    if (state.busy) return;
    final email = _normalize(rawEmail);
    if (!isValidEmail(email)) {
      _fail(AuthFailureKind.invalidEmail);
      return;
    }
    await _send(
      locale,
      (captchaToken) =>
          _auth.requestPasswordReset(email, captchaToken: captchaToken),
      () => PasswordAccessState(
        view: AccessView.forgot,
        email: email,
        notice: AccessNotice.resetSent,
      ),
    );
  }

  /// «Reinvia l'email»: el mismo link otra vez, al mismo email.
  Future<void> resend({String? locale}) async {
    final notice = state.notice;
    if (state.busy || notice == null) return;
    final email = state.email;
    await _send(
      locale,
      (captchaToken) => switch (notice) {
        AccessNotice.signUpSent => _auth.resendSignupEmail(
          email,
          captchaToken: captchaToken,
        ),
        AccessNotice.resetSent => _auth.requestPasswordReset(
          email,
          captchaToken: captchaToken,
        ),
      },
      () => state.copyWith(busy: false, resent: true),
    );
  }

  static String _normalize(String raw) => raw.trim().toLowerCase();

  void _fail(AuthFailureKind kind) {
    state = state.copyWith(error: kind, errorDetail: null, resent: false);
  }

  /// Pide un token de captcha nuevo y hace el pedido; si sale bien, el estado
  /// pasa a [onSuccess].
  Future<void> _send(
    String? locale,
    Future<void> Function(String? captchaToken) request,
    PasswordAccessState Function() onSuccess,
  ) async {
    state = state.copyWith(
      busy: true,
      error: null,
      errorDetail: null,
      resent: false,
    );
    // Si el aviso del link existe (la app lo crea al arrancar), se borra.
    if (ref.exists(authLinkErrorProvider)) {
      ref.read(authLinkErrorProvider.notifier).clear();
    }
    try {
      final (outcome, captchaToken) = await requestAuthCaptcha(ref, locale);
      if (!ref.mounted) return;
      if (outcome == CaptchaOutcome.failed) {
        state = state.copyWith(
          busy: false,
          error: AuthFailureKind.captcha,
          errorDetail: lastAuthCaptchaFailure(ref),
        );
        return;
      }
      await request(captchaToken);
      if (!ref.mounted) return;
      state = onSuccess();
    } on AuthFailure catch (failure) {
      if (!ref.mounted) return;
      state = state.copyWith(
        busy: false,
        error: failure.kind,
        errorDetail: failure.kind == AuthFailureKind.captcha ? 'auth' : null,
      );
    }
  }
}
