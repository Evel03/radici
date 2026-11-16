// Lo que la página del pedido lee del formulario y qué partes oculta. Pura: richiesta.ts solo lee los
// controles y asigna.
import type { RequestData } from "./model.ts";

/**
 * Las semanas marcadas en el selector. Siempre hay una (la 1 viene marcada en el HTML); sin ninguna, 1.
 * Lo que no sea un número lo rechaza la validación (NaN).
 */
export function weeksFromForm(value: string): number {
  return value === "" ? 1 : Number(value);
}

export interface HiddenPanels {
  /** La nota de alergias y su consentimiento: si marcó que nadie tiene (y entonces no se mandan). */
  allergyDetails: boolean;
  /** Las semanas son del pedido semanal: con una sesión extra se ocultan (y se manda 1). */
  weeks: boolean;
}

export function hiddenPanels(data: Pick<RequestData, "type" | "noAllergies">): HiddenPanels {
  return { allergyDetails: data.noAllergies, weeks: data.type !== "week" };
}
