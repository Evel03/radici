// Aviso de Safari: se muestra en el iPhone fuera de la app instalada hasta que
// se cierra, y una vez cerrado no vuelve en ese dispositivo.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/features/web_app/application/install_hint_controller.dart';
import 'package:radici/features/web_app/domain/install_hint.dart';

import '../../../support/browser_fakes.dart';
import '../../../support/pump_app.dart';

void main() {
  ProviderContainer open(FakeBrowser browser) => ProviderContainer.test(
    retry: noRetry,
    overrides: [browserProvider.overrideWithValue(browser)],
  );

  test('iPhone en Safari: se muestra', () {
    final container = open(FakeBrowser(info: iPhoneInSafari));
    expect(container.read(installHintControllerProvider), isTrue);
  });

  test('cerrado: se va y queda guardado en el dispositivo', () {
    final browser = FakeBrowser(info: iPhoneInSafari);
    final container = open(browser);
    container.read(installHintControllerProvider.notifier).dismiss();
    expect(container.read(installHintControllerProvider), isFalse);
    expect(browser.flags, {installHintDismissedKey: '1'});

    // Otra vez en Safari, en el mismo dispositivo: no vuelve.
    expect(open(browser).read(installHintControllerProvider), isFalse);
  });

  test('si el dispositivo no deja guardar, igual se cierra por ahora', () {
    final browser = FakeBrowser(info: iPhoneInSafari)..storageBlocked = true;
    final container = open(browser);
    container.read(installHintControllerProvider.notifier).dismiss();
    expect(container.read(installHintControllerProvider), isFalse);
  });

  test('en la app instalada, en otro dispositivo o fuera de la web: no', () {
    const installed = BrowserInfo(
      userAgent: iPhoneSafari,
      platform: 'iPhone',
      maxTouchPoints: 5,
      navigatorStandalone: true,
      displayModeStandalone: true,
    );
    expect(
      open(FakeBrowser(info: installed)).read(installHintControllerProvider),
      isFalse,
    );
    expect(open(FakeBrowser()).read(installHintControllerProvider), isFalse);
    expect(
      ProviderContainer.test().read(installHintControllerProvider),
      isFalse,
    );
  });
}
