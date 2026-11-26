// La contraseña que se elige en /accesso/: la misma regla que fija Auth (docs/contracts/auth.md; la pone PR14 en
// supabase/scripts/auth-config.ts): 10 caracteres o más, con letras y números. La página la revisa antes de mandarla
// para avisar enseguida, pero quien decide es Auth: lo que responda (weak_password, same_password) se muestra igual.

export const PASSWORD_MIN_LENGTH = 10;
/** GoTrue no acepta contraseñas de más de 72 bytes (el límite de bcrypt). */
export const PASSWORD_MAX_BYTES = 72;

export type PasswordProblem = "tooShort" | "tooLong" | "lettersDigits";

/** Qué le falta a la contraseña, o null si cumple la regla. */
export function passwordProblem(password: string): PasswordProblem | null {
  if ([...password].length < PASSWORD_MIN_LENGTH) return "tooShort";
  if (new TextEncoder().encode(password).length > PASSWORD_MAX_BYTES) return "tooLong";
  // Las de Auth: password_required_characters = letras (a-z, A-Z) y dígitos (0-9).
  if (!/[A-Za-z]/.test(password) || !/[0-9]/.test(password)) return "lettersDigits";
  return null;
}
