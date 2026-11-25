import { describe, expect, it } from "vitest";
import { dishMatches, filterDishes, normalizeText, queryWords, type SearchableDish } from "./menu-search.ts";

type Extra = { es?: [string, string]; en?: [string, string]; diet?: SearchableDish["diet"]; seasonMonths?: number[]; ingredients?: string[] };

function dish(name: string, description: string, extra: Extra = {}): SearchableDish {
  return {
    name: { it: name, es: extra.es?.[0] ?? null, en: extra.en?.[0] ?? null },
    description: { it: description, es: extra.es?.[1] ?? null, en: extra.en?.[1] ?? null },
    diet: extra.diet ?? null,
    seasonMonths: extra.seasonMonths ?? null,
    ingredients: extra.ingredients ?? [],
  };
}

const LASAGNE = dish("Lasagne", "Ragù e besciamella.", { es: ["Lasaña", "Ragú y bechamel."], seasonMonths: [10, 11, 12] });
const MANZO = dish("Brasato di manzo", "Cotto lentamente nel vino rosso.", { es: ["Estofado de res", "Cocido en vino tinto."], en: ["Braised beef", "Slow cooked."] });
const MAIALE = dish("Arrosto di maiale", "Con patate al forno.", { es: ["Asado de cerdo", "Con patatas."], en: ["Roast pork", "With potatoes."] });
const SALSICCIA = dish("Pasta con salsiccia", "Salsiccia e friarielli.", { es: ["Pasta con salchicha", "Con brócoli."], en: ["Pasta with sausage", "With rapini."] });
const AGNELLO = dish("Agnello al forno", "Con rosmarino.", { es: ["Cordero al horno", "Con romero."], en: ["Roast lamb", "With rosemary."] });
const VITELLO = dish("Vitello tonnato", "Fette sottili.", { es: ["Ternera con salsa de atún", "Fetas finas."], en: ["Veal with tuna sauce", "Thin slices."] });
const POLLO = dish("Pollo alla cacciatora", "Con olive e pomodoro.", { es: ["Pollo a la cazadora", "Con aceitunas."], en: ["Hunter's chicken", "With olives."] });
const TACCHINO = dish("Tacchino arrosto", "Ripieno di castagne.", { es: ["Pavo asado", "Relleno de castañas."], en: ["Roast turkey", "Stuffed with chestnuts."] });
const BRANZINO = dish("Branzino al forno", "Con limone.", { es: ["Lubina al horno", "Con limón."], en: ["Baked sea bass", "With lemon."] });
const MERLUZZO = dish("Merluzzo in umido", "Con pomodorini.", { es: ["Merluza guisada", "Con tomatitos."], en: ["Stewed cod", "With cherry tomatoes."] });
const GAMBERI = dish("Risotto ai gamberi", "Cremoso.", { es: ["Risotto de gambas", "Cremoso."], en: ["Prawn risotto", "Creamy."] });
const PARMIGIANA = dish("Parmigiana di melanzane", "Con mozzarella.", {
  es: ["Parmigiana de berenjena", "Con mozzarella."],
  en: ["Eggplant parmigiana", "With mozzarella."],
  diet: "vegetarian",
  seasonMonths: [6, 7, 8, 9],
});
const MINESTRONE = dish("Minestrone", "Verdure di stagione.", {
  es: ["Minestrone", "Verduras de temporada."],
  en: ["Minestrone soup", "Seasonal vegetables."],
  diet: "vegan",
});
const ZUCCHINE = dish("Zucchine ripiene", "Al forno.", { es: ["Calabacines rellenos", "Al horno."], en: ["Stuffed zucchini", "Baked."], seasonMonths: [6, 7, 8] });
const PANZANELLA = dish("Panzanella", "Pane, pomodoro e basilico.", { diet: "vegetarian", seasonMonths: [6, 7, 8] });
const ZUPPA = dish("Zuppa di cipolle", "Con crostini.", { seasonMonths: [12, 1, 2] });
const PRIMAVERA = dish("Pasta primavera", "Con verdure.");
const FRITTELLE = dish("Frittelle", "Dolci.", { seasonMonths: [2, 3] });
const ALL = [LASAGNE, MANZO, MAIALE, SALSICCIA, AGNELLO, VITELLO, POLLO, TACCHINO, BRANZINO, MERLUZZO, GAMBERI, PARMIGIANA, MINESTRONE, ZUCCHINE, PANZANELLA, ZUPPA, PRIMAVERA, FRITTELLE];

const names = (query: string): string[] => filterDishes(ALL, query).map((d) => d.name.it).sort();
const sorted = (list: SearchableDish[]): string[] => list.map((d) => d.name.it).sort();

