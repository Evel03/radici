// Contrato del pedido público: web → Edge Function `public-request`.
// Fuente única de verdad: la web arma el payload con estos tipos y el servidor lo valida
// con `parsePublicRequest`. Si cambia el contrato, subir PUBLIC_REQUEST_VERSION.
// Solo sintaxis borrable: corre en Node (tests), Deno (Edge Functions) y Vite (web).
import { LIMITS, type QuoteInput } from "./cook_load.ts";

/**
 * Versión del contrato: la que manda la web. Una página de una versión que el servidor ya no acepta
 * recibe `version: "invalid"` y la web pide recargarla.
 * 2: la pregunta de alergias (`noAllergies`, y las alergias escritas en `restrictionsNote`).
 * 3: las semanas del pedido semanal (`weeks`, obligatorio) y la estimación con el precio por semana (§2). Desde el
 * 22/11/2026 el 201 ya no lleva estimación ni precio (la respuesta cambió, no lo que manda la web).
 * 4: los platos que eligió el cliente en la pestaña «Menù» (`menu`, opcional; decisión del 19/11/2026).
 */
export const PUBLIC_REQUEST_VERSION = 4;
/**
 * Versiones que el servidor acepta. La 3 (sin `menu`: el menù lo propone Evelyn) y la 2 (sin `weeks`:
 * siempre una semana, no podía pedir más) mientras haya páginas en caché y mientras se despliegan la web
 * y la función, que salen por separado: así la función nueva atiende a la web de antes. Una función de
 * antes (la 3 y la 2) rechaza la 4 por versión y nunca guarda un pedido sin los platos que eligió el
 * cliente. Sacar las viejas en un PR propio.
 */
export const PUBLIC_REQUEST_VERSIONS: readonly number[] = [PUBLIC_REQUEST_VERSION, 3, 2];

/** Versión vigente del texto de los consentimientos (privacy y datos de salud). */
export const CONSENT_VERSION = "2026-11-29";
/**
 * Versiones de la privacy con que se puede guardar un pedido de la versión vigente del contrato. Al cambiar
 * el texto sin cambiar el contrato, agregar la nueva y dejar la anterior mientras haya páginas en caché (y
 * mientras la web y la función se despliegan, que corren por separado).
 * 2026-11-16 suma la pregunta de alergias y las consultas del calendario (GET …/availability, que guardan
 * un hash de la IP para el límite de consultas). 2026-11-19 suma el menú (los platos elegidos y las
 * consultas de GET …/menu en el mismo límite) y saca la compra de las tareas de Evelyn; 2026-11-16 queda
 * para las páginas abiertas antes del despliegue, que no mandan platos. 2026-11-22 suma la página de la
 * reserva (el link de la clienta, docs/contracts/client-link.md): las respuestas al menú, sus visitas y
 * respuestas en el límite por IP y el aviso a Evelyn sin el mensaje; el formulario no cambia, así que
 * 2026-11-19 y 2026-11-16 siguen valiendo para las páginas abiertas antes. 2026-11-23 suma el presupuesto en
 * esa página (SPEC 5.8): la página muestra el presupuesto (las fechas y el precio del servicio; antes decía
 * que nunca mostraba precios) y la clienta lo acepta o lo rechaza desde ahí, una respuesta más de la
 * solicitud (la misma base, art. 6.1.b, y la misma conservación); el formulario tampoco cambia, así que las
 * tres anteriores siguen valiendo. 2026-11-28 suma la cuenta de la clienta (sus datos, para qué, base, conservación y qué
 * es obligatorio; auth.md §18), sin cambiar el formulario: 2026-11-27 sigue valiendo. 2026-11-29 cuenta que la
 * cuenta se borra desde «Mi cuenta» en la app, al instante (auth.md §20), sin cambiar el formulario: 2026-11-28 y
 * las anteriores siguen valiendo. 2026-11-27 suma el punto 6, «Offerte e novità» (la casilla opcional de ofertas,
 * contrato §13), y corre la numeración de los siguientes; las páginas abiertas antes no la tienen, así que
 * 2026-11-23 y las anteriores siguen valiendo.
 */
export const CONSENT_VERSIONS: readonly string[] = [CONSENT_VERSION, "2026-11-28", "2026-11-27", "2026-11-23", "2026-11-22", "2026-11-19", "2026-11-16"];
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
 * Ningún texto anterior pedía las alergias escritas (el de 2026-10-19 era el de los alérgenos marcados con
 * casillas; el de 2026-11-15 no pedía datos de salud).
 */
export const HEALTH_CONSENT_VERSIONS: readonly string[] = ["2026-11-16"];
/**
 * Versión del texto de salud (la casilla y el punto 5 de la privacy) que manda la web en consents.health.
 * Va aparte de CONSENT_VERSION: las privacy 2026-11-19, 2026-11-22 y 2026-11-23 no tocaron la salud, y si la web mandara la versión de
 * la privacy, submit_public_request cerraría el consentimiento de salud vigente de un prospecto que vuelve
 * con alergias escritas (otra versión del texto), y con él consents_purge_health_data le borraría las
 * restricciones del hogar. Cambia solo cuando cambia el texto de salud.
 */
export const HEALTH_CONSENT_VERSION = "2026-11-16";

/**
 * Versión del texto de la casilla de ofertas y novedades (opcional, sin marcar; contrato §13) que manda la
 * web en consents.marketing. Lista explícita, como la de salud: una versión que se saca deja de aceptarse.
 */
