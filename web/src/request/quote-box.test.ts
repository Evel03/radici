import { describe, expect, it } from "vitest";
import type { Lang } from "../i18n/core.ts";
import { i18nFor, validRequest } from "./fixtures.ts";
import type { RequestData } from "./model.ts";
import { quoteBoxView, type QuoteBoxView } from "./quote-box.ts";
import { computeQuote } from "./quote.ts";

function view(lang: Lang, overrides: Partial<RequestData> = {}): QuoteBoxView {
  const data = validRequest(overrides);
  const quote = computeQuote(data);
  if (!quote) throw new Error("pedido inválido");
  return quoteBoxView(quote, data.type, i18nFor(lang));
}

/** Intl separa el importe del € con un espacio duro: en el test se escribe con uno normal. */
const money = (text: string): string => text.replace(/ €/g, " €");

/** El ahorro: la tarifa va pegada a «a settimana» (en el teléfono la palabra no queda sola en un renglón). */
const glued = (text: string): string => text.replace(/ (a|por) (settimana|semana|week)./, " $1 $2.");

describe("recuadro del precio del formulario (quoteBoxView)", () => {
  it("1 semana: el precio del servicio destacado, sin fila por semana ni ahorro; la compra y las porciones de la semana", () => {
    expect(view("it")).toEqual({
      manual: null,
      total: { label: "Prezzo del servizio", value: money("150,00 €") },
      weekly: null,
      savings: null,
      groceries: { label: "Spesa stimata a settimana", value: money("63,00 €") },
      portions: { label: "Porzioni a settimana", value: "20" },
    });
  });

  it("3 semanas: el servicio de las 3 destacado y el de cada semana, todavía sin descuento ni ahorro", () => {
    expect(view("it", { weeks: 3 })).toMatchObject({
      manual: null,
      total: { label: "Servizio, 3 settimane", value: money("450,00 €") },
      weekly: money("150,00 €"),
      savings: null,
    });
  });

  it("4 semanas: 560 € de servicio, 140 € por semana y el ahorro frente a 150 € por semana (it, es, en)", () => {
    expect(view("it", { weeks: 4 })).toEqual({
      manual: null,
      total: { label: "Servizio, 4 settimane", value: money("560,00 €") },
      weekly: money("140,00 €"),
      savings: glued(money("Risparmi 40,00 € rispetto a 150,00 € a settimana.")),
      groceries: { label: "Spesa stimata a settimana", value: money("63,00 €") },
      portions: { label: "Porzioni a settimana", value: "20" },
    });
    expect(view("es", { weeks: 4 })).toMatchObject({
      total: { label: "Servicio, 4 semanas", value: money("560,00 €") },
      weekly: money("140,00 €"),
      savings: glued(money("Ahorras 40,00 € frente a 150,00 € por semana.")),
      groceries: { label: "Compra estimada por semana" },
    });
    expect(view("en", { weeks: 8 })).toMatchObject({
      total: { label: "Service, 8 weeks", value: "€1,120.00" },
      weekly: "€140.00",
      savings: glued("You save €80.00 compared with €150.00 a week."),
      groceries: { label: "Estimated groceries per week", value: "€63.00" },
    });
  });

  it("6 personas: sin precio automático; en lugar del total, que el presupuesto lo prepara Evelyn (con el tope), y la compra", () => {
    expect(view("it", { adults: 3, kids: 3, weeks: 4 })).toEqual({
      manual: "Per più di 5 persone il preventivo per il servizio te lo prepara Evelyn.",
      total: null,
      weekly: null,
      savings: null,
      groceries: { label: "Spesa stimata a settimana", value: money("94,50 €") },
      portions: { label: "Porzioni a settimana", value: "30" },
    });
    expect(view("en", { adults: 3, kids: 3 }).manual).toBe("For more than 5 people, Evelyn will send you a quote for the service.");
  });

  it("sesión extra con el selector en 4: sin precio, el motivo de la extra y la compra de la sesión (no por semana)", () => {
    expect(view("es", { type: "extra", weeks: 4 })).toEqual({
      manual: "Para eventos y sesiones extra, el presupuesto del servicio te lo prepara Evelyn.",
      total: null,
      weekly: null,
      savings: null,
      groceries: { label: "Compra estimada", value: money("63,00 €") },
      portions: { label: "Porciones", value: "20" },
    });
  });
});
