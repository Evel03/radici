// Puente único hacia lo que la web usa del motor compartido (SPEC.md §5.1): los límites y la carga de cocina
// (porciones, recetas y minutos de cada sesión, de los que dependen los días libres del calendario).
// No se copia ni se modifica: se importa desde supabase/functions/_shared. vite.config.ts habilita esa carpeta en
// server.fs.allow. Sin tarifas: la web pública no muestra precios ni los lleva en el bundle (decisión del
// 22/11/2026; web/src/build/bundle.test.ts lo comprueba), así que no importa quote.ts.
export { calcCookLoad, LIMITS, validateInput } from "../../supabase/functions/_shared/cook_load.ts";
export type { CookLoad, QuoteInput } from "../../supabase/functions/_shared/cook_load.ts";
