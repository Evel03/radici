// Edge Function auth-email: el Send Email Hook de Supabase Auth (PR19, contrato docs/contracts/auth.md §16). La
// lógica y sus tests están en handler.ts; este archivo solo conecta lo real (Deno, supabase-js con la clave secreta,
// Resend).
//
// verify_jwt = false en supabase/config.toml: la llama GoTrue, no una persona. La protección es la firma Standard
// Webhooks con SEND_EMAIL_HOOK_SECRETS (sin ella, 503). Hasta PR20 GoTrue no la llama.
import { createClient } from "npm:@supabase/supabase-js@2.117.2";
import { parseHookSecrets } from "../_shared/auth_email_hook.ts";
import { StoreError, consoleLogger, resolveServiceKey, safeDbMessage } from "../_shared/edge.ts";
import { sendWithResend } from "../_shared/resend.ts";
import { GATE_DECISIONS, createAuthEmailHandler, type AuthEmailConfig, type AuthEmailStore, type GateDecision } from "./handler.ts";

const env = (name: string): string | undefined => Deno.env.get(name);
const value = (name: string): string | null => env(name)?.trim() || null;

const config: AuthEmailConfig = {
  hookKeys: parseHookSecrets(value("SEND_EMAIL_HOOK_SECRETS")),
  hashSalt: value("IP_HASH_SALT"),
  resendKey: value("RESEND_AUTH_KEY"),
  mailFrom: value("MAIL_FROM"),
  emailTransport: value("EMAIL_TRANSPORT")?.toLowerCase() === "log" ? "log" : "resend",
};

// Un aviso por arranque, solo con nombres de variables.
const missing = [
  config.hookKeys.length > 0 ? "" : "SEND_EMAIL_HOOK_SECRETS",
  config.hashSalt ? "" : "IP_HASH_SALT",
  config.emailTransport === "log" || config.resendKey ? "" : "RESEND_AUTH_KEY",
  config.emailTransport === "log" || config.mailFrom ? "" : "MAIL_FROM",
].filter(Boolean);
if (missing.length > 0) consoleLogger("warn", "config_incomplete", { missing });

function createStore(): AuthEmailStore {
  const supabaseUrl = env("SUPABASE_URL");
  const serviceKey = resolveServiceKey(env);
  if (!supabaseUrl || !serviceKey) {
    return { gate: () => Promise.reject(new StoreError("auth_email_gate", null, "supabase_not_configured")) };
  }
  // Clave secreta: solo para public.auth_email_gate.
  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  return {
    async gate(userId, kind, recipientHash) {
      const { data, error } = await supabase.rpc("auth_email_gate", {
        p_user_id: userId,
        p_kind: kind,
        p_recipient_hash: recipientHash,
      });
      // Nunca se pasan details ni hint: pueden traer valores.
      if (error) throw new StoreError("auth_email_gate", error.code ?? null, safeDbMessage(error.message));
      if (!(GATE_DECISIONS as readonly unknown[]).includes(data)) throw new StoreError("auth_email_gate", null, "unexpected_result");
      return data as GateDecision;
    },
  };
}

const handler = createAuthEmailHandler({
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
