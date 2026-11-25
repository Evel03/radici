import { describe, expect, it, vi } from "vitest";
import {
  CAPTCHA_SOURCE,
  CAPTCHA_VERSION,
  detectMode,
  envelope,
  frameTransport,
  isRequestId,
  isTokenShape,
  isTrustedHostEvent,
  nativeTransport,
  parseRequest,
  safeCode,
  type FrameEvent,
  type FrameWindow,
  type NativeWindow,
} from "./protocol.ts";

const ID = "0123456789abcdef0123456789abcdef";
const ORIGIN = "https://radicicucina.app";
const request = (id: unknown = ID) => ({ source: CAPTCHA_SOURCE, v: CAPTCHA_VERSION, type: "request", id });

describe("formas válidas", () => {
  it("id de pedido: 32 hexadecimales en minúscula", () => {
    expect(isRequestId(ID)).toBe(true);
    for (const bad of ["", "abc", ID.toUpperCase(), `${ID}0`, ID.slice(1), "g".repeat(32), 12, null, undefined, {}]) {
      expect(isRequestId(bad), String(bad)).toBe(false);
    }
  });

  it("token de Turnstile: solo letras, dígitos, punto, guion y guion bajo", () => {
    expect(isTokenShape("0.AbC-d_9")).toBe(true);
    expect(isTokenShape("a".repeat(2048))).toBe(true);
    for (const bad of ["", "a".repeat(2049), "con espacio", "a;b", "<script>", "a\nb", 5, null]) {
      expect(isTokenShape(bad), String(bad)).toBe(false);
    }
  });

  it("códigos de error: solo texto corto y seguro, si no «unknown» (nunca se refleja texto libre)", () => {
    expect(safeCode("300030")).toBe("300030");
    expect(safeCode(110200)).toBe("110200");
    expect(safeCode("timeout")).toBe("timeout");
    for (const bad of ["", "a b", "x".repeat(33), "<img>", null, undefined, 1.5, Number.NaN]) {
      expect(safeCode(bad), String(bad)).toBe("unknown");
    }
  });

  it("el sobre lleva la marca y la versión", () => {
    expect(envelope({ type: "ready" })).toEqual({ source: "radici-captcha", v: 1, type: "ready" });
  });
});

describe("parseRequest", () => {
  it("acepta un objeto o un string JSON con la marca, la versión y un id válido", () => {
    expect(parseRequest(request())).toBe(ID);
    expect(parseRequest(JSON.stringify(request()))).toBe(ID);
  });

  it("ignora todo lo demás", () => {
    const bad: unknown[] = [
      null,
      undefined,
      42,
      "no es json",
      "[]",
      [],
      { ...request(), source: "otra-cosa" },
      { ...request(), v: 2 },
      { ...request(), type: "token" },
      request("corto"),
      request(null),
      { source: CAPTCHA_SOURCE, v: 1, type: "request" },
    ];
    for (const raw of bad) expect(parseRequest(raw), JSON.stringify(raw)).toBeNull();
  });
});

describe("origen y fuente (canal frame)", () => {
  const parent = { name: "padre" };

  it("solo el mismo origen exacto y la ventana padre", () => {
    expect(isTrustedHostEvent({ origin: ORIGIN, source: parent }, ORIGIN, parent)).toBe(true);
    expect(isTrustedHostEvent({ origin: "https://evil.example", source: parent }, ORIGIN, parent)).toBe(false);
    // Coincidencias parciales: subdominio, prefijo, puerto, esquema, barra final.
    for (const origin of [
      "https://radicicucina.app.evil.example",
      "https://x.radicicucina.app",
      "http://radicicucina.app",
      "https://radicicucina.app:8443",
      "https://radicicucina.app/",
      "https://RADICICUCINA.APP",
    ]) {
      expect(isTrustedHostEvent({ origin, source: parent }, ORIGIN, parent), origin).toBe(false);
    }
    // Otra ventana con el origen correcto (otro marco del mismo sitio): tampoco.
    expect(isTrustedHostEvent({ origin: ORIGIN, source: { name: "otra" } }, ORIGIN, parent)).toBe(false);
    expect(isTrustedHostEvent({ origin: ORIGIN, source: null }, ORIGIN, parent)).toBe(false);
  });

  it("un documento con origen opaco («null») nunca es de fiar, ni siquiera frente a otro «null»", () => {
    expect(isTrustedHostEvent({ origin: "null", source: parent }, "null", parent)).toBe(false);
  });
});

