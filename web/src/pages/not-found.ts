// Página 404. Cloudflare Pages la sirve con estado 404 para cualquier ruta que no existe (busca el
// 404.html más cercano hacia arriba; hay uno solo, en la raíz). Con ella deja de tratar el sitio como
// SPA: antes una ruta inexistente devolvía la landing con 200. /gestione/ no cambia: la app usa rutas
// con # y sus archivos existen. Todas las URL del HTML son absolutas: sirve en cualquier profundidad.
// El contenido llega en italiano del build; acá solo se maneja el idioma.
import "../styles/base.css";
import "../styles/not-found.css";
import { initLanguage } from "./shell.ts";

initLanguage();
