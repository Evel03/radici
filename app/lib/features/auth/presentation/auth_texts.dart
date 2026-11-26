// Los textos de los errores de acceso, compartidos por el login con código,
// el acceso con contraseña y «Cambia password».
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/domain/password_rules.dart';
import 'package:radici/l10n/app_localizations.dart';

/// El texto del error. Con el del captcha, [detail] (el motivo, para el
/// diagnóstico) va primero y en su renglón, así nunca queda cortado:
/// «(codice: app-timeout)» y debajo «Non siamo riusciti…».
String authErrorText(AppLocalizations l10n, AuthFailureKind kind, {String? detail}) =>
    kind == AuthFailureKind.captcha && detail != null && detail.isNotEmpty
    ? '${l10n.authErrorCode(detail)}\n${l10n.authErrorCaptcha}'
    : switch (kind) {
      AuthFailureKind.invalidEmail => l10n.authErrorInvalidEmail,
      AuthFailureKind.invalidCode => l10n.authErrorInvalidCode,
      AuthFailureKind.rateLimited => l10n.authErrorRateLimited,
      AuthFailureKind.network => l10n.authErrorNetwork,
      AuthFailureKind.notAllowed => l10n.authErrorNotAllowed,
      AuthFailureKind.noBackend => l10n.authErrorNoBackend,
      AuthFailureKind.captcha => l10n.authErrorCaptcha,
      AuthFailureKind.passwordRequired => l10n.authErrorPasswordRequired,
      AuthFailureKind.invalidCredentials => l10n.authErrorInvalidCredentials,
      AuthFailureKind.kitchenCodeOnly => l10n.authErrorKitchenCodeOnly,
      AuthFailureKind.signupClosed => l10n.authErrorSignupClosed,
      AuthFailureKind.weakPassword => l10n.authErrorWeakPassword,
      AuthFailureKind.samePassword => l10n.authErrorSamePassword,
      AuthFailureKind.wrongCurrentPassword => l10n.authErrorWrongCurrentPassword,
      AuthFailureKind.unknown => l10n.authErrorUnknown,
    };

/// Qué le falta a la contraseña nueva.
String passwordProblemText(AppLocalizations l10n, PasswordProblem problem) =>
    switch (problem) {
      PasswordProblem.tooShort => l10n.passwordTooShort,
      PasswordProblem.tooLong => l10n.passwordTooLong,
      PasswordProblem.lettersDigits => l10n.passwordLettersDigits,
    };
