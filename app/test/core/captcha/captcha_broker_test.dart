// CaptchaBroker: un token por llamada, con el id del pedido, tiempo máximo y sin
// lanzar nunca. La sesión (iframe o WebView) es simulada.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/captcha/captcha_broker.dart';
import 'package:radici/core/captcha/captcha_protocol.dart';

class FakeSession implements CaptchaSession {
  final StreamController<CaptchaReply> controller = StreamController<CaptchaReply>.broadcast();
  final List<String> requested = [];
  bool disposed = false;

  @override
  Stream<CaptchaReply> get replies => controller.stream;

  @override
  void request(String id) => requested.add(id);

  @override
  void dispose() => disposed = true;

  void say(CaptchaReply reply) => controller.add(reply);
}

String idOf(int n) => n.toRadixString(16).padLeft(32, '0');

void main() {
  late List<FakeSession> sessions;
  late List<String?> locales;
  late int counter;
  late CaptchaBroker broker;

  CaptchaBroker build({Duration timeout = const Duration(seconds: 20), Duration interactive = const Duration(seconds: 120)}) {
    return CaptchaBroker(
      timeout: timeout,
      interactiveTimeout: interactive,
      newId: () => idOf(++counter),
      sessionFactory: (locale) {
        locales.add(locale);
        final session = FakeSession();
        sessions.add(session);
        return session;
      },
    );
  }

  setUp(() {
    sessions = [];
    locales = [];
    counter = 0;
    broker = build();
  });

  test('pide el token con un id nuevo cuando la página está lista y devuelve el que llega con ese id', () async {
    final future = broker.token(locale: 'es');
    await pumpEventQueue();
    final session = sessions.single;
    expect(locales, ['es']);
    expect(session.requested, isEmpty); // espera el ready

    session.say(const CaptchaReady());
    await pumpEventQueue();
    expect(session.requested, [idOf(1)]);

    session.say(CaptchaToken(id: idOf(1), token: 'tok.en'));
    expect(await future, 'tok.en');
    expect(session.disposed, isTrue);
  });

  test('un token con otro id (de otro pedido o inventado) se ignora', () async {
    final future = broker.token();
    await pumpEventQueue();
    final session = sessions.single..say(const CaptchaReady());
    await pumpEventQueue();
    session
      ..say(CaptchaToken(id: idOf(99), token: 'ajeno'))
      ..say(CaptchaError(id: idOf(99), code: 'x'))
      ..say(CaptchaInteractive(id: idOf(99), visible: true));
    await pumpEventQueue();
    session.say(CaptchaToken(id: idOf(1), token: 'bueno'));
    expect(await future, 'bueno');
  });

  test('cada llamada es un pedido nuevo: otro id, otra página, otro token', () async {
    final first = broker.token();
    await pumpEventQueue();
    sessions[0]
      ..say(const CaptchaReady())
      ..say(CaptchaToken(id: idOf(1), token: 'uno'));
    expect(await first, 'uno');

    final second = broker.token();
    await pumpEventQueue();
    expect(sessions, hasLength(2));
    sessions[1]
      ..say(const CaptchaReady())
      ..say(CaptchaToken(id: idOf(2), token: 'dos'));
    expect(await second, 'dos');
    expect(sessions.every((s) => s.disposed), isTrue);
  });

  test('llamadas a la vez: una por vez (cada token es de un solo pedido)', () async {
    final first = broker.token();
    final second = broker.token();
    await pumpEventQueue();
    expect(sessions, hasLength(1)); // la segunda espera
    sessions[0].say(CaptchaToken(id: idOf(1), token: 'uno'));
    expect(await first, 'uno');
    await pumpEventQueue();
    expect(sessions, hasLength(2));
    sessions[1].say(CaptchaToken(id: idOf(2), token: 'dos'));
    expect(await second, 'dos');
  });

  test('un error de la página con el id del pedido da null y cierra la página', () async {
    final future = broker.token();
    await pumpEventQueue();
    sessions.single.say(CaptchaError(id: idOf(1), code: '110200'));
    expect(await future, isNull);
    expect(sessions.single.disposed, isTrue);
  });

  test('si la página no carga (sin red) da null enseguida, sin esperar el tiempo', () async {
    final future = broker.token();
    await pumpEventQueue();
    sessions.single.say(const CaptchaLoadFailed());
    expect(await future, isNull);
  });

  test('si la página se cierra sin responder, null', () async {
    final future = broker.token();
    await pumpEventQueue();
    await sessions.single.controller.close();
    expect(await future, isNull);
  });

  test('si la plataforma no puede abrir la página (la fábrica lanza), null y no lanza', () async {
    final failing = CaptchaBroker(sessionFactory: (_) => throw UnsupportedError('sin WebView'));
    expect(await failing.token(), isNull);
    // Y la cola sigue andando para el pedido siguiente.
    expect(await failing.token(), isNull);
  });

  test('si la plataforma lanza al pedir el token, null', () async {
    final session = _ThrowingSession();
    final b = CaptchaBroker(sessionFactory: (_) => session);
    final future = b.token();
    await pumpEventQueue();
    session.controller.add(const CaptchaReady());
    expect(await future, isNull);
    expect(session.disposed, isTrue);
  });

  group('tiempos', () {
    test('sin respuesta a los 20 s: null y la página se cierra', () {
      fakeAsync((async) {
        // El broker se crea dentro de fakeAsync: su cola de pedidos usa los microtasks simulados.
        final b = build();
        String? result = 'sin resolver';
        b.token().then((value) => result = value);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 19));
        expect(result, 'sin resolver');
        async.elapse(const Duration(seconds: 2));
        expect(result, isNull);
        expect(sessions.single.disposed, isTrue);
      });
    });

    test('si Cloudflare pide tocar la casilla, hay más tiempo; al soltarla vuelve el corto', () {
      fakeAsync((async) {
        final b = build();
        String? result = 'sin resolver';
        b.token().then((value) => result = value);
        async.flushMicrotasks();
        sessions.single.say(CaptchaInteractive(id: idOf(1), visible: true));
        async.elapse(const Duration(seconds: 100));
        expect(result, 'sin resolver');
        sessions.single.say(CaptchaInteractive(id: idOf(1), visible: false));
        async.elapse(const Duration(seconds: 19));
        expect(result, 'sin resolver');
        async.elapse(const Duration(seconds: 2));
        expect(result, isNull);
      });
    });

    test('con la casilla a la vista, también vence a los 120 s', () {
      fakeAsync((async) {
        final b = build();
        String? result = 'sin resolver';
        b.token().then((value) => result = value);
        async.flushMicrotasks();
        sessions.single.say(CaptchaInteractive(id: idOf(1), visible: true));
        async.elapse(const Duration(seconds: 121));
        expect(result, isNull);
        expect(sessions.single.disposed, isTrue);
      });
    });

    test('un pedido que venció no bloquea al siguiente', () {
      fakeAsync((async) {
        final b = build();
        b.token();
        final second = <String?>[];
        b.token().then(second.add);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 21));
        expect(sessions, hasLength(2));
        sessions[1].say(CaptchaToken(id: idOf(2), token: 'dos'));
        async.flushMicrotasks();
        expect(second, ['dos']);
      });
    });
  });
}

class _ThrowingSession extends FakeSession {
  @override
  void request(String id) => throw StateError('sin canal');
}
