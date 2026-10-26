import { describe, expect, it, vi } from "vitest";
import {
  TURNSTILE_ACTION,
  TURNSTILE_SCRIPT_URL,
  classifyError,
  isTurnstileApi,
  mountTurnstile,
  widgetSize,
  type TurnstileApi,
  type TurnstileRenderOptions,
} from "./turnstile.ts";

/** API de Turnstile simulada: guarda las opciones de cada render para disparar sus callbacks. */
function fakeApi() {
  const renders: TurnstileRenderOptions[] = [];
  const api: TurnstileApi = {
    render: vi.fn((_container: HTMLElement, options: TurnstileRenderOptions) => {
      renders.push(options);
      return `w${renders.length}`;
    }),
    reset: vi.fn(),
    remove: vi.fn(),
  };
  const last = (): TurnstileRenderOptions => {
    const options = renders.at(-1);
    if (!options) throw new Error("no se dibujó el widget");
    return options;
  };
  return { api, renders, last };
}

function fakeContainer(width = 360): HTMLElement {
  return { clientWidth: width, dataset: {} } as unknown as HTMLElement;
}

async function mounted(width = 360, load?: () => Promise<TurnstileApi>) {
  const fake = fakeApi();
  const onChange = vi.fn();
  const container = fakeContainer(width);
  const widget = mountTurnstile(container, { siteKey: "1x00000000000000000000AA", language: "it", onChange }, {
    load: load ?? (async () => fake.api),
  });
  await vi.waitFor(() => expect(fake.renders.length > 0 || widget.status === "unavailable").toBe(true));
  return { ...fake, widget, onChange, container };
}

describe("script y opciones", () => {
  it("se carga en modo explícito desde la URL oficial", () => {
    expect(TURNSTILE_SCRIPT_URL).toMatch(/^https:\/\/challenges\.cloudflare\.com\/turnstile\/v0\/api\.js\?render=explicit&onload=\w+$/);
  });

  it("flexible si entra (≥ 300 px), si no compacto", () => {
    expect(widgetSize(300)).toBe("flexible");
    expect(widgetSize(520)).toBe("flexible");
    expect(widgetSize(299)).toBe("compact");
    expect(widgetSize(0)).toBe("compact");
  });

  it("solo cuenta como API un objeto con render (no un elemento del DOM llamado 'turnstile')", () => {
    expect(isTurnstileApi(fakeApi().api)).toBe(true);
    expect(isTurnstileApi({ id: "turnstile", tagName: "DIV" })).toBe(false);
    expect(isTurnstileApi(undefined)).toBe(false);
    expect(isTurnstileApi(null)).toBe(false);
  });

  it("clasifica los códigos de error del cliente", () => {
    for (const code of ["110100", "110110", "110200", "110420", "400020"]) expect(classifyError(code), code).toBe("misconfigured");
    for (const code of ["110500", "110510"]) expect(classifyError(code), code).toBe("unavailable");
    for (const code of ["110600", "110620", "200500", "300010", "600010", "200100", ""]) expect(classifyError(code), code).toBe("failed");
  });

  it("dibuja el widget con la sitekey, la acción, el idioma y sin campo oculto en el formulario", async () => {
    const { last, container } = await mounted(360);
    expect(last()).toMatchObject({
      sitekey: "1x00000000000000000000AA",
      action: TURNSTILE_ACTION,
      language: "it",
      theme: "auto",
      size: "flexible",
      "response-field": false,
    });
    expect(container.dataset["status"]).toBe("pending");
  });

  it("en una pantalla angosta usa el tamaño compacto", async () => {
    const { last } = await mounted(250);
    expect(last().size).toBe("compact");
  });
});

describe("estados del widget", () => {
  it("token: resuelto; vencido: pendiente (Turnstile lo renueva solo)", async () => {
    const { widget, last, onChange, container } = await mounted();
    last().callback?.("XXXX.DUMMY.TOKEN.XXXX");
    expect(widget.status).toBe("solved");
    expect(widget.token).toBe("XXXX.DUMMY.TOKEN.XXXX");
    expect(container.dataset["status"]).toBe("solved");
    last()["expired-callback"]?.();
    expect(widget.status).toBe("pending");
    expect(widget.token).toBeNull();
    expect(onChange).toHaveBeenCalled();
  });

  it("error del desafío: sin token y en estado fallido; uno de configuración no se reintenta", async () => {
    const { widget, last } = await mounted();
    last().callback?.("t1");
    last()["error-callback"]?.("300030");
    expect(widget.status).toBe("failed");
    expect(widget.token).toBeNull();
    last()["error-callback"]?.("110200");
    expect(widget.status).toBe("misconfigured");
  });

  it("navegador no compatible o desafío vencido", async () => {
    const { widget, last } = await mounted();
    last()["timeout-callback"]?.();
    expect(widget.status).toBe("pending");
    last()["unsupported-callback"]?.();
    expect(widget.status).toBe("unavailable");
  });

  it("reset después de un envío fallido: borra el token y reinicia el widget", async () => {
    const { widget, last, api } = await mounted();
    last().callback?.("t1");
    widget.reset();
    expect(api.reset).toHaveBeenCalledWith("w1");
    expect(widget.token).toBeNull();
    expect(widget.status).toBe("pending");
  });

  it("cambio de idioma: quita el widget y lo dibuja en el idioma nuevo", async () => {
    const { widget, renders, api } = await mounted();
    renders[0]?.callback?.("t1");
    widget.setLanguage("es");
    expect(api.remove).toHaveBeenCalledWith("w1");
    expect(renders).toHaveLength(2);
    expect(renders[1]?.language).toBe("es");
    expect(widget.token).toBeNull();
    widget.setLanguage("es"); // mismo idioma: no hace nada
    expect(renders).toHaveLength(2);
  });

  it("si el script no carga queda no disponible, y reset lo vuelve a intentar", async () => {
    const fake = fakeApi();
    const load = vi.fn<() => Promise<TurnstileApi>>().mockRejectedValueOnce(new Error("blocked")).mockResolvedValue(fake.api);
    const { widget } = await mounted(360, load);
    expect(widget.status).toBe("unavailable");
    widget.reset();
    await vi.waitFor(() => expect(fake.renders).toHaveLength(1));
    expect(load).toHaveBeenCalledTimes(2);
    expect(widget.status).toBe("pending");
  });

  it("reset después de un error del desafío lo reinicia", async () => {
    const { widget, last, api } = await mounted();
    last()["error-callback"]?.("300030");
    widget.reset();
    expect(api.reset).toHaveBeenCalledWith("w1");
    expect(widget.status).toBe("pending");
  });

  it("si render tira una excepción queda no disponible", async () => {
    const fake = fakeApi();
    fake.api.render = vi.fn(() => {
      throw new Error("bad sitekey");
    });
    const { widget } = await mounted(360, async () => fake.api);
    await vi.waitFor(() => expect(widget.status).toBe("unavailable"));
  });
});
