// Contrato del pedido público: web → Edge Function `public-request`.
// Fuente única de verdad: la web arma el payload con estos tipos y el servidor lo valida
// con `parsePublicRequest`. Si cambia el contrato, subir PUBLIC_REQUEST_VERSION.
// Solo sintaxis borrable: corre en Node (tests), Deno (Edge Functions) y Vite (web).
import { calcQuote, LIMITS, type Quote, type QuoteInput } from "./quote.ts";

/**
 * Versión del contrato. El servidor acepta solo esta: una página vieja en caché recibe
 * `version: "invalid"` y la web pide recargarla.
 * 2: la pregunta de alergias (`noAllergies`, y las alergias escritas en `restrictionsNote`).
 */
export const PUBLIC_REQUEST_VERSION = 2;

/** Versión vigente del texto de los consentimientos (privacy y datos de salud). */
export const CONSENT_VERSION = "2026-11-16";
/**
 * Versiones de la privacy con que se puede guardar un pedido de la versión vigente del contrato. Al cambiar
 * el texto sin cambiar el contrato, agregar la nueva y dejar la anterior mientras haya páginas en caché (y
 * mientras la web y la función se despliegan, que corren por separado).
 * 2026-11-16 suma la pregunta de alergias y las consultas del calendario (GET …/availability, que guardan
 * un hash de la IP para el límite de consultas).
 */
export const CONSENT_VERSIONS: readonly string[] = [CONSENT_VERSION];
/**
 * Privacy de las páginas de la versión 1 del contrato: 2026-11-15 (sin la pregunta de alergias ni las
 * consultas del calendario) y 2026-10-19 (el borrador, solo prueba interna). Nunca se guardan: se aceptan
 * solo en pedidos de otra versión, que se rechazan por versión, para que esas páginas reciban solo errores
 * de página (version y noAllergies) y la web vieja muestre "página desactualizada, recárgala" sin marcar
 * como faltante la casilla de privacy que sí aceptaron. Un pedido de la versión vigente con una de estas
 * (solo posible armado a mano) recibe consentRequired: no se guarda una privacy que no habla de las alergias.
 */
export const LEGACY_PAGE_CONSENT_VERSIONS: readonly string[] = ["2026-11-15", "2026-10-19"];
/**
 * Versiones aceptadas del consentimiento de salud (la web manda CONSENT_VERSION). Lista explícita, con
 * la misma regla que CONSENT_VERSIONS: al cambiar CONSENT_VERSION, agregarla acá (un test lo exige) y
 * dejar la anterior mientras haya páginas en caché, si el texto de salud (la casilla y el punto 5 de la
 * privacy) no cambió. Si siguiera sola a CONSENT_VERSION, un cambio de la privacy que no toca la salud
 * rechazaría el consentimiento de las páginas ya abiertas. Una versión que se saca a propósito (el texto
 * de salud cambió) no deja a nadie trabado: la página vieja pide recargar (translateErrors en la web).
 * Hoy solo 2026-11-16: ningún texto anterior pedía las alergias escritas (el de 2026-10-19 era el de
 * los alérgenos marcados con casillas; el de 2026-11-15 no pedía datos de salud).
 */
export const HEALTH_CONSENT_VERSIONS: readonly string[] = ["2026-11-16"];

/** Los 14 alérgenos del Reg. UE 1169/2011, en el orden del enum `allergen` de la base. */
export const ALLERGENS = [
  "gluten",
  "crustaceans",
  "eggs",
  "fish",
  "peanuts",
  "soy",
  "milk",
  "nuts",
  "celery",
  "mustard",
  "sesame",
  "sulphites",
  "lupin",
  "molluscs",
] as const;
export type Allergen = (typeof ALLERGENS)[number];

export const DIETS = ["vegetarian", "vegan"] as const;
export type Diet = (typeof DIETS)[number];

/** 'week' y 'extra' de `request_type` ('change' es solo para clientes con cuenta). */
export const REQUEST_TYPES = ["week", "extra"] as const;
export type RequestType = (typeof REQUEST_TYPES)[number];

