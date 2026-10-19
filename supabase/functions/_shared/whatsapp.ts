// Confirmación por WhatsApp Cloud API con una plantilla aprobada (fuera de la ventana de 24 h solo
// se pueden mandar plantillas). Opcional: sin WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID y
// WHATSAPP_TEMPLATE no se manda nada.
// Docs (revisadas el 19/10/2026): POST https://graph.facebook.com/v26.0/<PHONE_NUMBER_ID>/messages,
// Graph API v26.0 (29/07/2026). La plantilla usa un parámetro con nombre: {{first_name}}.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import type { Locale } from "./public_request.ts";
import type { SendOutcome } from "./resend.ts";

export const WHATSAPP_GRAPH_VERSION = "v26.0";

/** Idioma de la plantilla en Meta para cada idioma del cliente (la plantilla tiene que existir en los tres). */
export const WHATSAPP_TEMPLATE_LANGUAGES: Readonly<Record<Locale, string>> = { it: "it", es: "es", en: "en" };

export interface WhatsAppConfig {
  token: string;
  phoneNumberId: string;
  template: string;
}

export interface WhatsAppTemplateParams {
  /** "+<código país><número>" (phoneE164). */
  to: string;
  locale: Locale;
  firstName: string;
}

export function whatsAppConfigFrom(get: (name: string) => string | undefined): WhatsAppConfig | null {
  const token = get("WHATSAPP_TOKEN")?.trim() ?? "";
  const phoneNumberId = get("WHATSAPP_PHONE_NUMBER_ID")?.trim() ?? "";
  const template = get("WHATSAPP_TEMPLATE")?.trim() ?? "";
  if (!token || !/^\d+$/.test(phoneNumberId) || !/^[a-z0-9_]+$/.test(template)) return null;
  return { token, phoneNumberId, template };
}

export function buildTemplateMessage(
  config: WhatsAppConfig,
  params: WhatsAppTemplateParams,
): { url: string; init: { method: "POST"; headers: Record<string, string>; body: string } } {
  const body = {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to: params.to,
    type: "template",
    template: {
      name: config.template,
      language: { code: WHATSAPP_TEMPLATE_LANGUAGES[params.locale] },
      components: [
        {
          type: "body",
          // Meta rechaza parámetros vacíos.
          parameters: [{ type: "text", parameter_name: "first_name", text: params.firstName.trim() || "-" }],
        },
      ],
    },
  };
  return {
    url: `https://graph.facebook.com/${WHATSAPP_GRAPH_VERSION}/${config.phoneNumberId}/messages`,
    init: {
      method: "POST",
      headers: { Authorization: `Bearer ${config.token}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    },
  };
}

/** errorName es el código numérico de Meta (ej. "131026") o "network"; nunca el mensaje, que puede traer el número. */
export async function sendWhatsAppTemplate(
  config: WhatsAppConfig,
  params: WhatsAppTemplateParams,
  options: { fetch?: typeof fetch; timeoutMs?: number } = {},
): Promise<SendOutcome> {
  const doFetch = options.fetch ?? fetch;
  const request = buildTemplateMessage(config, params);
  let response: Response;
  try {
    response = await doFetch(request.url, { ...request.init, signal: AbortSignal.timeout(options.timeoutMs ?? 10000) });
  } catch {
    return { ok: false, status: null, errorName: "network" };
  }
  let data: unknown = null;
  try {
    data = await response.json();
  } catch {
    data = null;
  }
  const record = typeof data === "object" && data !== null ? (data as Record<string, unknown>) : {};
  if (response.ok) {
    const messages = record["messages"];
    const first: unknown = Array.isArray(messages) ? messages[0] : null;
    const id = typeof first === "object" && first !== null ? (first as Record<string, unknown>)["id"] : null;
    return { ok: true, id: typeof id === "string" ? id : null };
  }
  const error = record["error"];
  const code = typeof error === "object" && error !== null ? (error as Record<string, unknown>)["code"] : null;
  return { ok: false, status: response.status, errorName: typeof code === "number" || typeof code === "string" ? String(code) : null };
}
