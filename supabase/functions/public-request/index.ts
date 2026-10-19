// Edge Function public-request: pedido del formulario público (docs/contracts/public-request.md).
// Este archivo solo conecta lo real (Deno, supabase-js con la clave secreta, EdgeRuntime);
// la lógica y sus tests están en handler.ts.
//
// Pública: verify_jwt = false en supabase/config.toml. Las claves nuevas (sb_publishable_…,
// sb_secret_…) no son JWT y el chequeo de la plataforma no autentica a nadie: la protección es
// Turnstile + límite por IP + validación.
import { createClient } from "npm:@supabase/supabase-js@2.117.2";
import {
  StoreError,
  chefFromRow,
  configWarnings,
  consoleLogger,
  createPublicRequestHandler,
  missingRequiredConfig,
  readConfig,
  resolveServiceKey,
  safeDbMessage,
  type PublicRequestStore,
} from "./handler.ts";

const env = (name: string): string | undefined => Deno.env.get(name);
const config = readConfig(env);

// Un aviso por arranque, solo con nombres de variables.
const missing = missingRequiredConfig(config);
if (missing.length > 0) consoleLogger("error", "config_missing", { missing });
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
      loadChef: () => fail("load_chef"),
      submit: () => fail("submit"),
      markChefNotificationSent: () => fail("mark_sent"),
    };
  }

  // Clave secreta (sin RLS): solo para las funciones del pedido y la notificación.
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

    async loadChef(chefId) {
      const { data, error } = await supabase
        .from("chef_settings")
        .select(
          "hourly_rate_cents, travel_fee_cents, adult_portion_cents, kid_portion_cents, preauth_buffer_pct, min_cook_minutes, chefs(display_name)",
        )
        .eq("chef_id", chefId)
        .maybeSingle();
      if (error) throw storeError("load_chef", error);
      return data ? chefFromRow(data as Record<string, unknown>) : null;
    },

    async submit(params) {
      const { data, error } = await supabase.rpc("submit_public_request", { p: params });
      if (error) throw storeError("submit", error);
      if (typeof data !== "string") throw new StoreError("submit", null, "unexpected_result");
      return data;
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
