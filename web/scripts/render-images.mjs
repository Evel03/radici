// Genera las imágenes de web/public/ con Chrome sin ventana, por el protocolo de DevTools (CDP) y sin
// bibliotecas: Node 24 trae WebSocket y quita los tipos de los .ts que se importan. Sí necesita las
// fuentes de la marca instaladas (devDependencies @fontsource-variable/*: correr `npm ci` antes).
//   public/og-image.png          1200 × 630   vista previa al compartir un link (og:image)
//   public/apple-touch-icon.png   180 × 180   ícono de iOS (cuadrado y opaco)
//   public/favicon.ico            16, 32, 48  para quien pide /favicon.ico (PNG dentro de un ICO)
// Plantillas: scripts/images/*.html. Textos: src/i18n/it.json. Marca: VITE_BRAND_NAME (por defecto Radici).
// Nombres y tamaños: src/build/images.ts. Dibujo de los íconos: public/favicon.svg (la R de Cinzel ya
// convertida en trazo: no depende de ninguna fuente).
// Uso: `npm run images` (CHROME_PATH=<ruta> si Chrome o Edge no están en el lugar habitual).
//
// Cada imagen se dibuja al tamaño exacto con Emulation.setDeviceMetricsOverride (escala 1) y se captura
// con Page.captureScreenshot. La imagen para compartir usa las fuentes de la marca (Cinzel y Cormorant
// Garamond, las mismas del sitio), embebidas en la plantilla: no depende de las fuentes instaladas.
// Los archivos versionados son la referencia; regenerar solo si cambia el diseño.
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { APPLE_TOUCH_ICON, FAVICON_ICO, OG_IMAGE } from "../src/build/images.ts";
import { resolveConfig } from "../src/config.ts";

const webDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const publicDir = join(webDir, "public");
const templatesDir = join(webDir, "scripts", "images");

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

