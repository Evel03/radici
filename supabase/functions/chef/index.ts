// Edge Function chef: el área de Evelyn (docs/contracts/chef-api.md). Reservas de 1 a 8 semanas,
// mover y cancelar sesiones, con las funciones SQL chef_* (solo service_role).
// Este archivo solo conecta lo real (Deno y supabase-js con la clave secreta); la lógica y sus
// tests están en handler.ts.
//
// Con JWT: verify_jwt = true en supabase/config.toml ([functions.chef]). Ese chequeo de la
// plataforma también deja pasar las claves de API, así que la función valida además el token con
// Auth (auth.getUser) y busca la ficha de cocinera del usuario (chefs.profile_id) antes de tocar
// nada. CORS: ALLOWED_ORIGINS, la misma variable que public-request.
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

const env = (name: string): string | undefined => Deno.env.get(name);
const config = readChefConfig(env);

// Un aviso por arranque, solo con nombres de variables.
if (config.missing.length > 0) consoleLogger("error", "config_missing", { missing: config.missing });
const incomplete = chefConfigWarnings(config);
if (incomplete.length > 0) consoleLogger("warn", "config_incomplete", { missing: incomplete });

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
    };
  }

  // Clave secreta (sin RLS): solo para validar el token, buscar a la cocinera y llamar a las chef_*,
  // siempre con el chef_id que sale del token.
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
      const { data, error } = await supabase.from("chefs").select("id").eq("profile_id", userId).maybeSingle();
      if (error) throw storeErrorFrom("load_chef", error);
      const id = (data as { id?: unknown } | null)?.id;
      return typeof id === "string" ? id : null;
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
  };
}

Deno.serve(
  createChefHandler({
    config,
    store: createStore(),
    now: () => new Date(),
    log: consoleLogger,
  }),
);
