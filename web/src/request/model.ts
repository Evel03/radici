// Modelo del pedido de la web (Fase 0). Los valores coinciden con los enums de SPEC.md §4.

/** Los 14 alérgenos del Reg. UE 1169/2011, en el orden del enum `allergen`. */
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

export const MEAL_OPTIONS = ["lunch", "dinner", "both"] as const;
export type MealOption = (typeof MEAL_OPTIONS)[number];

export const SLOTS = ["morning", "afternoon", "any"] as const;
export type Slot = (typeof SLOTS)[number];

/** Largo máximo de los campos de texto (también como maxlength en el HTML). */
export const TEXT_LIMITS = {
  name: 80,
  zone: 80,
  phone: 30,
  email: 120,
  restrictionsNote: 200,
  notes: 500,
} as const;

/** Ventana de fechas: de mañana a +14 días (booking_horizon_days). */
export const DATE_WINDOW = { minDaysAhead: 1, maxDaysAhead: 14 } as const;

export interface RequestData {
  type: RequestType;
  adults: number;
  kids: number;
  days: number;
  meals: MealOption;
  allergens: Allergen[];
  diets: Diet[];
  restrictionsNote: string;
  /** "" si no eligió fecha; si no, "AAAA-MM-DD". */
  date: string;
  slot: Slot;
  name: string;
  zone: string;
  phone: string;
  email: string;
  notes: string;
  privacyConsent: boolean;
  healthConsent: boolean;
}

export function mealsPerDay(option: MealOption): number {
  return option === "both" ? 2 : 1;
}

/** Hay datos de salud si marcó algún alérgeno o dieta o escribió algo en "otros". */
export function hasRestrictions(data: Pick<RequestData, "allergens" | "diets" | "restrictionsNote">): boolean {
  return data.allergens.length > 0 || data.diets.length > 0 || data.restrictionsNote.trim() !== "";
}

export function isOneOf<T extends string>(list: readonly T[], value: unknown): value is T {
  return typeof value === "string" && (list as readonly string[]).includes(value);
}