/** Valores de `requests.meals`, en este orden. */
export const MEALS = ["lunch", "dinner"] as const;
export type Meal = (typeof MEALS)[number];

export const SLOTS = ["morning", "afternoon", "any"] as const;
export type Slot = (typeof SLOTS)[number];

export const LOCALES = ["it", "es", "en"] as const;
export type Locale = (typeof LOCALES)[number];

/** Largo máximo de los textos (también maxlength en el HTML). */
export const TEXT_LIMITS = {
  name: 80,
  zone: 80,
  phone: 30,
  email: 120,
  /** Las alergias e intolerancias escritas en el formulario. */
  restrictionsNote: 200,
  notes: 500,
} as const;

/**
 * Fecha preferida: de mañana a +56 días (8 semanas), en Europe/Rome. Es también la ventana de la base
 * (chef_settings.booking_horizon_days por defecto; availability.test.ts compara las dos). La web la dice
 * en semanas, así que maxDaysAhead es múltiplo de 7 (lo exige un test de la web).
 */
export const DATE_WINDOW = { minDaysAhead: 1, maxDaysAhead: 56 } as const;

/** El servidor rechaza cuerpos más grandes (413). */
export const MAX_PAYLOAD_BYTES = 8192;

/** Lo que manda la web (JSON, camelCase). */
export interface PublicRequestPayload {
  version: number;
  type: RequestType;
  adults: number;
  kids: number;
  days: number;
  /** 1 o 2 valores distintos. */
  meals: Meal[];
  /**
   * La pregunta de alergias: true = el cliente confirma que nadie de quienes van a comer (niños
   * incluidos) tiene alergias, intolerancias alimentarias ni celiaquía, y no manda restricciones;
   * false = las escribe en `restrictionsNote`, con el consentimiento de salud (`consents.health`).
   */
  noAllergies: boolean;
  /** La web los manda vacíos: las alergias llegan escritas en `restrictionsNote`. */
  allergens: Allergen[];
  /** La web los manda vacíos. */
  diets: Diet[];
  /** Las alergias e intolerancias escritas (varias líneas); "" si `noAllergies`. */
  restrictionsNote: string;
  /** "AAAA-MM-DD" o null si no eligió fecha. */
  preferredDate: string | null;
  slot: Slot;
  name: string;
  zone: string;
  phone: string;
  /** Obligatorio: ahí llega la confirmación. */
  email: string;
  /** Acepta recibir la confirmación por WhatsApp en `phone`. */
  whatsappOptIn: boolean;
  notes: string;
  locale: Locale;
  /** Versión del texto aceptado; `health` solo si hay restricciones (si no, null). */
  consents: { privacy: string; health: string | null };
  /** Token de Cloudflare Turnstile; lo verifica la Edge Function. */
  turnstileToken: string;
  /**
   * Clave de idempotencia (UUID) generada por la web una vez por pedido y reutilizada en los reintentos.
   * Si llega otra vez la misma clave, el servidor devuelve el pedido ya guardado y no repite los avisos.
   * Opcional para no romper clientes viejos.
   */
  requestKey?: string;
}

export type ErrorCode =
  | "required"
  | "invalid"
  | "range"
  | "tooLong"
  | "dateOutOfRange"
  | "consentRequired"
  | "healthConsentRequired";

export type PublicRequestField =
  | "payload"
  | "version"
  | "type"
  | "adults"
  | "kids"
  | "people"
  | "days"
  | "meals"
  | "noAllergies"
  | "allergens"
  | "diets"
  | "restrictionsNote"
  | "preferredDate"
  | "slot"
  | "name"
  | "zone"
  | "phone"
  | "email"
  | "whatsappOptIn"
  | "notes"
  | "locale"
  | "consentPrivacy"
  | "consentHealth"
  | "turnstileToken"
  | "requestKey";

export type PublicRequestErrors = Partial<Record<PublicRequestField, ErrorCode>>;

