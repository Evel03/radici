// Imágenes del sitio que genera scripts/render-images.mjs (Chrome sin ventana, por CDP) a partir de las
// plantillas de scripts/images/. Salen a public/ y se versionan: el build no necesita Chrome.
// Si cambian el nombre, el tamaño o el diseño, regenerar con `npm run images` (images.test.ts compara
// estos valores con los archivos).

/** Vista previa al compartir un link (WhatsApp, Telegram, Facebook, X…): 1200 × 630 y menos de 200 KB. */
export const OG_IMAGE = { path: "/og-image.png", width: 1200, height: 630, type: "image/png", maxBytes: 200 * 1024 } as const;

/** Ícono de iOS al agregar el sitio a la pantalla de inicio: 180 × 180 y opaco (iOS redondea las esquinas). */
export const APPLE_TOUCH_ICON = { path: "/apple-touch-icon.png", size: 180 } as const;

/** Para navegadores y servicios que piden /favicon.ico: PNG de 16, 32 y 48 px dentro de un ICO. */
export const FAVICON_ICO = { path: "/favicon.ico", sizes: [16, 32, 48] } as const;