describe("normalizeText y queryWords", () => {
  it("minúsculas, sin acentos, sin puntuación y con los espacios colapsados", () => {
    expect(normalizeText("  Ragù   e  Besciamella. ")).toBe("ragu e besciamella");
    expect(normalizeText("Otoño, Ñoquis")).toBe("otono noquis");
  });
  it("separa la consulta en palabras", () => {
    expect(queryWords("  Pollo   verano ")).toEqual(["pollo", "verano"]);
    expect(queryWords("   ")).toEqual([]);
  });
});

describe("búsqueda por nombre y descripción", () => {
  it("consulta vacía o en blanco: todos", () => {
    expect(filterDishes(ALL, "")).toHaveLength(ALL.length);
    expect(filterDishes(ALL, "   ")).toHaveLength(ALL.length);
  });
  it("encuentra por nombre y descripción, parcial y sin acentos ni mayúsculas", () => {
    expect(names("LASA")).toEqual(["Lasagne"]);
    expect(names("ragu")).toEqual(["Lasagne"]);
    expect(names("rosmarino")).toEqual(["Agnello al forno"]);
  });
  it("en cualquiera de los tres idiomas, sea cual sea el de la página", () => {
    expect(names("lasaña")).toEqual(["Lasagne"]);
    expect(names("braised")).toEqual(["Brasato di manzo"]);
    expect(names("estofado")).toEqual(["Brasato di manzo"]);
  });
  it("todas las palabras deben coincidir (Y)", () => {
    expect(names("pasta salsiccia")).toEqual(["Pasta con salsiccia"]);
    expect(names("lasagne pollo")).toEqual([]);
  });
  it("plural: con 5 letras o más también prueba sin la última", () => {
    expect(dishMatches(MINESTRONE, "verduras")).toBe(true);
    expect(dishMatches(POLLO, "polli")).toBe(true);
    expect(dishMatches(POLLO, "pollos")).toBe(true);
    expect(dishMatches(ZUCCHINE, "zucchini")).toBe(true);
    // Con 4 letras o menos no hay tolerancia: no ensancha de más.
    expect(dishMatches(dish("Pane", "Fresco."), "pani")).toBe(false);
  });
  it("nada coincide: vacío", () => {
    expect(names("sushi")).toEqual([]);
  });
});

describe("categorías", () => {
  it("carne: vacuno, cerdo, ternera, cordero y embutidos, en las tres lenguas", () => {
    const meat = [MANZO, MAIALE, SALSICCIA, AGNELLO, VITELLO];
    for (const word of ["carne", "carni", "carnes", "meat"]) expect(names(word)).toEqual(sorted(meat));
  });
  it("carne: cada palabra suelta, en italiano, español o inglés", () => {
    const words = [
      "Manzo", "Maiale", "Vitello", "Agnello", "Salsiccia", "Salsicce", "Res", "Vacuno", "Ternera", "Cerdo", "Cordero", "Salchicha",
      "Beef", "Pork", "Veal", "Lamb", "Sausage", "Sausages",
    ];
    for (const word of words) expect(dishMatches(dish("Plato", `Con ${word} y papas.`), "carne")).toBe(true);
  });
  it("carne no incluye aves ni pescado ni verduras, y «res» solo cuenta entera", () => {
    for (const d of [LASAGNE, POLLO, TACCHINO, BRANZINO, MINESTRONE, PANZANELLA]) expect(dishMatches(d, "carne")).toBe(false);
    expect(dishMatches(dish("Pane fresco", "Pressato."), "carne")).toBe(false);
  });
  it("pollo / chicken: incluye también el pavo (tacchino, turkey), decisión documentada", () => {
    for (const word of ["pollo", "polli", "chicken", "pollame", "poultry"]) {
      expect(dishMatches(POLLO, word)).toBe(true);
      expect(dishMatches(TACCHINO, word)).toBe(true);
      expect(dishMatches(MANZO, word)).toBe(false);
    }
  });
  it("pesce / pescado / fish", () => {
    for (const word of ["pesce", "pesci", "pescado", "fish", "mariscos", "seafood"]) {
      for (const d of [BRANZINO, MERLUZZO, GAMBERI]) expect(dishMatches(d, word)).toBe(true);
      for (const d of [MANZO, POLLO, MINESTRONE, LASAGNE]) expect(dishMatches(d, word)).toBe(false);
    }
  });
  it("verdura / verdure / vegetales / vegetables: dieta vegetariana o vegana y palabras de verduras", () => {
    for (const word of ["verdura", "verdure", "verduras", "vegetales", "vegetables", "veggies"]) {
      for (const d of [MINESTRONE, PARMIGIANA, PANZANELLA, ZUCCHINE]) expect(dishMatches(d, word)).toBe(true);
      for (const d of [MANZO, POLLO, BRANZINO, LASAGNE, MAIALE]) expect(dishMatches(d, word)).toBe(false);
    }
  });
  it("verdura: palabras sueltas de verduras en los tres idiomas", () => {
    for (const word of ["zucchine", "melanzane", "spinaci", "calabacin", "berenjena", "espinacas", "eggplant", "spinach", "cabbage"]) {
      expect(dishMatches(dish("Plato", `Con ${word}.`), "verdura")).toBe(true);
    }
  });
});

