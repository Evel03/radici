import { describe, expect, it } from "vitest";
import { TURNSTILE_TEST_SITE_KEY, isTurnstileTestKey, normalizeSupabaseUrl, resolveConfig } from "./config.ts";

describe("resolveConfig", () => {
  it("valores por defecto: marca Mestolo, noindex activado y sin backend", () => {
    expect(resolveConfig({})).toEqual({
      brandName: "Mestolo",
      noindex: true,
      siteUrl: null,
      supabaseUrl: null,
      supabasePublishableKey: null,
      turnstileSiteKey: null,
    });
  });

  it("lee las variables VITE_*", () => {
    const config = resolveConfig({
      VITE_BRAND_NAME: "  Cucina di Eve ",
      VITE_NOINDEX: "false",
      VITE_SITE_URL: "https://prova.example.com/",
      VITE_SUPABASE_URL: " https://abcdefgh.supabase.co/ ",
      VITE_SUPABASE_PUBLISHABLE_KEY: "sb_publishable_abc123",
      VITE_TURNSTILE_SITE_KEY: "0x4AAAAAAAexample",
    });
    expect(config).toEqual({
      brandName: "Cucina di Eve",
      noindex: false,
      siteUrl: "https://prova.example.com",
      supabaseUrl: "https://abcdefgh.supabase.co",
      supabasePublishableKey: "sb_publishable_abc123",
      turnstileSiteKey: "0x4AAAAAAAexample",
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

  it("claves con espacios o caracteres raros se ignoran (terminan en el HTML y en la CSP)", () => {
    expect(resolveConfig({ VITE_TURNSTILE_SITE_KEY: "0x4AA AAA" }).turnstileSiteKey).toBeNull();
    expect(resolveConfig({ VITE_TURNSTILE_SITE_KEY: "<script>" }).turnstileSiteKey).toBeNull();
    expect(resolveConfig({ VITE_SUPABASE_PUBLISHABLE_KEY: "sb publishable" }).supabasePublishableKey).toBeNull();
  });
});

describe("normalizeSupabaseUrl", () => {
  it("se queda con el origen (sin barra ni ruta final)", () => {
    expect(normalizeSupabaseUrl("https://abcdefgh.supabase.co")).toBe("https://abcdefgh.supabase.co");
    expect(normalizeSupabaseUrl("https://abcdefgh.supabase.co/")).toBe("https://abcdefgh.supabase.co");
    expect(normalizeSupabaseUrl("https://api.example.com/functions/v1")).toBe("https://api.example.com");
  });

  it("http solo en la máquina local (supabase start, mocks)", () => {
    expect(normalizeSupabaseUrl("http://127.0.0.1:54321")).toBe("http://127.0.0.1:54321");
    expect(normalizeSupabaseUrl("http://localhost:54321/")).toBe("http://localhost:54321");
    expect(normalizeSupabaseUrl("http://abcdefgh.supabase.co")).toBeNull();
  });

  it("rechaza lo que no es una URL http(s)", () => {
    expect(normalizeSupabaseUrl("")).toBeNull();
    expect(normalizeSupabaseUrl("abcdefgh.supabase.co")).toBeNull();
    expect(normalizeSupabaseUrl("javascript:alert(1)")).toBeNull();
    expect(normalizeSupabaseUrl("ftp://abcdefgh.supabase.co")).toBeNull();
  });
});

describe("isTurnstileTestKey", () => {
  it("reconoce las sitekeys de prueba de Cloudflare", () => {
    expect(TURNSTILE_TEST_SITE_KEY).toBe("1x00000000000000000000AA");
    expect(isTurnstileTestKey("1x00000000000000000000AA")).toBe(true);
    expect(isTurnstileTestKey("2x00000000000000000000AB")).toBe(true);
    expect(isTurnstileTestKey("3x00000000000000000000FF")).toBe(true);
    expect(isTurnstileTestKey("0x4AAAAAAAexample")).toBe(false);
  });
});
