import { describe, expect, it } from "vitest";
import type { ClientLinkView } from "../../../supabase/functions/_shared/client_link.ts";
import type { FetchLike } from "./api.ts";
import { createReservation, rateLimitMessage, type Reservation } from "./controller.ts";
import { SEND_1, SEND_NEW, SUPABASE_URL, TOKEN, menu, view, week } from "./fixtures.ts";

const json = (status: number, body: unknown, headers: Record<string, string> = {}): Response =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

type Respond = () => Response | Promise<Response>;
type RespondTo = (body: Record<string, unknown>) => Response | Promise<Response>;

interface FakeServer {
  current: ClientLinkView;
  viewResponse: Respond | null;
  confirm: RespondTo;
  changes: RespondTo;
  calls: Array<{ route: string; body: Record<string, unknown> }>;
  fetch: FetchLike;
}

/**
 * La función simulada: /view devuelve `current` (si no se cambia `viewResponse`); /confirm y /changes, lo que
 * digan `confirm` y `changes` (por defecto, como la función: guardan la respuesta en `current`). Registra cada
 * llamada (ruta y cuerpo).
 */
function fakeServer(initial: ClientLinkView = view()): FakeServer {
  /** Como la base: la respuesta queda en el envío de `current`. */
  const answer = (sendId: unknown, patch: Partial<NonNullable<ClientLinkView["weeks"][number]["menu"]>>): void => {
    server.current = {
      ...server.current,
      weeks: server.current.weeks.map((item) => (item.menu && item.menu.sendId === sendId ? { ...item, menu: { ...item.menu, ...patch } } : item)),
    };
  };
  const server: FakeServer = {
    current: initial,
    viewResponse: null,
    confirm: (body: Record<string, unknown>): Response | Promise<Response> => {
      answer(body["sendId"], { state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" });
      return json(200, { confirmedAt: "2027-02-26T10:00:00+00:00", already: false });
    },
    changes: (body: Record<string, unknown>): Response | Promise<Response> => {
      answer(body["sendId"], { state: "changesRequested", changesRequestedAt: "2027-02-26T11:00:00+00:00" });
      return json(200, { changesRequestedAt: "2027-02-26T11:00:00+00:00" });
    },
    calls: [] as Array<{ route: string; body: Record<string, unknown> }>,
    fetch: (async (url, init) => {
      const route = new URL(url).pathname.replace("/functions/v1/client-link", "");
      const body = JSON.parse(String(init.body)) as Record<string, unknown>;
      server.calls.push({ route, body });
      if (route === "/view") return server.viewResponse ? server.viewResponse() : json(200, server.current);
      if (route === "/confirm") return server.confirm(body);
      if (route === "/changes") return server.changes(body);
      throw new Error(`ruta inesperada: ${route}`);
    }) as FetchLike,
  };
  return server;
}

async function loaded(server = fakeServer()): Promise<Reservation> {
  const reservation = createReservation({ supabaseUrl: SUPABASE_URL, token: TOKEN, api: { fetch: server.fetch } });
  await reservation.load();
  return reservation;
}

/** El menú de la semana 1 del estado (para mirar lo que cambió). */
function firstMenu(reservation: Reservation) {
  return reservation.state.kind === "ready" ? reservation.state.view.weeks[0]?.menu : undefined;
}

describe("abrir la página", () => {
  it("sin token: link no válido, sin llamar a nadie", async () => {
    const server = fakeServer();
    const reservation = createReservation({ supabaseUrl: SUPABASE_URL, token: null, api: { fetch: server.fetch } });
    await reservation.load();
    expect(reservation.state).toEqual({ kind: "invalidLink" });
    expect(server.calls).toEqual([]);
  });

  it("sin Supabase configurado en el build: el error del servidor", async () => {
    const reservation = createReservation({ supabaseUrl: null, token: TOKEN });
    await reservation.load();
    expect(reservation.state).toEqual({ kind: "error", message: { key: "reservation.errors.server" } });
  });

  it("con la reserva: lista para mostrar, avisando a quien pinta en cada cambio", async () => {
    const server = fakeServer();
    const reservation = createReservation({ supabaseUrl: SUPABASE_URL, token: TOKEN, api: { fetch: server.fetch } });
    const seen: string[] = [];
    reservation.subscribe(() => seen.push(reservation.state.kind));
    const loading = reservation.load();
    expect(reservation.state.kind).toBe("loading");
    await loading;
    expect(reservation.state).toEqual({ kind: "ready", view: view() });
    expect(seen).toEqual(["loading", "ready"]);
    expect(server.calls).toEqual([{ route: "/view", body: { token: TOKEN } }]);
  });

  it("link vencido, demasiados intentos, error y sin conexión", async () => {
    const cases: Array<[() => Response | Promise<Response>, unknown]> = [
      [() => json(404, { error: "linkNotFound" }), { kind: "invalidLink" }],
      [() => json(429, { error: "rateLimited" }, { "Retry-After": "120" }), { kind: "error", message: { key: "reservation.errors.rateLimitedMinutes", params: { minutes: 2 } } }],
      [() => json(500, { error: "server" }), { kind: "error", message: { key: "reservation.errors.server" } }],
      [
        () => {
          throw new TypeError("offline");
        },
        { kind: "error", message: { key: "reservation.errors.network" } },
      ],
    ];
    for (const [respond, state] of cases) {
      const server = fakeServer();
      server.viewResponse = respond;
      expect((await loaded(server)).state).toEqual(state);
    }
  });

  it("«Riprova»: vuelve a pedir la reserva", async () => {
    const server = fakeServer();
    server.viewResponse = () => json(503, { error: "unavailable" });
    const reservation = await loaded(server);
    expect(reservation.state.kind).toBe("error");
    server.viewResponse = null;
    await reservation.load();
    expect(reservation.state.kind).toBe("ready");
  });
});

describe("confirmar el menú", () => {
  it("manda el envío de esa semana, la marca confirmada con la hora de la función, avisa y vuelve a leer la reserva", async () => {
    const server = fakeServer();
    const reservation = await loaded(server);
    const result = reservation.confirm(1);
    expect(reservation.ui(1).busy).toBe("confirm");
    expect(await result).toEqual({ focus: { kind: "status", week: 1 }, announce: null });
    expect(server.calls.map((call) => call.route)).toEqual(["/view", "/confirm", "/view"]);
    expect(server.calls[1]?.body).toEqual({ token: TOKEN, sendId: SEND_1 });
    expect(firstMenu(reservation)).toMatchObject({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" });
    expect(reservation.ui(1)).toMatchObject({ busy: null, error: null, notice: { key: "reservation.notices.confirmed" } });
  });

  it("si no puede volver a leer la reserva, queda confirmada con lo que devolvió la función", async () => {
    const server = fakeServer();
    const reservation = await loaded(server);
    server.viewResponse = () => json(503, { error: "unavailable" });
    await reservation.confirm(1);
    expect(reservation.state.kind).toBe("ready");
    expect(firstMenu(reservation)).toMatchObject({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" });
  });

  it("ya estaba confirmado: lo dice", async () => {
    const server = fakeServer();
    server.confirm = () => json(200, { confirmedAt: "2027-02-25T20:00:00+00:00", already: true });
    const reservation = await loaded(server);
    await reservation.confirm(1);
    expect(reservation.ui(1).notice).toEqual({ key: "reservation.notices.alreadyConfirmed" });
  });

  it("hay un menú más nuevo: lo dice y muestra el nuevo", async () => {
    const server = fakeServer();
    server.confirm = () => json(409, { error: "menuOutdated" });
    const reservation = await loaded(server);
    server.current = view({ weeks: [week({ menu: menu({ sendId: SEND_NEW, sentAt: "2027-02-26T09:00:00+00:00" }) })] });
    expect(await reservation.confirm(1)).toEqual({ focus: { kind: "status", week: 1 }, announce: null });
    expect(reservation.ui(1).notice).toEqual({ key: "reservation.notices.menuOutdated" });
    expect(firstMenu(reservation)?.sendId).toBe(SEND_NEW);
  });

  it("ya pidió cambios para ese menú: lo dice", async () => {
    const server = fakeServer();
    server.confirm = () => json(409, { error: "changesRequested" });
    const reservation = await loaded(server);
    await reservation.confirm(1);
    expect(reservation.ui(1).notice).toEqual({ key: "reservation.notices.changesAlreadyRequested" });
  });

  it("el envío ya no está: lo dice y vuelve a leer", async () => {
    const server = fakeServer();
    server.confirm = () => json(404, { error: "sendNotFound" });
    const reservation = await loaded(server);
    await reservation.confirm(1);
    expect(reservation.ui(1).notice).toEqual({ key: "reservation.notices.sendNotFound" });
    expect(server.calls.at(-1)?.route).toBe("/view");
  });

  it("el link venció mientras tanto: la página lo dice", async () => {
    const server = fakeServer();
    server.confirm = () => json(404, { error: "linkNotFound" });
    const reservation = await loaded(server);
    expect(await reservation.confirm(1)).toEqual({ focus: { kind: "problem" }, announce: null });
    expect(reservation.state).toEqual({ kind: "invalidLink" });
  });

  it("sin conexión, error o demasiados intentos: el error junto al botón, anunciado, y se puede reintentar", async () => {
    const cases: Array<[() => Response | Promise<Response>, unknown]> = [
      [
        () => {
          throw new TypeError("offline");
        },
        { key: "reservation.errors.network" },
      ],
      [() => json(500, { error: "server" }), { key: "reservation.errors.server" }],
      [() => json(429, { error: "rateLimited" }, { "Retry-After": "3600" }), { key: "reservation.errors.rateLimitedHours", params: { hours: 1 } }],
    ];
    for (const [respond, message] of cases) {
      const server = fakeServer();
      server.confirm = respond;
      const reservation = await loaded(server);
      expect(await reservation.confirm(1)).toEqual({ focus: { kind: "confirm", week: 1 }, announce: message });
      expect(reservation.ui(1)).toMatchObject({ busy: null, error: message });
      expect(firstMenu(reservation)?.state).toBe("pending");
      // Reintento: limpia el error.
      server.confirm = () => json(200, { confirmedAt: "2027-02-26T10:00:00+00:00", already: false });
      await reservation.confirm(1);
      expect(reservation.ui(1).error).toBeNull();
    }
  });

  it("no hace nada con una respuesta en camino, ni con un menú que no está por confirmar", async () => {
    const server = fakeServer(
      view({
        weeks: [
          week({ weeks: 5 }),
          week({ week: 2, weeks: 5, menu: menu({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" }) }),
          week({ week: 3, weeks: 5, done: true }),
          week({ week: 4, weeks: 5, menu: menu({ content: null }) }),
          week({ week: 5, weeks: 5, menu: null }),
        ],
      }),
    );
    const reservation = await loaded(server);
    const first = reservation.confirm(1);
    const second = reservation.confirm(1);
    expect(await second).toEqual({ focus: null, announce: null });
    await first;
    for (const n of [2, 3, 4, 5, 9]) expect(await reservation.confirm(n), String(n)).toEqual({ focus: null, announce: null });
    expect(server.calls.filter((call) => call.route === "/confirm")).toHaveLength(1);
  });
});

describe("pedir cambios", () => {
  it("abrir y cerrar el formulario (el mensaje queda guardado)", async () => {
    const reservation = await loaded();
    expect(reservation.openChanges(1)).toEqual({ focus: { kind: "textarea", week: 1 }, announce: null });
    expect(reservation.ui(1).formOpen).toBe(true);
    reservation.setDraft(1, "Senza cipolla");
    expect(reservation.closeChanges(1)).toEqual({ focus: { kind: "askChanges", week: 1 }, announce: null });
    expect(reservation.ui(1)).toMatchObject({ formOpen: false, draft: "Senza cipolla" });
    // Una semana sin menú por confirmar no abre nada.
    expect(reservation.openChanges(2)).toEqual({ focus: null, announce: null });
  });

  it("un mensaje vacío (o solo espacios) no sale: error en el campo; el error se va al escribir algo válido", async () => {
    const server = fakeServer();
    const reservation = await loaded(server);
    reservation.openChanges(1);
    reservation.setDraft(1, "  \n ");
    expect(await reservation.submitChanges(1)).toEqual({ focus: { kind: "textarea", week: 1 }, announce: null });
    expect(reservation.ui(1).textError).toBe(true);
    expect(server.calls.filter((call) => call.route === "/changes")).toEqual([]);
    expect(reservation.setDraft(1, "  ")).toEqual({ textErrorCleared: false });
    expect(reservation.setDraft(1, "Senza cipolla")).toEqual({ textErrorCleared: true });
    expect(reservation.ui(1).textError).toBe(false);
  });

  it("manda el mensaje normalizado, la semana queda con cambios pedidos y el formulario se cierra", async () => {
    const server = fakeServer();
    const reservation = await loaded(server);
    reservation.openChanges(1);
    reservation.setDraft(1, "  Senza cipolla,\r\ngrazie  ");
    expect(await reservation.submitChanges(1)).toEqual({ focus: { kind: "status", week: 1 }, announce: null });
    expect(server.calls.find((call) => call.route === "/changes")?.body).toEqual({ token: TOKEN, sendId: SEND_1, text: "Senza cipolla,\ngrazie" });
    expect(firstMenu(reservation)).toMatchObject({ state: "changesRequested", changesRequestedAt: "2027-02-26T11:00:00+00:00" });
    expect(reservation.ui(1)).toMatchObject({ formOpen: false, draft: "", notice: { key: "reservation.notices.changesSent" } });
  });

  it("ya lo había confirmado: lo dice (los cambios, a Evelyn) y cierra el formulario", async () => {
    const server = fakeServer();
    server.changes = () => json(409, { error: "alreadyConfirmed" });
    const reservation = await loaded(server);
    reservation.openChanges(1);
    reservation.setDraft(1, "Senza cipolla");
    await reservation.submitChanges(1);
    expect(reservation.ui(1)).toMatchObject({ formOpen: false, notice: { key: "reservation.notices.alreadyConfirmedChanges" } });
  });

  it("hay un menú más nuevo: el mensaje a medio escribir no se pierde", async () => {
    const server = fakeServer();
    server.changes = () => json(409, { error: "menuOutdated" });
    const reservation = await loaded(server);
    reservation.openChanges(1);
    reservation.setDraft(1, "Senza cipolla");
    server.current = view({ weeks: [week({ menu: menu({ sendId: SEND_NEW }) })] });
    await reservation.submitChanges(1);
    expect(reservation.ui(1)).toMatchObject({ formOpen: true, draft: "Senza cipolla", notice: { key: "reservation.notices.menuOutdated" } });
    expect(firstMenu(reservation)?.sendId).toBe(SEND_NEW);
  });

  it("la función rechaza el texto: error en el campo", async () => {
    const server = fakeServer();
    server.changes = () => json(400, { error: "invalidText" });
    const reservation = await loaded(server);
    reservation.openChanges(1);
    reservation.setDraft(1, "Senza cipolla");
    expect(await reservation.submitChanges(1)).toEqual({ focus: { kind: "textarea", week: 1 }, announce: null });
    expect(reservation.ui(1)).toMatchObject({ textError: true, formOpen: true });
  });

  it("sin conexión: el error junto al botón de enviar, anunciado; el mensaje queda", async () => {
    const server = fakeServer();
    server.changes = () => {
      throw new TypeError("offline");
    };
    const reservation = await loaded(server);
    reservation.openChanges(1);
    reservation.setDraft(1, "Senza cipolla");
    expect(await reservation.submitChanges(1)).toEqual({ focus: { kind: "submit", week: 1 }, announce: { key: "reservation.errors.network" } });
    expect(reservation.ui(1)).toMatchObject({ formOpen: true, draft: "Senza cipolla", busy: null });
  });
});

describe("rateLimitMessage", () => {
  it("en minutos hasta una hora, después en horas; sin tiempo, genérico", () => {
    expect(rateLimitMessage(null)).toEqual({ key: "reservation.errors.rateLimited" });
    expect(rateLimitMessage(0)).toEqual({ key: "reservation.errors.rateLimited" });
    expect(rateLimitMessage(61)).toEqual({ key: "reservation.errors.rateLimitedMinutes", params: { minutes: 2 } });
    expect(rateLimitMessage(7200)).toEqual({ key: "reservation.errors.rateLimitedHours", params: { hours: 2 } });
  });
});
