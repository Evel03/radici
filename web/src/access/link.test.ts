import { describe, expect, it } from "vitest";
import { addressWithoutFragment, hasLinkParams, readAccessLink } from "./link.ts";
import { maskEmail } from "./mask.ts";
import { PASSWORD_MAX_BYTES, PASSWORD_MIN_LENGTH, passwordProblem } from "./password.ts";

const HASH = "a".repeat(56);

describe("readAccessLink", () => {
  it("un link completo: token_hash y type email o recovery", () => {
    expect(readAccessLink(`#token_hash=${HASH}&type=email`)).toEqual({ kind: "link", link: { tokenHash: HASH, type: "email" } });
    expect(readAccessLink(`#type=recovery&token_hash=${HASH}`)).toEqual({ kind: "link", link: { tokenHash: HASH, type: "recovery" } });
  });

  it("acepta el token de un pedido con PKCE (pkce_ delante)", () => {
    expect(readAccessLink(`#token_hash=pkce_${HASH}&type=email`)).toEqual({ kind: "link", link: { tokenHash: `pkce_${HASH}`, type: "email" } });
  });

  it("sin nada del link: none (también con un ancla interna)", () => {
    expect(readAccessLink("")).toEqual({ kind: "none" });
    expect(readAccessLink("#")).toEqual({ kind: "none" });
    expect(readAccessLink("#main")).toEqual({ kind: "none" });
  });

  it("cortado o con otro tipo: broken, con el tipo si se sabe", () => {
    expect(readAccessLink("#token_hash=abc&type=email")).toEqual({ kind: "broken", type: "email" });
    expect(readAccessLink(`#token_hash=${HASH}`)).toEqual({ kind: "broken", type: null });
    expect(readAccessLink("#type=recovery")).toEqual({ kind: "broken", type: "recovery" });
    expect(readAccessLink(`#token_hash=${HASH}&type=magiclink`)).toEqual({ kind: "broken", type: null });
    expect(readAccessLink(`#token_hash=${HASH}&type=email_change`)).toEqual({ kind: "broken", type: null });
    expect(readAccessLink(`#token_hash=${HASH}%20x&type=email`)).toEqual({ kind: "broken", type: "email" });
    expect(readAccessLink(`#token_hash=${"a".repeat(201)}&type=email`)).toEqual({ kind: "broken", type: "email" });
  });

  it("un error de Auth en el fragmento nunca pasa por un link válido", () => {
    expect(readAccessLink("#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid")).toEqual({
      kind: "broken",
      type: null,
    });
    expect(readAccessLink(`#token_hash=${HASH}&type=email&error_code=otp_expired`)).toEqual({ kind: "broken", type: "email" });
  });
});

describe("sacar el link de la URL", () => {
  it("hasLinkParams: sí con cualquier parámetro del link, no con un ancla", () => {
    expect(hasLinkParams(`#token_hash=${HASH}&type=email`)).toBe(true);
    expect(hasLinkParams("#type=email")).toBe(true);
    expect(hasLinkParams("#error_code=otp_expired")).toBe(true);
    expect(hasLinkParams("#main")).toBe(false);
    expect(hasLinkParams("")).toBe(false);
  });

  it("la dirección sin fragmento conserva la ruta y el idioma", () => {
    expect(addressWithoutFragment({ pathname: "/accesso/", search: "?lang=es" })).toBe("/accesso/?lang=es");
    expect(addressWithoutFragment({ pathname: "/accesso/", search: "" })).toBe("/accesso/");
  });
});

describe("maskEmail", () => {
  it("deja ver el principio del usuario y del dominio, y la terminación", () => {
    expect(maskEmail("evelyn.rossi@gmail.com")).toBe("ev•••@g•••.com");
    expect(maskEmail("ana@libero.it")).toBe("a•••@l•••.it");
    expect(maskEmail("x@mail.example.co.uk")).toBe("x•••@m•••.uk");
    expect(maskEmail("üser.name@posta.it")).toBe("üs•••@p•••.it");
  });

  it("nunca muestra el usuario entero (si tiene más de una letra)", () => {
    for (const email of ["evelyn.rossi@gmail.com", "ana@libero.it", "ab@b.it", "nombre@dominio"]) {
      const local = email.slice(0, email.indexOf("@"));
      const masked = maskEmail(email);
      expect(masked).not.toBe(email);
      expect(masked.startsWith(local)).toBe(false);
    }
  });

  it("algo sin forma de email se tapa entero", () => {
    expect(maskEmail("")).toBe("•••");
    expect(maskEmail("sin-arroba")).toBe("•••");
    expect(maskEmail("@dominio.it")).toBe("•••");
    expect(maskEmail("usuario@")).toBe("•••");
  });
});

describe("passwordProblem (la regla de Auth: 10 o más, con letras y números)", () => {
  it("acepta 10 caracteres con letras y números", () => {
    expect(passwordProblem("abcdefghi1")).toBeNull();
    expect(passwordProblem("Bergamo2026!")).toBeNull();
    expect(passwordProblem(`${"a".repeat(PASSWORD_MAX_BYTES - 1)}1`)).toBeNull();
  });

  it("corta, sin letras o sin números", () => {
    expect(passwordProblem("abcdefgh1")).toBe("tooShort");
    expect(passwordProblem("")).toBe("tooShort");
    expect(passwordProblem("abcdefghij")).toBe("lettersDigits");
    expect(passwordProblem("1234567890")).toBe("lettersDigits");
    expect(passwordProblem("èèèèèèèèè1")).toBe("lettersDigits"); // Auth cuenta solo a-z y A-Z como letras
  });

  it("más de 72 bytes (el límite de bcrypt en GoTrue): too long, aunque sean menos caracteres", () => {
    expect(passwordProblem(`${"a".repeat(PASSWORD_MAX_BYTES)}1`)).toBe("tooLong");
    expect(passwordProblem(`a1${"é".repeat(36)}`)).toBe("tooLong"); // 38 caracteres, 74 bytes
  });

  it("el mínimo se cuenta en caracteres, no en bytes", () => {
    expect(PASSWORD_MIN_LENGTH).toBe(10);
    expect(passwordProblem("a1éééééé")).toBe("tooShort"); // 8 caracteres, 14 bytes
  });
});
