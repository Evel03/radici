// «Crear cuenta» (pedido de Nicolas del 27/11/2026, contrato docs/contracts/auth.md §19): la clienta carga sus datos,
// el email y la contraseña (dos veces) en la app y confirma el email con el código de 10 cifras que le llega, sin salir
// de la app. Los pasos:
//   1. form: se revisan los datos (las mismas reglas que la base) y se pide el alta (signUp, con captcha). Auth
//      contesta igual exista o no la cuenta: la pantalla nunca dice si un email tiene cuenta.
//   2. code: el código del email (verifySignUpCode) confirma el email y abre la sesión.
//   3. finishing: con esa sesión, la contraseña que eligió (la confirmación borra la del alta, auth.md §4) y sus datos
//      (save_account_details). Mientras dura, el router deja a la persona en esta pantalla ([holdsRoute]).
//   4. done: la pantalla la lleva a su área.
// El formulario (con la contraseña) vive solo en memoria, en este controlador, y se borra al terminar o al salir.
// Ningún dato personal va a un log ni al toString del estado.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/auth_captcha.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/domain/sign_up_form.dart';

enum SignUpStep { form, code, finishing, done }

class SignUpState {
  const SignUpState({
    this.step = SignUpStep.form,
    this.busy = false,
    this.problems = const {},
    this.error,
    this.errorDetail,
    this.email = '',
    this.resent = false,
  });

  final SignUpStep step;

  /// Hay un pedido en curso.
  final bool busy;

  /// Los campos del formulario con un problema (de la app o de la base).
  final Map<SignUpField, Object> problems;

  /// El error a mostrar (Auth, red, captcha), o null.
  final AuthFailureKind? error;

  /// Con el error del captcha: el motivo (diagnóstico).
  final String? errorDetail;

  /// El email al que se mandó el código (para mostrarlo y para reenviar).
  final String email;

  /// Se acaba de reenviar el código.
  final bool resent;

  /// Mientras se verifica el código y se terminan de guardar la contraseña y los datos, el router no saca a la persona
  /// de «Crear cuenta» aunque la sesión ya esté abierta.
  bool get holdsRoute =>
      (step == SignUpStep.code && busy) ||
      step == SignUpStep.finishing ||
      step == SignUpStep.done;

  SignUpState copyWith({
    SignUpStep? step,
    bool? busy,
    Map<SignUpField, Object>? problems,
    AuthFailureKind? Function()? error,
    String? Function()? errorDetail,
    String? email,
    bool? resent,
  }) => SignUpState(
    step: step ?? this.step,
    busy: busy ?? this.busy,
    problems: problems ?? this.problems,
    error: error != null ? error() : this.error,
    errorDetail: errorDetail != null ? errorDetail() : this.errorDetail,
    email: email ?? this.email,
    resent: resent ?? this.resent,
  );

  // Sin el email ni los datos.
  @override
  String toString() =>
      'SignUpState(step: $step, busy: $busy, problems: ${problems.keys.map((k) => k.name).toList()}, error: $error)';
}

/// No se descarta solo: el alta sigue aunque la pantalla se reconstruya o el router la mueva. [SignUpController.reset]
/// la vuelve al principio (al salir de la pantalla o al terminar).
final signUpControllerProvider =
    NotifierProvider<SignUpController, SignUpState>(SignUpController.new);

class SignUpController extends Notifier<SignUpState> {
  SignUpForm? _form;
  String? _locale;

  /// El código ya abrió la sesión: un reintento salta directo a guardar.
  bool _verified = false;

  /// La contraseña ya quedó: un reintento solo guarda los datos.
  bool _passwordSet = false;

  @override
  SignUpState build() => const SignUpState();

  AuthRepository get _auth => ref.read(authRepositoryProvider);

  /// Paso 1: revisa el formulario y pide el alta. Si el código ya abrió la sesión (los datos los rechazó la base y se
  /// corrigieron), guarda directo.
  Future<void> submit(SignUpForm form, {String? locale}) async {
    if (state.busy) return;
    final today = romeToday(ref.read(clockProvider)());
    final problems = signUpProblems(
      form,
      DateTime(today.year, today.month, today.day),
    );
    if (problems.isNotEmpty) {
      state = state.copyWith(
        problems: problems,
        error: () => null,
        errorDetail: () => null,
      );
      return;
    }
    _form = form;
    _locale = locale;
    if (_verified) {
      state = state.copyWith(
        step: SignUpStep.finishing,
        busy: true,
        problems: const {},
        error: () => null,
      );
      await _finish();
      return;
    }
    final email = form.normalizedEmail;
    state = SignUpState(busy: true, email: email);
    final sent = await _withCaptcha(
      (token) =>
          _auth.signUp(email: email, locale: locale, captchaToken: token),
    );
    if (!sent || !ref.mounted) return;
    state = SignUpState(step: SignUpStep.code, email: email);
  }

