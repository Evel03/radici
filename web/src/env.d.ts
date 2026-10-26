/// <reference types="vite/client" />

// En el navegador solo se leen las de SITE_ENV_KEYS (src/site-config.ts); el resto, en el build.
interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL?: string;
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string;
  readonly VITE_TURNSTILE_SITE_KEY?: string;
  readonly VITE_BRAND_NAME?: string;
  readonly VITE_NOINDEX?: string;
  readonly VITE_SITE_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
