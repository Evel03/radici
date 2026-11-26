// Emails de Supabase Auth (PR16, contrato docs/contracts/auth.md §13): una sola fuente para los seis tipos, en it, es y en.
//
// - magic_link: el código de acceso de la cocina (Evelyn y colaboradores). Solo el código, sin link.
// - confirmation: confirmar el alta (segundo paso del alta en dos pasos) → /accesso/ con type=email.
// - recovery: «Password dimenticata?» → /accesso/ con type=recovery.
// - email_change, reauthentication, invite: Radici no los usa. Si alguna vez salen, no llevan ni link ni código: nadie
//   puede completar con ellos un cambio de email (hasta que el hook de PR19 los bloquee antes de mandarlos) ni una
//   reautenticación, e invitar cuentas no existe.
//
// De acá salen:
// - las plantillas de GoTrue (goTrueTemplate y goTrueSubject): un solo HTML con una rama por idioma, elegida por
//   user_metadata.locale (.Data.locale, solo para comparar; nunca se imprime). supabase/scripts/auth-templates.ts las
//   escribe en supabase/templates/*.html (config.toml las usa en local y auth-config.ts las manda a producción) y un test
//   comprueba que los archivos son exactamente esto;
// - el email de un idioma con los valores reales (renderAuthEmail), para el hook de envío de PR19.
// El link a /accesso/ lleva el idioma en la query y el token_hash en el fragmento (nunca llega a un servidor). Nada del
// usuario sale en el email: ni su email, ni su nombre, ni la URL del sitio de Auth.
// Solo sintaxis borrable: corre en Node (tests, scripts) y en Deno (Edge Functions).
import { COLOR, FONT, FONT_DISPLAY, escapeHtml, logoHtml } from "./emails.ts";
import type { Locale } from "./public_request.ts";

export type AuthEmailKind = "magic_link" | "confirmation" | "recovery" | "email_change" | "reauthentication" | "invite";
export const AUTH_EMAIL_KINDS: readonly AuthEmailKind[] = ["magic_link", "confirmation", "recovery", "email_change", "reauthentication", "invite"];
export const AUTH_LOCALES: readonly Locale[] = ["it", "es", "en"];

/** La página que canjea los links de Auth (web/accesso/, contrato auth.md §11). */
export const ACCESS_PAGE = "https://radicicucina.app/accesso/";

/** El archivo de cada plantilla en supabase/templates/ (las rutas de config.toml). */
export const TEMPLATE_FILES: Readonly<Record<AuthEmailKind, string>> = {
  magic_link: "login_code.html",
  confirmation: "confirmation.html",
  recovery: "recovery.html",
  email_change: "email_change.html",
  reauthentication: "reauthentication.html",
  invite: "invite.html",
};

/** El type del link de cada plantilla que lleva uno. */
const LINK_TYPE: Partial<Record<AuthEmailKind, "email" | "recovery">> = { confirmation: "email", recovery: "recovery" };

interface Texts {
  subject: string;
  lead: string;
  /** Solo magic_link: el código, grande. */
  code?: true;
  /** Solo confirmation y recovery: el botón al link. */
  button?: string;
  /** Debajo del botón: el mismo link en texto, para quien no puede tocar el botón. */
  fallback?: string;
  note: string;
}