function chromePath() {
  const candidates = [
    process.env.CHROME_PATH,
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
    // Edge también es Chromium y habla el mismo protocolo (viene con Windows).
    "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
    "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ].filter(Boolean);
  const found = candidates.find((path) => existsSync(path));
  if (!found) throw new Error("No se encontró Chrome ni Edge: definir CHROME_PATH con la ruta del ejecutable.");
  return found;
}

/** Chrome sin ventana con un perfil temporal propio (nunca el del usuario). */
async function launchChrome() {
  const profile = mkdtempSync(join(tmpdir(), "radici-images-"));
  const child = spawn(
    chromePath(),
    [
      "--headless=new",
      "--remote-debugging-port=0",
      `--user-data-dir=${profile}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-extensions",
      "--disable-background-networking",
      "--hide-scrollbars",
      "--force-color-profile=srgb",
      "about:blank",
    ],
    { stdio: "ignore" },
  );
  // Chrome escribe el puerto y la ruta del WebSocket del navegador cuando está listo.
  const portFile = join(profile, "DevToolsActivePort");
  const deadline = Date.now() + 30_000;
  for (;;) {
    const lines = existsSync(portFile) ? readFileSync(portFile, "utf8").trim().split("\n") : [];
    if (lines.length >= 2) return { child, profile, wsUrl: `ws://127.0.0.1:${lines[0]}${lines[1]}` };
    if (Date.now() > deadline) throw new Error("Chrome no abrió el puerto de DevTools.");
    await sleep(100);
  }
}

/** Cliente CDP mínimo: comandos con respuesta y espera de un evento. */
function connect(wsUrl) {
  return new Promise((resolveClient, reject) => {
    const ws = new WebSocket(wsUrl);
    const pending = new Map();
    const waiters = [];
    let lastId = 0;
    ws.onmessage = (event) => {
      const message = JSON.parse(String(event.data));
      if (message.id !== undefined) {
        const call = pending.get(message.id);
        pending.delete(message.id);
        if (message.error) call?.reject(new Error(`${call.method}: ${message.error.message}`));
        else call?.resolve(message.result);
        return;
      }
      const index = waiters.findIndex((w) => w.method === message.method && w.sessionId === message.sessionId);
      if (index !== -1) waiters.splice(index, 1)[0].resolve(message.params);
    };
    ws.onerror = () => reject(new Error("No se pudo conectar con Chrome (DevTools)."));
    ws.onopen = () =>
      resolveClient({
        send(method, params = {}, sessionId) {
          const id = ++lastId;
          ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
          return new Promise((resolveCall, rejectCall) => pending.set(id, { resolve: resolveCall, reject: rejectCall, method }));
        },
        once(method, sessionId) {
          return new Promise((resolveEvent) => waiters.push({ method, sessionId, resolve: resolveEvent }));
        },
        close() {
          ws.close();
        },
      });
  });
}

function escapeHtml(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** {{clave}} → valor (ya escapado o HTML de confianza). Una clave sin valor es un error. */
function fill(template, values) {
  return template.replace(/\{\{(\w+)\}\}/g, (_match, key) => {
    if (!(key in values)) throw new Error(`Falta el valor de {{${key}}}`);
    return values[key];
  });
}

/**
 * @font-face de Cinzel y Cormorant Garamond (redonda e itálica) con los woff2 embebidos como data: URL:
 * la plantilla se abre como file:// y Chrome no carga fuentes de otros archivos locales (CORS).
 * Solo el subconjunto latino, que alcanza para los textos en italiano.
 */
function brandFontFaces() {
  const faces = [
    ["Cinzel Variable", "normal", "400 900", "@fontsource-variable/cinzel/files/cinzel-latin-wght-normal.woff2"],
    ["Cormorant Garamond Variable", "normal", "300 700", "@fontsource-variable/cormorant-garamond/files/cormorant-garamond-latin-wght-normal.woff2"],
    ["Cormorant Garamond Variable", "italic", "300 700", "@fontsource-variable/cormorant-garamond/files/cormorant-garamond-latin-wght-italic.woff2"],
  ];
  return faces
    .map(([family, style, weight, specifier]) => {
      const data = readFileSync(fileURLToPath(import.meta.resolve(specifier))).toString("base64");
      return `@font-face { font-family: "${family}"; font-style: ${style}; font-weight: ${weight}; src: url(data:font/woff2;base64,${data}) format("woff2"); }`;
    })
    .join("\n");
}

/** Ancho y alto de un PNG (cabecera IHDR). */
function pngSize(data) {
  if (data.readUInt32BE(0) !== 0x89504e47) throw new Error("No es un PNG");
  return { width: data.readUInt32BE(16), height: data.readUInt32BE(20) };
}

/** ICO con PNG adentro (válido desde Windows Vista y en todos los navegadores actuales). */
function buildIco(images) {
  const header = Buffer.alloc(6 + 16 * images.length);
  header.writeUInt16LE(0, 0); // reservado
  header.writeUInt16LE(1, 2); // tipo: ícono
  header.writeUInt16LE(images.length, 4);
  let offset = header.length;
  images.forEach(({ size, data }, i) => {
    const entry = 6 + 16 * i;
    header.writeUInt8(size >= 256 ? 0 : size, entry); // ancho (0 = 256)
    header.writeUInt8(size >= 256 ? 0 : size, entry + 1); // alto
    header.writeUInt8(0, entry + 2); // sin paleta
    header.writeUInt8(0, entry + 3); // reservado
    header.writeUInt16LE(1, entry + 4); // planos
    header.writeUInt16LE(32, entry + 6); // bits por píxel
    header.writeUInt32LE(data.length, entry + 8);
    header.writeUInt32LE(offset, entry + 12);
    offset += data.length;
  });
  return Buffer.concat([header, ...images.map((image) => image.data)]);
}

async function main() {
  const brand = resolveConfig(process.env).brandName;
  const it = JSON.parse(readFileSync(join(webDir, "src", "i18n", "it.json"), "utf8"));
  const text = (value) => escapeHtml(value.replaceAll("{brand}", brand));
  const ogHtml = fill(readFileSync(join(templatesDir, "og-image.html"), "utf8"), {
    fontFaces: brandFontFaces(),
    brand: text(brand),
    tagline: text(it.common.brandTagline),
    slogan: text(it.common.slogan),
    eyebrow: text(it.landing.hero.eyebrow),
  });
  const iconTemplate = readFileSync(join(templatesDir, "icon.html"), "utf8");
  const roundedSvg = readFileSync(join(publicDir, "favicon.svg"), "utf8").trim();
  // iOS recorta las esquinas solo: el ícono va cuadrado, sin el redondeo del favicon.
  const squareSvg = roundedSvg.replace(/\srx="[\d.]+"/, "");
  if (squareSvg === roundedSvg) throw new Error('favicon.svg no tiene rx="…" en el fondo: revisar el script.');

  const { child, profile, wsUrl } = await launchChrome();
  const cdp = await connect(wsUrl);
  try {
    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    await cdp.send("Page.enable", {}, sessionId);

    let count = 0;
    const render = async (html, { width, height, transparent }) => {
      const file = join(profile, `render-${++count}.html`);
      writeFileSync(file, html);
      await cdp.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false }, sessionId);
      await cdp.send(
        "Emulation.setDefaultBackgroundColorOverride",
        transparent ? { color: { r: 0, g: 0, b: 0, a: 0 } } : {},
        sessionId,
      );
      const loaded = cdp.once("Page.loadEventFired", sessionId);
      await cdp.send("Page.navigate", { url: pathToFileURL(file).href }, sessionId);
      await loaded;
      await cdp.send("Runtime.evaluate", { expression: "document.fonts.ready.then(() => true)", awaitPromise: true }, sessionId);
      const { data } = await cdp.send(
        "Page.captureScreenshot",
        { format: "png", clip: { x: 0, y: 0, width, height, scale: 1 } },
        sessionId,
      );
      const png = Buffer.from(data, "base64");
      const size = pngSize(png);
      if (size.width !== width || size.height !== height) {
        throw new Error(`Captura de ${size.width} × ${size.height} en vez de ${width} × ${height}`);
      }
      return png;
    };

    const og = await render(ogHtml, { width: OG_IMAGE.width, height: OG_IMAGE.height, transparent: false });
    if (og.length > OG_IMAGE.maxBytes) {
      throw new Error(`og-image.png pesa ${og.length} bytes (máximo ${OG_IMAGE.maxBytes}): simplificar la plantilla.`);
    }
    const appleIcon = await render(fill(iconTemplate, { svg: squareSvg }), {
      width: APPLE_TOUCH_ICON.size,
      height: APPLE_TOUCH_ICON.size,
      transparent: false,
    });
    const favicons = [];
    for (const size of FAVICON_ICO.sizes) {
      favicons.push({ size, data: await render(fill(iconTemplate, { svg: roundedSvg }), { width: size, height: size, transparent: true }) });
    }

    const outputs = [
      [OG_IMAGE.path, og],
      [APPLE_TOUCH_ICON.path, appleIcon],
      [FAVICON_ICO.path, buildIco(favicons)],
    ];
    for (const [path, data] of outputs) {
      writeFileSync(join(publicDir, path.slice(1)), data);
      console.log(`public${path}: ${data.length} bytes`);
    }
    await cdp.send("Browser.close").catch(() => undefined);
  } finally {
    cdp.close();
    await Promise.race([new Promise((done) => child.once("exit", done)), sleep(5000)]);
    if (child.exitCode === null) child.kill();
    rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  }
}

await main();
