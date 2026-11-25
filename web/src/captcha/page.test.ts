import { describe, expect, it, vi } from "vitest";
import type { TurnstileApi, TurnstileRenderOptions } from "../request/turnstile.ts";
import { startCaptchaPage, type PageState } from "./page.ts";
import type { PageMessage, PageTransport } from "./protocol.ts";

const ID1 = "11111111111111111111111111111111";
const ID2 = "22222222222222222222222222222222";

function setup(opts: { siteKey?: string | null; load?: () => Promise<TurnstileApi> } = {}) {
  const posted: PageMessage[] = [];
  let request: ((id: string) => void) | undefined;
  const transport: PageTransport = {
    post: (message) => posted.push(message),
    onRequest: (handler) => {
      request = handler;
    },
  };
  const renders: TurnstileRenderOptions[] = [];
  const api: TurnstileApi = {
    render: vi.fn((_container, options) => {
      renders.push(options);
      return "w1";
    }),
    reset: vi.fn(),
    remove: vi.fn(),
  };
  const states: PageState[] = [];
  const page = startCaptchaPage({
    siteKey: opts.siteKey === undefined ? "0x4AAAAAAAauth" : opts.siteKey,
    language: "es",
    transport,
    container: {} as HTMLElement,
    loadApi: opts.load ?? (async () => api),
    onState: (state) => states.push(state),
  });
  const ask = (id: string) => request?.(id);
  const last = (): TurnstileRenderOptions => {
    const options = renders.at(-1);
    if (!options) throw new Error("no se dibujó el widget");
    return options;
  };
  return { page, posted, api, renders, states, ask, last };
}

