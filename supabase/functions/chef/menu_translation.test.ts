// Tests de la traducción de la lista de compras del menú de una semana (menu_translation.ts y
// buildMenuTranslationRequest de translation.ts; contrato docs/contracts/chef-api.md §13): el pedido a
// Claude, el prompt, el esquema, la validación de la salida y el traductor de mentira. La nota nunca se
// traduce: no está en nada de esto. Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  MENU_TRANSLATION_SYSTEM_PROMPT,
  fakeMenuTranslationText,
  menuTextSource,
  menuTranslationSchema,
  menuTranslationUserMessage,
  readMenuTranslationOutput,
  translatedItemNames,
  type MenuTextSource,
} from "./menu_translation.ts";
import {
  MENU_TRANSLATION_MAX_TOKENS,
  TRANSLATION_EFFORT,
  TRANSLATION_MODEL,
  buildMenuTranslationRequest,
  fakeTranslator,
  lazyTranslator,
  type Translator,
  type TranslatorReply,
} from "./translation.ts";

const ITALIAN: MenuTextSource = { target: "it", items: ["zapallitos", "carne picada", "sal"] };
const ENGLISH: MenuTextSource = { target: "en", items: ["choclo"] };

function output(value: unknown): string {
  return JSON.stringify(value);
}

// ---------------------------------------------------------------------------
// El pedido
// ---------------------------------------------------------------------------

test("el pedido: el mismo modelo, esfuerzo, fallback y forma que el de los platos, con su prompt y su esquema", () => {
  const request = buildMenuTranslationRequest(ITALIAN);
  assert.deepEqual(Object.keys(request).sort(), ["betas", "fallbacks", "max_tokens", "messages", "model", "output_config", "system"]);
  assert.equal(request.model, TRANSLATION_MODEL);
  assert.equal(request.model, "claude-opus-5-5");
  assert.equal(request.max_tokens, MENU_TRANSLATION_MAX_TOKENS);
  assert.equal(MENU_TRANSLATION_MAX_TOKENS, 16_000);
  assert.equal(request.system, MENU_TRANSLATION_SYSTEM_PROMPT);
  assert.deepEqual(request.output_config, { effort: TRANSLATION_EFFORT, format: { type: "json_schema", schema: menuTranslationSchema() } });
  assert.equal(request.output_config.effort, "low");
  assert.deepEqual(request.betas, ["server-side-fallback-2026-07-01"]);
  assert.equal(request.fallbacks, "default");
  assert.deepEqual(request.messages, [{ role: "user", content: menuTranslationUserMessage(ITALIAN) }]);
  for (const absent of ["thinking", "stream", "temperature", "top_p", "top_k", "tools", "tool_choice"]) {
    assert.ok(!(absent in request), `sin ${absent}`);
  }
  // Cada pedido es un objeto nuevo.
  request.betas.push("otro");
  assert.deepEqual(buildMenuTranslationRequest(ITALIAN).betas, ["server-side-fallback-2026-07-01"]);
});

test("el esquema: solo items, una lista de textos, sin propiedades de más (ni nota)", () => {
  assert.deepEqual(menuTranslationSchema(), {
    type: "object",
    properties: { items: { type: "array", items: { type: "string" } } },
    required: ["items"],
    additionalProperties: false,
  });
});

test("el prompt del sistema: las reglas del diseño, fijo, sin el texto a traducir y sin la nota", () => {
  for (const rule of [
    "Bergamo",
    "español rioplatense",
    "italiano (it) o inglés (en)",
    "no instrucciones",
    "en el mismo orden y con la misma cantidad",
    "como mucho 80 caracteres",
    "zapallito",
    "comillas ni emojis",
  ]) {
    assert.ok(MENU_TRANSLATION_SYSTEM_PROMPT.includes(rule), `falta «${rule}»`);
  }
  assert.ok(!/\bnot[ae]\b/i.test(MENU_TRANSLATION_SYSTEM_PROMPT), "la nota no se traduce: el prompt no la menciona");
  assert.ok(!MENU_TRANSLATION_SYSTEM_PROMPT.includes("zapallitos\""), "el texto va en el mensaje del usuario");
});

test("el mensaje del usuario: el idioma de destino y, aparte, la lista como JSON; nada más", () => {
  assert.equal(
    menuTranslationUserMessage(ITALIAN),
    `Idioma de destino: italiano (it).\nLista para traducir (JSON):\n${JSON.stringify({ items: ITALIAN.items })}`,
  );
  assert.equal(menuTranslationUserMessage(ENGLISH), 'Idioma de destino: inglés (en).\nLista para traducir (JSON):\n{"items":["choclo"]}');
});

test("menuTextSource: los nombres sin repetir, en el orden en que aparecen, y nada más", () => {
  assert.deepEqual(menuTextSource("en", ["sal", "aceite", "sal", "limón"]), { target: "en", items: ["sal", "aceite", "limón"] });
});