export const MARKETING_CONSENT_VERSION = "2026-11-27";
export const MARKETING_CONSENT_VERSIONS: readonly string[] = [MARKETING_CONSENT_VERSION];

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
   * Semanas del pedido semanal, de 1 a LIMITS.maxWeeks: un menú y una sesión de cocina por semana. Una
   * sesión extra manda 1. Obligatorio desde la versión 3 (la 2 no lo manda: una semana).
   */
  weeks: number;
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
  /**
   * Versión del texto aceptado; `health` solo si hay restricciones (si no, null). `marketing` (opcional):
   * la versión de la casilla de ofertas si la marcó; sin marcar, ausente o null.
   */
  consents: { privacy: string; health: string | null; marketing?: string | null };
  /** Token de Cloudflare Turnstile; lo verifica la Edge Function. */
  turnstileToken: string;
  /**
   * Los platos que eligió en la pestaña «Menù» (ids de get_public_menu), en el orden en que los tildó: de
   * 0 a `days`, sin repetir. Solo desde la versión 4 (en la 3 y la 2 se ignora); opcional: sin el campo,
   * ninguno, y el menù lo propone Evelyn.
   */
  menu?: string[];
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
  | "healthConsentRequired"
  /** Más platos en el menù que días (`menu`). */
  | "tooMany";

export type PublicRequestField =
  | "payload"
  | "version"
  | "type"
  | "adults"
  | "kids"
  | "people"
  | "days"
  | "meals"
  | "weeks"
  | "noAllergies"
  | "allergens"
  | "diets"
  | "restrictionsNote"
  | "preferredDate"
  | "menu"
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
  | "consentMarketing"
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
  /** 1 a LIMITS.maxWeeks; 1 si no es un pedido semanal o si llegó de una página de la versión 2. */
  weeks: number;
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
  /** `health` es null si no hay restricciones; `marketing`, null si no marcó la casilla de ofertas. */
  consents: { privacy: string; health: string | null; marketing: string | null };
  turnstileToken: string;
  /** UUID en minúsculas, o null si la web no mandó clave. */
  requestKey: string | null;
  /** Los platos elegidos (uuids en minúsculas, en el orden en que los tildó); [] sin elegir o antes de la versión 4. */
  menu: string[];
  quoteInput: QuoteInput;
}

export type ParseResult =
  | { ok: true; value: NormalizedPublicRequest }
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

/**
 * Días de las sesiones de un pedido de varias semanas: el día elegido y el mismo día de cada semana
 * siguiente ("AAAA-MM-DD"). Lo usan el calendario y el resumen de la web y los emails.
 */
export function weeklyDates(first: string, weeks: number): string[] {
  return Array.from({ length: weeks }, (_, i) => addDays(first, 7 * i));
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
type RawConsents = { privacy?: unknown; health?: unknown; marketing?: unknown };

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

  const acceptedVersion = typeof raw.version === "number" && PUBLIC_REQUEST_VERSIONS.includes(raw.version);
  if (!acceptedVersion) errors.version = "invalid";

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

  // Semanas: desde la versión 3 se mandan siempre (sin el campo no se da por 1: nunca se pierden en
  // silencio, tampoco cuando la 3 deje de ser la vigente); una página de la versión 2 no las manda y su
  // pedido es de una semana (no podía pedir más).
  let weeks = 1;
  const weeksRaw = raw.weeks;
  if (weeksRaw === undefined || weeksRaw === null) {
    if (typeof raw.version === "number" && raw.version >= 3) errors.weeks = "required";
  } else if (typeof weeksRaw !== "number" || !Number.isInteger(weeksRaw) || weeksRaw < 1 || weeksRaw > LIMITS.maxWeeks) {
    errors.weeks = "range";
  } else if (weeksRaw > 1 && type === "extra") {
    // Una sesión extra es una sola: solo el pedido semanal tiene semanas.
    errors.weeks = "invalid";
  } else {
    weeks = weeksRaw;
  }

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
  // Las versiones 2 y 3 guardan con la privacy vigente; las viejas, solo para las páginas de la 1 (fallan por versión).
  const privacyVersions = acceptedVersion ? CONSENT_VERSIONS : [...CONSENT_VERSIONS, ...LEGACY_PAGE_CONSENT_VERSIONS];
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

  // Ofertas y novedades: opcional. Sin marcar (ausente o null), nada; marcada, con una versión aceptada.
  let marketing: string | null = null;
  if (consents.marketing !== undefined && consents.marketing !== null) {
    if (isOneOf(MARKETING_CONSENT_VERSIONS, consents.marketing)) marketing = consents.marketing;
    else errors.consentMarketing = "invalid";
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

  // Menù: desde la versión 4 (en la 3 y la 2 no existe y, si llega, se ignora). Hasta un plato por día; con
  // los días inválidos no se sabe el tope y solo vale el error de los días. Que el plato esté publicado lo
  // decide la base (submit_public_request descarta los que no, sin error).
  let menu: string[] = [];
  const menuRaw = raw.menu;
  if (typeof raw.version === "number" && raw.version >= 4 && menuRaw !== undefined && menuRaw !== null) {
    const ids = Array.isArray(menuRaw) && menuRaw.every((id) => typeof id === "string" && isUuid(id))
      ? (menuRaw as string[]).map((id) => id.toLowerCase())
      : null;
    if (!ids || new Set(ids).size !== ids.length) errors.menu = "invalid";
    else if (!errors.days && ids.length > days) errors.menu = "tooMany";
    else menu = ids;
  }

  if (Object.keys(errors).length > 0) return { ok: false, errors };

  const quoteInput: QuoteInput = { type: type as RequestType, adults, kids, days, meals: (meals as Meal[]).length, weeks };
  const value: NormalizedPublicRequest = {
    type: type as RequestType,
    adults,
    kids,
    days,
    meals: meals as Meal[],
    weeks,
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
    consents: { privacy: privacy as string, health, marketing },
    turnstileToken: turnstileToken as string,
    requestKey,
    menu,
    quoteInput,
  };
  return { ok: true, value };
}
