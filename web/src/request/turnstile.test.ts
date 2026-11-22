import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  TURNSTILE_ACTION,
  TURNSTILE_SCRIPT_URL,
  TURNSTILE_STALL_MS,
  classifyError,
  errorCodeText,
  isTurnstileApi,
  mountTurnstile,
  turnstileView,
  waitingStatus,
  widgetSize,
  type TurnstileApi,
  type TurnstileRenderOptions,
  type TurnstileViewInput,
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
      theme: "light",
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

describe("código del error (para que soporte lo diagnostique)", () => {
  it("un código de Turnstile se muestra tal cual, sin espacios alrededor", () => {
    expect(errorCodeText("200500")).toBe("200500");
    expect(errorCodeText(" 300030 ")).toBe("300030");
    expect(errorCodeText(600010)).toBe("600010");
  });

  it("nada vacío, raro ni largo: no es un código", () => {
    for (const code of ["", "   ", undefined, null, {}, Number.NaN, "<b>1</b>", "200 500", "1".repeat(33)]) {
      expect(errorCodeText(code), String(code)).toBeNull();
    }
  });

  it("el widget guarda el código del último error mientras dura y lo borra con el token", async () => {
    const { widget, last } = await mounted();
    expect(widget.errorCode).toBeNull();
    last()["error-callback"]?.("200500");
    expect(widget.status).toBe("failed");
    expect(widget.errorCode).toBe("200500");
    // Turnstile reintenta solo: cada error nuevo trae su código.
    last()["error-callback"]?.("600010");
    expect(widget.errorCode).toBe("600010");
    last()["error-callback"]?.("110200");
    expect(widget.status).toBe("misconfigured");
    expect(widget.errorCode).toBe("110200");
    last().callback?.("t1");
    expect(widget.errorCode).toBeNull();
  });

  it("reiniciar es un intento nuevo: sin el código del anterior", async () => {
    const { widget, last } = await mounted();
    last()["error-callback"]?.("300030");
    widget.reset();
    expect(widget.status).toBe("pending");
    expect(widget.errorCode).toBeNull();
  });

  it("sin código: navegador no compatible y script que no carga", async () => {
    const { widget, last } = await mounted();
    last()["error-callback"]?.("300030");
    last()["unsupported-callback"]?.();
    expect(widget.status).toBe("unavailable");
    expect(widget.errorCode).toBeNull();
    const blocked = await mounted(360, () => Promise.reject(new Error("blocked")));
    expect(blocked.widget.status).toBe("unavailable");
    expect(blocked.widget.errorCode).toBeNull();
  });
});

describe("lo que se ve junto al widget", () => {
  const view = (input: Partial<TurnstileViewInput>) =>
    turnstileView({ status: "pending", errorCode: null, stalled: false, rejected: false, ...input });

  it("con token o esperándolo (sin trabarse) no hay nada que mostrar", () => {
    const nothing = { error: null, code: null, help: false, retry: false };
    expect(view({ status: "solved" })).toEqual(nothing);
    expect(view({ status: "pending" })).toEqual(nothing);
    expect(view({ status: "loading" })).toEqual(nothing);
    // El token borra la sugerencia aunque el widget se hubiera trabado antes.
    expect(view({ status: "solved", stalled: true })).toEqual(nothing);
  });

  it("trabado sin token ni error: la sugerencia y «Ripeti la verifica», sin mensaje de error", () => {
    const stuck = { error: null, code: null, help: true, retry: true };
    expect(view({ status: "pending", stalled: true })).toEqual(stuck);
    expect(view({ status: "loading", stalled: true })).toEqual(stuck);
  });

  it("el desafío falló: el error con su código, la sugerencia y el reintento", () => {
    expect(view({ status: "failed", errorCode: "200500" })).toEqual({
      error: "errors.turnstileFailed",
      code: "200500",
      help: true,
      retry: true,
    });
    expect(view({ status: "failed" }).code).toBeNull();
  });

  it("no disponible (script bloqueado o navegador no compatible): igual, con el código si lo hubo", () => {
    expect(view({ status: "unavailable", errorCode: "110500" })).toEqual({
      error: "errors.turnstileUnavailable",
      code: "110500",
      help: true,
      retry: true,
    });
    expect(view({ status: "unavailable" })).toMatchObject({ code: null, help: true, retry: true });
  });

  it("mal configurado: el error y el código, sin sugerencia ni reintento (no depende del navegador)", () => {
    expect(view({ status: "misconfigured", errorCode: "110200", stalled: true })).toEqual({
      error: "errors.turnstileMisconfigured",
      code: "110200",
      help: false,
      retry: false,
    });
  });

  it("el servidor rechazó el token (403): el error de fallo hasta que llegue otro, sin código", () => {
    expect(view({ status: "pending", rejected: true })).toEqual({ error: "errors.turnstileFailed", code: null, help: false, retry: false });
    expect(view({ status: "pending", rejected: true, stalled: true })).toMatchObject({ help: true, retry: true });
  });

  it("el envío que espera el token avisa si el widget se trabó", () => {
    expect(waitingStatus(false)).toBe("request.statusWaitingTurnstile");
    expect(waitingStatus(true)).toBe("request.statusTurnstileStalled");
  });
});

