// Cómo responde Cloudflare Pages a una ruta que no existe, para que `vite preview` haga lo mismo.
// Docs "Serving Pages" (act. 10/10/2026) y notFound() del asset-server de workers-sdk: busca el
// 404.html más cercano subiendo por las carpetas de la ruta y lo devuelve con estado 404, con las
// cabeceras de _headers de esa ruta y Cache-Control: no-store. Sin un 404.html en la raíz trata el
// sitio como SPA (index.html con 200 en cualquier ruta): por eso existe web/404.html.

/** 404.html candidatos para una ruta, del más cercano a la raíz: "/a/b" → /a/404.html, /404.html. */
export function notFoundCandidates(pathname: string): string[] {
  const candidates: string[] = [];
  let dir = pathname;
  while (dir.startsWith("/")) {
    dir = dir.slice(0, dir.lastIndexOf("/"));
    candidates.push(`${dir}/404.html`);
  }
  return candidates;
}
