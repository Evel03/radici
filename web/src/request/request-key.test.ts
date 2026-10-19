import { afterEach, describe, expect, it, vi } from "vitest";
import { isUuid } from "../../../supabase/functions/_shared/public_request.ts";
import { TEST_TOKEN, TODAY, validRequest } from "./fixtures.ts";
import { parsePublicRequest, type PublicRequestPayload, type RequestData } from "./model.ts";
import { buildPayload } from "./payload.ts";
import { createRequestKeys, doneViewFor, newRequestKey, type AttemptOutcome } from "./request-key.ts";
import { sendPublicRequest } from "./submit.ts";

afterEach(() => {
  vi.restoreAllMocks();
});

/** Versión 4 y variante RFC 9562 (8, 9, a o b). */
function isUuidV4(key: string): boolean {
  return isUuid(key) && key === key.toLowerCase() && key[14] === "4" && "89ab".includes(key[19] ?? "");
}

describe("newRequestKey", () => {
  it("con el crypto del entorno: UUID v4 en minúsculas que el contrato acepta", () => {
    expect(isUuidV4(newRequestKey())).toBe(true);
  });

  it("usa crypto.randomUUID si existe", () => {
    expect(newRequestKey({ randomUUID: () => "6F1C7C1E-9F7E-4A53-9A77-2F5D2F0F7A10" })).toBe("6f1c7c1e-9f7e-4a53-9a77-2f5d2f0f7a10");
  });

  it("sin randomUUID (http en la red local, Safari 14): crypto.getRandomValues con versión y variante", () => {
    const fill = (value: number) => ({
      getRandomValues: (array: Uint8Array<ArrayBuffer>) => array.fill(value),
    });
    expect(newRequestKey(fill(0xff))).toBe("ffffffff-ffff-4fff-bfff-ffffffffffff");
    expect(newRequestKey(fill(0x00))).toBe("00000000-0000-4000-8000-000000000000");
    const real = { getRandomValues: (array: Uint8Array<ArrayBuffer>) => globalThis.crypto.getRandomValues(array) };
    const keys = new Set(Array.from({ length: 1000 }, () => newRequestKey(real)));
    expect(keys.size).toBe(1000);
    expect([...keys].every(isUuidV4)).toBe(true);
  });

  it("sin crypto: Math.random (sigue siendo un UUID v4 válido)", () => {
    vi.spyOn(Math, "random").mockReturnValue(0.999);
    expect(newRequestKey(null)).toBe("ffffffff-ffff-4fff-bfff-ffffffffffff");
    vi.spyOn(Math, "random").mockReturnValue(0);
    expect(newRequestKey({})).toBe("00000000-0000-4000-8000-000000000000");
  });
});

describe("createRequestKeys: cuándo se reutiliza y cuándo cambia la clave", () => {
  const A = JSON.stringify(validRequest());
  const B = JSON.stringify(validRequest({ notes: "citofono rotto" }));

  function tracker() {
    let n = 0;
    const generate = vi.fn(() => `key-${++n}`);
    return { keys: createRequestKeys(generate), generate };
  }

  it("una sola clave hasta que haya un resultado", () => {
    const { keys, generate } = tracker();
    expect(keys.current()).toBe("key-1");
    expect(keys.current()).toBe("key-1");
    expect(generate).toHaveBeenCalledTimes(1);
  });

  it("reintentos después de red, 5xx o 429: la misma clave, aunque el formulario cambie", () => {
    const { keys } = tracker();
    const first = keys.current();
    for (const outcome of ["network", "server", "rateLimited"] as const satisfies readonly AttemptOutcome[]) {
      keys.settle(outcome, A);
      keys.edited(B);
      expect(keys.current(), outcome).toBe(first);
    }
  });

  it("después de un pedido guardado, el próximo envío lleva clave nueva", () => {
    const { keys } = tracker();
    keys.current();
    keys.settle("created", A);
    expect(keys.current()).toBe("key-2");
  });

  for (const outcome of ["invalid", "turnstile", "tooLarge"] as const satisfies readonly AttemptOutcome[]) {
    it(`rechazo seguro (${outcome}): misma clave si los datos no cambian; nueva si el cliente los edita`, () => {
      const { keys } = tracker();
      keys.current();
      keys.settle(outcome, A);
      keys.edited(A); // un change por mover el foco no es una edición
      expect(keys.current()).toBe("key-1");
      keys.edited(B);
      expect(keys.current()).toBe("key-2");
      keys.edited(A); // ya es otro pedido: no vuelve a cambiar
      expect(keys.current()).toBe("key-2");
    });
  }

  it("un rechazo después de un error de red no cambia la clave: el primer envío pudo quedar guardado", () => {
    const { keys } = tracker();
    keys.current();
    keys.settle("network", A);
    keys.settle("invalid", A);
    keys.edited(B);
    expect(keys.current()).toBe("key-1");
    keys.settle("created", B);
    expect(keys.current()).toBe("key-2");
  });
});

