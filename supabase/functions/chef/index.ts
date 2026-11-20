// Edge Function chef: el área de Evelyn (docs/contracts/chef-api.md). Reservas de 1 a 8 semanas,
// mover y cancelar sesiones, con las funciones SQL chef_* (solo service_role), y la traducción de los
// platos con Claude (POST /translate).
// Este archivo solo conecta lo real (Deno, supabase-js con la clave secreta y el traductor); la
// lógica y sus tests están en handler.ts y translation.ts.
//
// Con JWT: verify_jwt = true en supabase/config.toml ([functions.chef]). Ese chequeo de la
// plataforma también deja pasar las claves de API, así que la función valida además el token con
// Auth (auth.getUser) y busca la cocina del usuario con public.chef_id_for_user (la de la que es
// dueña o colaborador: la misma regla que las políticas) antes de tocar nada. CORS: ALLOWED_ORIGINS,
// la misma variable que public-request.
import { createClient } from "npm:@supabase/supabase-js@2.117.2";
import { StoreError, consoleLogger, resolveServiceKey } from "../_shared/edge.ts";
import {
  authFailureKind,
  chefConfigWarnings,
  createChefHandler,
  readChefConfig,
  storeErrorFrom,
  type ChefStore,
} from "./handler.ts";
// claude_translator.ts (el SDK de Anthropic) no se importa acá: se carga en la primera traducción
// (createTranslator), así una falla al cargarlo nunca tumba /bookings ni /sessions/*.
import { fakeTranslator, lazyTranslator, type Translator } from "./translation.ts";

const env = (name: string): string | undefined => Deno.env.get(name);
const config = readChefConfig(env);

// Un aviso por arranque, solo con nombres de variables.
if (config.missing.length > 0) consoleLogger("error", "config_missing", { missing: config.missing });
const incomplete = chefConfigWarnings(config);
if (incomplete.length > 0) consoleLogger("warn", "config_incomplete", { missing: incomplete });
if (config.translation === "fake") consoleLogger("warn", "translate_fake");
// TRANSLATE_TRANSPORT=fake fuera de un Supabase local: se ignora (la traducción queda apagada).
if (config.translationFakeIgnored) consoleLogger("error", "translate_fake_ignored");

function createStore(): ChefStore {
  const supabaseUrl = env("SUPABASE_URL")?.trim();
  const serviceKey = resolveServiceKey(env);
  if (!supabaseUrl || !serviceKey) {
    // El handler responde 500 antes de llegar acá (config.missing).
    const fail = (op: string) => Promise.reject(new StoreError(op, null, "supabase_not_configured"));
    return {
      userIdFromToken: () => fail("get_user"),
      chefIdForUser: () => fail("load_chef"),
      createBooking: () => fail("create_booking"),
      moveSession: () => fail("move_session"),
      cancelSessions: () => fail("cancel_sessions"),
      hitRateLimit: () => fail("rate_limit"),
    };
  }

  // Clave secreta (sin RLS): solo para validar el token, buscar la cocina del usuario y llamar a las
  // chef_*, siempre con el chef_id que sale del token.
  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  return {
    async userIdFromToken(token) {
      // Auth valida la firma, el vencimiento y que la sesión siga abierta.
      const { data, error } = await supabase.auth.getUser(token);
      if (error) {
        if (authFailureKind(error.status) === "invalid") return null;
        throw new StoreError("get_user", error.status ? String(error.status) : null, null);
      }
      return data.user?.id ?? null;
    },

    async chefIdForUser(userId) {
      // La cocina de la que es dueña (chefs.profile_id) o colaborador (chef_members), o null: el
      // handler la interpreta (chefIdFromRpc).
      const { data, error } = await supabase.rpc("chef_id_for_user", { p_user_id: userId });
      if (error) throw storeErrorFrom("load_chef", error);
      return data;
    },

    async createBooking(params) {
      const { data, error } = await supabase.rpc("chef_create_booking", params);
      if (error) throw storeErrorFrom("create_booking", error);
      return data;
    },

    async moveSession(params) {
      const { data, error } = await supabase.rpc("chef_move_session", params);
      if (error) throw storeErrorFrom("move_session", error);
      return data;
    },

    async cancelSessions(params) {
      const { data, error } = await supabase.rpc("chef_cancel_sessions", params);
      if (error) throw storeErrorFrom("cancel_sessions", error);
      return data;
    },

    async hitRateLimit(key, maxPerHour, maxPerDay) {
      // La misma función que el límite del formulario, con la clave de la cocina (translateRateKey).
      const { data, error } = await supabase.rpc("hit_public_request_rate", {
        p_ip_hash: key,
        p_max_hour: maxPerHour,
        p_max_day: maxPerDay,
      });
      if (error) throw storeErrorFrom("rate_limit", error);
      return data === true;
    },
  };
}

/**
 * Claude con ANTHROPIC_API_KEY (secreto de las funciones, lo carga deploy-supabase.yml); el de mentira
 * con TRANSLATE_TRANSPORT=fake (solo con un Supabase local, desarrollo, sin gastar); si no, null: POST
 * /translate responde 501 y el arranque ya avisó (config_incomplete). El SDK se carga con un import
 * dinámico recién en la primera traducción y queda guardado (lazyTranslator); si no carga, esa
 * traducción falla (sdkLoad) y la próxima lo vuelve a intentar.
 */
function createTranslator(): Translator | null {
  if (config.translation === "fake") return fakeTranslator;
  if (config.translation === "off") return null;
  const apiKey = env("ANTHROPIC_API_KEY")?.trim();
  if (!apiKey) return null;
  return lazyTranslator(async () => {
    const { createClaudeTranslator } = await import("./claude_translator.ts");
    return createClaudeTranslator(apiKey);
  });
}

Deno.serve(
  createChefHandler({
    config,
    store: createStore(),
    translator: createTranslator(),
    now: () => new Date(),
    log: consoleLogger,
  }),
);
