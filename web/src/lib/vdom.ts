// Árbol de elementos como datos: la página lo arma con funciones puras (testeables en Node, sin DOM) y mount()
// lo convierte en nodos reales con createElement, setAttribute y nodos de texto. Nunca innerHTML: un texto
// que llega de afuera (el nombre de un plato, la nota de Evelyn) siempre queda como texto. toHtml() es para
// los tests (y para ver el resultado): escapa todo.
// Además, por las dudas: los atributos on* no se aceptan, y src/href solo llevan http(s), una ruta propia o #.

export type AttrValue = string | number | boolean | null | undefined;
export type Child = VNode | string | null | undefined | false;

export interface VNode {
  readonly tag: string;
  readonly attrs: Readonly<Record<string, string>>;
  readonly children: ReadonlyArray<VNode | string>;
}

const NAME_PATTERN = /^[a-z][a-z0-9-]*$/;
const URL_ATTRS = new Set(["src", "href", "action", "formaction"]);
const SAFE_URL = /^(https?:\/\/|\/(?!\/)|#|\?)/i;
const VOID_TAGS = new Set(["img", "br", "hr", "input", "meta", "link"]);

/**
 * Un elemento. Atributos: false, null y undefined no van; true va vacío (booleano); los números, como texto.
 * Hijos: textos y elementos (también listas); false, null y undefined no van.
 */
export function h(tag: string, attrs: Readonly<Record<string, AttrValue>> = {}, ...children: Array<Child | Child[]>): VNode {
  if (!NAME_PATTERN.test(tag)) throw new Error(`Etiqueta no válida: ${tag}`);
  const out: Record<string, string> = {};
  for (const [name, value] of Object.entries(attrs)) {
    if (!NAME_PATTERN.test(name) || name.startsWith("on")) throw new Error(`Atributo no permitido: ${name}`);
    if (value === false || value === null || value === undefined) continue;
    const text = value === true ? "" : String(value);
    if (URL_ATTRS.has(name) && !SAFE_URL.test(text)) continue;
    out[name] = text;
  }
  const flat: Array<VNode | string> = [];
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    flat.push(child);
  }
  return { tag, attrs: out, children: flat };
}

const ESCAPES: Readonly<Record<string, string>> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

function escape(value: string): string {
  return value.replace(/[&<>"']/g, (char) => ESCAPES[char] ?? char);
}

/** HTML del árbol, con todo escapado (para los tests). */
export function toHtml(node: VNode | string): string {
  if (typeof node === "string") return escape(node);
  const attrs = Object.entries(node.attrs)
    .map(([name, value]) => (value === "" ? ` ${name}` : ` ${name}="${escape(value)}"`))
    .join("");
  if (VOID_TAGS.has(node.tag)) return `<${node.tag}${attrs}>`;
  return `<${node.tag}${attrs}>${node.children.map(toHtml).join("")}</${node.tag}>`;
}

/** El texto del árbol, como textContent (para los tests). */
export function textOf(node: VNode | string): string {
  return typeof node === "string" ? node : node.children.map(textOf).join("");
}

/** El primer elemento (en profundidad) que cumple la condición, o null (para los tests). */
export function find(node: VNode | string, test: (node: VNode) => boolean): VNode | null {
  if (typeof node === "string") return null;
  if (test(node)) return node;
  for (const child of node.children) {
    const found = find(child, test);
    if (found) return found;
  }
  return null;
}

/** Todos los elementos que cumplen la condición, en orden (para los tests). */
export function findAll(node: VNode | string, test: (node: VNode) => boolean, out: VNode[] = []): VNode[] {
  if (typeof node === "string") return out;
  if (test(node)) out.push(node);
  for (const child of node.children) findAll(child, test, out);
  return out;
}

/** Lo que mount necesita del documento (en el navegador, document). */
export interface DocumentLike {
  createElement(tag: string): Element;
  createTextNode(text: string): Text;
}

/** Nodos reales del árbol: createElement, setAttribute y nodos de texto. */
export function mount(node: VNode | string, doc: DocumentLike): Node {
  if (typeof node === "string") return doc.createTextNode(node);
  const el = doc.createElement(node.tag);
  for (const [name, value] of Object.entries(node.attrs)) el.setAttribute(name, value);
  for (const child of node.children) el.appendChild(mount(child, doc));
  return el;
}
