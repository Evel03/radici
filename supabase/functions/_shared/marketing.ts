// La lista de ofertas y novedades (contrato docs/contracts/public-request.md §13): lo común de la función
// public-request (la casilla del pedido y las rutas del link) y de la página /preferenze/ (PR siguiente).
// Doble opt-in: marcar la casilla deja el contacto pendiente; confirma la dueña del email desde el link.
import type { Locale } from "./public_request.ts";

/** Las rutas del link, bajo la función public-request: POST con { token }. */
export const MARKETING_ROUTES = {
  status: "/marketing/status",
  confirm: "/marketing/confirm",
  withdraw: "/marketing/withdraw",
} as const;

export type MarketingRoute = keyof typeof MARKETING_ROUTES;

/** Los estados de public.marketing_contacts. */
export const MARKETING_STATUSES = ["pending", "confirmed", "withdrawn"] as const;
export type MarketingStatus = (typeof MARKETING_STATUSES)[number];

/** La página del link (web, PR siguiente): /preferenze/ con el token en el fragmento (no viaja al servidor de la web). */
export const MARKETING_PAGE_PATH = "/preferenze/";

/** Tope del cuerpo de las rutas del link: solo trae el token. */
export const MARKETING_MAX_PAYLOAD_BYTES = 256;

/** Límite por IP de las rutas del link (su propio contador: no gasta el del formulario). */
export const MARKETING_RATE_LIMITS = { perHour: 30, perDay: 120 } as const;

/** El link del email: la página en el idioma del pedido y el token en el fragmento. */
export function marketingPageUrl(siteUrl: string, locale: Locale, token: string): string {
  const base = `${siteUrl.replace(/\/+$/, "")}${MARKETING_PAGE_PATH}`;
  return `${base}${locale === "it" ? "" : `?lang=${locale}`}#t=${token}`;
}

/**
 * El email enmascarado que ve la página: la primera letra, *** y el dominio («g***@example.it»). Así la
 * persona reconoce su dirección sin que el link la muestre entera a quien lo vea por encima del hombro.
 */
export function maskEmail(email: string): string {
  const at = email.lastIndexOf("@");
  if (at < 1) return "***";
  return `${email.slice(0, 1)}***${email.slice(at)}`;
}

/** Lo que devuelve public.marketing_status / marketing_set, validado; null si no tiene esa forma. */
export function marketingStateFromRpc(data: unknown): { status: MarketingStatus; locale: Locale; email: string | null } | null {
  if (data === null || typeof data !== "object" || Array.isArray(data)) return null;
  const row = data as Record<string, unknown>;
  const status = row["status"];
  const locale = row["locale"];
  if (typeof status !== "string" || !(MARKETING_STATUSES as readonly string[]).includes(status)) return null;
  if (locale !== "it" && locale !== "es" && locale !== "en") return null;
  const email = typeof row["email"] === "string" ? row["email"] : null;
  return { status: status as MarketingStatus, locale, email };
}
