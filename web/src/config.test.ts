import { describe, expect, it } from "vitest";
import { normalizeWhatsAppNumber, resolveConfig } from "./config.ts";

describe("resolveConfig", () => {
  it("valores por defecto: sin número, marca Mestolo, noindex activado", () => {
    expect(resolveConfig({})).toEqual({ whatsappNumber: null, brandName: "Mestolo", noindex: true, siteUrl: null });
  });

  it("lee las variables VITE_*", () => {
    const config = resolveConfig({
      VITE_WHATSAPP_NUMBER: "39 333 123 4567",
      VITE_BRAND_NAME: "  Cucina di Eve ",
      VITE_NOINDEX: "false",
      VITE_SITE_URL: "https://prova.example.com/",
    });
    expect(config).toEqual({
      whatsappNumber: "393331234567",
      brandName: "Cucina di Eve",
      noindex: false,
      siteUrl: "https://prova.example.com",
    });
  });

  it("noindex solo se desactiva explícitamente", () => {
    expect(resolveConfig({ VITE_NOINDEX: "0" }).noindex).toBe(false);
    expect(resolveConfig({ VITE_NOINDEX: "cualquier cosa" }).noindex).toBe(true);
    expect(resolveConfig({ VITE_NOINDEX: "" }).noindex).toBe(true);
  });

  it("una URL sin protocolo se ignora", () => {
    expect(resolveConfig({ VITE_SITE_URL: "prova.example.com" }).siteUrl).toBeNull();
  });
});

describe("normalizeWhatsAppNumber", () => {
  it("acepta +, 00, espacios y guiones; devuelve solo dígitos", () => {
    expect(normalizeWhatsAppNumber("+39 333-123-4567")).toBe("393331234567");
    expect(normalizeWhatsAppNumber("0039 333 1234567")).toBe("393331234567");
  });

  it("rechaza números vacíos, cortos o con letras", () => {
    expect(normalizeWhatsAppNumber("")).toBeNull();
    expect(normalizeWhatsAppNumber("12345")).toBeNull();
    expect(normalizeWhatsAppNumber("39abc1234567")).toBeNull();
    expect(normalizeWhatsAppNumber("0333 1234567")).toBeNull();
  });
});
