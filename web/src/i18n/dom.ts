// Aplica las traducciones al DOM. Mismo contrato que src/build/html.ts:
// data-i18n (texto), data-i18n-html (HTML propio y de confianza), data-i18n-attr ("attr:clave;...").
import { parseAttrSpec, type I18n } from "./core.ts";

export function applyTranslations(root: ParentNode, i18n: I18n): void {
  for (const el of root.querySelectorAll<HTMLElement>("[data-i18n]")) {
    el.textContent = i18n.text(el.dataset["i18n"] ?? "");
  }
  for (const el of root.querySelectorAll<HTMLElement>("[data-i18n-html]")) {
    // Solo textos de nuestros JSON, nunca datos del usuario.
    el.innerHTML = i18n.text(el.dataset["i18nHtml"] ?? "");
  }
  for (const el of root.querySelectorAll<HTMLElement>("[data-i18n-attr]")) {
    for (const [attr, key] of parseAttrSpec(el.dataset["i18nAttr"] ?? "")) {
      el.setAttribute(attr, i18n.text(key));
    }
  }
}
