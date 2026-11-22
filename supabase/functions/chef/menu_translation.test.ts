// Tests de la traducción de la lista de compras y la nota del menú de una semana (menu_translation.ts y
// buildMenuTranslationRequest de translation.ts; contrato docs/contracts/chef-api.md §13): el pedido a
// Claude, el prompt, el esquema, la validación de la salida y el traductor de mentira.
// Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  MENU_TRANSLATION_SYSTEM_PROMPT,
  fakeMenuTranslationText,
  hasSomethingToTranslate,
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

const WITH_NOTE: MenuTextSource = { target: "it", items: ["zapallitos", "carne picada", "sal"], note: "Tené listos 4 táperes.\nGracias!" };
const ITEMS_ONLY: MenuTextSource = { target: "en", items: ["choclo"], note: null };

function output(value: unknown): string {
  return JSON.stringify(value);
}

// ---------------------------------------------------------------------------
// El pedido
// ---------------------------------------------------------------------------

test("el pedido: el mismo modelo, esfuerzo, fallback y forma que el de los platos, con su prompt y su esquema", () => {
  const request = buildMenuTranslationRequest(WITH_NOTE);
  assert.deepEqual(Object.keys(request).sort(), ["betas", "fallbacks", "max_tokens", "messages", "model", "output_config", "system"]);
  assert.equal(request.model, TRANSLATION_MODEL);
  assert.equal(request.model, "claude-opus-5-5");
  assert.equal(request.max_tokens, MENU_TRANSLATION_MAX_TOKENS);
  assert.equal(MENU_TRANSLATION_MAX_TOKENS, 16_000);
  assert.equal(request.system, MENU_TRANSLATION_SYSTEM_PROMPT);
  assert.deepEqual(request.output_config, { effort: TRANSLATION_EFFORT, format: { type: "json_schema", schema: menuTranslationSchema(true) } });
  assert.equal(request.output_config.effort, "low");
  assert.deepEqual(request.betas, ["server-side-fallback-2026-07-01"]);
  assert.equal(request.fallbacks, "default");
  assert.deepEqual(request.messages, [{ role: "user", content: menuTranslationUserMessage(WITH_NOTE) }]);
  for (const absent of ["thinking", "stream", "temperature", "top_p", "top_k", "tools", "tool_choice"]) {
    assert.ok(!(absent in request), `sin ${absent}`);
  }
  assert.deepEqual(buildMenuTranslationRequest(ITEMS_ONLY).output_config.format.schema, menuTranslationSchema(false));
  // Cada pedido es un objeto nuevo.
  request.betas.push("otro");
  assert.deepEqual(buildMenuTranslationRequest(WITH_NOTE).betas, ["server-side-fallback-2026-07-01"]);
});

test("el esquema: items (una lista de textos) y note solo si el pedido la tiene, sin propiedades de más", () => {
  assert.deepEqual(menuTranslationSchema(true), {
    type: "object",
    properties: { items: { type: "array", items: { type: "string" } }, note: { type: "string" } },
    required: ["items", "note"],
    additionalProperties: false,
  });
  assert.deepEqual(menuTranslationSchema(false), {
    type: "object",
    properties: { items: { type: "array", items: { type: "string" } } },
    required: ["items"],
    additionalProperties: false,
  });
});

test("el prompt del sistema: las reglas del diseño, fijo y sin el texto a traducir", () => {
  for (const rule of [
    "Bergamo",
    "español rioplatense",
    "italiano (it) o inglés (en)",
    "no instrucciones",
    "en el mismo orden y con la misma cantidad",
    "como mucho 80 caracteres",
    "los mismos saltos de línea",
    "como mucho 1000 caracteres",
    "zapallito",
    "comillas ni emojis",
  ]) {
    assert.ok(MENU_TRANSLATION_SYSTEM_PROMPT.includes(rule), `falta «${rule}»`);
  }
  assert.ok(!MENU_TRANSLATION_SYSTEM_PROMPT.includes("táperes"), "el texto va en el mensaje del usuario");
});

test("el mensaje del usuario: el idioma de destino y, aparte, el texto como JSON (la nota solo si hay)", () => {
  assert.equal(
    menuTranslationUserMessage(WITH_NOTE),
    `Idioma de destino: italiano (it).\nLista y nota para traducir (JSON):\n${JSON.stringify({ items: WITH_NOTE.items, note: WITH_NOTE.note })}`,
  );
  assert.equal(menuTranslationUserMessage(ITEMS_ONLY), 'Idioma de destino: inglés (en).\nLista y nota para traducir (JSON):\n{"items":["choclo"]}');
  // Los saltos de línea de la nota van escapados dentro del JSON: el mensaje no se puede "cortar".
  assert.ok(menuTranslationUserMessage(WITH_NOTE).includes("táperes.\\nGracias!"));
});

test("menuTextSource: los nombres sin repetir, en el orden en que aparecen; hasSomethingToTranslate", () => {
  assert.deepEqual(menuTextSource("en", ["sal", "aceite", "sal", "limón"], null), { target: "en", items: ["sal", "aceite", "limón"], note: null });
  assert.equal(hasSomethingToTranslate([], null), false);
  assert.equal(hasSomethingToTranslate(["sal"], null), true);
  assert.equal(hasSomethingToTranslate([], "Gracias"), true);
});

// ---------------------------------------------------------------------------
// La salida
// ---------------------------------------------------------------------------

