// Tests de publish-app-entries.sh, el paso de Deploy web que arma dist/gestione/ y dist/app/ desde un solo
// build de Flutter web. Corren sobre un build falso armado con el index.html, el manifest y el
// flutter_bootstrap.js reales de app/web/ (si alguien los cambia y el script no se entera, falla acá).
// Necesita bash y tar, como el runner de ubuntu del CI: si falta alguno, se saltea. Correr con: npm test (raíz).
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const REPO = join(HERE, "..", "..");
const SCRIPT = join(HERE, "publish-app-entries.sh");
const BUILD_ID = "abc1234";

const probe = spawnSync("bash", ["-c", "command -v tar"], { encoding: "utf8" });
const skip = probe.status === 0 ? false : "faltan bash o tar (el runner del CI los tiene)";

function write(root: string, path: string, content: string): void {
  const file = join(root, path);
  mkdirSync(join(file, ".."), { recursive: true });
  writeFileSync(file, content);
}

type BuildOptions = { mainJs?: string; bootstrap?: string };

/** Un build de Flutter web como lo deja `flutter build web --base-href /gestione/`. */
function fakeBuild(root: string, opts: BuildOptions = {}): void {
  const index = readFileSync(join(REPO, "app/web/index.html"), "utf8").replace("$FLUTTER_BASE_HREF", "/gestione/");
  write(root, "index.html", index);
  write(root, "manifest.json", readFileSync(join(REPO, "app/web/manifest.json"), "utf8"));
  const bootstrap = readFileSync(join(REPO, "app/web/flutter_bootstrap.js"), "utf8").replace(
    "{{flutter_build_config}}",
    '_flutter.buildConfig = {"useLocalCanvasKit":true,"renderer":"canvaskit"};',
  );
  write(root, "flutter_bootstrap.js", opts.bootstrap ?? bootstrap);
  write(root, "main.dart.js", opts.mainJs ?? `var b="${BUILD_ID}";\n`);
  write(root, "flutter_service_worker.js", "// sw");
  write(root, "version.json", "{}");
  write(root, "assets/AssetManifest.bin", "x");
  for (const f of ["canvaskit.js", "canvaskit.wasm", "chromium/canvaskit.js", "chromium/canvaskit.wasm", "skwasm.wasm", "skwasm.js.symbols"]) {
    write(root, `canvaskit/${f}`, "x");
  }
}

function sandbox(opts: BuildOptions = {}, dist: Record<string, string> = {}): string {
  const dir = mkdtempSync(join(tmpdir(), "radici-entries-"));
  fakeBuild(join(dir, "src"), opts);
  write(dir, "dist/_headers", "/*\n  X-Frame-Options: DENY\n");
  write(dir, "dist/sitemap.xml", "<loc>https://x.example/</loc>");
  write(dir, "dist/robots.txt", "User-agent: *\nAllow: /\n");
  for (const [path, content] of Object.entries(dist)) write(dir, `dist/${path}`, content);
  return dir;
}

function run(dir: string, env: Record<string, string> = {}): { code: number | null; out: string } {
  const res = spawnSync("bash", [SCRIPT], {
    cwd: dir,
    encoding: "utf8",
    env: { ...process.env, SRC: "src", DIST: "dist", BUILD_ID, ...env },
  });
  return { code: res.status, out: `${res.stdout}${res.stderr}` };
}

const read = (dir: string, path: string): string => readFileSync(join(dir, "dist", path), "utf8");

function files(root: string, base = ""): string[] {
  return readdirSync(join(root, base)).flatMap((n) => {
    const rel = base ? `${base}/${n}` : n;
    return statSync(join(root, rel)).isDirectory() ? files(root, rel) : [rel];
  });
}

test("arma dist/gestione y dist/app con su base, su entrada y su manifest", { skip }, () => {
  const dir = sandbox();
  const { code, out } = run(dir);
  assert.equal(code, 0, out);

  const gestione = read(dir, "gestione/index.html");
  assert.match(gestione, /<base href="\/gestione\/">/);
  assert.match(gestione, /<meta name="radici-entry" content="gestione">/);
  assert.equal(JSON.parse(read(dir, "gestione/manifest.json")).id, "/gestione/");

  const app = read(dir, "app/index.html");
  assert.match(app, /<base href="\/app\/">/);
  assert.match(app, /<meta name="radici-entry" content="app">/);
  assert.doesNotMatch(app, /content="gestione"/);
  assert.doesNotMatch(app, /<base href="\/gestione\/">/);
  assert.match(app, /<title>Radici Cucina<\/title>/);
  assert.match(app, /noindex/);
  // La cáscara de /app/ cumple la CSP: sin scripts ni estilos inline, y con la pantalla de carga de siempre.
  assert.doesNotMatch(app, /<script(?![^>]*\ssrc=)/);
  assert.doesNotMatch(app, /<style|\sstyle=/);
  assert.match(app, /<script src="flutter_bootstrap\.js" async><\/script>/);
  assert.match(app, /<link rel="manifest" href="manifest\.json">/);
  const manifest = JSON.parse(read(dir, "app/manifest.json"));
  assert.equal(manifest.id, "/app/");
  assert.equal(manifest.start_url, "/app/");
  assert.equal(manifest.scope, "/app/");
  assert.equal(manifest.name, "Radici Cucina");
  assert.ok(manifest.icons.length >= 2);

  // Cada entrada con su build.json (el aviso de versión nueva lo lee relativo a su base).
  for (const e of ["gestione", "app"]) assert.deepEqual(JSON.parse(read(dir, `${e}/build.json`)), { buildId: BUILD_ID });
});

