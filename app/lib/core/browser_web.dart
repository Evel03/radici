// El navegador real (/gestione/). Solo se compila para la web: lo elige el
// import condicional de browser.dart. Todo lo que puede fallar (red,
// localStorage bloqueado) se atrapa acá y vuelve como null.
import 'dart:js_interop';

import 'package:radici/core/browser.dart';
import 'package:web/web.dart' as web;

Browser createBrowser() => const WebBrowser();

class WebBrowser implements Browser {
  const WebBrowser();

  @override
  Uri? get baseUri => Uri.tryParse(web.document.baseURI);

  @override
  Future<String?> fetchFresh(Uri uri) async {
    try {
      final response = await web.window
          .fetch(uri.toString().toJS, web.RequestInit(cache: 'no-store'))
          .toDart;
      if (response.status != 200) return null;
      return (await response.text().toDart).toDart;
    } on Object {
      return null;
    }
  }

  @override
  String? readMeta(String name) {
    try {
      return web.document
          .querySelector('meta[name="$name"]')
          ?.getAttribute('content');
    } on Object {
      return null;
    }
  }

  @override
  void reload() => web.window.location.reload();

  @override
  BrowserInfo get info {
    final navigator = web.window.navigator;
    return BrowserInfo(
      userAgent: navigator.userAgent,
      platform: navigator.platform,
      maxTouchPoints: navigator.maxTouchPoints,
      navigatorStandalone: navigator.standalone ?? false,
      displayModeStandalone: web.window
          .matchMedia('(display-mode: standalone)')
          .matches,
    );
  }

  @override
  String? readFlag(String key) {
    try {
      return web.window.localStorage.getItem(key);
    } on Object {
      return null;
    }
  }

  @override
  void writeFlag(String key, String value) {
    try {
      web.window.localStorage.setItem(key, value);
    } on Object {
      // Sin almacenamiento, la marca no queda: el aviso vuelve la próxima vez.
    }
  }

  @override
  void revokeObjectUrl(String url) {
    if (!url.startsWith('blob:')) return;
    try {
      web.URL.revokeObjectURL(url);
    } on Object {
      // Ya estaba suelta: nada que hacer.
    }
  }

  @override
  bool downloadText(String fileName, String text, String mimeType) {
    try {
      final blob = web.Blob(
        [text.toJS].toJS,
        web.BlobPropertyBag(type: mimeType),
      );
      final url = web.URL.createObjectURL(blob);
      final link = web.HTMLAnchorElement()
        ..href = url
        ..download = fileName;
      web.document.body?.append(link);
      link.click();
      link.remove();
      // Algunos navegadores leen el Blob después del click: se suelta un rato
      // más tarde, no enseguida.
      Future<void>.delayed(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
      return true;
    } on Object {
      return false;
    }
  }
}

extension on web.Navigator {
  /// Solo Safari de iOS: true en la app agregada a la pantalla de inicio. No
  /// es estándar, por eso no está en package:web.
  external bool? get standalone;
}
