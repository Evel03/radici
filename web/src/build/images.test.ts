// Las imágenes versionadas de public/ coinciden con lo que declara el HTML (images.ts).
// Si falla: regenerarlas con `npm run images` (scripts/render-images.mjs).
import { describe, expect, it } from "vitest";
import { APPLE_TOUCH_ICON, FAVICON_ICO, OG_IMAGE } from "./images.ts";

// La web no tiene @types/node: fs se carga con un import dinámico sin tipos (los tests corren en Node).
const fs = (await import("node:fs" as string)) as { readFileSync(path: URL): Uint8Array };
const publicFile = (path: string): Uint8Array => fs.readFileSync(new URL(`../../public${path}`, import.meta.url));

function pngSize(bytes: Uint8Array): { width: number; height: number } {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  expect(view.getUint32(0), "firma PNG").toBe(0x89504e47);
  return { width: view.getUint32(16), height: view.getUint32(20) };
}

describe("imágenes de public/", () => {
  it("og-image.png: PNG de 1200 × 630 y menos de 200 KB", () => {
    const bytes = publicFile(OG_IMAGE.path);
    expect(pngSize(bytes)).toEqual({ width: OG_IMAGE.width, height: OG_IMAGE.height });
    expect(bytes.byteLength).toBeLessThan(OG_IMAGE.maxBytes);
    expect(OG_IMAGE.maxBytes).toBe(200 * 1024);
  });

  it("apple-touch-icon.png: PNG de 180 × 180", () => {
    expect(pngSize(publicFile(APPLE_TOUCH_ICON.path))).toEqual({ width: 180, height: 180 });
  });

  it("favicon.ico: un ICO con un PNG por tamaño (16, 32 y 48)", () => {
    const bytes = publicFile(FAVICON_ICO.path);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    expect(view.getUint16(0, true)).toBe(0);
    expect(view.getUint16(2, true), "tipo ícono").toBe(1);
    const count = view.getUint16(4, true);
    const sizes: number[] = [];
    for (let i = 0; i < count; i += 1) {
      const entry = 6 + 16 * i;
      const size = view.getUint8(entry) || 256;
      const length = view.getUint32(entry + 8, true);
      const offset = view.getUint32(entry + 12, true);
      expect(pngSize(bytes.subarray(offset, offset + length))).toEqual({ width: size, height: size });
      sizes.push(size);
    }
    expect(sizes).toEqual([...FAVICON_ICO.sizes]);
  });
});
