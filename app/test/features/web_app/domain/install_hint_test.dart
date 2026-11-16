// Cuándo va el aviso de Safari: iPhone o iPad en el navegador, fuera de la app
// agregada a la pantalla de inicio.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/features/web_app/domain/install_hint.dart';

import '../../../support/browser_fakes.dart';

BrowserInfo _info(
  String userAgent, {
  String platform = 'iPhone',
  int maxTouchPoints = 5,
  bool navigatorStandalone = false,
  bool displayModeStandalone = false,
}) => BrowserInfo(
  userAgent: userAgent,
  platform: platform,
  maxTouchPoints: maxTouchPoints,
  navigatorStandalone: navigatorStandalone,
  displayModeStandalone: displayModeStandalone,
);

const _iPadSafari =
    'Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1';
// iPadOS 13 o más nuevo: Safari pide la versión de escritorio y se presenta
// como un Mac.
const _iPadDesktop =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/18.6 Safari/605.1.15';
const _iPhoneChrome =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0.7390.96 '
    'Mobile/15E148 Safari/604.1';
const _androidChrome =
    'Mozilla/5.0 (Linux; Android 15; Pixel 8) AppleWebKit/537.36 (KHTML, like '
    'Gecko) Chrome/141.0.0.0 Mobile Safari/537.36';
const _windowsEdge =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like '
    'Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0';

void main() {
  test('iPhone en Safari: sí', () {
    expect(isIosBrowserOutsideApp(iPhoneInSafari), isTrue);
  });

  test('iPad en Safari, también cuando se presenta como un Mac', () {
    expect(isIosBrowserOutsideApp(_info(_iPadSafari, platform: 'iPad')), isTrue);
    expect(
      isIosBrowserOutsideApp(_info(_iPadDesktop, platform: 'MacIntel')),
      isTrue,
    );
  });

  test('otro navegador del iPhone (también es Safari por dentro): sí', () {
    expect(isIosBrowserOutsideApp(_info(_iPhoneChrome)), isTrue);
  });

  test('la app instalada (pantalla de inicio): no', () {
    expect(
      isIosBrowserOutsideApp(_info(iPhoneSafari, navigatorStandalone: true)),
      isFalse,
    );
    expect(
      isIosBrowserOutsideApp(_info(iPhoneSafari, displayModeStandalone: true)),
      isFalse,
    );
  });

  test('un Mac, Android o la computadora: no', () {
    expect(
      isIosBrowserOutsideApp(
        _info(_iPadDesktop, platform: 'MacIntel', maxTouchPoints: 0),
      ),
      isFalse,
    );
    expect(
      isIosBrowserOutsideApp(_info(_androidChrome, platform: 'Linux armv81')),
      isFalse,
    );
    expect(
      isIosBrowserOutsideApp(
        _info(_windowsEdge, platform: 'Win32', maxTouchPoints: 0),
      ),
      isFalse,
    );
  });
}
