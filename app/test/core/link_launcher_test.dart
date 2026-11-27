// Qué modo de url_launcher usa cada método de LinkLauncher: las apps externas
// (WhatsApp, teléfono) fuera de la app; las páginas de la web en la hoja de
// Safari o la pestaña de Chrome, con el navegador como respaldo.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Registra cada pedido; [inAppResult] es lo que contesta la vista interna
/// (o [inAppError], que se lanza).
class _FakeUrlLauncher extends UrlLauncherPlatform {
  final List<(String, PreferredLaunchMode)> calls = [];
  bool inAppResult = true;
  PlatformException? inAppError;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    calls.add((url, options.mode));
    if (options.mode == PreferredLaunchMode.inAppBrowserView) {
      final error = inAppError;
      if (error != null) throw error;
      return inAppResult;
    }
    return true;
  }
}

void main() {
  late UrlLauncherPlatform original;
  late _FakeUrlLauncher platform;
  final page = Uri.parse('https://radicicucina.app/richiesta/?lang=es');
  const launcher = UrlLauncherLinkLauncher();

  setUp(() {
    original = UrlLauncherPlatform.instance;
    platform = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = platform;
  });
  tearDown(() => UrlLauncherPlatform.instance = original);

  test('launch abre afuera de la app', () async {
    expect(await launcher.launch(Uri.parse('https://wa.me/39333')), isTrue);
    expect(platform.calls, [
      ('https://wa.me/39333', PreferredLaunchMode.externalApplication),
    ]);
  });

  test(
    'openPage abre la página en la vista del navegador del sistema',
    () async {
      expect(await launcher.openPage(page), isTrue);
      expect(platform.calls, [
        (page.toString(), PreferredLaunchMode.inAppBrowserView),
      ]);
    },
  );

  test('si la vista interna no abre, openPage usa el navegador', () async {
    platform.inAppResult = false;
    expect(await launcher.openPage(page), isTrue);
    expect(platform.calls.map((c) => c.$2), [
      PreferredLaunchMode.inAppBrowserView,
      PreferredLaunchMode.externalApplication,
    ]);
  });

  test('si la vista interna falla, openPage usa el navegador', () async {
    platform.inAppError = PlatformException(code: 'ACTIVITY_NOT_FOUND');
    expect(await launcher.openPage(page), isTrue);
    expect(platform.calls.map((c) => c.$2), [
      PreferredLaunchMode.inAppBrowserView,
      PreferredLaunchMode.externalApplication,
    ]);
  });
}
