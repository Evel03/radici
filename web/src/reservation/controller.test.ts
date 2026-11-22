import { describe, expect, it } from "vitest";
import type { ClientLinkView } from "../../../supabase/functions/_shared/client_link.ts";
import type { FetchLike } from "./api.ts";
import { createReservation, menuQuoteMode, quoteView as quoteViewOf, rateLimitMessage, type Reservation } from "./controller.ts";
import {
  QUOTE_ID,
  SEND_1,
  SEND_2,
  SEND_NEW,
  SESSION_1,
  SESSION_2,
  SESSION_3,
  SUPABASE_URL,
  TOKEN,
  menu,
  quoteView,
  session,
  view,
  week,
} from "./fixtures.ts";

const json = (status: number, body: unknown, headers: Record<string, string> = {}): Response =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

type Respond = () => Response | Promise<Response>;
type RespondTo = (body: Record<string, unknown>) => Response | Promise<Response>;

interface FakeServer {
  current: ClientLinkView;
  viewResponse: Respond | null;
  confirm: RespondTo;
  changes: RespondTo;
  accept: RespondTo;
  decline: RespondTo;
  calls: Array<{ route: string; body: Record<string, unknown> }>;
  fetch: FetchLike;
}

/**
 * La función simulada: /view devuelve `current` (si no se cambia `viewResponse`); /confirm, /changes, /accept y
 * /decline, lo que digan `confirm`, `changes`, `accept` y `decline` (por defecto, como la función: guardan la
 * respuesta en `current`; rechazar el presupuesto cancela sus semanas). Registra cada llamada (ruta y cuerpo).
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
    confirm: (body) => {
      answer(body["sendId"], { state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" });
      return json(200, { confirmedAt: "2027-02-26T10:00:00+00:00", already: false });
    },
    changes: (body) => {
      answer(body["sendId"], { state: "changesRequested", changesRequestedAt: "2027-02-26T11:00:00+00:00" });
      return json(200, { changesRequestedAt: "2027-02-26T11:00:00+00:00" });
    },
    accept: (body) => {
      answer(body["sendId"], { state: "confirmed", confirmedAt: "2027-02-26T12:00:00+00:00" });
      if (server.current.quote) server.current = { ...server.current, quote: { ...server.current.quote, status: "accepted", acceptedAt: "2027-02-26T12:00:00+00:00" } };
      return json(200, { acceptedAt: "2027-02-26T12:00:00+00:00", already: false });
    },
    decline: () => {
      // Como la base: las semanas del presupuesto se cancelan (salen de la lista) y queda el estado.
      if (server.current.quote) server.current = { ...server.current, weeks: [], quote: { ...server.current.quote, status: "declined", summary: null } };
      return json(200, { already: false });
    },
    calls: [],
    fetch: (async (url, init) => {
      const route = new URL(url).pathname.replace("/functions/v1/client-link", "");
      const body = JSON.parse(String(init.body)) as Record<string, unknown>;
      server.calls.push({ route, body });
      if (route === "/view") return server.viewResponse ? server.viewResponse() : json(200, server.current);
      if (route === "/confirm") return server.confirm(body);
      if (route === "/changes") return server.changes(body);
      if (route === "/accept") return server.accept(body);
      if (route === "/decline") return server.decline(body);
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

/** El menú de una semana del estado (para mirar lo que cambió). */
function menuOf(reservation: Reservation, sessionId = SESSION_1) {
  return reservation.state.kind === "ready" ? reservation.state.view.weeks.find((item) => item.sessionId === sessionId)?.menu : undefined;
}

/** Una promesa que se resuelve a mano (para ordenar respuestas). */
function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolve: (value: T) => void = () => {};
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

/** Deja correr las promesas pendientes (las respuestas simuladas). */
async function flush(): Promise<void> {
  for (let i = 0; i < 20; i++) await Promise.resolve();
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
    const cases: Array<[Respond, unknown]> = [
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
});

describe("«Riprova»", () => {
  it("no pasa por «cargando»: el error queda con el botón esperando, y con la reserva el foco va al saludo", async () => {
    const server = fakeServer();
    server.viewResponse = () => json(503, { error: "unavailable" });
    const reservation = await loaded(server);
    expect(reservation.state.kind).toBe("error");
    server.viewResponse = null;
    const kinds: string[] = [];
    reservation.subscribe(() => kinds.push(`${reservation.state.kind}${reservation.retrying ? "+retrying" : ""}`));
    const result = reservation.retry();
    expect(reservation.retrying).toBe(true);
    expect(await result).toEqual({ focus: { kind: "greeting" }, announce: null });
    expect(reservation.state.kind).toBe("ready");
    expect(kinds).toEqual(["error+retrying", "ready"]);
  });

  it("si vuelve a fallar, el foco va al recuadro del error (que se lee con el mensaje nuevo)", async () => {
    const server = fakeServer();
    server.viewResponse = () => {
      throw new TypeError("offline");
    };
    const reservation = await loaded(server);
    server.viewResponse = () => json(429, {}, { "Retry-After": "600" });
    expect(await reservation.retry()).toEqual({ focus: { kind: "problem" }, announce: null });
    expect(reservation.state).toEqual({ kind: "error", message: { key: "reservation.errors.rateLimitedMinutes", params: { minutes: 10 } } });
    expect(reservation.retrying).toBe(false);
  });

  it("un segundo toque mientras reintenta no hace nada", async () => {
    const server = fakeServer();
    server.viewResponse = () => json(503, {});
    const reservation = await loaded(server);
    const first = reservation.retry();
    expect(await reservation.retry()).toEqual({ focus: null, announce: null });
    await first;
    expect(server.calls.filter((call) => call.route === "/view")).toHaveLength(2);
  });
});

