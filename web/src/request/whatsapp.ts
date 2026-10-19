// Mensaje de WhatsApp para Evelyn (Fase 0: el pedido viaja por wa.me, sin backend).
import type { Quote } from "../engine.ts";
import type { I18n } from "../i18n/core.ts";
import { formatCents, formatDuration, formatIsoDate } from "../lib/format.ts";
import { hasRestrictions, type RequestData } from "./model.ts";

/** Campos de una línea: sin saltos ni espacios repetidos. */
function oneLine(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

/** Notas: conserva los saltos de línea pero no más de una línea en blanco seguida. */
function multiLine(value: string): string {
  return value
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((line) => line.replace(/[ \t]+/g, " ").trim())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function peopleText(data: RequestData, i18n: I18n): string {
  const { t } = i18n;
  const adults = data.adults === 1 ? t("whatsapp.adultsOne") : t("whatsapp.adultsOther", { n: data.adults });
  const kids = data.kids === 1 ? t("whatsapp.kidsOne") : t("whatsapp.kidsOther", { n: data.kids });
  if (data.kids === 0) return adults;
  if (data.adults === 0) return kids;
  return t("whatsapp.peopleJoin", { a: adults, b: kids });
}

/**
 * Arma el texto del pedido, en el idioma elegido por el cliente.
 * Las restricciones (datos de salud) solo se incluyen si hay consentimiento explícito.
 */
export function buildWhatsAppMessage(data: RequestData, quote: Quote, i18n: I18n): string {
  const { t, locale } = i18n;
  const money = (cents: number): string => formatCents(cents, locale);
  const lines: string[] = [];
  const section = (title: string): void => {
    lines.push("", `*${title}*`);
  };

  lines.push(t("whatsapp.greeting"));

  section(t("whatsapp.sectionRequest"));
  lines.push(t("whatsapp.type", { value: t(`request.type.${data.type}`) }));
  lines.push(t("whatsapp.people", { value: peopleText(data, i18n) }));
  lines.push(t("whatsapp.days", { n: data.days }));
  lines.push(t("whatsapp.meals", { value: t(`request.meals.${data.meals}`) }));
  lines.push(
    t("whatsapp.date", { value: data.date ? formatIsoDate(data.date, locale) : t("whatsapp.dateNone") }),
  );
  lines.push(t("whatsapp.slot", { value: t(`request.slot.${data.slot}`) }));

  section(t("whatsapp.sectionRestrictions"));
  const withRestrictions = hasRestrictions(data);
  if (!withRestrictions) {
    lines.push(t("whatsapp.restrictionsNone"));
  } else if (!data.healthConsent) {
    lines.push(t("whatsapp.restrictionsWithheld"));
  } else {
    if (data.allergens.length > 0) {
      lines.push(t("whatsapp.allergens", { value: data.allergens.map((a) => t(`allergens.${a}`)).join(", ") }));
    }
    if (data.allergens.includes("gluten")) lines.push(t("whatsapp.celiac"));
    if (data.diets.length > 0) {
      lines.push(t("whatsapp.diets", { value: data.diets.map((d) => t(`diets.${d}`)).join(", ") }));
    }
    const note = oneLine(data.restrictionsNote);
    if (note) lines.push(t("whatsapp.restrictionsNote", { value: note }));
  }

  section(t("whatsapp.sectionQuote"));
  lines.push(t("whatsapp.service", { value: money(quote.serviceCents) }));
  lines.push(t("whatsapp.groceries", { value: money(quote.groceriesEstCents) }));
  lines.push(t("whatsapp.total", { value: money(quote.totalCents) }));
  lines.push(t("whatsapp.time", { value: formatDuration(quote.cookMinutes, i18n) }));
  lines.push(t("whatsapp.portions", { n: quote.portions }));

  section(t("whatsapp.sectionContact"));
  lines.push(t("whatsapp.name", { value: oneLine(data.name) }));
  lines.push(t("whatsapp.zone", { value: oneLine(data.zone) }));
  lines.push(t("whatsapp.phone", { value: oneLine(data.phone) }));
  const email = oneLine(data.email);
  if (email) lines.push(t("whatsapp.email", { value: email }));

  const notes = multiLine(data.notes);
  if (notes) {
    section(t("whatsapp.sectionNotes"));
    lines.push(notes);
  }

  lines.push("");
  lines.push(t("whatsapp.language", { value: t(`common.langs.${i18n.lang}`) }));
  if (data.privacyConsent) lines.push(t("whatsapp.consentPrivacy"));
  if (withRestrictions && data.healthConsent) lines.push(t("whatsapp.consentHealth"));

  return lines.join("\n");
}

/** Link wa.me con el texto ya codificado. `number`: solo dígitos, formato internacional sin "+". */
export function buildWhatsAppUrl(number: string, message: string): string {
  if (!/^\d{8,15}$/.test(number)) throw new Error("Número de WhatsApp no válido");
  return `https://wa.me/${number}?text=${encodeURIComponent(message)}`;
}
