// El envío del menú con el SDK real contra un servidor HTTP simulado: lo que
// salió, leído de menu_sends con la RLS (una sola consulta para varias
// semanas, el último de cada una aunque las filas lleguen en otro orden), y
// la vista previa y el envío con la función chef (POST con la sesión de
// Evelyn y la región en la URL, nunca la cabecera x-region): la respuesta
// leída entera o nada, cada error a su tipo (con el estado de la sesión y
// emailSent), la sesión renovada una vez ante un 401 y el tiempo de espera.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/features/requests/domain/chef_request.dart'
    show ClientLocale;
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';

import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';
import '../../../support/supabase_http_fake.dart';

Matcher _failure(
  MenuSendFailureKind kind, {
  bool emailSent = false,
  SessionStatus? status,
}) => throwsA(
  isA<MenuSendFailure>()
      .having((f) => f.kind, 'kind', kind)
      .having((f) => f.emailSent, 'emailSent', emailSent)
      .having((f) => f.status, 'status', status),
);

Map<String, Object?> _sendRow({
  required String id,
  required String session,
  int version = 1,
  String sentAt = '2026-11-22T13:32:00+00:00',
  List<String> via = const ['email'],
  String? confirmedAt,
  String? changesAt,
  String? changesText,
}) => {
  'id': id,
  'session_id': session,
  'menu_version': version,
  'sent_at': sentAt,
  'sent_via': via,
  'client_confirmed_at': confirmedAt,
  'changes_requested_at': changesAt,
  'changes_text': changesText,
};