describe("startCaptchaPage", () => {
  it("avisa «ready» al arrancar y no dibuja nada hasta que haya un pedido", () => {
    const { posted, api } = setup();
    expect(posted).toEqual([{ type: "ready" }]);
    expect(api.render).not.toHaveBeenCalled();
  });

  it("un pedido dibuja el widget de Auth (modo interaction-only, acción auth) y devuelve el token con el id del pedido", async () => {
    const { ask, last, posted, states } = setup();
    ask(ID1);
    await vi.waitFor(() => expect(last).not.toThrow());
    const options = last();
    expect(options).toMatchObject({
      sitekey: "0x4AAAAAAAauth",
      action: "auth",
      appearance: "interaction-only",
      "refresh-expired": "manual",
      "response-field": false,
      language: "es",
    });
    options.callback?.("tok.en-1");
    expect(posted).toEqual([{ type: "ready" }, { type: "token", id: ID1, token: "tok.en-1" }]);
    expect(states).toEqual(["working", "idle"]);
  });

  it("un token se entrega una sola vez: uno repetido o suelto se ignora", async () => {
    const { ask, last, posted } = setup();
    ask(ID1);
    await vi.waitFor(() => expect(last).not.toThrow());
    last().callback?.("a");
    last().callback?.("b");
    expect(posted.filter((m) => m.type === "token")).toEqual([{ type: "token", id: ID1, token: "a" }]);
  });

  it("el pedido siguiente reinicia el widget y su token lleva el id nuevo", async () => {
    const { ask, last, posted, api } = setup();
    ask(ID1);
    await vi.waitFor(() => expect(last).not.toThrow());
    last().callback?.("a");
    ask(ID2);
    expect(api.reset).toHaveBeenCalledExactlyOnceWith("w1");
    expect(api.render).toHaveBeenCalledTimes(1);
    last().callback?.("b");
    expect(posted.filter((m) => m.type === "token")).toEqual([
      { type: "token", id: ID1, token: "a" },
      { type: "token", id: ID2, token: "b" },
    ]);
  });

  it("dos pedidos mientras carga el script: un solo widget, para el último", async () => {
    let resolve!: (api: TurnstileApi) => void;
    const slow = new Promise<TurnstileApi>((r) => {
      resolve = r;
    });
    const { ask, api, last, posted } = setup({ load: () => slow });
    ask(ID1);
    ask(ID2);
    resolve(api);
    await vi.waitFor(() => expect(api.render).toHaveBeenCalledTimes(1));
    last().callback?.("x");
    expect(posted.at(-1)).toEqual({ type: "token", id: ID2, token: "x" });
  });

  it("sin sitekey: responde error «misconfigured» sin cargar nada", () => {
    const { ask, posted, api } = setup({ siteKey: null });
    ask(ID1);
    expect(posted.at(-1)).toEqual({ type: "error", id: ID1, code: "misconfigured" });
    expect(api.render).not.toHaveBeenCalled();
  });

  it("si el script no carga: error «unavailable»; el pedido siguiente lo vuelve a intentar", async () => {
    let calls = 0;
    const { ask, posted, api, last } = setup({
      load: async () => {
        calls += 1;
        if (calls === 1) throw new Error("sin red");
        return api;
      },
    });
    ask(ID1);
    await vi.waitFor(() => expect(posted.at(-1)).toEqual({ type: "error", id: ID1, code: "unavailable" }));
    ask(ID2);
    await vi.waitFor(() => expect(last).not.toThrow());
    last().callback?.("ok");
    expect(posted.at(-1)).toEqual({ type: "token", id: ID2, token: "ok" });
  });

  it("errores de Turnstile: el código llega saneado y el pedido termina", async () => {
    const { ask, last, posted } = setup();
    ask(ID1);
    await vi.waitFor(() => expect(last).not.toThrow());
    last()["error-callback"]?.("110200");
    expect(posted.at(-1)).toEqual({ type: "error", id: ID1, code: "110200" });
    // Un token que llegara después ya no tiene a quién entregarse.
    last().callback?.("tarde");
    expect(posted.filter((m) => m.type === "token")).toEqual([]);

    ask(ID2);
    last()["error-callback"]?.("texto <libre> con espacios");
    expect(posted.at(-1)).toEqual({ type: "error", id: ID2, code: "unknown" });
  });

  it("timeout y navegador no compatible terminan el pedido con su código", async () => {
    const { ask, last, posted } = setup();
    ask(ID1);
    await vi.waitFor(() => expect(last).not.toThrow());
    last()["timeout-callback"]?.();
    expect(posted.at(-1)).toEqual({ type: "error", id: ID1, code: "timeout" });
    ask(ID2);
    last()["unsupported-callback"]?.();
    expect(posted.at(-1)).toEqual({ type: "error", id: ID2, code: "unsupported" });
  });

  it("si Turnstile pide tocar la casilla avisa «interactive» (con el id) y al terminar, que ya no", async () => {
    const { ask, last, posted, states } = setup();
    ask(ID1);
    await vi.waitFor(() => expect(last).not.toThrow());
    last()["before-interactive-callback"]?.();
    last()["after-interactive-callback"]?.();
    last().callback?.("tok");
    expect(posted).toEqual([
      { type: "ready" },
      { type: "interactive", id: ID1, visible: true },
      { type: "interactive", id: ID1, visible: false },
      { type: "token", id: ID1, token: "tok" },
    ]);
    expect(states).toEqual(["working", "interactive", "working", "idle"]);
  });

  it("«Annulla» termina el pedido con el código «cancelled»; sin pedido no hace nada", async () => {
    const { page, ask, last, posted } = setup();
    page.cancel();
    expect(posted).toEqual([{ type: "ready" }]);
    ask(ID1);
    await vi.waitFor(() => expect(last).not.toThrow());
    last()["before-interactive-callback"]?.();
    page.cancel();
    expect(posted.at(-1)).toEqual({ type: "error", id: ID1, code: "cancelled" });
  });

  it("un render que falla (excepción) termina el pedido con «unavailable»", async () => {
    const { ask, api, posted } = setup();
    vi.mocked(api.render).mockImplementation(() => {
      throw new Error("boom");
    });
    ask(ID1);
    await vi.waitFor(() => expect(posted.at(-1)).toEqual({ type: "error", id: ID1, code: "unavailable" }));
  });
});
