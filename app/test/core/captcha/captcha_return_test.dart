// ReturnCaptchaService: el captcha en iOS y Android, en el navegador del
// sistema (Safari / Chrome), con la vuelta radicicaptcha://result. El navegador
// es simulado: [authenticate] devuelve la dirección de vuelta o lanza.
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/captcha/captcha_return.dart';

String idOf(int n) => n.toRadixString(16).padLeft(32, '0');

void main() {
  late List<String> opened;
  late int counter;

  ReturnCaptchaService service(Future<String> Function(String url) reply) {
    return ReturnCaptchaService(
      newId: () => idOf(++counter),
      authenticate: (url) {
        opened.add(url);
        return reply(url);
      },
    );
  }

  setUp(() {
    opened = [];
    counter = 0;
  });

  test('abre /captcha/ con channel=return, el id del pedido y el idioma, y devuelve el token de la vuelta', () async {
    final s = service((url) async => 'radicicaptcha://result?id=${idOf(1)}&token=0.tok-en_1');
    expect(await s.token(locale: 'es'), '0.tok-en_1');
    expect(s.lastFailure, isNull);
    final uri = Uri.parse(opened.single);
    expect('${uri.scheme}://${uri.host}${uri.path}', 'https://radicicucina.app/captcha/');
    expect(uri.queryParameters, {'channel': 'return', 'id': idOf(1), 'lang': 'es'});
  });

  test('cada pedido, su id: la vuelta de otro pedido no vale', () async {
    final s = service((url) async => 'radicicaptcha://result?id=${idOf(99)}&token=ajeno');
    expect(await s.token(), isNull);
    expect(s.lastFailure, 'app-bad-return');
  });

  test('un error de la página llega con su código', () async {
    final s = service((url) async => 'radicicaptcha://result?id=${idOf(1)}&code=600010');
    expect(await s.token(), isNull);
    expect(s.lastFailure, 'page-600010');
  });

  test('un código raro no se refleja: unknown', () async {
    final s = service((url) async => 'radicicaptcha://result?id=${idOf(1)}&code=%3Cb%3Ehola%3C%2Fb%3E');
    expect(await s.token(), isNull);
    expect(s.lastFailure, 'page-unknown');
  });

  test('un token con otra forma: page-token-shape', () async {
    final s = service((url) async => 'radicicaptcha://result?id=${idOf(1)}&token=con%20espacio');
    expect(await s.token(), isNull);
    expect(s.lastFailure, 'page-token-shape');
  });

  test('otra dirección de vuelta (otro esquema u otro host): app-bad-return', () async {
    for (final returned in [
      'https://radicicucina.app/?id=${idOf(1)}&token=x',
      'radicicaptcha://otra?id=${idOf(1)}&token=x',
      'radicicaptcha://result?id=${idOf(1)}',
      'no es una url',
    ]) {
      counter = 0;
      final s = service((url) async => returned);
      expect(await s.token(), isNull, reason: returned);
      expect(s.lastFailure, 'app-bad-return', reason: returned);
    }
  });

  test('la persona cierra la hoja: app-cancelled; otro error del sistema: app-browser-<código>; cualquier otra cosa: app-unavailable', () async {
    final cancelled = service((url) => Future.error(PlatformException(code: 'CANCELED')));
    await cancelled.token();
    expect(cancelled.lastFailure, 'app-cancelled');
    final browser = service((url) => Future.error(PlatformException(code: 'NO_BROWSER')));
    await browser.token();
    expect(browser.lastFailure, 'app-browser-NO_BROWSER');
    final other = service((url) => Future.error(StateError('x')));
    expect(await other.token(), isNull);
    expect(other.lastFailure, 'app-unavailable');
  });

  test('después de un fallo, un pedido que anda deja lastFailure en null', () async {
    var fail = true;
    final s = service((url) async {
      final id = Uri.parse(url).queryParameters['id'];
      return fail ? 'radicicaptcha://result?id=$id&code=cancelled' : 'radicicaptcha://result?id=$id&token=ok';
    });
    expect(await s.token(), isNull);
    expect(s.lastFailure, 'page-cancelled');
    fail = false;
    expect(await s.token(), 'ok');
    expect(s.lastFailure, isNull);
  });

  test('de a un pedido por vez: el segundo abre su hoja cuando terminó el primero', () async {
    final s = service((url) async {
      final id = Uri.parse(url).queryParameters['id'];
      return 'radicicaptcha://result?id=$id&token=t-$id';
    });
    final results = await Future.wait([s.token(), s.token()]);
    expect(results, ['t-${idOf(1)}', 't-${idOf(2)}']);
    expect(opened.length, 2);
  });
}
