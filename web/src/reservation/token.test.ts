import { describe, expect, it } from "vitest";
import { TOKEN } from "./fixtures.ts";
import { readToken } from "./token.ts";

describe("readToken", () => {
  it("lee el token del fragmento (#t=…)", () => {
    expect(readToken(`#t=${TOKEN}`)).toBe(TOKEN);
    expect(readToken(`t=${TOKEN}`)).toBe(TOKEN);
    expect(readToken(`#lang=es&t=${TOKEN}`)).toBe(TOKEN);
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
