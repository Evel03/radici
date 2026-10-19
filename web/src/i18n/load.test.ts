import { afterEach, describe, expect, it, vi } from "vitest";
import en from "./en.json";
import es from "./es.json";
import { DICT_URLS, createDictLoader, type DictLoaders } from "./load.ts";

const NETWORK_ERROR = "Failed to fetch";

function loaders(overrides: Partial<DictLoaders> = {}): DictLoaders {
  const ok = (dict: unknown) => async () => dict;
  return { it: ok({ a: "ciao" }), es: ok({ a: "hola" }), en: ok({ a: "hello" }), ...overrides };
}

describe("createDictLoader", () => {
  it("si la descarga falla, rechaza y el próximo pedido vuelve a descargar el idioma", async () => {
    const es_ = vi
      .fn<DictLoaders["es"]>()
      .mockRejectedValueOnce(new TypeError(NETWORK_ERROR))
      .mockResolvedValueOnce({ common: { reload: "Volver a cargar la página" } });
    const load = createDictLoader(loaders({ es: es_ }));
    await expect(load("es")).rejects.toThrow(NETWORK_ERROR);
    await expect(load("es")).resolves.toEqual({ "common.reload": "Volver a cargar la página" });
    expect(es_).toHaveBeenCalledTimes(2);
  });

  it("un reintento dentro del mismo manejador del error ya descarga de nuevo", async () => {
    const it_ = vi.fn<DictLoaders["it"]>().mockRejectedValueOnce(new TypeError(NETWORK_ERROR)).mockResolvedValueOnce({ a: "ciao" });
    const load = createDictLoader(loaders({ it: it_ }));
    expect(await load("it").catch(() => load("it"))).toEqual({ a: "ciao" });
    expect(it_).toHaveBeenCalledTimes(2);
  });

  it("un JSON que no son textos también se descarta y se reintenta", async () => {
    const en_ = vi.fn<DictLoaders["en"]>().mockResolvedValueOnce({ a: 1 }).mockResolvedValueOnce({ a: "hello" });
    const load = createDictLoader(loaders({ en: en_ }));
    await expect(load("en")).rejects.toThrow(TypeError);
    await expect(load("en")).resolves.toEqual({ a: "hello" });
  });

  it("un idioma que cargó bien se descarga una sola vez, también con pedidos simultáneos", async () => {
    const es_ = vi.fn<DictLoaders["es"]>(async () => ({ a: "hola" }));
    const load = createDictLoader(loaders({ es: es_ }));
    const [first, second] = await Promise.all([load("es"), load("es")]);
    expect(first).toBe(second);
    expect(await load("es")).toBe(first);
    expect(es_).toHaveBeenCalledTimes(1);
  });
});

describe("loadDict (fetch del JSON publicado)", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.resetModules();
  });

  it("pide el JSON del idioma por su URL y lo aplana", async () => {
    const fetchMock = vi.fn(async (url: string) => Response.json(url === DICT_URLS.es ? es : en));
    vi.stubGlobal("fetch", fetchMock);
    const { loadDict } = await import("./load.ts");
    const dict = await loadDict("es");
    expect(dict["common.reload"]).toBe(es.common.reload);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0]?.[0]).toBe(DICT_URLS.es);
    expect(DICT_URLS.es).toMatch(/es\.json/);
  });

  it("sin conexión o con 404 (deploy nuevo) rechaza, y el reintento vuelve a pedirlo", async () => {
    const fetchMock = vi
      .fn<(url: string) => Promise<Response>>()
      .mockRejectedValueOnce(new TypeError(NETWORK_ERROR))
      .mockResolvedValueOnce(new Response("<!doctype html>", { status: 404, headers: { "Content-Type": "text/html" } }))
      .mockResolvedValueOnce(Response.json(en));
    vi.stubGlobal("fetch", fetchMock);
    const { loadDict } = await import("./load.ts");
    await expect(loadDict("en")).rejects.toThrow(NETWORK_ERROR);
    await expect(loadDict("en")).rejects.toThrow(/HTTP 404/);
    expect((await loadDict("en"))["common.reload"]).toBe(en.common.reload);
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
});