describe("dieta", () => {
  it("vegetariano incluye también los veganos; vegano solo los veganos", () => {
    for (const word of ["vegetariano", "vegetariana", "vegetarian", "vegetariani"]) {
      expect(names(word)).toEqual(sorted([PANZANELLA, PARMIGIANA, MINESTRONE]));
    }
    for (const word of ["vegano", "vegana", "vegan", "veganos"]) expect(names(word)).toEqual(["Minestrone"]);
  });
});

describe("temporada", () => {
  it("verano / estate / summer: los de junio a agosto", () => {
    for (const word of ["verano", "estate", "summer"]) expect(names(word)).toEqual(sorted([PANZANELLA, PARMIGIANA, ZUCCHINE]));
  });
  it("invierno / inverno / winter: los que tocan diciembre, enero o febrero", () => {
    for (const word of ["invierno", "inverno", "winter"]) expect(names(word)).toEqual(sorted([LASAGNE, ZUPPA, FRITTELLE]));
  });
  it("otoño / autunno / autumn / fall: los que tocan septiembre a noviembre", () => {
    for (const word of ["otoño", "autunno", "autumn", "fall"]) expect(names(word)).toEqual(sorted([LASAGNE, PARMIGIANA]));
  });
  it("primavera / spring: los que tocan marzo a mayo", () => {
    expect(names("spring")).toEqual(["Frittelle"]);
    // «primavera» también está en el nombre de «Pasta primavera»: esa sale por el texto, no por los meses.
    expect(names("primavera")).toEqual(sorted([FRITTELLE, PRIMAVERA]));
  });
  it("un plato de todo el año (null) no responde a una estación", () => {
    expect(dishMatches(MINESTRONE, "invierno")).toBe(false);
    expect(dishMatches(MANZO, "summer")).toBe(false);
  });
  it("se combina con otras palabras (Y)", () => {
    expect(names("verano vegetariano")).toEqual(sorted([PANZANELLA, PARMIGIANA]));
    expect(names("verano carne")).toEqual([]);
  });
});

describe("ingredientes (solo para buscar)", () => {
  const CHILI = dish("Chili", "Un plato de olla.", { ingredients: ["Carne de res", "Frijoles", "Cebolla"] });
  const RAGU = dish("Ragù bianco", "Lento.", { ingredients: ["Cerdo", "Zanahoria", "Vino blanco"] });
  const CREMA = dish("Crema", "Suave.", { ingredients: ["Calabacines", "Papa"] });
  const SIN = dish("Pan", "Crujiente.");
  const LIST = [CHILI, RAGU, CREMA, SIN];
  const found = (query: string): string[] => filterDishes(LIST, query).map((d) => d.name.it);

  it("una palabra que está en un ingrediente encuentra el plato, sin acentos ni mayúsculas", () => {
    expect(found("frijoles")).toEqual(["Chili"]);
    expect(found("ZANAHORIA")).toEqual(["Ragù bianco"]);
    expect(found("vino")).toEqual(["Ragù bianco"]);
  });
  it("con la tolerancia al plural de siempre", () => {
    expect(found("cebollas")).toEqual(["Chili"]);
    expect(found("frijol")).toEqual(["Chili"]);
  });
  it("las categorías valen para los ingredientes: «carne» encuentra «carne de res» y «cerdo»", () => {
    expect(found("carne")).toEqual(["Chili", "Ragù bianco"]);
    expect(found("meat")).toEqual(["Chili", "Ragù bianco"]);
    expect(found("verdura")).toEqual(["Chili", "Ragù bianco", "Crema"]);
    expect(dishMatches(CREMA, "carne")).toBe(false);
  });
  it("se combina con las demás palabras (Y) y un plato sin ingredientes sigue buscándose por su texto", () => {
    expect(found("carne cebolla")).toEqual(["Chili"]);
    expect(found("crujiente")).toEqual(["Pan"]);
    expect(found("papa")).toEqual(["Crema"]);
  });
});
