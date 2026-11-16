// Lee el id del build publicado (build.json, junto a la app) desde la página:
// sin la caché del navegador y con `?t=<ms>` (domain/published_build.dart).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/features/web_app/domain/published_build.dart';

abstract interface class PublishedBuildRepository {
  /// El id publicado, o null si no se pudo saber: sin red, una respuesta rara
  /// o fuera de la web.
  Future<String?> fetchPublishedBuildId();
}

final publishedBuildRepositoryProvider = Provider<PublishedBuildRepository>(
  (ref) => BrowserPublishedBuildRepository(
    ref.watch(browserProvider),
    ref.watch(clockProvider),
  ),
);

class BrowserPublishedBuildRepository implements PublishedBuildRepository {
  const BrowserPublishedBuildRepository(this._browser, this._clock);

  final Browser _browser;
  final DateTime Function() _clock;

  @override
  Future<String?> fetchPublishedBuildId() async {
    final base = _browser.baseUri;
    if (base == null) return null;
    final body = await _browser.fetchFresh(publishedBuildUri(base, _clock()));
    return body == null ? null : parsePublishedBuildId(body);
  }
}