/** Pedido validado y normalizado, listo para guardar. */
export interface NormalizedPublicRequest {
  type: RequestType;
  adults: number;
  kids: number;
  days: number;
  meals: Meal[];
  /** true: confirmó que nadie tiene alergias, intolerancias ni celiaquía (y no hay restricciones). */
  noAllergies: boolean;
  allergens: Allergen[];
  diets: Diet[];
  restrictionsNote: string;
  /** true si hay alérgenos, dietas o nota de restricciones (datos de salud, art. 9 RGPD). */
  hasRestrictions: boolean;
  preferredDate: string | null;
  slot: Slot;
  name: string;
  zone: string;
  /** Como lo escribió el cliente (limpio). */
  phone: string;
  /** "+<código país><número>", sin espacios; sirve para wa.me (sin el "+"). */
  phoneE164: string;
  email: string;
  whatsappOptIn: boolean;
  notes: string;
  locale: Locale;
  /** `health` es null si no hay restricciones. */
  consents: { privacy: string; health: string | null };
  turnstileToken: string;
  /** UUID en minúsculas, o null si la web no mandó clave. */
  requestKey: string | null;
  quoteInput: QuoteInput;
}

export type ParseResult =
  | { ok: true; value: NormalizedPublicRequest; estimate: Quote }
  | { ok: false; errors: PublicRequestErrors };

// ---------------------------------------------------------------------------
// Helpers puros (también los usa la web)
// ---------------------------------------------------------------------------

export function isOneOf<T extends string>(list: readonly T[], value: unknown): value is T {
  return typeof value === "string" && (list as readonly string[]).includes(value);
}