  /// Paso 2: el código del email. Abre la sesión y, sin soltar la pantalla, guarda la contraseña y los datos.
  Future<void> verify(String rawCode) async {
    if (state.busy || state.step != SignUpStep.code || _form == null) return;
    final code = rawCode.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^\d{6,10}$').hasMatch(code)) {
      state = state.copyWith(
        error: () => AuthFailureKind.invalidCode,
        resent: false,
      );
      return;
    }
    state = state.copyWith(
      busy: true,
      error: () => null,
      errorDetail: () => null,
      resent: false,
    );
    try {
      await _auth.verifySignUpCode(email: state.email, code: code);
    } on AuthFailure catch (failure) {
      if (!ref.mounted) return;
      state = state.copyWith(busy: false, error: () => failure.kind);
      return;
    }
    if (!ref.mounted) return;
    _verified = true;
    state = state.copyWith(step: SignUpStep.finishing);
    await _finish();
  }

  /// Si falló guardar la contraseña o los datos (la red), lo intenta otra vez.
  Future<void> retryFinish() async {
    if (state.step != SignUpStep.finishing || state.busy) return;
    state = state.copyWith(busy: true, error: () => null);
    await _finish();
  }

  /// «Reenviar el código».
  Future<void> resend() async {
    if (state.busy || state.step != SignUpStep.code) return;
    state = state.copyWith(
      busy: true,
      error: () => null,
      errorDetail: () => null,
      resent: false,
    );
    final sent = await _withCaptcha(
      (token) => _auth.resendSignupEmail(state.email, captchaToken: token),
    );
    if (!sent || !ref.mounted) return;
    state = state.copyWith(busy: false, resent: true);
  }

  /// «Cambiar mis datos»: vuelve al formulario (lo escrito sigue en la pantalla) para corregir o pedir con otro email.
  void editForm() {
    if (state.busy || state.step != SignUpStep.code) return;
    state = SignUpState(email: state.email);
  }

  /// Al salir de la pantalla: se olvida todo, salvo que esté terminando de guardar (la pantalla vuelve).
  void resetUnlessFinishing() {
    // La app se cerró (o el test terminó) antes: no queda nada que olvidar.
    if (!ref.mounted) return;
    if (state.step != SignUpStep.finishing) reset();
  }

  /// Al salir de la pantalla o al terminar: se olvida todo, la contraseña incluida.
  void reset() {
    _form = null;
    _locale = null;
    _verified = false;
    _passwordSet = false;
    state = const SignUpState();
  }

  Future<void> _finish() async {
    final form = _form;
    if (form == null) return;
    try {
      if (!_passwordSet) {
        await _auth.setNewPassword(form.password);
        _passwordSet = true;
      }
      await ref
          .read(accountRepositoryProvider)
          .saveAccountDetails(accountDetailsPayload(form));
    } on AccountDetailsRejected catch (rejected) {
      if (!ref.mounted) return;
      // La base no aceptó algo (por ejemplo, la edad el día justo): vuelve al formulario con esos campos; la sesión y
      // la contraseña ya están, así que al mandar otra vez solo se guardan los datos.
      state = SignUpState(
        email: state.email,
        problems: {for (final field in rejected.fields) field: true},
        error: rejected.fields.isEmpty ? AuthFailureKind.unknown : null,
      );
      return;
    } on AuthFailure catch (failure) {
      if (!ref.mounted) return;
      state = state.copyWith(busy: false, error: () => failure.kind);
      return;
    } on Object {
      if (!ref.mounted) return;
      state = state.copyWith(busy: false, error: () => AuthFailureKind.network);
      return;
    }
    if (!ref.mounted) return;
    _form = null;
    state = state.copyWith(step: SignUpStep.done, busy: false);
  }

  /// Pide un token de captcha y hace el pedido. Devuelve si salió bien; si no, deja el error en el estado.
  Future<bool> _withCaptcha(
    Future<void> Function(String? token) request,
  ) async {
    try {
      final (outcome, token) = await requestAuthCaptcha(ref, _locale);
      if (!ref.mounted) return false;
      if (outcome == CaptchaOutcome.failed) {
        state = state.copyWith(
          busy: false,
          error: () => AuthFailureKind.captcha,
          errorDetail: () => lastAuthCaptchaFailure(ref),
        );
        return false;
      }
      await request(token);
      return true;
    } on AuthFailure catch (failure) {
      if (!ref.mounted) return false;
      state = state.copyWith(
        busy: false,
        error: () => failure.kind,
        errorDetail: () =>
            failure.kind == AuthFailureKind.captcha ? 'auth' : null,
      );
      return false;
    }
  }
}
