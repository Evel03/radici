// Tests del mensaje de plantilla de WhatsApp Cloud API. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  WHATSAPP_GRAPH_VERSION,
  buildTemplateMessage,
  sendWhatsAppTemplate,
  whatsAppConfigFrom,
  type WhatsAppConfig,
} from "./whatsapp.ts";

const CONFIG: WhatsAppConfig = { token: "EAAtest", phoneNumberId: "106540352242922", template: "richiesta_ricevuta" };

function env(values: Record<string, string>): (name: string) => string | undefined {
  return (name) => values[name];
}

test("config: solo con token, phone number id y plantilla", () => {
  assert.deepEqual(
    whatsAppConfigFrom(env({ WHATSAPP_TOKEN: " EAAtest ", WHATSAPP_PHONE_NUMBER_ID: "106540352242922", WHATSAPP_TEMPLATE: "richiesta_ricevuta" })),
    CONFIG,
  );
  assert.equal(whatsAppConfigFrom(env({ WHATSAPP_TOKEN: "EAAtest", WHATSAPP_PHONE_NUMBER_ID: "1" })), null);
  assert.equal(whatsAppConfigFrom(env({ WHATSAPP_PHONE_NUMBER_ID: "1", WHATSAPP_TEMPLATE: "t" })), null);
  assert.equal(whatsAppConfigFrom(env({ WHATSAPP_TOKEN: "x", WHATSAPP_PHONE_NUMBER_ID: "no-numérico", WHATSAPP_TEMPLATE: "t" })), null);
  assert.equal(whatsAppConfigFrom(env({})), null);
});

test("arma la llamada a la Graph API con la plantilla en el idioma del cliente y el nombre de pila", () => {
  const request = buildTemplateMessage(CONFIG, { to: "+393331234567", locale: "es", firstName: "Giulia" });
  assert.equal(WHATSAPP_GRAPH_VERSION, "v26.0");
  assert.equal(request.url, "https://graph.facebook.com/v26.0/106540352242922/messages");
  assert.equal(request.init.method, "POST");
  assert.equal(request.init.headers["Authorization"], "Bearer EAAtest");
  assert.equal(request.init.headers["Content-Type"], "application/json");
  assert.deepEqual(JSON.parse(request.init.body), {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to: "+393331234567",
    type: "template",
    template: {
      name: "richiesta_ricevuta",
      language: { code: "es" },
      components: [{ type: "body", parameters: [{ type: "text", parameter_name: "first_name", text: "Giulia" }] }],
    },
  });
});

test("sin nombre de pila usable, el parámetro va con un guion (la plantilla lo exige)", () => {
  const request = buildTemplateMessage(CONFIG, { to: "+393331234567", locale: "it", firstName: "" });
  const body = JSON.parse(request.init.body) as { template: { components: Array<{ parameters: Array<{ text: string }> }> } };
  assert.equal(body.template.components[0]?.parameters[0]?.text, "-");
});

test("envío: devuelve el id del mensaje; ante un error, solo el código (sin el mensaje)", async () => {
  const ok = (async () =>
    Response.json({ messaging_product: "whatsapp", contacts: [{ input: "+39", wa_id: "39" }], messages: [{ id: "wamid.ABC" }] })) as typeof fetch;
  assert.deepEqual(await sendWhatsAppTemplate(CONFIG, { to: "+393331234567", locale: "it", firstName: "Giulia" }, { fetch: ok }), {
    ok: true,
    id: "wamid.ABC",
  });

  const failing = (async () =>
    Response.json(
      { error: { message: "(#132001) Template name does not exist in the translation", type: "OAuthException", code: 132001, fbtrace_id: "x" } },
      { status: 404 },
    )) as typeof fetch;
  assert.deepEqual(await sendWhatsAppTemplate(CONFIG, { to: "+393331234567", locale: "it", firstName: "Giulia" }, { fetch: failing }), {
    ok: false,
    status: 404,
    errorName: "132001",
  });

  const down = (async () => {
    throw new TypeError("fetch failed");
  }) as typeof fetch;
  assert.deepEqual(await sendWhatsAppTemplate(CONFIG, { to: "+393331234567", locale: "it", firstName: "Giulia" }, { fetch: down }), {
    ok: false,
    status: null,
    errorName: "network",
  });
});
