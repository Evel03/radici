// Lectura de build.json desde la página: junto a la app, sin caché y con ?t=.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/web_app/data/published_build_repository.dart';

import '../../../support/browser_fakes.dart';

void main() {
  final now = DateTime.utc(2026, 11, 16, 9);

  test('pide /gestione/build.json?t=<ms> y devuelve el id', () async {
    final browser = FakeBrowser(
      baseUri: Uri.parse('https://radicicucina.app/gestione/'),
      body: '{"buildId":"def5678"}',
    );
    final repository = BrowserPublishedBuildRepository(browser, () => now);

    expect(await repository.fetchPublishedBuildId(), 'def5678');
    expect(browser.fetched, [
      Uri.parse('https://radicicucina.app/gestione/build.json?t=1794819600000'),
    ]);
  });

  test('cada pedido lleva la hora del momento', () async {
    var clock = now;
    final browser = FakeBrowser(
      baseUri: Uri.parse('https://radicicucina.app/gestione/'),
      body: '{"buildId":"def5678"}',
    );
    final repository = BrowserPublishedBuildRepository(browser, () => clock);

    await repository.fetchPublishedBuildId();
    clock = now.add(const Duration(minutes: 5));
    await repository.fetchPublishedBuildId();
    expect(browser.fetched.map((u) => u.queryParameters['t']), [
      '1794819600000',
      '1794819900000',
    ]);
  });

  test('sin red o con una respuesta rara: null', () async {
    final browser = FakeBrowser(
      baseUri: Uri.parse('https://radicicucina.app/gestione/'),
    );
    final repository = BrowserPublishedBuildRepository(browser, () => now);

    expect(await repository.fetchPublishedBuildId(), isNull);
    browser.body = '<!DOCTYPE html><html><title>404</title></html>';
    expect(await repository.fetchPublishedBuildId(), isNull);
  });

  test('fuera de la web (sin base de la página) no pide nada', () async {
    final browser = FakeBrowser(body: '{"buildId":"def5678"}');
    final repository = BrowserPublishedBuildRepository(browser, () => now);

    expect(await repository.fetchPublishedBuildId(), isNull);
    expect(browser.fetched, isEmpty);
  });
}
