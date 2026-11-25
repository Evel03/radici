// Buscador de platos del formulario (pestaña «Menù»). Puro: decide si un plato responde a lo que escribió la
// clienta; menu.ts lo usa para filtrar y la página solo pinta.
// - Todo se normaliza igual (minúsculas, sin acentos, sin puntuación, espacios colapsados) y la consulta se parte
//   en palabras: todas deben coincidir (Y).
// - Una palabra coincide si es parte del nombre o la descripción en CUALQUIERA de los tres idiomas (así «carne» o
//   «lasaña» valen aunque la página esté en italiano), con tolerancia al plural: las palabras de 5 letras o más
//   también se prueban sin la última («verduras» → «verdura», «polli» → «poll», que está en «pollo»).
// - Además, tres tipos de palabras con significado propio: estaciones, dieta y categorías (listas de abajo).
// - Los nombres de los ingredientes (en español, como los escribió Evelyn) también se buscan, igual que el resto
//   (plural y categorías incluidos), pero la página nunca los muestra (decisión de la dueña, 25/11/2026).
import type { MenuDish } from "../../../supabase/functions/_shared/menu.ts";

/** Lo que el buscador lee de un plato (los ingredientes solo se buscan: nada los muestra). */
export type SearchableDish = Pick<MenuDish, "name" | "description" | "diet" | "seasonMonths" | "ingredients">;

