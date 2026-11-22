import { describe, expect, it } from "vitest";
import { TOKEN } from "./fixtures.ts";
import { hashChangeAction, readToken, tokenFragment } from "./token.ts";

const OTHER = "OrdK1lNJ7pSQ-fEGuL401rGenNXRim5HBWZUSJuX8Y8";

describe("readToken", () => {
  it("lee el token del fragmento (#t=…)", () => {
    expect(readToken(`#t=${TOKEN}`)).toBe(TOKEN);
    expect(readToken(`t=${TOKEN}`)).toBe(TOKEN);
    expect(readToken(`#lang=es&t=${TOKEN}`)).toBe(TOKEN);
    expect(readToken(tokenFragment(TOKEN))).toBe(TOKEN);
  });

  it("tolera lo que algunos programas pegan al final de un link (un punto, un paréntesis)", () => {
    expect(readToken(`#t=${TOKEN}.`)).toBe(TOKEN);
    expect(readToken(`#t=${TOKEN})`)).toBe(TOKEN);
  });

  it("sin token, o con uno que no tiene la forma: null", () => {
    for (const hash of ["", "#", "#t=", `#x=${TOKEN}`, "#t=abc", `#t=${TOKEN}A`, `#t=${TOKEN.slice(1)}`, `#t=${TOKEN.slice(0, 42)}+`]) {
      expect(readToken(hash), hash).toBeNull();
    }
  });
});

describe("hashChangeAction: qué hacer si cambia el fragmento con la página abierta", () => {
  it("un ancla interna (el «Vai al contenuto», #main) o un fragmento sin token: se vuelve a poner el token, sin recargar", () => {
    for (const hash of ["#main", "", "#", "#t=", "#t=abc"]) {
      expect(hashChangeAction(TOKEN, hash), hash).toBe("restore");
    }
  });

  it("otro link pegado en la misma pestaña: se recarga", () => {
    expect(hashChangeAction(TOKEN, `#t=${OTHER}`)).toBe("reload");
    // La página había abierto sin token y llegó uno.
    expect(hashChangeAction(null, `#t=${OTHER}`)).toBe("reload");
  });

  it("el mismo token (también con un punto pegado) o una página sin token que sigue sin uno: nada", () => {
    expect(hashChangeAction(TOKEN, `#t=${TOKEN}`)).toBe("ignore");
    expect(hashChangeAction(TOKEN, `#t=${TOKEN}.`)).toBe("ignore");
    expect(hashChangeAction(null, "#main")).toBe("ignore");
  });
});