test("las dos copias son el mismo build salvo index.html y manifest.json", { skip }, () => {
  const dir = sandbox();
  assert.equal(run(dir).code, 0);
  const g = files(join(dir, "dist/gestione")).sort();
  const a = files(join(dir, "dist/app")).sort();
  assert.deepEqual(a, g);
  for (const f of g.filter((f) => !["index.html", "manifest.json"].includes(f))) {
    assert.equal(read(dir, `app/${f}`), read(dir, `gestione/${f}`), f);
  }
});

test("no publica lo que un build con CanvasKit no carga ni un service worker (los scopes no chocan)", { skip }, () => {
  const dir = sandbox();
  assert.equal(run(dir).code, 0);
  for (const e of ["gestione", "app"]) {
    assert.equal(existsSync(join(dir, "dist", e, "flutter_service_worker.js")), false, e);
    assert.equal(existsSync(join(dir, "dist", e, "canvaskit/skwasm.wasm")), false, e);
    assert.equal(existsSync(join(dir, "dist", e, "canvaskit/skwasm.js.symbols")), false, e);
    assert.equal(existsSync(join(dir, "dist", e, "canvaskit/chromium/canvaskit.wasm")), true, e);
  }
  assert.doesNotMatch(read(dir, "gestione/flutter_bootstrap.js"), /serviceWorker/i);
});

test("el meta cruzado o ausente corta (nunca /gestione/ con content=app ni /app/ sin cambiar)", { skip }, () => {
  // El index de origen ya trae content="app": /gestione/ saldría con la entrada de las clientas.
  const dir = sandbox();
  const index = join(dir, "src/index.html");
  writeFileSync(index, readFileSync(index, "utf8").replace('content="gestione"', 'content="app"'));
  const cruzado = run(dir);
  assert.notEqual(cruzado.code, 0);
  assert.match(cruzado.out, /::error::/);

  // Sin el meta en el origen: el script no puede cambiarlo en /app/.
  const sin = sandbox();
  const idx = join(sin, "src/index.html");
  writeFileSync(idx, readFileSync(idx, "utf8").replace(/<meta name="radici-entry"[^>]*>/, ""));
  const ausente = run(sin);
  assert.notEqual(ausente.code, 0);
  assert.match(ausente.out, /radici-entry/);
});

test("corta si el JS de la app lleva la ruta de la otra entrada (haría falta un build propio)", { skip }, () => {
  const bootstrap = readFileSync(join(REPO, "app/web/flutter_bootstrap.js"), "utf8").replace(
    "{{flutter_build_config}}",
    '"useLocalCanvasKit":true; var base = "/gestione/main.dart.js";',
  );
  const { code, out } = run(sandbox({ bootstrap }));
  assert.notEqual(code, 0);
  assert.match(out, /build propio/);
});

test("corta si main.dart.js no tiene el id del build", { skip }, () => {
  const { code, out } = run(sandbox({ mainJs: "var b=1;\n" }));
  assert.notEqual(code, 0);
  assert.match(out, /::error::.*id del build/);
});

test("corta si CanvasKit no es local, si usa skwasm o si faltan los marcadores de _headers", { skip }, () => {
  const cdn = run(sandbox({ bootstrap: '"useLocalCanvasKit":false' }));
  assert.notEqual(cdn.code, 0);
  assert.match(cdn.out, /CanvasKit no es local/);
  const wasm = run(sandbox({ bootstrap: '"useLocalCanvasKit":true,"renderer":"skwasm"' }));
  assert.notEqual(wasm.code, 0);
  assert.match(wasm.out, /skwasm/);
  const headers = run(sandbox({}, { _headers: "script-src __SUPABASE_ORIGIN__" }));
  assert.notEqual(headers.code, 0);
  assert.match(headers.out, /marcadores de Supabase/);
});

test("ni el sitemap ni robots.txt pueden anunciar /app/ (hasta PR69)", { skip }, () => {
  for (const f of ["sitemap.xml", "robots.txt"]) {
    const { code, out } = run(sandbox({}, { [f]: "https://x.example/app/" }));
    assert.notEqual(code, 0, f);
    assert.match(out, /no se anuncia/);
  }
});

test("avisa (sin cortar) si main.dart.js pasa el umbral de peso", { skip }, () => {
  const big = sandbox({ mainJs: `var b="${BUILD_ID}";${"x".repeat(2000)}\n` });
  const over = run(big, { MAIN_JS_WARN_BYTES: "1000" });
  assert.equal(over.code, 0, over.out);
  assert.match(over.out, /::warning::main\.dart\.js pesa \d+ bytes \(más de 1000\)/);

  const under = run(sandbox(), { MAIN_JS_WARN_BYTES: "1000000" });
  assert.equal(under.code, 0, under.out);
  assert.doesNotMatch(under.out, /::warning::/);
});

test("el umbral por defecto deja un margen sobre el main.dart.js de hoy (5,4 MB)", () => {
  assert.match(readFileSync(SCRIPT, "utf8"), /MAIN_JS_WARN_BYTES:-6000000/);
});

test("no corre dos veces sobre el mismo dist", { skip }, () => {
  const dir = sandbox();
  assert.equal(run(dir).code, 0);
  const again = run(dir);
  assert.notEqual(again.code, 0);
  assert.match(again.out, /ya existe/);
});
