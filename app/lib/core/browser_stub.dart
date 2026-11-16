// Fuera de la web (iOS, Android y los tests en la VM): no hay página, así que
// no se pide nada, no se recarga nada y no hay avisos de la web.
import 'package:radici/core/browser.dart';

Browser createBrowser() => const NoBrowser();

class NoBrowser implements Browser {
  const NoBrowser();

  @override
  Uri? get baseUri => null;

  @override
  Future<String?> fetchFresh(Uri uri) async => null;

  @override
  void reload() {}

  @override
  BrowserInfo? get info => null;

  @override
  String? readFlag(String key) => null;

  @override
  void writeFlag(String key, String value) {}
}