describe("replayed: qué tiene guardado el servidor cuando contesta duplicate (contrato §2)", () => {
  const A = JSON.stringify(validRequest());
  const B = JSON.stringify(validRequest({ email: "giulia.corretta@example.test", adults: 4 }));
  const keysFor = () => createRequestKeys(() => "key-1");

  it("el mismo formulario que el envío que quedó sin respuesta: es lo que se acaba de mandar", () => {
    const keys = keysFor();
    keys.current();
    keys.settle("network", A);
    expect(keys.replayed(A)).toEqual({ kind: "sent" });
  });

  it("el formulario cambió después del error de red: lo guardado es lo del envío anterior", () => {
    const keys = keysFor();
    keys.current();
    keys.settle("network", A);
    keys.settle("network", A);
    keys.edited(B);
    keys.settle("rateLimited", B); // un 429 no guarda nada
    expect(keys.replayed(B)).toEqual({ kind: "earlier", formSnapshot: A });
  });

  it("un rechazo seguro (400, 403, 413) no cuenta como envío que pudo quedar guardado", () => {
    const keys = keysFor();
    keys.current();
    keys.settle("server", A);
    keys.settle("invalid", B);
    keys.settle("turnstile", B);
    expect(keys.replayed(B)).toEqual({ kind: "earlier", formSnapshot: A });
  });

  it("dos envíos sin respuesta con datos distintos: no se sabe cuál llegó", () => {
    const keys = keysFor();
    keys.current();
    keys.settle("server", A);
    keys.settle("network", B);
    expect(keys.replayed(B)).toEqual({ kind: "unknown" });
    expect(keys.replayed(A)).toEqual({ kind: "unknown" });
  });

  it("sin un envío anterior sin respuesta (no debería pasar): desconocido, nunca 'lo que se mandó'", () => {
    const keys = keysFor();
    keys.current();
    expect(keys.replayed(A)).toEqual({ kind: "unknown" });
  });

  it("después de un pedido guardado se olvidan los envíos anteriores", () => {
    const keys = keysFor();
    keys.current();
    keys.settle("network", A);
    keys.settle("created", A);
    expect(keys.replayed(B)).toEqual({ kind: "unknown" });
  });
});

describe("doneViewFor: qué muestra la pantalla de gracias", () => {
  const sent = validRequest({ email: "giulia.corretta@example.test", adults: 4 });
  const earlier = validRequest({ email: "giulai@example.test", adults: 2 });

  it("pedido nuevo o reintento sin cambios: lo que se mandó, sin aviso", () => {
    expect(doneViewFor({ kind: "sent" }, sent)).toEqual({ data: sent, replay: null });
  });

  it("reintento con cambios: los datos (y el email) del envío que se guardó, con aviso", () => {
    expect(doneViewFor({ kind: "earlier", formSnapshot: JSON.stringify(earlier) }, sent)).toEqual({ data: earlier, replay: "earlier" });
  });

  it("no se sabe qué se guardó: sin resumen ni email, con aviso", () => {
    expect(doneViewFor({ kind: "unknown" }, sent)).toEqual({ data: null, replay: "unknown" });
  });

  it("un snapshot ilegible cuenta como desconocido", () => {
    expect(doneViewFor({ kind: "earlier", formSnapshot: "{roto" }, sent)).toEqual({ data: null, replay: "unknown" });
  });
});

describe("la clave en el payload", () => {
  it("viaja en el JSON y el servidor la acepta (normalizada a minúsculas)", () => {
    const key = newRequestKey();
    const payload = buildPayload(validRequest(), { locale: "it", turnstileToken: TEST_TOKEN, requestKey: key });
    expect(payload.requestKey).toBe(key);
    const result = parsePublicRequest(JSON.parse(JSON.stringify(payload)), { today: TODAY });
    expect(result.ok && result.value.requestKey).toBe(key);
  });

  it("sin clave (validación local) el payload no la incluye", () => {
    expect(buildPayload(validRequest(), { locale: "it", turnstileToken: "" })).not.toHaveProperty("requestKey");
  });
});

