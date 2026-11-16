// Puente único hacia el motor de presupuesto compartido (SPEC.md §5.1).
// No se copia ni se modifica: se importa desde supabase/functions/_shared.
// vite.config.ts habilita esa carpeta en server.fs.allow.
export {
  calcQuote,
  DEFAULT_PRICING,
  LIMITS,
  validateInput,
} from "../../supabase/functions/_shared/quote.ts";
export type {
  NoAutoPriceReason,
  PricedQuote,
  PricingSettings,
  Quote,
  QuoteInput,
} from "../../supabase/functions/_shared/quote.ts";