void main() {
  const sendId = 'bbbbbbbb-0000-4000-8000-000000000001';

  Map<String, Object?> previewBody() => {
    'sendId': sendId,
    'locale': 'it',
    'translated': true,
    'contact': {
      'name': 'Giulia Rossi',
      'email': 'giulia@example.test',
      'phone': '+393331234567',
    },
    'message': {
      'subject': 'Radici: il menù della settimana 2 di 4 (2 dic)',
      'emailText': 'Ciao Giulia!\n\n[link personale per confermare]',
      'whatsappText': 'Ciao Giulia!\n[link personale per confermare]',
    },
  };

  Map<String, Object?> sendBody({bool whatsapp = true}) => {
    'sentAt': '2026-11-22T13:32:00.123456+00:00',
    'sentVia': ['email', if (whatsapp) 'whatsapp'],
    if (whatsapp)
      'whatsappText':
          'Ciao Giulia!\nhttps://radicicucina.app/prenotazione/#t=x',
    if (whatsapp) 'whatsappPhone': '+393331234567',
  };

  final previewRequest = MenuPreviewRequest(
    sessionId: sessionId(2),
    menuVersion: 3,
  );
  const sendRequest = MenuSendRequest(
    sendId: sendId,
    email: true,
    whatsapp: true,
  );

  late FakeSupabaseHttp server;
  late SupabaseMenuSendsRepository repository;

  setUp(() async {
    server = FakeSupabaseHttp((_) async => jsonResponse(<Object>[]));
    repository = SupabaseMenuSendsRepository(server.client);
    await signInFake(server);
  });

  tearDown(() => server.dispose());

  group('fetchLatestSends', () {
    test('una sola lectura de menu_sends para todas las semanas, solo los que salieron, y el último de cada una', () async {
      server.handler = (_) async => jsonResponse([
        // Llegan en cualquier orden: el último sale igual.
        _sendRow(id: 'send-1', session: sessionId(1)),
        _sendRow(
          id: 'send-2',
          session: sessionId(1),
          version: 2,
          sentAt: '2026-11-22T15:00:00+00:00',
          changesAt: '2026-11-22T16:00:00+00:00',
          changesText: 'Sin cebolla',
        ),
        _sendRow(id: 'send-3', session: sessionId(3), via: ['whatsapp']),
      ]);

      final latest = await repository.fetchLatestSends(
        chefId: testChefId,
        sessionIds: [sessionId(1), sessionId(2), sessionId(3)],
      );

      expect(latest.keys, unorderedEquals([sessionId(1), sessionId(3)]));
      expect(latest[sessionId(1)]!.id, 'send-2');
      expect(latest[sessionId(1)]!.changesText, 'Sin cebolla');
      expect(latest[sessionId(3)]!.via, [MenuSendChannel.whatsapp]);
      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/rest/v1/menu_sends');
      final query = request.url.queryParameters;
      expect(
        query['select'],
        'id,session_id,menu_version,sent_at,sent_via,client_confirmed_at,'
        'changes_requested_at,changes_text',
      );
      expect(query['chef_id'], 'eq.$testChefId');
      expect(
        query['session_id'],
        'in.("${sessionId(1)}","${sessionId(2)}","${sessionId(3)}")',
      );
      expect(query['sent_at'], 'not.is.null');
      expect(query['order'], 'sent_at.desc.nullslast,id.desc.nullslast');
      expect(query['limit'], '1000');
      // La sesión de quien entró: la RLS de la cocina.
      expect(request.headers['Authorization'], 'Bearer ${fakeJwt('user-1')}');
    });

    test('sin semanas no pregunta nada', () async {
      expect(
        await repository.fetchLatestSends(chefId: testChefId, sessionIds: []),
        isEmpty,
      );
      expect(server.requests, isEmpty);
    });

    // Sin red no: el SDK reintenta los GET con esperas de segundos; la
    // traducción es la misma (_read).
    test('una fila rota o un 500 dan unavailable', () async {
      server.handler = (_) async => jsonResponse([
        {..._sendRow(id: 'send-1', session: sessionId(1)), 'sent_via': null},
      ]);
      await expectLater(
        repository.fetchLatestSends(
          chefId: testChefId,
          sessionIds: [sessionId(1)],
        ),
        _failure(MenuSendFailureKind.unavailable),
      );
      server.handler = (_) async => jsonResponse({
        'code': 'XX000',
        'message': 'error',
        'details': null,
        'hint': null,
      }, status: 500);
      await expectLater(
        repository.fetchLatestSends(
          chefId: testChefId,
          sessionIds: [sessionId(1)],
        ),
        _failure(MenuSendFailureKind.unavailable),
      );
    });
  });

  group('fetchSend', () {
    test('el envío por id si ya salió (la RLS de la cocina)', () async {
      server.handler = (_) async =>
          jsonResponse([_sendRow(id: sendId, session: sessionId(2))]);
      final record = await repository.fetchSend(
        chefId: testChefId,
        sendId: sendId,
      );
      expect(record!.sessionId, sessionId(2));
      final query = server.last.url.queryParameters;
      expect(query['id'], 'eq.$sendId');
      expect(query['chef_id'], 'eq.$testChefId');
      expect(query['sent_at'], 'not.is.null');
    });

    test('null si no existe o todavía no salió', () async {
      server.handler = (_) async => jsonResponse(<Object>[]);
      expect(
        await repository.fetchSend(chefId: testChefId, sendId: sendId),
        isNull,
      );
    });
  });

  group('preview', () {
    test('POST a /functions/v1/chef/menus/preview con la sesión, la región en la URL y las tres claves', () async {
      server.handler = (_) async => jsonResponse(previewBody());

      final preview = await repository.preview(previewRequest);

      expect(preview.sendId, sendId);
      expect(preview.locale, ClientLocale.it);
      expect(preview.contact.name, 'Giulia Rossi');
      final request = server.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/functions/v1/chef/menus/preview');
      expect(request.url.queryParameters, {
        'forceFunctionRegion': 'eu-central-1',
      });
      expect(request.headers['Authorization'], 'Bearer ${fakeJwt('user-1')}');
      expect(request.headers['apikey'], 'sb_publishable_test');
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('x-region')),
      );
      expect(jsonBodyOf(request), {
        'sessionId': sessionId(2),
        'menuVersion': 3,
        'translate': true,
      });
    });

    test('un 200 con otra forma: server (no se ofrece reintentar)', () async {
      server.handler = (_) async =>
          jsonResponse({...previewBody(), 'message': null});
      await expectLater(
        repository.preview(previewRequest),
        _failure(MenuSendFailureKind.server),
      );
    });

    final cases = <(String, int, Object?, MenuSendFailureKind, SessionStatus?)>[
      (
        'la lista no se pudo traducir',
        422,
        {'error': 'untranslatable'},
        MenuSendFailureKind.untranslatable,
        null,
      ),
      (
        'la traducción está apagada',
        501,
        {'error': 'notConfigured'},
        MenuSendFailureKind.notConfigured,
        null,
      ),
      (
        'la cocina pasó su límite',
        429,
        {'error': 'rateLimited'},
        MenuSendFailureKind.rateLimited,
        null,
      ),
      (
        'un 429 de la plataforma',
        429,
        {'message': 'Too many requests'},
        MenuSendFailureKind.unavailable,
        null,
      ),
      (
        'Claude o la base no respondieron',
        503,
        {'error': 'unavailable'},
        MenuSendFailureKind.unavailable,
        null,
      ),
      (
        'otra versión del menú',
        409,
        {'error': 'menuChanged'},
        MenuSendFailureKind.menuChanged,
        null,
      ),
      (
        'un menú sin platos',
        409,
        {'error': 'menuEmpty'},
        MenuSendFailureKind.menuEmpty,
        null,
      ),
      (
        'la semana ya no se manda, con su estado',
        409,
        {'error': 'sessionNotEditable', 'status': 'cancelled'},
        MenuSendFailureKind.sessionNotEditable,
        SessionStatus.cancelled,
      ),
      (
        'un estado que no se conoce no pasa',
        409,
        {'error': 'sessionNotEditable', 'status': 'raro'},
        MenuSendFailureKind.sessionNotEditable,
        null,
      ),
      (
        'una sesión sin pedido',
        409,
        {'error': 'sessionWithoutRequest'},
        MenuSendFailureKind.sessionWithoutRequest,
        null,
      ),
      (
        'otro 409',
        409,
        {'error': 'conflict'},
        MenuSendFailureKind.conflict,
        null,
      ),
      (
        'la sesión no existe',
        404,
        {'error': 'sessionNotFound'},
        MenuSendFailureKind.sessionNotFound,
        null,
      ),
      (
        'sin menú guardado',
        404,
        {'error': 'menuNotFound'},
        MenuSendFailureKind.menuNotFound,
        null,
      ),
      (
        'la función sin desplegar',
        404,
        {'message': 'Not found'},
        MenuSendFailureKind.unavailable,
        null,
      ),
      (
        'una ruta que la función no tiene',
        404,
        {'error': 'notFound'},
        MenuSendFailureKind.unavailable,
        null,
      ),
      (
        'un campo que no cumple',
        400,
        {
          'errors': {'menuVersion': 'range'},
        },
        MenuSendFailureKind.invalid,
        null,
      ),
      (
        'un 422 sin su código',
        422,
        {'message': 'Unprocessable'},
        MenuSendFailureKind.invalid,
        null,
      ),
      (
        'no es la cocinera',
        403,
        {'error': 'forbidden'},
        MenuSendFailureKind.forbidden,
        null,
      ),
      (
        'error del servidor',
        500,
        {'error': 'server'},
        MenuSendFailureKind.server,
        null,
      ),
      (
        'un 501 sin su código',
        501,
        'Not Implemented',
        MenuSendFailureKind.server,
        null,
      ),
      (
        'la plataforma no llegó (504)',
        504,
        'Gateway Timeout',
        MenuSendFailureKind.unavailable,
        null,
      ),
    ];
    for (final (name, status, body, kind, sessionStatus) in cases) {
      test('cada error a su tipo: $name', () async {
        server.handler = (_) async => body is String
            ? http.Response(
                body,
                status,
                headers: {'content-type': 'text/plain'},
              )
            : jsonResponse(body, status: status);
        await expectLater(
          repository.preview(previewRequest),
          _failure(kind, status: sessionStatus),
        );
      });
    }

    test('sin conexión', () async {
      server.handler = (_) async => throw http.ClientException('offline');
      await expectLater(
        repository.preview(previewRequest),
        _failure(MenuSendFailureKind.offline),
      );
    });

    test('un Error al mandar (un TypeError) no es sin conexión', () async {
      server.handler = (_) async => throw TypeError();
      await expectLater(
        repository.preview(previewRequest),
        _failure(MenuSendFailureKind.server),
      );
    });

    test('el relay de la plataforma, por su estado', () async {
      for (final (status, kind) in const [
        (502, MenuSendFailureKind.unavailable),
        (500, MenuSendFailureKind.server),
      ]) {
        server.handler = (_) async => http.Response(
          '{"message":"relay"}',
          status,
          headers: {
            'content-type': 'application/json',
            'x-relay-error': 'true',
          },
        );
        await expectLater(repository.preview(previewRequest), _failure(kind));
      }
    });

    test('si no responde en el tiempo de espera, timeout', () async {
      final never = Completer<http.Response>();
      addTearDown(() => never.complete(jsonResponse(previewBody())));
      server.handler = (_) => never.future;
      final quick = SupabaseMenuSendsRepository(
        server.client,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        quick.preview(previewRequest),
        _failure(MenuSendFailureKind.timeout),
      );
    });

    // La traducción corta a los 40 s y el email a unos 25 s (contrato §12 y
    // §13): la app espera más.
    test('el tiempo de espera por defecto tolera lo que tarda la función', () {
      expect(
        SupabaseMenuSendsRepository(server.client).timeout,
        const Duration(seconds: 60),
      );
    });
  });

  group('send', () {
    test('POST a /functions/v1/chef/menus/send con el envío y los canales; con WhatsApp, el texto y el teléfono', () async {
      server.handler = (_) async => jsonResponse(sendBody());

      final result = await repository.send(sendRequest);

      expect(result.via, [MenuSendChannel.email, MenuSendChannel.whatsapp]);
      expect(result.whatsappPhone, '+393331234567');
      expect(result.whatsAppLink!.path, '/393331234567');
      final request = server.last;
      expect(request.url.path, '/functions/v1/chef/menus/send');
      expect(request.url.queryParameters, {
        'forceFunctionRegion': 'eu-central-1',
      });
      expect(jsonBodyOf(request), {
        'sendId': sendId,
        'email': true,
        'whatsapp': true,
      });
    });

    test('solo por email: sin texto de WhatsApp', () async {
      server.handler = (_) async => jsonResponse(sendBody(whatsapp: false));
      final result = await repository.send(
        const MenuSendRequest(sendId: sendId, email: true, whatsapp: false),
      );
      expect(result.whatsAppLink, isNull);
    });

    final cases = <(String, int, Object?, MenuSendFailureKind, bool)>[
      (
        'el email no salió',
        502,
        {'error': 'emailFailed'},
        MenuSendFailureKind.emailFailed,
        false,
      ),
      (
        'un 502 de la plataforma',
        502,
        'Bad Gateway',
        MenuSendFailureKind.unavailable,
        false,
      ),
      (
        'el email no está configurado',
        503,
        {'error': 'emailUnavailable'},
        MenuSendFailureKind.emailUnavailable,
        false,
      ),
      (
        'ya había salido',
        409,
        {'error': 'alreadySent'},
        MenuSendFailureKind.alreadySent,
        false,
      ),
      (
        'el contacto sin email',
        409,
        {'error': 'noEmail'},
        MenuSendFailureKind.noEmail,
        false,
      ),
      (
        'el contacto sin teléfono',
        409,
        {'error': 'noPhone'},
        MenuSendFailureKind.noPhone,
        false,
      ),
      (
        'cambió algo desde la vista previa',
        409,
        {'error': 'menuChanged'},
        MenuSendFailureKind.menuChanged,
        false,
      ),
      (
        'el envío no existe',
        404,
        {'error': 'sendNotFound'},
        MenuSendFailureKind.sendNotFound,
        false,
      ),
      (
        'el email salió y la base no respondió al marcarlo',
        503,
        {'error': 'unavailable', 'emailSent': true},
        MenuSendFailureKind.unavailable,
        true,
      ),
      (
        'el email salió y justo cambió el menú',
        409,
        {'error': 'menuChanged', 'emailSent': true},
        MenuSendFailureKind.menuChanged,
        true,
      ),
      (
        'el email salió y la base dio otro error',
        500,
        {'error': 'server', 'emailSent': true},
        MenuSendFailureKind.server,
        true,
      ),
      (
        'emailSent que no es true no cuenta',
        503,
        {'error': 'unavailable', 'emailSent': 'true'},
        MenuSendFailureKind.unavailable,
        false,
      ),
    ];
    for (final (name, status, body, kind, emailSent) in cases) {
      test('cada error a su tipo: $name', () async {
        server.handler = (_) async => body is String
            ? http.Response(
                body,
                status,
                headers: {'content-type': 'text/plain'},
              )
            : jsonResponse(body, status: status);
        await expectLater(
          repository.send(sendRequest),
          _failure(kind, emailSent: emailSent),
        );
      });
    }

    test('un 200 con otra forma: server', () async {
      server.handler = (_) async => jsonResponse({
        'sentAt': 'ayer',
        'sentVia': ['email'],
      });
      await expectLater(
        repository.send(sendRequest),
        _failure(MenuSendFailureKind.server),
      );
    });

    test('se pueden reintentar solo las fallas de la red o del momento', () {
      expect(
        {
          for (final kind in MenuSendFailureKind.values)
            if (kind.canRetry) kind,
        },
        {
          MenuSendFailureKind.offline,
          MenuSendFailureKind.timeout,
          MenuSendFailureKind.unavailable,
        },
      );
    });
  });

  group('un 401: renueva la sesión una vez y reintenta una vez', () {
    bool isRefresh(http.Request request) =>
        request.url.path == '/auth/v1/token' &&
        request.url.queryParameters['grant_type'] == 'refresh_token';
    bool isSend(http.Request request) =>
        request.url.path == '/functions/v1/chef/menus/send';
    final renewed = fakeJwt('user-1-renovado');
    Map<String, Object?> renewedSession() => {
      ...fakeSessionJson('user-1', 'evelyn@example.test'),
      'access_token': renewed,
    };

    test('con la sesión renovada, el reintento manda (un 401 no llegó a mandar nada)', () async {
      var calls = 0;
      server.handler = (request) async {
        if (isRefresh(request)) return jsonResponse(renewedSession());
        calls++;
        return calls == 1
            ? jsonResponse({'error': 'unauthorized'}, status: 401)
            : jsonResponse(sendBody());
      };
      final result = await repository.send(sendRequest);
      expect(result.via, hasLength(2));
      final sends = server.requests.where(isSend).toList();
      expect(sends, hasLength(2));
      expect(sends.last.headers['Authorization'], 'Bearer $renewed');
    });

    test('si vuelve a dar 401, unauthorized, sin más intentos', () async {
      server.handler = (request) async => isRefresh(request)
          ? jsonResponse(renewedSession())
          : jsonResponse({'error': 'unauthorized'}, status: 401);
      await expectLater(
        repository.send(sendRequest),
        _failure(MenuSendFailureKind.unauthorized),
      );
      expect(server.requests.where(isRefresh), hasLength(1));
      expect(server.requests.where(isSend), hasLength(2));
    });

    test(
      'si la sesión no se puede renovar, unauthorized sin reintentar',
      () async {
        server.handler = (request) async => isRefresh(request)
            ? jsonResponse({
                'code': 400,
                'error_code': 'refresh_token_not_found',
                'msg': 'Invalid Refresh Token',
              }, status: 400)
            : jsonResponse({'error': 'unauthorized'}, status: 401);
        await expectLater(
          repository.send(sendRequest),
          _failure(MenuSendFailureKind.unauthorized),
        );
        expect(server.requests.where(isSend), hasLength(1));
      },
    );
  });

  test('MenuSendFailure no imprime nada más que el tipo', () {
    expect(
      const MenuSendFailure(
        MenuSendFailureKind.unavailable,
        emailSent: true,
      ).toString(),
      'MenuSendFailure(unavailable, emailSent)',
    );
  });
}
