import { describe, expect, it } from "vitest";
import { find, findAll, h, mount, textOf, toHtml, type DocumentLike } from "./vdom.ts";

describe("h y toHtml", () => {
  it("atributos: false/null/undefined no van, true vacío, números como texto; hijos aplanados", () => {
    const node = h("button", { type: "button", disabled: true, hidden: false, title: null, "data-week": 2 }, "Ok", [null, h("span", {}, "!")], false);
    expect(toHtml(node)).toBe('<button type="button" disabled data-week="2">Ok<span>!</span></button>');
  });

  it("escapa los textos y los valores de los atributos", () => {
    const node = h("p", { title: '"><script>' }, "<img src=x onerror=alert(1)> & co");
    expect(toHtml(node)).toBe('<p title="&quot;&gt;&lt;script&gt;">&lt;img src=x onerror=alert(1)&gt; &amp; co</p>');
  });

  it("no acepta atributos on* ni nombres raros; src y href solo con http(s), una ruta propia o #", () => {
    expect(() => h("img", { onerror: "alert(1)" })).toThrow(/onerror/);
    expect(() => h("p", { "a b": "x" })).toThrow();
    expect(() => h("scr ipt")).toThrow();
    expect(toHtml(h("a", { href: "javascript:alert(1)" }, "x"))).toBe("<a>x</a>");
    expect(toHtml(h("a", { href: "//evil.example/" }, "x"))).toBe("<a>x</a>");
    expect(toHtml(h("img", { src: "data:image/png;base64,AAAA" }))).toBe("<img>");
    expect(toHtml(h("a", { href: "/" }, "x"))).toBe('<a href="/">x</a>');
    expect(toHtml(h("img", { src: "https://abcdefgh.supabase.co/x.jpg", alt: "" }))).toBe('<img src="https://abcdefgh.supabase.co/x.jpg" alt>');
  });

  it("textOf, find y findAll recorren el árbol", () => {
    const tree = h("div", {}, h("p", { class: "a" }, "uno ", h("b", {}, "dos")), h("p", { class: "a" }, "tres"));
    expect(textOf(tree)).toBe("uno dostres");
    expect(find(tree, (n) => n.tag === "b")?.children).toEqual(["dos"]);
    expect(findAll(tree, (n) => n.attrs["class"] === "a")).toHaveLength(2);
    expect(find(tree, (n) => n.tag === "table")).toBeNull();
  });
});

describe("mount", () => {
  /** Un documento mínimo que registra lo que se crea. */
  function fakeDocument(): { doc: DocumentLike; html: (node: Node) => string } {
    interface FakeNode {
      tag?: string;
      text?: string;
      attrs: Array<[string, string]>;
      children: FakeNode[];
    }
    const element = (tag: string): FakeNode & Record<string, unknown> => {
      const node: FakeNode & Record<string, unknown> = { tag, attrs: [], children: [] };
      node["setAttribute"] = (name: string, value: string) => node.attrs.push([name, value]);
      node["appendChild"] = (child: FakeNode) => node.children.push(child);
      // Si mount usara innerHTML, el test lo vería.
      Object.defineProperty(node, "innerHTML", {
        set: () => {
          throw new Error("innerHTML");
        },
      });
      return node;
    };
    const serialize = (node: FakeNode): string =>
      node.tag === undefined
        ? `[${node.text ?? ""}]`
        : `<${node.tag}${node.attrs.map(([k, v]) => ` ${k}=${v}`).join("")}>${node.children.map(serialize).join("")}</${node.tag}>`;
    return {
      doc: {
        createElement: (tag) => element(tag) as unknown as Element,
        createTextNode: (text) => ({ text, attrs: [], children: [] }) as unknown as Text,
      },
      html: (node) => serialize(node as unknown as FakeNode),
    };
  }

  it("crea elementos, atributos y nodos de texto (un texto con HTML queda como texto)", () => {
    const { doc, html } = fakeDocument();
    const node = mount(h("li", { class: "dish" }, h("p", {}, "<b>Lasagne</b>")), doc);
    expect(html(node)).toBe("<li class=dish><p>[<b>Lasagne</b>]</p></li>");
  });
});
