// Aviso de versión nueva: compara el id compilado con el de build.json, al
// abrir y al volver a primer plano, como mucho una vez cada 5 minutos. Sin red,
// con una respuesta rara o sin id compilado, no avisa. Nunca recarga sola.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/core/build_id.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/features/web_app/application/app_update_controller.dart';
import 'package:radici/features/web_app/data/published_build_repository.dart';

import '../../../support/browser_fakes.dart';
import '../../../support/pump_app.dart';

void main() {
  final start = DateTime.utc(2026, 11, 16, 9);
  late DateTime now;
  late FakePublishedBuildRepository repository;
  late FakeBrowser browser;
  late ProviderContainer container;

  void open({String buildId = 'abc1234'}) {
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        buildIdProvider.overrideWithValue(buildId),
        publishedBuildRepositoryProvider.overrideWithValue(repository),
        browserProvider.overrideWithValue(browser),
        clockProvider.overrideWithValue(() => now),
      ],
    );
  }

  AppUpdateController controller() =>
      container.read(appUpdateControllerProvider.notifier);
  bool updateAvailable() => container.read(appUpdateControllerProvider);

  setUp(() {
    now = start;
    repository = FakePublishedBuildRepository('abc1234');
    browser = FakeBrowser();
  });

  test('el mismo id publicado: no avisa', () async {
    open();
    await controller().check();
    expect(repository.calls, 1);
    expect(updateAvailable(), isFalse);
  });

  test('otro id publicado: avisa, y no recarga sola', () async {
    repository.published = 'def5678';
    open();
    await controller().check();
    expect(updateAvailable(), isTrue);
    expect(browser.reloads, 0);
  });

  test('«Actualizar» recarga la página', () async {
    repository.published = 'def5678';
    open();
    await controller().check();
    controller().reload();
    expect(browser.reloads, 1);
  });

  test('sin red o con una respuesta rara: no avisa', () async {
    repository.published = null;
    open();
    await controller().check();
    expect(repository.calls, 1);
    expect(updateAvailable(), isFalse);
  });

  test('si leer build.json falla con un error: no avisa ni lo propaga', () async {
    repository.error = Exception('red');
    open();
    await controller().check();
    expect(updateAvailable(), isFalse);
  });

  test('sin id compilado (flutter run, tests, iOS y Android): no pide nada', () async {
    repository.published = 'def5678';
    open(buildId: '');
    await controller().check();
    expect(repository.calls, 0);
    expect(updateAvailable(), isFalse);
  });

  test('como mucho una vez cada 5 minutos, también si el intento falló', () async {
    repository.published = null;
    open();
    await controller().check();
    expect(repository.calls, 1);

    now = start.add(const Duration(minutes: 4, seconds: 59));
    repository.published = 'def5678';
    await controller().check();
    expect(repository.calls, 1);
    expect(updateAvailable(), isFalse);

    now = start.add(const Duration(minutes: 5));
    await controller().check();
    expect(repository.calls, 2);
    expect(updateAvailable(), isTrue);
  });

  test('mientras hay una lectura en curso no empieza otra', () async {
    repository.pending = Completer<void>();
    open();
    final first = controller().check();
    now = start.add(const Duration(minutes: 6));
    await controller().check();
    expect(repository.calls, 1);

    repository.pending!.complete();
    await first;
    expect(updateAvailable(), isFalse);
  });

  test('si el reloj del teléfono vuelve atrás, mira igual', () async {
    open();
    await controller().check();
    now = start.subtract(const Duration(hours: 1));
    await controller().check();
    expect(repository.calls, 2);
  });

  test('ya avisado: un intento sin red no saca el aviso; si el publicado vuelve '
      'a ser el compilado, sí', () async {
    repository.published = 'def5678';
    open();
    await controller().check();
    expect(updateAvailable(), isTrue);

    now = start.add(const Duration(minutes: 5));
    repository.published = null;
    await controller().check();
    expect(updateAvailable(), isTrue);

    now = start.add(const Duration(minutes: 10));
    repository.published = 'abc1234';
    await controller().check();
    expect(updateAvailable(), isFalse);
  });

  test('si se descarta mientras lee build.json: no lanza', () async {
    repository
      ..published = 'def5678'
      ..pending = Completer<void>();
    // A mano (no .test): se descarta en medio de la lectura.
    final own = ProviderContainer(
      retry: noRetry,
      overrides: [
        buildIdProvider.overrideWithValue('abc1234'),
        publishedBuildRepositoryProvider.overrideWithValue(repository),
        browserProvider.overrideWithValue(browser),
        clockProvider.overrideWithValue(() => now),
      ],
    );
    final check = own.read(appUpdateControllerProvider.notifier).check();
    own.dispose();
    repository.pending!.complete();
    await check;
  });

  testWidgets('si build.json no responde en 15 s, se da por perdido y a los '
      '5 minutos se vuelve a mirar', (tester) async {
    repository.pending = Completer<void>();
    open();
    // Sin esperar el future: si faltara el timeout no terminaría nunca y el
    // test se colgaría hasta el límite de testWidgets (10 minutos).
    var done = false;
    unawaited(controller().check().then((_) => done = true));
    await tester.pump(updateCheckTimeout);
    expect(done, isTrue);
    expect(updateAvailable(), isFalse);

    repository
      ..pending = null
      ..published = 'def5678';
    now = start.add(updateCheckInterval);
    await controller().check();
    expect(repository.calls, 2);
    expect(updateAvailable(), isTrue);
  });

  test('el repositorio por defecto lee la página real (fuera de la web, nada)', () async {
    final real = ProviderContainer.test(
      overrides: [clockProvider.overrideWithValue(() => now)],
    );
    expect(
      await real.read(publishedBuildRepositoryProvider).fetchPublishedBuildId(),
      isNull,
    );
    expect(real.read(buildIdProvider), isEmpty);
  });
}