/** Saca caracteres de control (y los de dirección bidi) y colapsa espacios: para campos de una línea. */
export function cleanOneLine(raw: string): string {
  return raw
    .replace(/[\u0000-\u001F\u007F‪-‮⁦-⁩]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** Para notas: conserva saltos de línea, máximo una línea en blanco seguida. */
export function cleanMultiLine(raw: string): string {
  return raw
    .replace(/\r\n?/g, "\n")
    .replace(/[\u0000-\u0009\u000B-\u001F\u007F‪-‮⁦-⁩]/g, " ")
    .split("\n")
    .map((line) => line.replace(/[ \t]+/g, " ").trim())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function isValidEmail(raw: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(raw);
}

/**
 * Normaliza un teléfono a "+<dígitos>". Sin prefijo internacional se asume Italia solo para
 * formatos italianos inequívocos: móvil de 9–10 cifras que empieza con 3, o fijo que empieza con 0.
 * Cualquier otro número sin "+" o "00" es inválido (pedir el prefijo, ej. +34).
 */
export function normalizePhone(raw: string): string | null {
  const compact = raw.trim().replace(/[\s().\/-]/g, "");
  let digits: string;
  if (compact.startsWith("+")) digits = compact.slice(1);
  else if (compact.startsWith("00")) digits = compact.slice(2);
  else if (/^3\d{8,9}$/.test(compact)) digits = `39${compact}`;
  else if (/^0\d{5,10}$/.test(compact)) digits = `39${compact}`;
  else if (/^39\d{9,11}$/.test(compact)) digits = compact; // ya trae el 39, sin "+"
  else return null;
  return /^[1-9]\d{7,14}$/.test(digits) ? `+${digits}` : null;
}

/** Fecha de hoy en Europe/Rome como "AAAA-MM-DD" (por partes, sin depender del formato de un idioma). */
export function romeToday(now: Date): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/Rome",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const part = (type: "year" | "month" | "day"): string => parts.find((p) => p.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")}`;
}

/** Año, mes (1–12) y día de "AAAA-MM-DD", o null si el formato no es ese. */
function isoParts(value: string): { y: number; m: number; d: number } | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return null;
  return { y: Number(match[1]), m: Number(match[2]), d: Number(match[3]) };
}

/** true si es una fecha de calendario real con formato "AAAA-MM-DD". */
export function isIsoDate(value: string): boolean {
  const p = isoParts(value);
  if (!p) return false;
  const date = new Date(Date.UTC(p.y, p.m - 1, p.d));
  return date.getUTCFullYear() === p.y && date.getUTCMonth() === p.m - 1 && date.getUTCDate() === p.d;
}

/** Suma días a una fecha "AAAA-MM-DD" (sin zonas horarias). Lanza RangeError si la fecha no tiene ese formato. */
export function addDays(iso: string, days: number): string {
  const p = isoParts(iso);
  if (!p) throw new RangeError(`Fecha inválida: ${iso}`);
  return new Date(Date.UTC(p.y, p.m - 1, p.d + days)).toISOString().slice(0, 10);
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** true si es un UUID (cualquier versión) en formato canónico. */
export function isUuid(value: string): boolean {
  return UUID_PATTERN.test(value);
}

export function hasRestrictions(data: { allergens: readonly string[]; diets: readonly string[]; restrictionsNote: string }): boolean {
  return data.allergens.length > 0 || data.diets.length > 0 || data.restrictionsNote.trim() !== "";
}

// ---------------------------------------------------------------------------
// Validación del servidor
// ---------------------------------------------------------------------------

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** El JSON recibido, con las claves del contrato declaradas (valores sin validar). */
type RawPayload = { [K in keyof PublicRequestPayload]?: unknown };
type RawConsents = { privacy?: unknown; health?: unknown };

/** Lista de valores válidos y sin repetir, devuelta en el orden canónico de `list`. */
function parseSet<T extends string>(list: readonly T[], value: unknown, max: number): T[] | null {
  if (!Array.isArray(value) || value.length > max) return null;
  if (!value.every((v) => isOneOf(list, v))) return null;
  if (new Set(value).size !== value.length) return null;
  return list.filter((item) => (value as unknown[]).includes(item));
}

/**
 * Valida y normaliza el payload de la web. Pura: `today` es la fecha de hoy en Europe/Rome
 * (usar `romeToday(new Date())`). No verifica Turnstile: eso lo hace la Edge Function.
 */
export function parsePublicRequest(input: unknown, opts: { today: string }): ParseResult {
  if (!isRecord(input)) return { ok: false, errors: { payload: "invalid" } };
  const raw: RawPayload = input;
  const errors: PublicRequestErrors = {};

  if (raw.version !== PUBLIC_REQUEST_VERSION) errors.version = "invalid";

  const type = isOneOf(REQUEST_TYPES, raw.type) ? raw.type : null;
  if (!type) errors.type = raw.type === undefined ? "required" : "invalid";

  const intField = (field: "adults" | "kids" | "days", min: number, max: number): number => {
    const value = raw[field];
    if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
      errors[field] = value === undefined ? "required" : "range";
      return min;
    }
    return value;
  };
  const adults = intField("adults", 0, LIMITS.maxPeople);
  const kids = intField("kids", 0, LIMITS.maxPeople);
  const days = intField("days", 1, LIMITS.maxDays);
  if (!errors.adults && !errors.kids && adults + kids < 1) errors.people = "range";

  const meals = parseSet(MEALS, raw.meals, MEALS.length);
  if (!meals || meals.length === 0) errors.meals = raw.meals === undefined ? "required" : "invalid";

  // La pregunta de alergias se contesta siempre: o nadie tiene (true) o las escribe (false).
  const noAllergies = typeof raw.noAllergies === "boolean" ? raw.noAllergies : null;
  if (noAllergies === null) errors.noAllergies = "invalid";

  const allergens = parseSet(ALLERGENS, raw.allergens ?? [], ALLERGENS.length);
  if (!allergens) errors.allergens = "invalid";
  const diets = parseSet(DIETS, raw.diets ?? [], DIETS.length);
  if (!diets) errors.diets = "invalid";

  const text = (
    field: "restrictionsNote" | "name" | "zone" | "phone" | "email" | "notes",
    { required, multiLine = false }: { required: boolean; multiLine?: boolean },
  ): string => {
    const received = raw[field] ?? "";
    if (typeof received !== "string") {
      errors[field] = "invalid";
      return "";
    }
    const value = multiLine ? cleanMultiLine(received) : cleanOneLine(received);
    if (required && value === "") errors[field] = "required";
    else if (value.length > TEXT_LIMITS[field]) errors[field] = "tooLong";
    return value;
  };
  // Un área de texto: conserva los saltos de línea (una alergia por renglón).
  const restrictionsNote = text("restrictionsNote", { required: false, multiLine: true });
  const name = text("name", { required: true });
  const zone = text("zone", { required: true });
  const phone = text("phone", { required: true });
  const email = text("email", { required: true }).toLowerCase();
  const notes = text("notes", { required: false, multiLine: true });

  const phoneE164 = phone ? normalizePhone(phone) : null;
  if (!errors.phone && !phoneE164) errors.phone = "invalid";
  if (!errors.email && !isValidEmail(email)) errors.email = "invalid";

  let preferredDate: string | null = null;
  const dateRaw = raw.preferredDate;
  if (dateRaw !== null && dateRaw !== undefined && dateRaw !== "") {
    if (typeof dateRaw !== "string" || !isIsoDate(dateRaw)) {
      errors.preferredDate = "invalid";
    } else {
      const min = addDays(opts.today, DATE_WINDOW.minDaysAhead);
      const max = addDays(opts.today, DATE_WINDOW.maxDaysAhead);
      if (dateRaw < min || dateRaw > max) errors.preferredDate = "dateOutOfRange";
      else preferredDate = dateRaw;
    }
  }

  const slot = isOneOf(SLOTS, raw.slot) ? raw.slot : null;
  if (!slot) errors.slot = raw.slot === undefined ? "required" : "invalid";

  const whatsappOptIn = raw.whatsappOptIn ?? false;
  if (typeof whatsappOptIn !== "boolean") errors.whatsappOptIn = "invalid";

  const locale: Locale = isOneOf(LOCALES, raw.locale) ? raw.locale : "it";

  const consents: RawConsents = isRecord(raw.consents) ? raw.consents : {};
  const privacyVersions =
    raw.version === PUBLIC_REQUEST_VERSION ? CONSENT_VERSIONS : [...CONSENT_VERSIONS, ...LEGACY_PAGE_CONSENT_VERSIONS];
  const privacy = isOneOf(privacyVersions, consents.privacy) ? consents.privacy : null;
  if (!privacy) errors.consentPrivacy = "consentRequired";

  const restricted = hasRestrictions({
    allergens: allergens ?? [],
    diets: diets ?? [],
    restrictionsNote,
  });
  if (noAllergies === true && restricted) {
    // Dice que nadie tiene alergias y a la vez manda restricciones: no se sabe cuál vale.
    errors.noAllergies = "invalid";
  } else if (noAllergies === false && !restricted && !errors.restrictionsNote) {
    errors.restrictionsNote = "required";
  }
  let health: string | null = null;
  if (restricted && noAllergies !== true) {
    health = isOneOf(HEALTH_CONSENT_VERSIONS, consents.health) ? consents.health : null;
    if (!health) errors.consentHealth = "healthConsentRequired";
  }

  const turnstileToken = raw.turnstileToken;
  if (typeof turnstileToken !== "string" || turnstileToken === "" || turnstileToken.length > 2048) {
    errors.turnstileToken = "required";
  }

  let requestKey: string | null = null;
  if (raw.requestKey !== undefined && raw.requestKey !== null) {
    if (typeof raw.requestKey === "string" && isUuid(raw.requestKey)) requestKey = raw.requestKey.toLowerCase();
    else errors.requestKey = "invalid";
  }

  if (Object.keys(errors).length > 0) return { ok: false, errors };

  const quoteInput: QuoteInput = { adults, kids, days, meals: (meals as Meal[]).length };
  const value: NormalizedPublicRequest = {
    type: type as RequestType,
    adults,
    kids,
    days,
    meals: meals as Meal[],
    noAllergies: noAllergies as boolean,
    allergens: allergens as Allergen[],
    diets: diets as Diet[],
    restrictionsNote,
    hasRestrictions: restricted,
    preferredDate,
    slot: slot as Slot,
    name,
    zone,
    phone,
    phoneE164: phoneE164 as string,
    email,
    whatsappOptIn: whatsappOptIn as boolean,
    notes,
    locale,
    consents: { privacy: privacy as string, health },
    turnstileToken: turnstileToken as string,
    requestKey,
    quoteInput,
  };
  return { ok: true, value, estimate: calcQuote(quoteInput) };
}
