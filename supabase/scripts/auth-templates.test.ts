// Tests de los emails de Auth (PR16, contrato docs/contracts/auth.md §13): la fuente única
// (supabase/functions/_shared/auth_emails.ts), las plantillas generadas y el link a /accesso/. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { readAccessLink } from "../../web/src/access/link.ts";
import {
  ACCESS_PAGE,
  AUTH_EMAIL_KINDS,
  AUTH_LOCALES,
  TEMPLATE_FILES,
  accessLink,
  authEmailTexts,
  goTrueSubject,
  goTrueTemplate,
  renderAuthEmail,
} from "../functions/_shared/auth_emails.ts";
import { staleTemplates } from "./auth-templates.ts";

const read = (file: string): string | null => {
  try {
    return readFileSync(new URL(`../templates/${file}`, import.meta.url), "utf8");
  } catch {
    return null;
  }
};
const HASH = "pkce_" + "a".repeat(56);

test("las plantillas de supabase/templates/ son exactamente las que genera auth_emails.ts", () => {
  assert.deepEqual(staleTemplates(read), [], "correr: node supabase/scripts/auth-templates.ts");
  assert.deepEqual(staleTemplates(() => "otra cosa"), Object.values(TEMPLATE_FILES));
});

test("cada tipo tiene sus textos en los tres idiomas, sin repetir el idioma", () => {
  for (const kind of AUTH_EMAIL_KINDS) {
    const subjects = AUTH_LOCALES.map((locale) => authEmailTexts(kind, locale).subject);
    for (const locale of AUTH_LOCALES) {
      const texts = authEmailTexts(kind, locale);
      assert.ok(texts.subject && texts.lead && texts.note, `${kind} ${locale}`);
    }
    if (kind !== "invite") assert.equal(new Set(subjects).size, 3, `${kind}: un asunto por idioma`);
  }
});

test("solo .Data.locale (para comparar) y, de lo que se imprime, el código o el token_hash: nada del usuario", () => {
  const allowed: Record<string, string[]> = { magic_link: [".Token"], confirmation: [".TokenHash"], recovery: [".TokenHash"] };
  for (const kind of AUTH_EMAIL_KINDS) {
    for (const text of [goTrueTemplate(kind), goTrueSubject(kind)]) {
      for (const action of text.match(/\{\{[^}]*\}\}/g) ?? []) {
        if (action.includes(".Data")) {
          assert.match(action, /^\{\{ (else )?if and \.Data\.locale \(eq \.Data\.locale "(es|en)"\) \}\}$/, `${kind}: ${action}`);
        }
      }
      for (const banned of [".ConfirmationURL", ".SiteURL", ".RedirectTo", ".Email", ".NewEmail", ".Data.name", "{{ .Data.locale }}"]) {
        assert.ok(!text.includes(banned), `${kind} no usa ${banned}`);
      }
    }
    const printed = [...goTrueTemplate(kind).matchAll(/\{\{\s*([^}]*?)\s*\}\}/g)].map((m) => m[1] ?? "").filter((a) => !/^(if|else|end)\b/.test(a));
    assert.deepEqual([...new Set(printed)], allowed[kind] ?? [], kind);
  }
});

test("alta y recuperación: el link a /accesso/ con el idioma en la query y el token en el fragmento; nunca la URL de Auth", () => {
  for (const [kind, type] of [["confirmation", "email"], ["recovery", "recovery"]] as const) {
    const html = goTrueTemplate(kind);
    for (const locale of AUTH_LOCALES) {
      const href = `${ACCESS_PAGE}?lang=${locale}#token_hash={{ .TokenHash }}&type=${type}`;
      // El botón y el link en texto, en cada idioma.
      assert.equal(html.split(`href="${href}"`).length - 1, 2, `${kind} ${locale}`);
    }
    assert.ok(!/supabase\.co|\/auth\/v1|\/verify/.test(html), `${kind}: nunca el link de GoTrue`);
  }
  for (const kind of ["magic_link", "email_change", "reauthentication", "invite"] as const) {
    assert.ok(!/href=/i.test(goTrueTemplate(kind)), `${kind}: sin link`);
    if (kind !== "magic_link") assert.ok(!goTrueTemplate(kind).includes(".Token"), `${kind}: sin código`);
  }
});

test("el link que arman los emails es el que lee /accesso/ (web/src/access/link.ts)", () => {
  for (const type of ["email", "recovery"] as const) {
    const url = new URL(accessLink("es", HASH, type));
    assert.equal(`${url.origin}${url.pathname}`, "https://radicicucina.app/accesso/");
    assert.equal(url.searchParams.get("lang"), "es");
    assert.equal(url.search, "?lang=es", "en la query, solo el idioma");
    assert.deepEqual(readAccessLink(url.hash), { kind: "link", link: { tokenHash: HASH, type } });
  }
});

test("la plantilla del código: vale una hora y no se comparte con nadie, en los tres idiomas", () => {
  const html = goTrueTemplate("magic_link");
  for (const text of ["Vale un'ora.", "Vale una hora.", "It is valid for one hour.", "nemmeno con Evelyn", "ni siquiera con Evelyn", "not even Evelyn"]) {
    assert.ok(html.includes(text), text);
  }
  assert.ok(!/10 minut/.test(html));
});

test("email_change: le sirve a las dos direcciones (la vieja y la nueva) y dice que no cambia nada", () => {
  for (const locale of AUTH_LOCALES) {
    const texts = authEmailTexts("email_change", locale);
    assert.ok(!/tuo account|tu cuenta|your account/i.test(texts.lead), `${locale}: no supone que es la dueña de la cuenta`);
  }
});

test("renderAuthEmail (el hook de PR19): un idioma, con los valores escapados", () => {
  const code = renderAuthEmail("magic_link", "es", { token: "1234567890" });
  assert.equal(code.subject, "Tu código de acceso");
  assert.ok(code.html.includes(">1234567890</p>"));
  assert.ok(code.html.includes('<html lang="es">'));
  assert.ok(!code.html.includes("{{"));
  const link = renderAuthEmail("recovery", "en", { tokenHash: "abc<script>" });
  assert.ok(link.html.includes("#token_hash=abc%3Cscript%3E&type=recovery"));
  assert.ok(!link.html.includes("<script>"));
  assert.ok(renderAuthEmail("magic_link", "it", { token: "<b>" }).html.includes("&lt;b&gt;"));
});