/** Minúsculas, sin acentos (NFD), lo que no es letra ni número pasa a espacio y los espacios se colapsan. */
export function normalizeText(text: string): string {
  return text
    .normalize("NFD")
    .replace(/\p{M}+/gu, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

/** Las palabras de la consulta, normalizadas; [] si no hay nada que buscar. */
export function queryWords(query: string): string[] {
  const text = normalizeText(query);
  return text === "" ? [] : text.split(" ");
}

/** Plural simple: de 5 letras en adelante se quita la última (verduras → verdura, zucchine → zucchin). */
function stem(word: string): string {
  return word.length >= 5 ? word.slice(0, -1) : word;
}

/** La palabra y, si es larga, su raíz sin la última letra. */
function forms(word: string): string[] {
  const root = stem(word);
  return root === word ? [word] : [word, root];
}

/**
 * Categorías: lo que escribe la clienta (`keys`) y las palabras que, ENTERAS (no como parte de otra), hacen que un
 * plato cuente en la categoría si aparecen en su texto (`words`). Todo explícito, en italiano, español e inglés:
 * se amplía acá. Decisiones:
 * - «carne» = vacuno, cerdo, ternera, cordero y embutidos (los que pidió la dueña); las aves no entran (se buscan
 *   con «pollo»).
 * - «pollo» incluye el pavo (tacchino, pavo, turkey): quien busca ave quiere los dos.
 * - «verdura» suma, a las palabras de verduras, todo plato de dieta vegetariana o vegana (`viaDiet`). No lleva el
 *   tomate ni el pomodoro: son salsa de medio menú y harían de «verdura» un plato de pollo.
 * Las palabras cortas y ambiguas («res») solo cuentan enteras: «fresco» no es «res».
 */
interface Category {
  keys: string[];
  words: string[];
  /** Los platos de dieta vegetariana o vegana también responden a esta categoría. */
  viaDiet?: boolean;
}

const CATEGORIES: readonly Category[] = [
  {
    keys: ["carne", "carni", "carnes", "meat"],
    words: [
      // italiano
      "manzo", "manzi", "maiale", "maiali", "vitello", "vitelli", "agnello", "agnelli", "salsiccia", "salsicce", "bistecca",
      "polpette", "cotoletta", "prosciutto", "pancetta", "salame", "hamburger",
      // español
      "res", "vacuno", "ternera", "cerdo", "cordero", "salchicha", "salchichas", "bistec", "filete", "albondigas", "jamon", "tocino",
      // inglés
      "beef", "pork", "veal", "lamb", "sausage", "sausages", "steak", "meatballs", "ham", "bacon", "mutton",
    ],
  },
  {
    keys: ["pollo", "polli", "pollos", "pollame", "chicken", "chickens", "poultry"],
    words: ["pollo", "polli", "pollame", "gallina", "tacchino", "tacchini", "pollos", "pavo", "pavos", "chicken", "chickens", "poultry", "turkey", "turkeys"],
  },
  {
    keys: ["pesce", "pesci", "pescado", "pescados", "fish", "marisco", "mariscos", "seafood"],
    words: [
      // italiano
      "pesce", "pesci", "merluzzo", "salmone", "tonno", "branzino", "orata", "baccala", "acciughe", "sarde", "sardine", "trota",
      "gamberi", "gamberetti", "calamari", "cozze", "vongole", "polpo", "seppie", "spigola", "sogliola",
      // español
      "pescado", "pescados", "merluza", "salmon", "atun", "lubina", "dorada", "bacalao", "anchoas", "sardinas", "trucha",
      "gambas", "camarones", "calamares", "mejillones", "almejas", "pulpo", "sepia", "marisco", "mariscos",
      // inglés
      "fish", "cod", "tuna", "bass", "trout", "anchovies", "anchovy", "sardines", "shrimp", "prawn", "prawns", "squid", "mussels",
      "clams", "octopus", "sole", "seafood", "shellfish",
    ],
  },
  {
    keys: ["verdura", "verdure", "verduras", "vegetales", "vegetali", "vegetable", "vegetables", "veggie", "veggies"],
    words: [
      // italiano
      "verdura", "verdure", "zucchine", "zucchina", "melanzane", "melanzana", "carote", "carota", "spinaci", "peperoni", "peperone",
      "cavolo", "cavoli", "broccoli", "zucca", "cipolla", "cipolle", "finocchi", "finocchio", "insalata", "carciofi", "asparagi",
      "piselli", "fagiolini", "cavolfiore", "bietole", "radicchio", "minestrone",
      // español
      "verduras", "vegetales", "calabacin", "calabacines", "berenjena", "berenjenas", "zanahoria", "zanahorias", "espinacas", "pimiento",
      "pimientos", "col", "calabaza", "cebolla", "cebollas", "hinojo", "ensalada", "alcachofas", "esparragos", "guisantes", "coliflor",
      "acelgas",
      // inglés
      "vegetables", "veggies", "zucchini", "courgette", "courgettes", "eggplant", "eggplants", "aubergine", "carrot", "carrots",
      "spinach", "pepper", "peppers", "cabbage", "pumpkin", "squash", "onion", "onions", "fennel", "salad", "artichokes", "asparagus",
      "peas", "cauliflower", "chard",
    ],
    viaDiet: true,
  },
];

/** La dieta que pide una palabra: «vegetariano» también incluye los veganos, «vegano» solo ellos. */
function dietFor(word: string): "vegetarian" | "vegan" | null {
  if (word.startsWith("vegetarian")) return "vegetarian";
  if (word.startsWith("vegan")) return "vegan";
  return null;
}

/** Estaciones en los tres idiomas y sus meses (hemisferio norte; el invierno cruza el año). */
const SEASONS: ReadonlyArray<{ words: string[]; months: number[] }> = [
  { words: ["primavera", "spring"], months: [3, 4, 5] },
  { words: ["estate", "verano", "summer"], months: [6, 7, 8] },
  { words: ["autunno", "otono", "autumn", "fall"], months: [9, 10, 11] },
  { words: ["inverno", "invierno", "winter"], months: [12, 1, 2] },
];

/** Las categorías se normalizan una vez, al cargar (las listas de arriba se escriben legibles, con tildes si hacen falta). */
const NORMALIZED_CATEGORIES = CATEGORIES.map((category) => ({
  keys: new Set(category.keys.map(normalizeText)),
  stems: new Set(category.words.map((word) => stem(normalizeText(word)))),
  viaDiet: category.viaDiet === true,
}));

interface Haystack {
  /** Nombre, descripción (los tres idiomas) e ingredientes, normalizados, en una cadena. */
  text: string;
  /** Las palabras de ese texto, cada una sin la última letra si es larga (para comparar con las categorías). */
  stems: Set<string>;
}

function haystack(dish: SearchableDish): Haystack {
  const parts = [dish.name.it, dish.name.es, dish.name.en, dish.description.it, dish.description.es, dish.description.en, ...dish.ingredients];
  const text = normalizeText(parts.filter((part): part is string => part !== null).join(" "));
  return { text, stems: new Set(text.split(" ").map(stem)) };
}

function matchesWord(dish: SearchableDish, word: string, hay: Haystack): boolean {
  const wordForms = forms(word);
  // 1. Es parte del texto del plato (nombre o descripción, en cualquier idioma).
  if (wordForms.some((form) => hay.text.includes(form))) return true;
  // 2. Estación: por los meses del plato; los de todo el año (null) no responden.
  const season = SEASONS.find((entry) => wordForms.some((form) => entry.words.includes(form)));
  if (season) return dish.seasonMonths !== null && dish.seasonMonths.some((month) => season.months.includes(month));
  // 3. Dieta.
  const diet = dietFor(word);
  if (diet) return diet === "vegetarian" ? dish.diet !== null : dish.diet === "vegan";
  // 4. Categoría: alguna de sus palabras, entera, en el texto del plato (o, en verdura, una dieta vegetariana o vegana).
  return NORMALIZED_CATEGORIES.some(
    (category) =>
      wordForms.some((form) => category.keys.has(form)) &&
      ((category.viaDiet && dish.diet !== null) || [...hay.stems].some((token) => category.stems.has(token))),
  );
}

/** true si el plato responde a todas las palabras de la consulta; consulta vacía = todos. */
export function dishMatches(dish: SearchableDish, query: string): boolean {
  const words = queryWords(query);
  if (words.length === 0) return true;
  const hay = haystack(dish);
  return words.every((word) => matchesWord(dish, word, hay));
}

/** Los platos que responden a la consulta, en el mismo orden. */
export function filterDishes<T extends SearchableDish>(dishes: readonly T[], query: string): T[] {
  return queryWords(query).length === 0 ? [...dishes] : dishes.filter((dish) => dishMatches(dish, query));
}
