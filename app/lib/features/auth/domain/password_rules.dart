// Las contraseñas de las clientas: la misma regla que fija Auth
// (docs/contracts/auth.md §12, `supabase/scripts/auth-config.ts`) y que revisa
// /accesso/ (`web/src/access/password.ts`; auth-config.test.ts compara las
// tres). La app la revisa antes de mandarla para avisar enseguida, pero quien
// decide es Auth: lo que responda (weak_password, same_password) se muestra
// igual.
import 'dart:convert';
import 'dart:math';

const int passwordMinLength = 10;

/// GoTrue no acepta contraseñas de más de 72 bytes (el límite de bcrypt).
const int passwordMaxBytes = 72;

enum PasswordProblem { tooShort, tooLong, lettersDigits }

/// Qué le falta a [password], o null si cumple la regla.
PasswordProblem? passwordProblem(String password) {
  if (password.runes.length < passwordMinLength) {
    return PasswordProblem.tooShort;
  }
  if (utf8.encode(password).length > passwordMaxBytes) {
    return PasswordProblem.tooLong;
  }
  // Las de Auth: password_required_characters = letras (a-z, A-Z) y dígitos.
  if (!RegExp('[A-Za-z]').hasMatch(password) ||
      !RegExp('[0-9]').hasMatch(password)) {
    return PasswordProblem.lettersDigits;
  }
  return null;
}

const String _alphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

/// Largo de la contraseña al azar del alta.
const int signupPasswordLength = 40;

/// La contraseña del alta en dos pasos (diseño del 22/11/2026): «Crea
/// account» la manda al azar y nadie la conoce; la clienta elige la suya en
/// /accesso/ desde el link de confirmación, y la primera confirmación borra la
/// del alta (trigger `on_auth_user_confirmed_clear_password`). 40 caracteres de
/// letras y dígitos al azar (`Random.secure`), con al menos una letra y un
/// dígito: así cumple la regla de Auth. Nunca se guarda ni se muestra.
String generateSignupPassword([Random? random]) {
  final rng = random ?? Random.secure();
  while (true) {
    final password = String.fromCharCodes(
      List.generate(
        signupPasswordLength,
        (_) => _alphabet.codeUnitAt(rng.nextInt(_alphabet.length)),
      ),
    );
    if (passwordProblem(password) == null) return password;
  }
}
