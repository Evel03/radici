// Edge Function menu-reminders: los avisos a Evelyn para completar el menú de cada semana (SPEC 5.8).
// La llama la base cada 15 minutos (pg_cron + pg_net) con el secreto compartido; la lógica y sus tests
// están en handler.ts. Este archivo solo conecta lo real (Deno, supabase-js con la clave secreta,
// Resend).
//
// verify_jwt = false en supabase/config.toml: la protección es el secreto de la cabecera
// x-reminders-secret (MENU_REMINDERS_SECRET, el mismo que el despliegue guarda en Vault). Sin él la
// función no hace nada (503).
import { createClient } from "npm:@supabase/supabase-js@2.117.2";
import { StoreError, consoleLogger, resolveServiceKey, safeDbMessage } from "../_shared/edge.ts";
import { sendWithResend } from "../_shared/resend.ts";
import {
  createMenuRemindersHandler,
  readRemindersConfig,
  remindersConfigWarnings,
  type RemindersStore,
} from "./handler.ts";

const env = (name: string): string | undefined => Deno.env.get(name);
const config = readRemindersConfig(env);

// Un aviso por arranque, solo con nombres de variables.
if (config.invalid.length > 0) consoleLogger("error", "config_invalid", { invalid: config.invalid });
const incomplete = remindersConfigWarnings(config);
if (incomplete.length > 0) consoleLogger("warn", "config_incomplete", { missing: incomplete });

interface PostgrestLikeError {
  code?: string;
  message?: string;
}

/** Nunca se pasan `details` ni `hint`: pueden traer filas con datos personales. */
function storeError(op: string, error: PostgrestLikeError): StoreError {
  return new StoreError(op, error.code ?? null, safeDbMessage(error.message));
}

function createStore(): RemindersStore {
  const supabaseUrl = env("SUPABASE_URL");
  const serviceKey = resolveServiceKey(env);
  if (!supabaseUrl || !serviceKey) {
    consoleLogger("error", "config_missing", {
      missing: [supabaseUrl ? "" : "SUPABASE_URL", serviceKey ? "" : "SUPABASE_SECRET_KEYS"].filter(Boolean),
    });
    const fail = (op: string) => Promise.reject(new StoreError(op, null, "supabase_not_configured"));
    return { resolveDefaultChef: () => fail("resolve_chef"), due: () => fail("due"), mark: () => fail("mark") };
  }

  // Clave secreta: solo para menu_reminders_due, menu_reminders_mark y la cocina por defecto.
  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  return {
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

    async due(chefId, nowIso) {
      const { data, error } = await supabase.rpc("menu_reminders_due", { p_chef_id: chefId, p_now: nowIso });
      if (error) throw storeError("due", error);
      return data;
    },

    async mark(chefId, items, nowIso) {
      const { data, error } = await supabase.rpc("menu_reminders_mark", { p_chef_id: chefId, p_items: items, p_now: nowIso });
      if (error) throw storeError("mark", error);
      return typeof data === "number" ? data : 0;
    },
  };
}

const handler = createMenuRemindersHandler({
  config,
  store: createStore(),
  sendEmail: (message, apiKey) =>
    sendWithResend(message, {
      apiKey,
      fetch: (input, init) => fetch(input, init),
      sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    }),
  log: consoleLogger,
  now: () => new Date(),
});

Deno.serve(handler);