const TEXTS: Readonly<Record<AuthEmailKind, Readonly<Record<Locale, Texts>>>> = {
  magic_link: {
    it: {
      subject: "Il tuo codice di accesso",
      lead: "Il tuo codice per entrare in Radici:",
      code: true,
      note: "Scrivilo nell'app. Vale un'ora. Non condividere questo codice con nessuno, nemmeno con Evelyn. Se non l'hai chiesto tu, ignora questa email.",
    },
    es: {
      subject: "Tu código de acceso",
      lead: "Tu código para entrar en Radici:",
      code: true,
      note: "Escríbelo en la app. Vale una hora. No compartas este código con nadie, ni siquiera con Evelyn. Si no lo pediste, ignora este email.",
    },
    en: {
      subject: "Your sign-in code",
      lead: "Your code to sign in to Radici:",
      code: true,
      note: "Type it in the app. It is valid for one hour. Don't share this code with anyone, not even Evelyn. If you didn't ask for it, ignore this email.",
    },
  },
  confirmation: {
    it: {
      subject: "Attiva il tuo account Radici",
      lead: "Per attivare il tuo account Radici e scegliere la password, apri questo link:",
      button: "Attiva l'account",
      fallback: "Se il pulsante non si apre, copia questo indirizzo nel browser:",
      note: "Il link vale un'ora e si usa una sola volta. Se non hai chiesto tu di creare un account, ignora questa email: senza conferma l'account non si attiva.",
    },
    es: {
      subject: "Activa tu cuenta de Radici",
      lead: "Para activar tu cuenta de Radici y elegir la contraseña, abre este enlace:",
      button: "Activar la cuenta",
      fallback: "Si el botón no se abre, copia esta dirección en el navegador:",
      note: "El enlace vale una hora y se usa una sola vez. Si no pediste crear una cuenta, ignora este email: sin confirmación la cuenta no se activa.",
    },
    en: {
      subject: "Activate your Radici account",
      lead: "To activate your Radici account and choose your password, open this link:",
      button: "Activate account",
      fallback: "If the button doesn't open, copy this address into your browser:",
      note: "The link is valid for one hour and works once. If you didn't ask to create an account, ignore this email: without confirmation the account isn't activated.",
    },
  },
  recovery: {
    it: {
      subject: "Scegli una nuova password",
      lead: "Hai chiesto di scegliere una nuova password per il tuo account Radici. Apri questo link:",
      button: "Scegli la password",
      fallback: "Se il pulsante non si apre, copia questo indirizzo nel browser:",
      note: "Il link vale un'ora e si usa una sola volta. Se non l'hai chiesto tu, ignora questa email: la tua password non cambia.",
    },
    es: {
      subject: "Elige una contraseña nueva",
      lead: "Pediste elegir una contraseña nueva para tu cuenta de Radici. Abre este enlace:",
      button: "Elegir la contraseña",
      fallback: "Si el botón no se abre, copia esta dirección en el navegador:",
      note: "El enlace vale una hora y se usa una sola vez. Si no lo pediste, ignora este email: tu contraseña no cambia.",
    },
    en: {
      subject: "Choose a new password",
      lead: "You asked to choose a new password for your Radici account. Open this link:",
      button: "Choose a password",
      fallback: "If the button doesn't open, copy this address into your browser:",
      note: "The link is valid for one hour and works once. If you didn't ask for it, ignore this email: your password stays the same.",
    },
  },
  email_change: {
    it: {
      subject: "Richiesta di cambio email",
      lead: "Abbiamo ricevuto una richiesta per usare questo indirizzo email in un account Radici.",
      note: "Per ora l'email di un account non si può cambiare: non cambia niente e non devi fare niente. Se non l'hai chiesto tu, avvisa Evelyn.",
    },
    es: {
      subject: "Pedido de cambio de email",
      lead: "Recibimos un pedido para usar esta dirección de email en una cuenta de Radici.",
      note: "Por ahora el email de una cuenta no se puede cambiar: no cambia nada y no tienes que hacer nada. Si no lo pediste, avísale a Evelyn.",
    },
    en: {
      subject: "Email change request",
      lead: "We received a request to use this email address on a Radici account.",
      note: "For now an account's email can't be changed: nothing changes and you don't need to do anything. If you didn't ask for it, let Evelyn know.",
    },
  },
  reauthentication: {
    it: {
      subject: "Verifica del tuo account",
      lead: "Abbiamo ricevuto una richiesta di verifica per il tuo account Radici.",
      note: "Radici non usa questa verifica: non devi fare niente. Se non l'hai chiesta tu, avvisa Evelyn.",
    },
    es: {
      subject: "Verificación de tu cuenta",
      lead: "Recibimos un pedido de verificación para tu cuenta de Radici.",
      note: "Radici no usa esta verificación: no tienes que hacer nada. Si no la pediste, avísale a Evelyn.",
    },
    en: {
      subject: "Account verification",
      lead: "We received a verification request for your Radici account.",
      note: "Radici doesn't use this verification: you don't need to do anything. If you didn't ask for it, let Evelyn know.",
    },
  },
  invite: {
    it: {
      subject: "Radici",
      lead: "Radici non manda inviti a creare un account.",
      note: "Se hai ricevuto questa email per errore, ignorala.",
    },
    es: {
      subject: "Radici",
      lead: "Radici no manda invitaciones para crear una cuenta.",
      note: "Si recibiste este email por error, ignóralo.",
    },
    en: {
      subject: "Radici",
      lead: "Radici doesn't send invitations to create an account.",
      note: "If you received this email by mistake, ignore it.",
    },
  },
};

/** Los textos de un email (para los tests y el hook de PR19). */
export function authEmailTexts(kind: AuthEmailKind, locale: Locale): Texts {
  return TEXTS[kind][locale];
}

/** El link a /accesso/ (contrato auth.md §11): el idioma en la query, el token_hash en el fragmento. */
export function accessLink(locale: Locale, tokenHash: string, type: "email" | "recovery"): string {
  return `${ACCESS_PAGE}?lang=${locale}#token_hash=${tokenHash}&type=${type}`;
}

