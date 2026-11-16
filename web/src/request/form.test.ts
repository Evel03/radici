import { describe, expect, it } from "vitest";
import { validRequest } from "./fixtures.ts";
import { hiddenPanels, weeksFromForm } from "./form.ts";

describe("weeksFromForm (el selector de semanas)", () => {
  it("lleva al pedido las semanas marcadas; sin ninguna, 1; lo que no es un número queda NaN para la validación", () => {
    expect(weeksFromForm("4")).toBe(4);
    expect(weeksFromForm("8")).toBe(8);
    expect(weeksFromForm("1")).toBe(1);
    expect(weeksFromForm("")).toBe(1);
    expect(weeksFromForm("cuatro")).toBeNaN();
  });
});

describe("hiddenPanels", () => {
  it("las semanas se ven solo en el pedido semanal: con una sesión extra se ocultan", () => {
    expect(hiddenPanels(validRequest({ type: "week" })).weeks).toBe(false);
    expect(hiddenPanels(validRequest({ type: "extra", weeks: 4 })).weeks).toBe(true);
  });

  it("la nota de alergias se oculta si marcó que nadie tiene", () => {
    expect(hiddenPanels(validRequest({ noAllergies: true })).allergyDetails).toBe(true);
    expect(hiddenPanels(validRequest({ noAllergies: false })).allergyDetails).toBe(false);
  });
});