describe("secuencia de la página (richiesta.ts): reintentos con la misma clave", () => {
  const URL_ = "https://abcdefgh.supabase.co/functions/v1/public-request";
  const CREATED = { requestId: "6f1c7c1e-9f7e-4a53-9a77-2f5d2f0f7a10" };

  /** fetch simulado que contesta en orden y guarda las claves recibidas. */
  function scripted(responses: Array<() => Response>) {
    const received: Array<string | undefined> = [];
    const fetchFn = vi.fn(async (_url: string, init: RequestInit) => {
      received.push((JSON.parse(String(init.body)) as PublicRequestPayload).requestKey);
      const next = responses.shift();
      if (!next) throw new Error("sin más respuestas");
      return next();
    });
    return { fetchFn, received };
  }

  /** Lo mismo que submitRequest en la página: reconcilia, arma el payload con la clave, envía y anota el resultado. */
  async function submit(keys: ReturnType<typeof createRequestKeys>, data: RequestData, fetchFn: ReturnType<typeof scripted>["fetchFn"]) {
    const snapshot = JSON.stringify(data);
    keys.edited(snapshot);
    const payload = buildPayload(data, { locale: "it", turnstileToken: TEST_TOKEN, requestKey: keys.current() });
    const outcome = await sendPublicRequest(URL_, payload, { fetch: fetchFn });
    keys.settle(outcome.kind, snapshot);
    return outcome.kind;
  }

  it("red caída, 503 y 429 (aun editando la nota): siempre la misma clave hasta el 201; después, otra", async () => {
    const { fetchFn, received } = scripted([
      () => {
        throw new TypeError("Failed to fetch");
      },
      () => Response.json({ error: "server" }, { status: 503 }),
      () => Response.json({ error: "rateLimited" }, { status: 429, headers: { "Retry-After": "60" } }),
      () => Response.json(CREATED, { status: 201 }),
      () => Response.json(CREATED, { status: 201 }),
    ]);
    const keys = createRequestKeys();
    const kinds = [
      await submit(keys, validRequest(), fetchFn),
      await submit(keys, validRequest(), fetchFn),
      await submit(keys, validRequest({ notes: "suonare due volte" }), fetchFn),
      await submit(keys, validRequest({ notes: "suonare due volte" }), fetchFn),
      await submit(keys, validRequest(), fetchFn),
    ];
    expect(kinds).toEqual(["network", "server", "rateLimited", "created", "created"]);
    const [first, ...rest] = received;
    expect(isUuidV4(first ?? "")).toBe(true);
    expect(rest.slice(0, 3)).toEqual([first, first, first]);
    expect(rest[3]).not.toBe(first);
    expect(isUuidV4(rest[3] ?? "")).toBe(true);
  });

  it("red caída, el cliente corrige el email y reintenta: misma clave, duplicate y la página muestra lo del primer envío", async () => {
    const { fetchFn, received } = scripted([
      () => {
        throw new TypeError("Failed to fetch");
      },
      () => Response.json({ ...CREATED, duplicate: true }, { status: 201 }),
    ]);
    const keys = createRequestKeys();
    const typo = validRequest({ email: "giulai@example.test", adults: 2 });
    const fixed = validRequest({ email: "giulia@example.test", adults: 4 });
    expect(await submit(keys, typo, fetchFn)).toBe("network");

    // Lo mismo que submitRequest en la página: replayed antes de settle.
    const snapshot = JSON.stringify(fixed);
    keys.edited(snapshot);
    const payload = buildPayload(fixed, { locale: "it", turnstileToken: TEST_TOKEN, requestKey: keys.current() });
    const outcome = await sendPublicRequest(URL_, payload, { fetch: fetchFn });
    expect(outcome).toMatchObject({ kind: "created", duplicate: true });
    const view = doneViewFor(keys.replayed(snapshot), fixed);
    keys.settle(outcome.kind, snapshot);

    expect(received[1]).toBe(received[0]);
    expect(view).toEqual({ data: typo, replay: "earlier" });
    expect(view.data?.email).toBe("giulai@example.test");
  });

  it("400 y el cliente corrige el teléfono: el envío corregido lleva clave nueva", async () => {
    const { fetchFn, received } = scripted([
      () => Response.json({ errors: { phone: "invalid" } }, { status: 400 }),
      () => Response.json(CREATED, { status: 201 }),
    ]);
    const keys = createRequestKeys();
    expect(await submit(keys, validRequest({ phone: "123" }), fetchFn)).toBe("invalid");
    expect(await submit(keys, validRequest(), fetchFn)).toBe("created");
    expect(received[0]).not.toBe(received[1]);
  });
});