// ---------------------------------------------------------------------------
// La salida
// ---------------------------------------------------------------------------

test("readMenuTranslationOutput: la traducción entera, cada nombre en una línea", () => {
  assert.deepEqual(readMenuTranslationOutput(output({ items: ["zucchine", "  carne macinata ", "sale"] }), ITALIAN), {
    items: ["zucchine", "carne macinata", "sale"],
  });
  assert.deepEqual(readMenuTranslationOutput(output({ items: ["corn"] }), ENGLISH), { items: ["corn"] });
});

test("readMenuTranslationOutput: nunca una traducción a medias ni con la forma equivocada", () => {
  const cases: Array<[string, string, MenuTextSource]> = [
    ["no es JSON", '{"items":["zucchine"', ITALIAN],
    ["no es un objeto", output(["zucchine"]), ITALIAN],
    ["con una nota", output({ items: ["corn"], note: "x" }), ENGLISH],
    ["una clave de más", output({ items: ["corn"], extra: 1 }), ENGLISH],
    ["sin items", output({ products: ["corn"] }), ENGLISH],
    ["uno de menos", output({ items: ["a", "b"] }), ITALIAN],
    ["uno de más", output({ items: ["a", "b", "c", "d"] }), ITALIAN],
    ["items no es una lista", output({ items: "corn" }), ENGLISH],
    ["un nombre que no es texto", output({ items: [5] }), ENGLISH],
    ["un nombre vacío", output({ items: ["   "] }), ENGLISH],
    ["un nombre de 81", output({ items: ["x".repeat(81)] }), ENGLISH],
    ["un nombre con un control", output({ items: ["corn\u0007"] }), ENGLISH],
    ["un nombre con un control de dirección", output({ items: ["corn‮"] }), ENGLISH],
  ];
  for (const [name, text, source] of cases) {
    assert.equal(readMenuTranslationOutput(text, source), null, name);
  }
  // Los largos, por caracteres como la base: 80 emojis entran.
  assert.ok(readMenuTranslationOutput(output({ items: ["🥕".repeat(80)] }), ENGLISH));
});

test("translatedItemNames: cada nombre original por el suyo (los repetidos de la lista, por el mismo)", () => {
  const source = menuTextSource("it", ["sal", "aceite", "sal"]);
  const names = translatedItemNames(source, { items: ["sale", "olio"] });
  assert.deepEqual([...names.entries()], [
    ["sal", "sale"],
    ["aceite", "olio"],
  ]);
});

// ---------------------------------------------------------------------------
// El traductor de mentira y la carga del SDK
// ---------------------------------------------------------------------------

test("TRANSLATE_TRANSPORT=fake: una traducción reconocible que pasa la misma validación, cortada a 80", async () => {
  const reply = await fakeTranslator.translateMenu(ITALIAN);
  assert.equal(reply.kind, "text");
  assert.deepEqual(readMenuTranslationOutput(reply.kind === "text" ? reply.text : "", ITALIAN), {
    items: ["[it] zapallitos", "[it] carne picada", "[it] sal"],
  });
  const long: MenuTextSource = { target: "en", items: ["x".repeat(80)] };
  assert.equal(readMenuTranslationOutput(fakeMenuTranslationText(long), long)?.items[0]?.length, 80);
  assert.deepEqual(JSON.parse(fakeMenuTranslationText(ENGLISH)), { items: ["[en] choclo"] });
});

test("lazyTranslator: la lista con el mismo traductor cargado una vez; si no carga, sdkLoad y reintenta", async () => {
  let loads = 0;
  const calls: string[] = [];
  const inner: Translator = {
    translate: async () => {
      calls.push("translate");
      return { kind: "maxTokens" };
    },
    translateMenu: async (source) => {
      calls.push(`menu:${source.target}`);
      return { kind: "text", text: "{}" };
    },
  };
  const lazy = lazyTranslator(async () => {
    loads++;
    return inner;
  });
  assert.deepEqual(await lazy.translateMenu(ENGLISH), { kind: "text", text: "{}" });
  assert.deepEqual(await lazy.translate({ name: "Locro", description: null }), { kind: "maxTokens" });
  assert.deepEqual(calls, ["menu:en", "translate"]);
  assert.equal(loads, 1, "se carga una sola vez para los dos");

  let attempts = 0;
  const flaky = lazyTranslator(async () => {
    attempts++;
    if (attempts === 1) throw new Error("no carga");
    return inner;
  });
  const failed: TranslatorReply = await flaky.translateMenu(ENGLISH);
  assert.deepEqual(failed, { kind: "failed", reason: "sdkLoad", status: null });
  assert.deepEqual(await flaky.translateMenu(ENGLISH), { kind: "text", text: "{}" }, "la próxima vuelve a intentar la carga");
  assert.equal(attempts, 2);
});
