// Navegador y build.json falsos para los avisos de la web (/gestione/):
// versión nueva y Safari fuera de la app instalada.
import 'dart:async';

import 'package:radici/core/browser.dart';
import 'package:radici/features/web_app/data/published_build_repository.dart';

/// Safari en un iPhone.
const String iPhoneSafari =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 '
    'Safari/604.1';

/// El iPhone en Safari, fuera de la app instalada.
const BrowserInfo iPhoneInSafari = BrowserInfo(
  userAgent: iPhoneSafari,
  platform: 'iPhone',
  maxTouchPoints: 5,
  navigatorStandalone: false,
  displayModeStandalone: false,
);

/// La página en memoria: lo que pidió, cuántas veces recargó y las marcas
/// guardadas.
class FakeBrowser implements Browser {
  FakeBrowser({this.baseUri, this.info, this.body});

  @override
  Uri? baseUri;

  @override
  BrowserInfo? info;

  /// Lo que devuelve [fetchFresh]: null es sin red o una respuesta que no es
  /// 200.
  String? body;

  /// URLs pedidas con [fetchFresh], en orden.
  final List<Uri> fetched = [];

  int reloads = 0;

  /// Marcas guardadas (localStorage).
  final Map<String, String> flags = {};

  /// Almacenamiento bloqueado (Safari privado, datos del sitio borrados): no
  /// guarda nada.
  bool storageBlocked = false;

  @override
  Future<String?> fetchFresh(Uri uri) async {
    fetched.add(uri);
    return body;
  }

  @override
  void reload() => reloads++;

  @override
  String? readFlag(String key) => storageBlocked ? null : flags[key];

  @override
  void writeFlag(String key, String value) {
    if (!storageBlocked) flags[key] = value;
  }

  /// URLs soltadas con [revokeObjectUrl], en orden.
  final List<String> revoked = [];

  @override
  void revokeObjectUrl(String url) => revoked.add(url);
}

/// El id publicado en build.json, controlable.
class FakePublishedBuildRepository implements PublishedBuildRepository {
  FakePublishedBuildRepository([this.published]);

  /// Lo que devuelve: null es sin red o una respuesta rara.
  String? published;

  /// Si no es null, falla con este error.
  Exception? error;

  /// Si no es null, espera a que se complete (red lenta).
  Completer<void>? pending;

  int calls = 0;

  @override
  Future<String?> fetchPublishedBuildId() async {
    calls++;
    final pending = this.pending;
    if (pending != null) await pending.future;
    final error = this.error;
    if (error != null) throw error;
    return published;
  }
}