describe("confirmar el menú", () => {
  it("manda el envío de esa semana, la marca confirmada con la hora de la función, avisa y vuelve a leer la reserva", async () => {
    const server = fakeServer();
    const reservation = await loaded(server);
    const result = reservation.confirm(SESSION_1);
    expect(reservation.ui(SESSION_1).busy).toBe("confirm");
    expect(await result).toEqual({ focus: { kind: "status", session: SESSION_1 }, announce: null });
    expect(server.calls.map((call) => call.route)).toEqual(["/view", "/confirm", "/view"]);
    expect(server.calls[1]?.body).toEqual({ token: TOKEN, sendId: SEND_1 });
    expect(menuOf(reservation)).toMatchObject({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" });
    expect(reservation.ui(SESSION_1)).toMatchObject({ busy: null, error: null, notice: { key: "reservation.notices.confirmed" } });
  });

  it("si no puede volver a leer la reserva, queda confirmada con lo que devolvió la función", async () => {
    const server = fakeServer();
    const reservation = await loaded(server);
    server.viewResponse = () => json(503, { error: "unavailable" });
    await reservation.confirm(SESSION_1);
    expect(reservation.state.kind).toBe("ready");
    expect(menuOf(reservation)).toMatchObject({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" });
  });

  it("ya estaba confirmado: lo dice", async () => {
    const server = fakeServer();
    server.confirm = () => json(200, { confirmedAt: "2027-02-25T20:00:00+00:00", already: true });
    const reservation = await loaded(server);
    await reservation.confirm(SESSION_1);
    expect(reservation.ui(SESSION_1).notice).toEqual({ key: "reservation.notices.alreadyConfirmed" });
  });

  it("hay un menú más nuevo: lo dice y muestra el nuevo", async () => {
    const server = fakeServer();
    server.confirm = () => json(409, { error: "menuOutdated" });
    const reservation = await loaded(server);
    server.current = view({ weeks: [week({ menu: menu({ sendId: SEND_NEW, sentAt: "2027-02-26T09:00:00+00:00" }) })] });
    expect(await reservation.confirm(SESSION_1)).toEqual({ focus: { kind: "status", session: SESSION_1 }, announce: null });
    expect(reservation.ui(SESSION_1).notice).toEqual({ key: "reservation.notices.menuOutdated" });
    expect(menuOf(reservation)?.sendId).toBe(SEND_NEW);
  });

  it("ya pidió cambios para ese menú: lo dice", async () => {
    const server = fakeServer();
    server.confirm = () => json(409, { error: "changesRequested" });
    const reservation = await loaded(server);
    await reservation.confirm(SESSION_1);
    expect(reservation.ui(SESSION_1).notice).toEqual({ key: "reservation.notices.changesAlreadyRequested" });
  });

  it("el envío ya no está: lo dice y vuelve a leer", async () => {
    const server = fakeServer();
    server.confirm = () => json(404, { error: "sendNotFound" });
    const reservation = await loaded(server);
    await reservation.confirm(SESSION_1);
    expect(reservation.ui(SESSION_1).notice).toEqual({ key: "reservation.notices.sendNotFound" });
    expect(server.calls.at(-1)?.route).toBe("/view");
  });

  it("la semana se canceló después del envío: aviso arriba con su fecha (al volver a leer ya no está) y el foco ahí", async () => {
    const server = fakeServer();
    server.confirm = () => json(409, { error: "sessionCancelled" });
    const reservation = await loaded(server);
    reservation.openChanges(SESSION_1);
    reservation.closeChanges(SESSION_1);
    server.current = view({ weeks: [week({ sessionId: SESSION_2, week: 1, weeks: 1, date: "2027-03-08", menu: null })] });
    expect(await reservation.confirm(SESSION_1)).toEqual({ focus: { kind: "notice" }, announce: null });
    expect(reservation.pageNotice).toEqual({ key: "reservation.notices.sessionCancelled", date: "2027-03-01" });
    expect(reservation.state.kind === "ready" && reservation.state.view.weeks.map((item) => item.sessionId)).toEqual([SESSION_2]);
    // Lo de esa semana se olvidó: queda como una semana sin nada.
    expect(reservation.ui(SESSION_1)).toEqual(reservation.ui(SESSION_3));
    // La próxima acción saca el aviso.
    server.current = view({ weeks: [week({ sessionId: SESSION_2, week: 1, weeks: 1 })] });
    server.confirm = () => json(200, { confirmedAt: "2027-02-26T10:00:00+00:00", already: false });
    await reservation.load();
    await reservation.confirm(SESSION_2);
    expect(reservation.pageNotice).toBeNull();
  });

  it("el link venció mientras tanto: la página lo dice", async () => {
    const server = fakeServer();
    server.confirm = () => json(404, { error: "linkNotFound" });
    const reservation = await loaded(server);
    expect(await reservation.confirm(SESSION_1)).toEqual({ focus: { kind: "problem" }, announce: null });
    expect(reservation.state).toEqual({ kind: "invalidLink" });
  });

  it("sin conexión, error o demasiados intentos: el error junto al botón, anunciado, y se puede reintentar", async () => {
    const cases: Array<[Respond, unknown]> = [
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
      expect(await reservation.confirm(SESSION_1)).toEqual({ focus: { kind: "confirm", session: SESSION_1 }, announce: message });
      expect(reservation.ui(SESSION_1)).toMatchObject({ busy: null, error: message });
      expect(menuOf(reservation)?.state).toBe("pending");
      // Reintento: limpia el error.
      server.confirm = () => json(200, { confirmedAt: "2027-02-26T10:00:00+00:00", already: false });
      await reservation.confirm(SESSION_1);
      expect(reservation.ui(SESSION_1).error).toBeNull();
    }
  });

  it("no hace nada con una respuesta en camino, ni con un menú que no está por confirmar", async () => {
    const server = fakeServer(
      view({
        weeks: [
          week({ sessionId: session(1), week: 1, weeks: 5 }),
          week({ sessionId: session(2), week: 2, weeks: 5, menu: menu({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" }) }),
          week({ sessionId: session(3), week: 3, weeks: 5, done: true }),
          week({ sessionId: session(4), week: 4, weeks: 5, menu: menu({ content: null }) }),
          week({ sessionId: session(5), week: 5, weeks: 5, menu: null }),
        ],
      }),
    );
    const reservation = await loaded(server);
    const first = reservation.confirm(session(1));
    const second = reservation.confirm(session(1));
    expect(await second).toEqual({ focus: null, announce: null });
    await first;
    for (const s of [session(2), session(3), session(4), session(5), session(9)]) {
      expect(await reservation.confirm(s), s).toEqual({ focus: null, announce: null });
    }
    expect(server.calls.filter((call) => call.route === "/confirm")).toHaveLength(1);
  });
});

describe("lecturas de la reserva en orden", () => {
  it("una lectura que llega tarde no pisa una más nueva: dos confirmaciones seguidas quedan confirmadas", async () => {
    const server = fakeServer(
      view({
        weeks: [
          week({ sessionId: SESSION_1, week: 1, weeks: 2 }),
          week({ sessionId: SESSION_2, week: 2, weeks: 2, date: "2027-03-08", menu: menu({ sendId: SEND_2 }) }),
        ],
      }),
    );
    const reservation = await loaded(server);
    // Las dos lecturas que siguen a las respuestas quedan esperando, cada una con la base de su momento.
    const reads: Array<{ resolve: (value: Response) => void; snapshot: ClientLinkView }> = [];
    server.viewResponse = () => {
      const wait = deferred<Response>();
      reads.push({ resolve: wait.resolve, snapshot: server.current });
      return wait.promise;
    };
    const first = reservation.confirm(SESSION_1);
    await flush();
    const second = reservation.confirm(SESSION_2);
    await flush();
    expect(reads).toHaveLength(2);
    // La lectura nueva (con las dos confirmadas) llega primero; la vieja (con la semana 2 por confirmar), después.
    reads[1]?.resolve(json(200, reads[1].snapshot));
    await second;
    reads[0]?.resolve(json(200, reads[0].snapshot));
    await first;
    expect(menuOf(reservation, SESSION_1)?.state).toBe("confirmed");
    expect(menuOf(reservation, SESSION_2)?.state).toBe("confirmed");
  });
});

describe("cada semana por su sesión", () => {
  it("si se cancela una semana anterior, el mensaje sigue en la misma semana (no en la que queda con su número) y sale para su envío", async () => {
    const weeks = [1, 2, 3, 4].map((k) =>
      week({ sessionId: session(k), week: k, weeks: 4, date: `2027-03-0${k}`, menu: menu({ sendId: `5e0d0000-0000-4000-8000-00000000000${k}` }) }),
    );
    const server = fakeServer(view({ weeks }));
    const reservation = await loaded(server);
    reservation.openChanges(session(3));
    reservation.setDraft(session(3), "Al posto del salmone, meglio pollo");
    // Evelyn cancela la semana 2: las demás se renumeran.
    server.current = view({ weeks: [weeks[0], weeks[2], weeks[3]].map((item, i) => ({ ...item!, week: i + 1, weeks: 3 })) });
    await reservation.confirm(session(1));
    expect(reservation.ui(session(3))).toMatchObject({ formOpen: true, draft: "Al posto del salmone, meglio pollo" });
    expect(reservation.ui(session(4)).formOpen).toBe(false);
    await reservation.submitChanges(session(3));
    expect(server.calls.find((call) => call.route === "/changes")?.body["sendId"]).toBe("5e0d0000-0000-4000-8000-000000000003");
  });

  it("lo de una semana que ya no está se olvida", async () => {
    const server = fakeServer();
    const reservation = await loaded(server);
    reservation.openChanges(SESSION_1);
    reservation.setDraft(SESSION_1, "Senza cipolla");
    server.current = view({ weeks: [week({ sessionId: SESSION_2, week: 1, weeks: 1, menu: menu({ sendId: SEND_2 }) })] });
    await reservation.load();
    expect(reservation.ui(SESSION_1)).toMatchObject({ formOpen: false, draft: "" });
  });

  it("si Evelyn manda otro menú mientras la clienta escribe, se le avisa y el mensaje queda (y sale para el nuevo)", async () => {
    const server = fakeServer(
      view({
        weeks: [
          week({ sessionId: SESSION_1, week: 1, weeks: 2 }),
          week({ sessionId: SESSION_2, week: 2, weeks: 2, menu: menu({ sendId: SEND_2 }) }),
        ],
      }),
    );
    const reservation = await loaded(server);
    reservation.openChanges(SESSION_2);
    reservation.setDraft(SESSION_2, "Senza cipolla");
    server.current = view({
      weeks: [
        week({ sessionId: SESSION_1, week: 1, weeks: 2 }),
        week({ sessionId: SESSION_2, week: 2, weeks: 2, menu: menu({ sendId: SEND_NEW }) }),
      ],
    });
    // Otra respuesta (en la semana 1) vuelve a leer la reserva: la semana 2 tiene otro envío.
    await reservation.confirm(SESSION_1);
    expect(reservation.ui(SESSION_2)).toMatchObject({ formOpen: true, draft: "Senza cipolla", notice: { key: "reservation.notices.menuOutdated" } });
    await reservation.submitChanges(SESSION_2);
    expect(server.calls.find((call) => call.route === "/changes")?.body["sendId"]).toBe(SEND_NEW);
  });
});

describe("pedir cambios", () => {
  it("abrir y cerrar el formulario (el mensaje queda guardado)", async () => {
    const reservation = await loaded();
    expect(reservation.openChanges(SESSION_1)).toEqual({ focus: { kind: "textarea", session: SESSION_1 }, announce: null });
    expect(reservation.ui(SESSION_1)).toMatchObject({ formOpen: true, draftFor: SEND_1 });
    reservation.setDraft(SESSION_1, "Senza cipolla");
    expect(reservation.closeChanges(SESSION_1)).toEqual({ focus: { kind: "askChanges", session: SESSION_1 }, announce: null });
    expect(reservation.ui(SESSION_1)).toMatchObject({ formOpen: false, draft: "Senza cipolla" });
    // Una semana sin menú por confirmar no abre nada.
    expect(reservation.openChanges(SESSION_2)).toEqual({ focus: null, announce: null });
  });

  it("vacío (o solo espacios y caracteres invisibles): error de vacío; el error se va al escribir algo válido", async () => {
    const server = fakeServer();
    const reservation = await loaded(server);
    reservation.openChanges(SESSION_1);
    reservation.setDraft(SESSION_1, `  \n ${String.fromCharCode(7)} `);
    expect(await reservation.submitChanges(SESSION_1)).toEqual({ focus: { kind: "textarea", session: SESSION_1 }, announce: null });
    expect(reservation.ui(SESSION_1).textError).toBe("empty");
    expect(server.calls.filter((call) => call.route === "/changes")).toEqual([]);
    expect(reservation.setDraft(SESSION_1, "  ")).toEqual({ textErrorCleared: false });
    expect(reservation.setDraft(SESSION_1, "Senza cipolla")).toEqual({ textErrorCleared: true });
    expect(reservation.ui(SESSION_1).textError).toBeNull();
  });

  it("demasiado largo (pegado sin pasar por el tope del campo): error de largo", async () => {
    const reservation = await loaded();
    reservation.openChanges(SESSION_1);
    reservation.setDraft(SESSION_1, "a".repeat(1001));
    await reservation.submitChanges(SESSION_1);
    expect(reservation.ui(SESSION_1).textError).toBe("tooLong");
  });

  it("manda el mensaje limpio (los saltos de Word a \\n), la semana queda con cambios pedidos y el formulario se cierra", async () => {
    const server = fakeServer();
    const reservation = await loaded(server);
    reservation.openChanges(SESSION_1);
    reservation.setDraft(SESSION_1, `  Senza cipolla,\r\ngrazie${String.fromCharCode(11)}davvero  `);
    expect(await reservation.submitChanges(SESSION_1)).toEqual({ focus: { kind: "status", session: SESSION_1 }, announce: null });
    expect(server.calls.find((call) => call.route === "/changes")?.body).toEqual({ token: TOKEN, sendId: SEND_1, text: "Senza cipolla,\ngrazie\ndavvero" });
    expect(menuOf(reservation)).toMatchObject({ state: "changesRequested", changesRequestedAt: "2027-02-26T11:00:00+00:00" });
    expect(reservation.ui(SESSION_1)).toMatchObject({ formOpen: false, draft: "", notice: { key: "reservation.notices.changesSent" } });
  });

  it("ya lo había confirmado: lo dice (los cambios, a Evelyn) y cierra el formulario", async () => {
    const server = fakeServer();
    server.changes = () => json(409, { error: "alreadyConfirmed" });
    const reservation = await loaded(server);
    reservation.openChanges(SESSION_1);
    reservation.setDraft(SESSION_1, "Senza cipolla");
    await reservation.submitChanges(SESSION_1);
    expect(reservation.ui(SESSION_1)).toMatchObject({ formOpen: false, notice: { key: "reservation.notices.alreadyConfirmedChanges" } });
  });

  it("hay un menú más nuevo: el mensaje a medio escribir no se pierde", async () => {
    const server = fakeServer();
    server.changes = () => json(409, { error: "menuOutdated" });
    const reservation = await loaded(server);
    reservation.openChanges(SESSION_1);
    reservation.setDraft(SESSION_1, "Senza cipolla");
    server.current = view({ weeks: [week({ menu: menu({ sendId: SEND_NEW }) })] });
    await reservation.submitChanges(SESSION_1);
    expect(reservation.ui(SESSION_1)).toMatchObject({ formOpen: true, draft: "Senza cipolla", notice: { key: "reservation.notices.menuOutdated" } });
    expect(menuOf(reservation)?.sendId).toBe(SEND_NEW);
  });

  it("la semana se canceló: el aviso arriba", async () => {
    const server = fakeServer();
    server.changes = () => json(409, { error: "sessionCancelled" });
    const reservation = await loaded(server);
    reservation.openChanges(SESSION_1);
    reservation.setDraft(SESSION_1, "Senza cipolla");
    expect(await reservation.submitChanges(SESSION_1)).toEqual({ focus: { kind: "notice" }, announce: null });
    expect(reservation.pageNotice).toEqual({ key: "reservation.notices.sessionCancelled", date: "2027-03-01" });
  });

  it("la función rechaza el texto: error en el campo (que se va al cambiarlo)", async () => {
    const server = fakeServer();
    server.changes = () => json(400, { error: "invalidText" });
    const reservation = await loaded(server);
    reservation.openChanges(SESSION_1);
    reservation.setDraft(SESSION_1, "Senza cipolla");
    expect(await reservation.submitChanges(SESSION_1)).toEqual({ focus: { kind: "textarea", session: SESSION_1 }, announce: null });
    expect(reservation.ui(SESSION_1)).toMatchObject({ textError: "invalid", formOpen: true });
    expect(reservation.setDraft(SESSION_1, "Senza cipolla, grazie")).toEqual({ textErrorCleared: true });
  });

  it("sin conexión: el error junto al botón de enviar, anunciado; el mensaje queda", async () => {
    const server = fakeServer();
    server.changes = () => {
      throw new TypeError("offline");
    };
    const reservation = await loaded(server);
    reservation.openChanges(SESSION_1);
    reservation.setDraft(SESSION_1, "Senza cipolla");
    expect(await reservation.submitChanges(SESSION_1)).toEqual({ focus: { kind: "submit", session: SESSION_1 }, announce: { key: "reservation.errors.network" } });
    expect(reservation.ui(SESSION_1)).toMatchObject({ formOpen: true, draft: "Senza cipolla", busy: null });
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

// ---------------------------------------------------------------------------
// El presupuesto (SPEC 5.8)
// ---------------------------------------------------------------------------

describe("quoteView y menuQuoteMode", () => {
  it("por aceptar: se acepta y se rechaza; con cambios pedidos, solo se rechaza", () => {
    expect(quoteViewOf(quoteView())).toMatchObject({ display: "pending", canAccept: true, canDecline: true, week: { sessionId: SESSION_1 } });
    expect(quoteViewOf(quoteView({}, { state: "changesRequested", changesRequestedAt: "2027-02-26T09:00:00+00:00" }))).toMatchObject({
      display: "changesRequested",
      canAccept: false,
      canDecline: true,
    });
    expect(quoteViewOf(view())).toBeNull();
  });

  it("cambiado, aceptado, rechazado, retirado o vencido: el estado, sin botones", () => {
    for (const status of ["changed", "accepted", "declined", "withdrawn", "expired"] as const) {
      const acceptedAt = status === "accepted" ? "2027-02-26T09:00:00+00:00" : null;
      expect(quoteViewOf(quoteView({ status, acceptedAt })), status).toMatchObject({ display: status, canAccept: false, canDecline: false });
    }
  });

  it("lo que no se ve no se contesta: sin el menú que lo lleva, sin resumen, una foto que no se lee o la semana fuera de la lista", () => {
    const cases: ClientLinkView[] = [
      quoteView({}, { content: null }),
      quoteView({ summary: null }),
      quoteView({ sendId: SEND_NEW }),
      quoteView({ sendId: null }),
      { ...quoteView(), weeks: [] },
    ];
    for (const value of cases) expect(quoteViewOf(value)).toMatchObject({ display: "unreadable", canAccept: false, canDecline: false });
  });

  it("el menú de un envío: sin presupuesto (none), con el presupuesto abierto (open) o con uno cerrado (closed)", () => {
    const open = quoteView();
    expect(menuQuoteMode(open, menu())).toBe("none");
    expect(menuQuoteMode(open, menu({ quoteId: QUOTE_ID }))).toBe("open");
    expect(menuQuoteMode(quoteView({ status: "changed" }), menu({ quoteId: QUOTE_ID }))).toBe("open");
    for (const status of ["accepted", "declined", "withdrawn", "expired"] as const) {
      expect(menuQuoteMode(quoteView({ status, acceptedAt: status === "accepted" ? "2027-02-26T09:00:00+00:00" : null }), menu({ quoteId: QUOTE_ID })), status).toBe("closed");
    }
    // Un presupuesto que la página no conoce: no se contesta.
    expect(menuQuoteMode(view(), menu({ quoteId: QUOTE_ID }))).toBe("closed");
  });
});

describe("aceptar el presupuesto", () => {
  it("manda el envío que lo lleva, lo marca aceptado (y el menú de la semana 1 confirmado), avisa y vuelve a leer la reserva", async () => {
    const server = fakeServer(quoteView());
    const reservation = await loaded(server);
    const result = reservation.acceptQuote();
    expect(reservation.quoteUi.busy).toBe("accept");
    expect(await result).toEqual({ focus: { kind: "quoteStatus" }, announce: null });
    expect(server.calls.map((call) => call.route)).toEqual(["/view", "/accept", "/view"]);
    expect(server.calls[1]?.body).toEqual({ token: TOKEN, sendId: SEND_1 });
    expect(reservation.state.kind === "ready" && reservation.state.view.quote).toMatchObject({ status: "accepted", acceptedAt: "2027-02-26T12:00:00+00:00" });
    expect(menuOf(reservation)).toMatchObject({ state: "confirmed", confirmedAt: "2027-02-26T12:00:00+00:00" });
    expect(reservation.quoteUi).toMatchObject({ busy: null, error: null, notice: { key: "reservation.quote.notices.accepted" } });
  });

  it("si no puede volver a leer la reserva, queda aceptado con lo que devolvió la función (también el menú)", async () => {
    const server = fakeServer(quoteView());
    const reservation = await loaded(server);
    server.viewResponse = () => json(503, { error: "unavailable" });
    await reservation.acceptQuote();
    expect(reservation.state.kind === "ready" && reservation.state.view.quote?.status).toBe("accepted");
    expect(menuOf(reservation)?.state).toBe("confirmed");
  });

  it("ya lo había aceptado: lo dice", async () => {
    const server = fakeServer(quoteView());
    server.accept = () => json(200, { acceptedAt: "2027-02-25T20:00:00+00:00", already: true });
    const reservation = await loaded(server);
    await reservation.acceptQuote();
    expect(reservation.quoteUi.notice).toEqual({ key: "reservation.quote.notices.alreadyAccepted" });
  });

  it("cada respuesta de la función con su aviso, y la reserva vuelta a leer", async () => {
    const cases: Array<[Response, string]> = [
      [json(409, { error: "menuOutdated" }), "reservation.quote.notices.outdated"],
      [json(409, { error: "changesRequested" }), "reservation.quote.notices.changesRequested"],
      [json(409, { error: "quoteChanged" }), "reservation.quote.notices.changed"],
      [json(409, { error: "sessionCancelled" }), "reservation.quote.notices.changed"],
      [json(409, { error: "quoteClosed", reason: "accepted" }), "reservation.quote.notices.closedAccepted"],
      [json(409, { error: "quoteClosed", reason: "declined" }), "reservation.quote.notices.closedDeclined"],
      [json(409, { error: "quoteClosed", reason: "withdrawn" }), "reservation.quote.notices.closedWithdrawn"],
      [json(409, { error: "quoteClosed", reason: "expired" }), "reservation.quote.notices.closedExpired"],
      [json(409, { error: "quoteClosed" }), "reservation.quote.notices.unavailable"],
      [json(409, { error: "quoteEmpty" }), "reservation.quote.notices.empty"],
      [json(409, { error: "notAQuote" }), "reservation.quote.notices.unavailable"],
      [json(404, { error: "sendNotFound" }), "reservation.quote.notices.unavailable"],
    ];
    for (const [response, key] of cases) {
      const server = fakeServer(quoteView());
      server.accept = () => response.clone();
      const reservation = await loaded(server);
      expect(await reservation.acceptQuote(), key).toEqual({ focus: { kind: "quoteStatus" }, announce: null });
      expect(reservation.quoteUi.notice, key).toEqual({ key });
      expect(reservation.quoteUi.error).toBeNull();
      expect(server.calls.at(-1)?.route, key).toBe("/view");
    }
  });

  it("sin conexión, error o demasiados intentos: el error junto al botón, anunciado, y se puede reintentar", async () => {
    const cases: Array<[Respond, unknown]> = [
      [
        () => {
          throw new TypeError("offline");
        },
        { key: "reservation.errors.network" },
      ],
      [() => json(500, { error: "server" }), { key: "reservation.errors.server" }],
      [() => json(429, { error: "rateLimited" }, { "Retry-After": "120" }), { key: "reservation.errors.rateLimitedMinutes", params: { minutes: 2 } }],
    ];
    for (const [respond, message] of cases) {
      const server = fakeServer(quoteView());
      server.accept = respond;
      const reservation = await loaded(server);
      expect(await reservation.acceptQuote()).toEqual({ focus: { kind: "quoteAccept" }, announce: message });
      expect(reservation.quoteUi).toMatchObject({ busy: null, error: message });
      expect(reservation.state.kind === "ready" && reservation.state.view.quote?.status).toBe("sent");
      server.accept = () => json(200, { acceptedAt: "2027-02-26T12:00:00+00:00", already: false });
      await reservation.acceptQuote();
      expect(reservation.quoteUi.error).toBeNull();
    }
  });

  it("el link venció mientras tanto: la página lo dice", async () => {
    const server = fakeServer(quoteView());
    server.accept = () => json(404, { error: "linkNotFound" });
    const reservation = await loaded(server);
    expect(await reservation.acceptQuote()).toEqual({ focus: { kind: "problem" }, announce: null });
    expect(reservation.state).toEqual({ kind: "invalidLink" });
  });

  it("no hace nada con una respuesta en camino, con cambios pedidos, cambiado, ya aceptado ni sin presupuesto", async () => {
    const server = fakeServer(quoteView());
    const reservation = await loaded(server);
    const first = reservation.acceptQuote();
    expect(await reservation.acceptQuote()).toEqual({ focus: null, announce: null });
    await first;
    for (const value of [
      quoteView({}, { state: "changesRequested", changesRequestedAt: "2027-02-26T09:00:00+00:00" }),
      quoteView({ status: "changed" }),
      quoteView({ status: "accepted", acceptedAt: "2027-02-26T09:00:00+00:00" }),
      view(),
    ]) {
      const other = fakeServer(value);
      const page = await loaded(other);
      expect(await page.acceptQuote()).toEqual({ focus: null, announce: null });
      expect(other.calls.filter((call) => call.route === "/accept")).toEqual([]);
    }
  });
});

describe("rechazar el presupuesto", () => {
  it("pide confirmar: el foco va a la pregunta; «No» la cierra y vuelve a «Rifiuto»; sin confirmar no se rechaza nada", async () => {
    const server = fakeServer(quoteView());
    const reservation = await loaded(server);
    expect(await reservation.declineQuote()).toEqual({ focus: null, announce: null });
    expect(reservation.openDecline()).toEqual({ focus: { kind: "quoteDeclineQuestion" }, announce: null });
    expect(reservation.quoteUi).toMatchObject({ declineOpen: true, declineFor: SEND_1 });
    expect(reservation.closeDecline()).toEqual({ focus: { kind: "quoteDecline" }, announce: null });
    expect(reservation.quoteUi.declineOpen).toBe(false);
    expect(server.calls.filter((call) => call.route === "/decline")).toEqual([]);
  });

  it("confirmado: manda el envío, lo marca rechazado, avisa y vuelve a leer (sus semanas ya no están)", async () => {
    const server = fakeServer(quoteView());
    const reservation = await loaded(server);
    reservation.openDecline();
    const result = reservation.declineQuote();
    expect(reservation.quoteUi.busy).toBe("decline");
    expect(await result).toEqual({ focus: { kind: "quoteStatus" }, announce: null });
    expect(server.calls.map((call) => call.route)).toEqual(["/view", "/decline", "/view"]);
    expect(server.calls[1]?.body).toEqual({ token: TOKEN, sendId: SEND_1 });
    expect(reservation.state.kind === "ready" && reservation.state.view.quote).toMatchObject({ status: "declined", summary: null });
    expect(reservation.state.kind === "ready" && reservation.state.view.weeks).toEqual([]);
    expect(reservation.quoteUi).toMatchObject({ declineOpen: false, busy: null, notice: { key: "reservation.quote.notices.declined" } });
  });

  it("se puede rechazar después de pedir cambios; ya rechazado, lo dice", async () => {
    const server = fakeServer(quoteView({}, { state: "changesRequested", changesRequestedAt: "2027-02-26T09:00:00+00:00" }));
    server.decline = () => json(200, { already: true });
    const reservation = await loaded(server);
    reservation.openDecline();
    await reservation.declineQuote();
    expect(reservation.quoteUi.notice).toEqual({ key: "reservation.quote.notices.alreadyDeclined" });
  });

  it("un error deja la confirmación abierta, con el error junto a «Sì, rifiuto» (que recibe el foco)", async () => {
    const server = fakeServer(quoteView());
    server.decline = () => {
      throw new TypeError("offline");
    };
    const reservation = await loaded(server);
    reservation.openDecline();
    expect(await reservation.declineQuote()).toEqual({ focus: { kind: "quoteDeclineConfirm" }, announce: { key: "reservation.errors.network" } });
    expect(reservation.quoteUi).toMatchObject({ declineOpen: true, error: { key: "reservation.errors.network" } });
  });

  it("si llega otra versión con la confirmación abierta, se cierra (no se rechaza lo que no vio) y se le avisa", async () => {
    const server = fakeServer(quoteView());
    const reservation = await loaded(server);
    reservation.openDecline();
    // Evelyn lo reenvía (versión 2, otro envío); otra lectura de la reserva lo trae.
    server.current = quoteView({ version: 2, sendId: SEND_NEW }, { sendId: SEND_NEW });
    await reservation.load();
    expect(reservation.quoteUi).toMatchObject({ declineOpen: false, declineFor: null, notice: { key: "reservation.quote.notices.outdated" } });
    expect(await reservation.declineQuote()).toEqual({ focus: null, announce: null });
  });

  it("otro presupuesto (otro id): lo del anterior se olvida", async () => {
    const server = fakeServer(quoteView());
    const reservation = await loaded(server);
    reservation.openDecline();
    server.current = quoteView({ id: "9a0e0000-0000-4000-8000-000000000002" }, { quoteId: "9a0e0000-0000-4000-8000-000000000002" });
    await reservation.load();
    expect(reservation.quoteUi).toEqual({ declineOpen: false, declineFor: null, busy: null, error: null, notice: null });
  });
});

describe("el menú que va con el presupuesto", () => {
  it("abierto: no se confirma solo (se acepta el presupuesto); los cambios sí, y entonces el presupuesto ya no se acepta", async () => {
    const server = fakeServer(quoteView());
    const reservation = await loaded(server);
    expect(await reservation.confirm(SESSION_1)).toEqual({ focus: null, announce: null });
    expect(server.calls.filter((call) => call.route === "/confirm")).toEqual([]);
    expect(reservation.openChanges(SESSION_1)).toEqual({ focus: { kind: "textarea", session: SESSION_1 }, announce: null });
    reservation.setDraft(SESSION_1, "Meglio alle 11");
    await reservation.submitChanges(SESSION_1);
    expect(server.calls.find((call) => call.route === "/changes")?.body).toEqual({ token: TOKEN, sendId: SEND_1, text: "Meglio alle 11" });
    const current = reservation.state.kind === "ready" ? quoteViewOf(reservation.state.view) : null;
    expect(current).toMatchObject({ display: "changesRequested", canAccept: false, canDecline: true });
  });

  it("cerrado (rechazado, retirado o vencido): ni se confirma ni se piden cambios", async () => {
    for (const status of ["declined", "withdrawn", "expired"] as const) {
      const server = fakeServer(quoteView({ status }));
      const reservation = await loaded(server);
      expect(await reservation.confirm(SESSION_1), status).toEqual({ focus: null, announce: null });
      expect(reservation.openChanges(SESSION_1), status).toEqual({ focus: null, announce: null });
      expect(server.calls.filter((call) => call.route !== "/view")).toEqual([]);
    }
  });

  it("si la función dice que va con el presupuesto (quotePending) o que el presupuesto se cerró (quoteClosed), lo avisa en la semana", async () => {
    for (const [response, key] of [
      [json(409, { error: "quotePending" }), "reservation.notices.quotePending"],
      [json(409, { error: "quoteClosed" }), "reservation.notices.quoteClosed"],
    ] as const) {
      const server = fakeServer();
      server.confirm = () => response.clone();
      const reservation = await loaded(server);
      expect(await reservation.confirm(SESSION_1)).toEqual({ focus: { kind: "status", session: SESSION_1 }, announce: null });
      expect(reservation.ui(SESSION_1).notice).toEqual({ key });
    }
  });

  it("aceptar el presupuesto saca el aviso de la página (una semana cancelada antes)", async () => {
    const server = fakeServer(quoteView());
    server.changes = () => json(409, { error: "sessionCancelled" });
    const reservation = await loaded(server);
    reservation.openChanges(SESSION_1);
    reservation.setDraft(SESSION_1, "x");
    server.current = quoteView();
    await reservation.submitChanges(SESSION_1);
    expect(reservation.pageNotice).not.toBeNull();
    await reservation.acceptQuote();
    expect(reservation.pageNotice).toBeNull();
    expect(server.calls.filter((call) => call.route === "/accept")).toHaveLength(1);
  });
});
