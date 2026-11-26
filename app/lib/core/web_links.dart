// Páginas de la web pública que la app abre en el navegador.
const String radiciWebOrigin = 'https://radicicucina.app';

const Set<String> _webLanguages = {'it', 'es', 'en'};

/// [path] de la web en el idioma de la app: la web lo toma de `?lang=` (sin
/// él, italiano).
Uri _webPage(String path, String languageCode) =>
    Uri.parse('$radiciWebOrigin$path').replace(
      queryParameters: _webLanguages.contains(languageCode)
          ? {'lang': languageCode}
          : null,
    );

/// El formulario de pedido de la web (`/richiesta/`): la app no calcula
/// precios (22/11/2026), la clienta pide y Evelyn le prepara el presupuesto.
Uri requestFormUri(String languageCode) =>
    _webPage('/richiesta/', languageCode);

/// La informativa de la web (`/privacy/`).
Uri privacyPolicyUri(String languageCode) =>
    _webPage('/privacy/', languageCode);
