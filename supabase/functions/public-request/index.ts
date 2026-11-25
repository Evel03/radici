// Edge Function public-request: pedido del formulario público (POST), disponibilidad por día del
// calendario (GET …/availability) y platos de la pestaña «Menù» (GET …/menu)
// (docs/contracts/public-request.md §2, §11 y §12).
// Este archivo solo conecta lo real (Deno, supabase-js con la clave secreta, EdgeRuntime);
// la lógica y sus tests están en handler.ts.
//
// Pública: verify_jwt = false en supabase/config.toml. Las claves nuevas (sb_publishable_…,
// sb_secret_…) no son JWT y el chequeo de la plataforma no autentica a nadie: la protección es
// Turnstile + límite por IP + validación (las lecturas de disponibilidad y del menù: límite por IP propio).
import { createClient } from "npm:@supabase/supabase-js@2.117.2";
import { menuDishesFromRpc, photoOrigin } from "../_shared/menu.ts";
import {
  CHEF_SETTINGS_COLUMNS,
  StoreError,
  availableDatesFromRpc,
  chefFromRow,
  configWarnings,
  consoleLogger,
  createPublicRequestHandler,
  missingRequiredConfig,
  readConfig,
  resolveServiceKey,
  safeDbMessage,
  submitResultFromRpc,
  type PublicRequestStore,
} from "./handler.ts";

const env = (name: string): string | undefined => Deno.env.get(name);
const config = readConfig(env);

// Un aviso por arranque, solo con nombres de variables.
const missing = missingRequiredConfig(config);
if (missing.length > 0) consoleLogger("error", "config_missing", { missing });
if (config.invalid.length > 0) consoleLogger("error", "config_invalid", { invalid: config.invalid });
else if (!config.chefId) consoleLogger("info", "chef_id_auto");
const incomplete = configWarnings(config);
if (incomplete.length > 0) consoleLogger("warn", "config_incomplete", { missing: incomplete });

interface PostgrestLikeError {
  code?: string;
  message?: string;
}

/** Nunca se pasan `details` ni `hint`: pueden traer la fila con datos personales. */
function storeError(op: string, error: PostgrestLikeError): StoreError {
  return new StoreError(op, error.code ?? null, safeDbMessage(error.message));
}

function createStore(): PublicRequestStore {
  const supabaseUrl = env("SUPABASE_URL");
  const serviceKey = resolveServiceKey(env);
  if (!supabaseUrl || !serviceKey) {
    consoleLogger("error", "config_missing", { missing: [supabaseUrl ? "" : "SUPABASE_URL", serviceKey ? "" : "SUPABASE_SECRET_KEYS"].filter(Boolean) });
    const fail = (op: string) => Promise.reject(new StoreError(op, null, "supabase_not_configured"));
    return {
      hitRateLimit: () => fail("rate_limit"),
      resolveDefaultChef: () => fail("resolve_chef"),
      loadChef: () => fail("load_chef"),
      submit: () => fail("submit"),
      markChefNotificationSent: () => fail("mark_sent"),
      freeDays: () => fail("free_days"),
      publicMenu: () => fail("public_menu"),
    };
  }

  // Las fotos de los platos son URL públicas de Storage en este origen. Con supabase functions serve,
  // SUPABASE_URL es la dirección interna de Docker (http://kong:8000), que el navegador no abre: sin fotos.
  const storageOrigin = photoOrigin(supabaseUrl);
  if (!storageOrigin) consoleLogger("info", "menu_photos_off");

  // Clave secreta (sin RLS): solo para las funciones del pedido, la notificación, la disponibilidad y el menù.
  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  return {
    async hitRateLimit(ipHash, maxPerHour, maxPerDay) {
      const { data, error } = await supabase.rpc("hit_public_request_rate", {
        p_ip_hash: ipHash,
        p_max_hour: maxPerHour,
        p_max_day: maxPerDay,
      });
      if (error) throw storeError("rate_limit", error);
      return data === true;
    },

    async resolveDefaultChef() {
      // Con dos filas ya se sabe que no hay una sola: no hace falta contar todas.
      const { data, error } = await supabase.from("chefs").select("id").order("id").limit(2);
      if (error) throw storeError("resolve_chef", error);
      const rows = (data ?? []) as Array<{ id?: unknown }>;
      if (rows.length === 0) return { ok: false, reason: "no_chef" };
      if (rows.length > 1) return { ok: false, reason: "multiple_chefs" };
      const id = rows[0]?.id;
      if (typeof id !== "string") throw new StoreError("resolve_chef", null, "unexpected_result");
      return { ok: true, chefId: id };
    },

    async loadChef(chefId) {
      const { data, error } = await supabase
        .from("chef_settings")
        .select(CHEF_SETTINGS_COLUMNS)
        .eq("chef_id", chefId)
        .maybeSingle();
      if (error) throw storeError("load_chef", error);
      return data ? chefFromRow(data as Record<string, unknown>) : null;
    },

    async submit(params) {
      const { data, error } = await supabase.rpc("submit_public_request", { p: params });
      if (error) throw storeError("submit", error);
      const result = submitResultFromRpc(data);
      if (!result) throw new StoreError("submit", null, "unexpected_result");
      return result;
    },

    async markChefNotificationSent(requestId) {
      const { error } = await supabase
        .from("notifications")
        .update({ sent_at: new Date().toISOString() })
        .eq("kind", "new_request")
        .eq("payload->>request_id", requestId)
        .is("sent_at", null);
      if (error) throw storeError("mark_sent", error);
    },

    async freeDays(chefId, cookMinutes, fromDate, days) {
      const { data, error } = await supabase.rpc("get_free_days", {
        p_chef_id: chefId,
        p_cook_minutes: cookMinutes,
        p_from_date: fromDate,
        p_days: days,
      });
      if (error) throw storeError("free_days", error);
      const dates = availableDatesFromRpc(data);
      if (!dates) throw new StoreError("free_days", null, "unexpected_result");
      return dates;
    },

    async publicMenu(chefId) {
      const { data, error } = await supabase.rpc("get_public_menu", { p_chef_id: chefId });
      if (error) throw storeError("public_menu", error);
      // Se arma de nuevo plato por plato: nada que no sea del contrato (cantidades, unidades, secciones, notas) sale a la web.
      // La foto: las URL públicas de sus archivos (photoId de la base, este origen y la cocinera).
      const result = menuDishesFromRpc(data, { origin: storageOrigin, chefId });
      if (!result) throw new StoreError("public_menu", null, "unexpected_result");
      // Solo la cantidad: nunca los nombres ni los ids.
      if (result.skipped > 0) consoleLogger("warn", "public_menu_dish_skipped", { count: result.skipped });
      return result.dishes;
    },
  };
}

// EdgeRuntime.waitUntil deja terminar los envíos después de responder (sin él, la tarea igual corre).
const edgeRuntime = (globalThis as { EdgeRuntime?: { waitUntil(task: Promise<unknown>): void } }).EdgeRuntime;

const handler = createPublicRequestHandler({
  config,
  store: createStore(),
  fetch: (input, init) => fetch(input, init),
  now: () => new Date(),
  waitUntil: (task) => edgeRuntime?.waitUntil(task),
  log: consoleLogger,
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  newId: () => crypto.randomUUID(),
});

Deno.serve(handler);
