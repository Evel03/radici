// Configuración del navegador (solo módulos de páginas: en Node import.meta.env no existe).
// Cada variable se lee por su nombre: Vite reemplaza exactamente esas en el JS publicado. Leer
// import.meta.env entero metería en el bundle todas las VITE_* y las de Vite (MODE, BASE_URL...).
// Una variable que falta en el build queda undefined (Vite 8: import.meta.env.* → undefined).
// Las demás (noindex, URL del sitio) las usa solo el build: vite.config.ts aplica resolveConfig al
// entorno resuelto. Si se suma una lectura acá, sumarla también a SITE_ENV_KEYS (config.ts).
import { resolveConfig, toSiteConfig, type SiteConfig } from "./config.ts";

export const config: SiteConfig = toSiteConfig(
  resolveConfig({
    VITE_BRAND_NAME: import.meta.env.VITE_BRAND_NAME,
    VITE_SUPABASE_URL: import.meta.env.VITE_SUPABASE_URL,
    VITE_SUPABASE_PUBLISHABLE_KEY: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
    VITE_TURNSTILE_SITE_KEY: import.meta.env.VITE_TURNSTILE_SITE_KEY,
    VITE_TURNSTILE_AUTH_SITE_KEY: import.meta.env.VITE_TURNSTILE_AUTH_SITE_KEY,
  }),
);