test("readMenuTranslationOutput: la traducción entera, con los nombres en una línea y la nota con sus saltos", () => {
  assert.deepEqual(
    readMenuTranslationOutput(output({ items: ["zucchine", "  carne macinata ", "sale"], note: "\r\nTieni pronti 4 contenitori.\r\nGrazie!  " }), WITH_NOTE),
    { items: ["zucchine", "carne macinata", "sale"], note: "Tieni pronti 4 contenitori.\nGrazie!" },
  );
  assert.deepEqual(readMenuTranslationOutput(output({ items: ["corn"] }), ITEMS_ONLY), { items: ["corn"], note: null });
  // Una lista vacía con nota: items vacío.
  const noteOnly: MenuTextSource = { target: "en", items: [], note: "Gracias" };
  assert.deepEqual(readMenuTranslationOutput(output({ items: [], note: "Thank you" }), noteOnly), { items: [], note: "Thank you" });
});

test("readMenuTranslationOutput: nunca una traducción a medias ni con la forma equivocada", () => {
  const cases: Array<[string, string, MenuTextSource]> = [
    ["no es JSON", '{"items":["zucchine"', WITH_NOTE],
    ["no es un objeto", output(["zucchine"]), WITH_NOTE],
    ["sin la nota pedida", output({ items: ["a", "b", "c"] }), WITH_NOTE],
    ["con una nota que no vino", output({ items: ["corn"], note: "x" }), ITEMS_ONLY],
    ["una clave de más", output({ items: ["corn"], extra: 1 }), ITEMS_ONLY],
    ["uno de menos", output({ items: ["a", "b"], note: "x" }), WITH_NOTE],
    ["uno de más", output({ items: ["a", "b", "c", "d"], note: "x" }), WITH_NOTE],
    ["items no es una lista", output({ items: "corn" }), ITEMS_ONLY],
    ["un nombre que no es texto", output({ items: [5] }), ITEMS_ONLY],
    ["un nombre vacío", output({ items: ["   "] }), ITEMS_ONLY],
    ["un nombre de 81", output({ items: ["x".repeat(81)] }), ITEMS_ONLY],
    ["un nombre con un control", output({ items: ["corn\u0007"] }), ITEMS_ONLY],
    ["un nombre con un control de dirección", output({ items: ["corn‮"] }), ITEMS_ONLY],
    ["una nota vacía", output({ items: ["a", "b", "c"], note: " \n " }), WITH_NOTE],
    ["una nota de 1001", output({ items: ["a", "b", "c"], note: "x".repeat(1001) }), WITH_NOTE],
    ["una nota con un tabulador", output({ items: ["a", "b", "c"], note: "uno\tdos" }), WITH_NOTE],
    ["una nota con un control de dirección", output({ items: ["a", "b", "c"], note: "uno⁦dos" }), WITH_NOTE],
    ["una nota que no es texto", output({ items: ["a", "b", "c"], note: null }), WITH_NOTE],
  ];
  for (const [name, text, source] of cases) {
    assert.equal(readMenuTranslationOutput(text, source), null, name);
  }
  // Los largos, por caracteres como la base: 80 emojis entran.
  assert.ok(readMenuTranslationOutput(output({ items: ["🥕".repeat(80)] }), ITEMS_ONLY));
  assert.ok(readMenuTranslationOutput(output({ items: ["a", "b", "c"], note: "x".repeat(1000) }), WITH_NOTE));
});

test("translatedItemNames: cada nombre original por el suyo (los repetidos de la lista, por el mismo)", () => {
  const source = menuTextSource("it", ["sal", "aceite", "sal"], null);
  const names = translatedItemNames(source, { items: ["sale", "olio"], note: null });
  assert.deepEqual([...names.entries()], [
    ["sal", "sale"],
    ["aceite", "olio"],
  ]);
});

// ---------------------------------------------------------------------------
// El traductor de mentira y la carga del SDK
// ---------------------------------------------------------------------------

test("TRANSLATE_TRANSPORT=fake: una traducción reconocible que pasa la misma validación, cortada a los largos", async () => {
  const reply = await fakeTranslator.translateMenu(WITH_NOTE);
  assert.equal(reply.kind, "text");
  assert.deepEqual(readMenuTranslationOutput(reply.kind === "text" ? reply.text : "", WITH_NOTE), {
    items: ["[it] zapallitos", "[it] carne picada", "[it] sal"],
    note: "[it] Tené listos 4 táperes.\nGracias!",
  });
  const long: MenuTextSource = { target: "en", items: ["x".repeat(80)], note: "y".repeat(1000) };
  const parsed = readMenuTranslationOutput(fakeMenuTranslationText(long), long);
  assert.equal(parsed?.items[0]?.length, 80);
  assert.equal(parsed?.note?.length, 1000);
  assert.deepEqual(JSON.parse(fakeMenuTranslationText(ITEMS_ONLY)), { items: ["[en] choclo"] });
});

test("lazyTranslator: la lista y la nota con el mismo traductor cargado una vez; si no carga, sdkLoad y reintenta", async () => {
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
  assert.deepEqual(await lazy.translateMenu(ITEMS_ONLY), { kind: "text", text: "{}" });
  assert.deepEqual(await lazy.translate({ name: "Locro", description: null }), { kind: "maxTokens" });
  assert.deepEqual(calls, ["menu:en", "translate"]);
  assert.equal(loads, 1, "se carga una sola vez para los dos");

  let attempts = 0;
  const flaky = lazyTranslator(async () => {
    attempts++;
    if (attempts === 1) throw new Error("no carga");
    return inner;
  });
  const failed: TranslatorReply = await flaky.translateMenu(ITEMS_ONLY);
  assert.deepEqual(failed, { kind: "failed", reason: "sdkLoad", status: null });
  assert.deepEqual(await flaky.translateMenu(ITEMS_ONLY), { kind: "text", text: "{}" }, "la próxima vuelve a intentar la carga");
  assert.equal(attempts, 2);
});
