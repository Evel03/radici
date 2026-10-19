{{flutter_js}}
{{flutter_build_config}}

// Arranque de Mestolo · gestione (/gestione/). Todo se sirve desde el mismo
// origen: la CSP solo permite 'self' (más Supabase en connect-src).
// - CanvasKit local: el build usa --no-web-resources-cdn y, por las dudas,
//   canvasKitBaseUrl apunta a la carpeta propia (nunca a www.gstatic.com).
// - Fuentes: Roboto va empaquetada en los assets de la app, así el motor no la
//   descarga. Las fuentes de respaldo (glifos que Roboto no tiene, como emoji)
//   el motor las buscaría en fonts.gstatic.com: se apuntan a una carpeta propia
//   que no existe. Si falta un glifo se ve un recuadro y el motor deja de
//   intentar; nunca se pide nada a Google.
const config = {
  canvasKitBaseUrl: "canvaskit/",
  fontFallbackBaseUrl: "fonts-fallback/",
};

_flutter.loader.load({
  config,
  onEntrypointLoaded: async (engineInitializer) => {
    // Con onEntrypointLoaded propio, la config se pasa a mano al motor.
    const appRunner = await engineInitializer.initializeEngine(config);
    await appRunner.runApp();
    const loading = document.getElementById("loading");
    if (loading) loading.remove();
  },
});