/** Texto fijo de la plantilla: solo &, < y > (los apóstrofos quedan como están, como en el resto de las plantillas). */
function escapeText(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/** Valores que van en el email: ya escapados (los reales) o los marcadores de GoTrue. */
interface Values {
  token: string;
  tokenHash: string;
}

/** El contenido de la tarjeta en un idioma. */
function cardBody(kind: AuthEmailKind, locale: Locale, values: Values): string {
  const texts = TEXTS[kind][locale];
  const parts: string[] = [`<p style="margin:0 0 16px;">${escapeText(texts.lead)}</p>`];
  if (texts.code) {
    parts.push(
      `<p style="margin:0 0 16px;font-size:32px;font-weight:700;letter-spacing:8px;font-family:Menlo,Consolas,monospace;color:${COLOR.text};">${values.token}</p>`,
    );
  }
  const type = LINK_TYPE[kind];
  if (type && texts.button && texts.fallback) {
    const href = accessLink(locale, values.tokenHash, type);
    // Como los botones de la web y de los emails del pedido (emails.ts): oliva y crema, esquinas casi rectas.
    parts.push(
      `<table role="presentation" cellspacing="0" cellpadding="0" style="margin:8px 0 20px;"><tr>` +
        `<td style="border-radius:2px;background:${COLOR.accent};">` +
        `<a href="${href}" style="display:inline-block;padding:13px 26px;font-family:${FONT_DISPLAY};font-size:17px;` +
        `letter-spacing:0.06em;font-variant:small-caps;color:${COLOR.onAccent};text-decoration:none;border-radius:2px;">` +
        `${escapeText(texts.button)}</a></td></tr></table>`,
      `<p style="margin:0 0 16px;font-size:14px;line-height:1.5;color:${COLOR.muted};">${escapeText(texts.fallback)}<br>` +
        `<a href="${href}" style="color:${COLOR.accent};word-break:break-all;overflow-wrap:anywhere;">${href}</a></p>`,
    );
  }
  parts.push(`<p style="margin:0;font-size:15px;line-height:1.5;font-style:italic;color:${COLOR.muted};">${escapeText(texts.note)}</p>`);
  return parts.join("\n");
}

/** El HTML alrededor de la tarjeta (el mismo de los emails del pedido). `lang` y `body` ya armados. */
function page(lang: string, body: string, comment: string): string {
  return [
    "<!doctype html>",
    ...(comment ? [comment] : []),
    `<html lang="${lang}">`,
    "<head>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    '<meta name="color-scheme" content="light">',
    "<title>Radici</title>",
    "</head>",
    `<body style="margin:0;padding:0;background:${COLOR.page};">`,
    `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:${COLOR.page};">`,
    `<tr><td align="center" style="padding:24px 12px;">`,
    `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:480px;background:${COLOR.card};border:1px solid ${COLOR.border};border-radius:2px;font-family:${FONT};font-variant-numeric:lining-nums;color:${COLOR.text};">`,
    `<tr><td align="center" style="padding:32px 24px 8px;">`,
    logoHtml("Radici"),
    "</td></tr>",
    `<tr><td style="padding:20px 24px 28px;font-size:17px;line-height:1.55;">`,
    body,
    "</td></tr>",
    "</table>",
    "</td></tr>",
    "</table>",
    "</body>",
    "</html>",
    "",
  ].join("\n");
}

/** La rama de un idioma en una plantilla de GoTrue: «{{ if es }}…{{ else if en }}…{{ else }}…{{ end }}». */
function byLocale(render: (locale: Locale) => string): string {
  return (
    `{{ if and .Data.locale (eq .Data.locale "es") }}${render("es")}` +
    `{{ else if and .Data.locale (eq .Data.locale "en") }}${render("en")}` +
    `{{ else }}${render("it")}{{ end }}`
  );
}

/** Los marcadores de GoTrue. Solo esto se imprime: nada del usuario. */
const GOTRUE_VALUES: Values = { token: "{{ .Token }}", tokenHash: "{{ .TokenHash }}" };

/** La plantilla de GoTrue de un tipo: un solo HTML, con el idioma de user_metadata.locale (it si no hay). */
export function goTrueTemplate(kind: AuthEmailKind): string {
  const comment =
    `<!-- Plantilla «${kind}» de Supabase Auth, en it, es y en según user_metadata.locale. ` +
    "GENERADA desde supabase/functions/_shared/auth_emails.ts con node supabase/scripts/auth-templates.ts: no editar a mano " +
    "(contrato docs/contracts/auth.md §13). En producción la aplica deploy-supabase.yml (auth-config.ts). -->";
  return page(
    byLocale((locale) => locale),
    byLocale((locale) => `\n${cardBody(kind, locale, GOTRUE_VALUES)}\n`),
    comment,
  );
}

/** El asunto de GoTrue de un tipo, con el mismo condicional de idioma. */
export function goTrueSubject(kind: AuthEmailKind): string {
  return byLocale((locale) => TEXTS[kind][locale].subject);
}

/** Un email de un idioma con los valores reales (el hook de envío de PR19). Los valores se escapan acá. */
export function renderAuthEmail(kind: AuthEmailKind, locale: Locale, values: { token?: string; tokenHash?: string } = {}): { subject: string; html: string } {
  const body = cardBody(kind, locale, { token: escapeHtml(values.token ?? ""), tokenHash: encodeURIComponent(values.tokenHash ?? "") });
  return { subject: TEXTS[kind][locale].subject, html: page(locale, body, "") };
}
