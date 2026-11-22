// Edge Function client-link: el link de la clienta (docs/contracts/client-link.md, SPEC 5.8). La página
// /prenotazione/ de la web muestra la reserva con el menú que Evelyn mandó de cada semana, y la clienta lo
// confirma o pide cambios, con las funciones SQL client_link_* (solo service_role).
// Este archivo solo conecta lo real (Deno, supabase-js con la clave secreta, EdgeRuntime); la lógica y sus
// tests están en handler.ts.
//
// Pública: verify_jwt = false en supabase/config.toml ([functions.client-link]). La llave es el token del link
// (la base guarda solo su hash); además, límite por IP y validación.
import { createClient } from "npm:@supabase/supabase-js@2.117.2";
import {
  StoreError,
  clientLinkConfigWarnings,
  consoleLogger,
  createClientLinkHandler,
  readClientLinkConfig,
  resolveServiceKey,
  storeErrorFrom,
  type ClientLinkStore,
} from "./handler.ts";

const env = (name: string): string | undefined => Deno.env.get(name);
const config = readClientLinkConfig(env);

// Un aviso por arranque, solo con nombres de variables.
if (config.missing.length > 0) consoleLogger("error", "config_missing", { missing: config.missing });
const incomplete = clientLinkConfigWarnings(config);
if (incomplete.length > 0) consoleLogger("warn", "config_incomplete", { missing: incomplete });
// Con supabase functions serve, SUPABASE_URL es la dirección interna de Docker: los platos salen sin foto.
if (!config.storageOrigin) consoleLogger("info", "menu_photos_off");

function createStore(): ClientLinkStore {
  const supabaseUrl = env("SUPABASE_URL")?.trim();
  const serviceKey = resolveServiceKey(env);
  if (!supabaseUrl || !serviceKey) {
    // El handler responde 500 antes de llegar acá (config.missing).
    const fail = (op: string) => Promise.reject(new StoreError(op, null, "supabase_not_configured"));
    return {
      hitRateLimit: () => fail("rate_limit"),
      view: () => fail("view"),
      confirmMenu: () => fail("confirm_menu"),
      requestChanges: () => fail("request_changes"),
    };
  }

  // Clave secreta (sin RLS): solo para el límite por IP y las funciones client_link_*, siempre con el hash del token.
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
      if (error) throw storeErrorFrom("rate_limit", error);
      return data === true;
    },

    async view(tokenHash) {
      const { data, error } = await supabase.rpc("client_link_view", { p_token_hash: tokenHash });
      if (error) throw storeErrorFrom("view", error);
      return data;
    },

    async confirmMenu(tokenHash, sendId) {
      const { data, error } = await supabase.rpc("client_link_confirm_menu", { p_token_hash: tokenHash, p_send_id: sendId });
      if (error) throw storeErrorFrom("confirm_menu", error);
      return data;
    },

    async requestChanges(tokenHash, sendId, text) {
      const { data, error } = await supabase.rpc("client_link_request_changes", {
        p_token_hash: tokenHash,
        p_send_id: sendId,
        p_text: text,
      });
      if (error) throw storeErrorFrom("request_changes", error);
      return data;
    },
  };
}

// EdgeRuntime.waitUntil deja terminar el aviso a Evelyn después de responder (sin él, la tarea igual corre).
const edgeRuntime = (globalThis as { EdgeRuntime?: { waitUntil(task: Promise<unknown>): void } }).EdgeRuntime;

const handler = createClientLinkHandler({
  config,
  store: createStore(),
  fetch: (input, init) => fetch(input, init),
  waitUntil: (task) => edgeRuntime?.waitUntil(task),
  log: consoleLogger,
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
});

Deno.serve(handler);