describe("widget trabado: sin token ni error un rato después de dibujarlo", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  /** Con timers falsos: monta y deja que la carga (una promesa) termine y se dibuje el widget. */
  async function mountedNow(load?: () => Promise<TurnstileApi>) {
    const fake = fakeApi();
    const onChange = vi.fn();
    const widget = mountTurnstile(fakeContainer(), { siteKey: "1x00000000000000000000AA", language: "it", onChange }, {
      load: load ?? (async () => fake.api),
    });
    await vi.advanceTimersByTimeAsync(0);
    return { ...fake, widget, onChange };
  }

  it(`a los ${TURNSTILE_STALL_MS / 1000} s sin token ni error queda trabado y avisa a la página`, async () => {
    expect(TURNSTILE_STALL_MS).toBe(15_000);
    const { widget, renders, onChange } = await mountedNow();
    expect(renders).toHaveLength(1);
    vi.advanceTimersByTime(TURNSTILE_STALL_MS - 1);
    expect(widget.stalled).toBe(false);
    onChange.mockClear();
    vi.advanceTimersByTime(1);
    expect(widget.stalled).toBe(true);
    expect(widget.status).toBe("pending");
    expect(onChange).toHaveBeenCalledTimes(1);
    // Ya avisó: no vuelve a avisar mientras siga igual.
    vi.advanceTimersByTime(TURNSTILE_STALL_MS * 3);
    expect(onChange).toHaveBeenCalledTimes(1);
  });

  it("el token lo destraba en el acto", async () => {
    const { widget, last } = await mountedNow();
    vi.advanceTimersByTime(TURNSTILE_STALL_MS);
    expect(widget.stalled).toBe(true);
    last().callback?.("t1");
    expect(widget.stalled).toBe(false);
    expect(widget.status).toBe("solved");
  });

  it("con token o con error antes de tiempo no se traba", async () => {
    const solved = await mountedNow();
    solved.last().callback?.("t1");
    vi.advanceTimersByTime(TURNSTILE_STALL_MS * 2);
    expect(solved.widget.stalled).toBe(false);

    const failed = await mountedNow();
    failed.last()["error-callback"]?.("600010");
    vi.advanceTimersByTime(TURNSTILE_STALL_MS * 2);
    expect(failed.widget.stalled).toBe(false);
    expect(failed.widget.status).toBe("failed");
  });

  it("mientras espera que la persona toque la casilla (modo interactivo) no está trabado", async () => {
    const { widget, last } = await mountedNow();
    vi.advanceTimersByTime(100);
    last()["before-interactive-callback"]?.();
    vi.advanceTimersByTime(TURNSTILE_STALL_MS * 2);
    expect(widget.stalled).toBe(false);
    // Tocó la casilla: sale del modo interactivo y vuelve a contar hasta el token.
    last()["after-interactive-callback"]?.();
    vi.advanceTimersByTime(TURNSTILE_STALL_MS - 1);
    expect(widget.stalled).toBe(false);
    vi.advanceTimersByTime(1);
    expect(widget.stalled).toBe(true);
    // Si después pasa a pedir la casilla, la sugerencia sobra.
    last()["before-interactive-callback"]?.();
    expect(widget.stalled).toBe(false);
  });

  it("al tocar la casilla llega el token enseguida: nunca se traba", async () => {
    const { widget, last } = await mountedNow();
    last()["before-interactive-callback"]?.();
    vi.advanceTimersByTime(TURNSTILE_STALL_MS * 2);
    last()["after-interactive-callback"]?.();
    last().callback?.("XXXX.DUMMY.TOKEN.XXXX");
    vi.advanceTimersByTime(TURNSTILE_STALL_MS * 2);
    expect(widget.stalled).toBe(false);
    expect(widget.token).toBe("XXXX.DUMMY.TOKEN.XXXX");
  });

  it("«Ripeti la verifica» no esconde la sugerencia: sigue hasta que llegue un token", async () => {
    const { widget, last, api } = await mountedNow();
    vi.advanceTimersByTime(TURNSTILE_STALL_MS);
    widget.reset();
    expect(api.reset).toHaveBeenCalledWith("w1");
    expect(widget.status).toBe("pending");
    expect(widget.stalled).toBe(true);
    last().callback?.("t1");
    expect(widget.stalled).toBe(false);
  });

  it("después de un error, reiniciar vuelve a contar desde cero", async () => {
    const { widget, last } = await mountedNow();
    vi.advanceTimersByTime(TURNSTILE_STALL_MS - 1000);
    last()["error-callback"]?.("300030");
    widget.reset();
    vi.advanceTimersByTime(TURNSTILE_STALL_MS - 1);
    expect(widget.stalled).toBe(false);
    vi.advanceTimersByTime(1);
    expect(widget.stalled).toBe(true);
  });

  it("token vencido o desafío vencido: vuelve a esperar y a contar", async () => {
    const expired = await mountedNow();
    expired.last().callback?.("t1");
    vi.advanceTimersByTime(TURNSTILE_STALL_MS * 2);
    expired.last()["expired-callback"]?.();
    expect(expired.widget.status).toBe("pending");
    vi.advanceTimersByTime(TURNSTILE_STALL_MS);
    expect(expired.widget.stalled).toBe(true);

    const timeout = await mountedNow();
    timeout.last()["before-interactive-callback"]?.();
    vi.advanceTimersByTime(TURNSTILE_STALL_MS * 2);
    timeout.last()["timeout-callback"]?.();
    vi.advanceTimersByTime(TURNSTILE_STALL_MS);
    expect(timeout.widget.stalled).toBe(true);
  });

  it("si el script no termina de cargar, también se traba (y reintentar lo vuelve a pedir)", async () => {
    const load = vi.fn(() => new Promise<TurnstileApi>(() => undefined));
    const { widget } = await mountedNow(load);
    expect(widget.status).toBe("loading");
    vi.advanceTimersByTime(TURNSTILE_STALL_MS);
    expect(widget.stalled).toBe(true);
    widget.reset();
    expect(load).toHaveBeenCalledTimes(2);
  });

  it("cambiar de idioma dibuja otro widget y vuelve a contar", async () => {
    const { widget, renders } = await mountedNow();
    vi.advanceTimersByTime(TURNSTILE_STALL_MS - 1000);
    widget.setLanguage("es");
    expect(renders).toHaveLength(2);
    vi.advanceTimersByTime(TURNSTILE_STALL_MS - 1);
    expect(widget.stalled).toBe(false);
    vi.advanceTimersByTime(1);
    expect(widget.stalled).toBe(true);
  });
});