describe("frameTransport", () => {
  function setup() {
    const parent = { postMessage: vi.fn() };
    let listener: ((event: FrameEvent) => void) | undefined;
    const win: FrameWindow = {
      location: { origin: ORIGIN },
      parent,
      addEventListener: (_type, fn) => {
        listener = fn;
      },
    };
    const handler = vi.fn();
    const transport = frameTransport(win);
    transport.onRequest(handler);
    const send = (event: Partial<FrameEvent>) => listener?.({ origin: ORIGIN, source: parent, data: request(), ...event });
    return { parent, transport, handler, send };
  }

  it("manda al padre con el origen exacto del sitio como destino (nunca «*»)", () => {
    const { parent, transport } = setup();
    transport.post({ type: "token", id: ID, token: "t0k.en" });
    expect(parent.postMessage).toHaveBeenCalledTimes(1);
    expect(parent.postMessage).toHaveBeenCalledWith({ source: "radici-captcha", v: 1, type: "token", id: ID, token: "t0k.en" }, ORIGIN);
  });

  it("atiende un pedido del padre del mismo origen", () => {
    const { handler, send } = setup();
    send({});
    expect(handler).toHaveBeenCalledExactlyOnceWith(ID);
  });

  it("ignora otro origen, otra fuente y mensajes que no son un pedido", () => {
    const { handler, send } = setup();
    send({ origin: "https://evil.example" });
    send({ origin: "https://radicicucina.app.evil.example" });
    send({ source: { postMessage: vi.fn() } });
    send({ data: { ...request(), source: "x" } });
    send({ data: "hola" });
    send({ data: request("no-es-un-id") });
    expect(handler).not.toHaveBeenCalled();
  });
});

describe("nativeTransport", () => {
  it("manda un string JSON por el canal de la app y atiende pedidos por la función global", () => {
    const channel = { postMessage: vi.fn() };
    const win: NativeWindow = { RadiciCaptcha: channel };
    const transport = nativeTransport(win);
    const handler = vi.fn();
    transport.onRequest(handler);

    transport.post({ type: "ready" });
    expect(channel.postMessage).toHaveBeenCalledWith('{"source":"radici-captcha","v":1,"type":"ready"}');

    win.radiciCaptchaRequest?.(ID);
    expect(handler).toHaveBeenCalledExactlyOnceWith(ID);
    // Un id que no es un id: se ignora.
    win.radiciCaptchaRequest?.("x");
    win.radiciCaptchaRequest?.({ id: ID });
    win.radiciCaptchaRequest?.(undefined);
    expect(handler).toHaveBeenCalledTimes(1);
  });

  it("sin canal no manda nada ni falla", () => {
    expect(() => nativeTransport({}).post({ type: "ready" })).not.toThrow();
  });
});

describe("detectMode", () => {
  it("native solo con ?channel=native y el canal instalado", () => {
    expect(detectMode("?channel=native&lang=it", true, false)).toBe("native");
    expect(detectMode("?channel=native", false, false)).toBe("standalone");
    // Dentro de un marco, ?channel=native sin canal no se toma por frame: el canal lo instala solo la app.
    expect(detectMode("?channel=native", false, true)).toBe("standalone");
  });

  it("frame si está en un marco; suelta, standalone", () => {
    expect(detectMode("", false, true)).toBe("frame");
    expect(detectMode("?lang=es", false, true)).toBe("frame");
    expect(detectMode("", false, false)).toBe("standalone");
    expect(detectMode("?channel=otro", true, false)).toBe("standalone");
  });
});
