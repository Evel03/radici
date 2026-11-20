// La traducción de un plato con el SDK real contra un servidor HTTP simulado:
// POST a /functions/v1/chef/translate con la sesión de Evelyn y la región en
// la URL (nunca la cabecera x-region, que CORS no permite), la respuesta
// leída entera o nada, cada error a su tipo y el tiempo de espera.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/features/recipes/data/translation_repository.dart';
import 'package:radici/features/recipes/domain/recipe_translation.dart';

import '../../../support/supabase_http_fake.dart';

Matcher _failure(TranslationFailureKind kind) =>
    throwsA(isA<TranslationFailure>().having((f) => f.kind, 'kind', kind));

void main() {
  const SpanishText milanesa = (
    name: 'Milanesa a la napolitana',
    description: 'Con salsa de tomate, jamón y mozzarella.',
  );

  Map<String, Object?> translated({bool withDescription = true}) => {
    'it': {
      'name': 'Cotoletta alla napoletana',
      'description': withDescription
          ? 'Con pomodoro, prosciutto cotto e mozzarella.'
          : null,
    },
    'en': {
      'name': 'Neapolitan-style milanese',
      'description': withDescription
          ? 'With tomato sauce, ham and mozzarella.'
          : null,
    },
  };

  late FakeSupabaseHttp server;
  late SupabaseTranslationRepository repository;

  setUp(() async {
    server = FakeSupabaseHttp((_) async => jsonResponse(translated()));
    repository = SupabaseTranslationRepository(server.client);
    await signInFake(server);
  });

  tearDown(() => server.dispose());

  test('POST a /functions/v1/chef/translate con la sesión, la región en la URL y el español', () async {
    final result = await repository.translate(milanesa);

    expect(result, (
      it: (
        name: 'Cotoletta alla napoletana',
        description: 'Con pomodoro, prosciutto cotto e mozzarella.',
      ),
      en: (
        name: 'Neapolitan-style milanese',
        description: 'With tomato sauce, ham and mozzarella.',
      ),
    ));
    final request = server.last;
    expect(request.method, 'POST');
    expect(request.url.path, '/functions/v1/chef/translate');
    expect(request.url.queryParameters, {
      'forceFunctionRegion': 'eu-central-1',
    });
    // La sesión de Evelyn, no la clave publicable, y la clave en apikey.
    expect(request.headers['Authorization'], 'Bearer ${fakeJwt('user-1')}');
    expect(request.headers['apikey'], 'sb_publishable_test');
    expect(request.headers['Content-Type'], startsWith('application/json'));
    expect(
      request.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('x-region')),
    );
    // Solo el nombre y la descripción (contrato §12: una clave de más es 400).
    expect(jsonBodyOf(request), {
      'name': 'Milanesa a la napolitana',
      'description': 'Con salsa de tomate, jamón y mozzarella.',
    });
  });

  test('sin descripción manda null y vuelve sin descripción', () async {
    server.handler = (_) async =>
        jsonResponse(translated(withDescription: false));
    final result = await repository.translate((
      name: 'Locro',
      description: null,
    ));
    expect(jsonBodyOf(server.last), {'name': 'Locro', 'description': null});
    expect(result.it, (name: 'Cotoletta alla napoletana', description: null));
    expect(result.en.description, isNull);
  });

  test(
    'los textos quedan como los guarda la base: sin espacios de más',
    () async {
      server.handler = (_) async => jsonResponse({
        'it': {
          'name': '  Cotoletta   alla napoletana ',
          'description': 'Con\tpomodoro.',
        },
        'en': {'name': 'Milanese', 'description': 'With tomato.'},
      });
      final result = await repository.translate(milanesa);
      expect(result.it, (
        name: 'Cotoletta alla napoletana',
        description: 'Con pomodoro.',
      ));
    },
  );

  group('una respuesta 200 con otra forma: todo o nada', () {
    final cases = <(String, Object?)>[
      ('no es un objeto', 'ok'),
      ('falta el inglés', {'it': translated()['it']}),
      (
        'un nombre vacío',
        {
          ...translated(),
          'en': {'name': '  ', 'description': 'With tomato.'},
        },
      ),
      (
        'un nombre de más de 120 caracteres',
        {
          ...translated(),
          'it': {'name': 'n' * 121, 'description': 'Con pomodoro.'},
        },
      ),
      (
        'una descripción de más de 200 caracteres',
        {
          ...translated(),
          'en': {'name': 'Milanese', 'description': 'd' * 201},
        },
      ),
      ('sin la descripción que se pidió', translated(withDescription: false)),
      (
        'un nombre que no es texto',
        {
          ...translated(),
          'it': {'name': 7, 'description': 'Con pomodoro.'},
        },
      ),
    ];
    for (final (name, body) in cases) {
      test(name, () async {
        server.handler = (_) async => jsonResponse(body);
        await expectLater(
          repository.translate(milanesa),
          _failure(TranslationFailureKind.unavailable),
        );
      });
    }

    test('con una descripción que no se pidió', () async {
      await expectLater(
        repository.translate((name: 'Locro', description: null)),
        _failure(TranslationFailureKind.unavailable),
      );
    });
  });

  group('cada error, a su tipo', () {
    final cases = <(String, int, Object?, TranslationFailureKind)>[
      (
        'la traducción no está disponible ahora (503)',
        503,
        {'error': 'unavailable'},
        TranslationFailureKind.unavailable,
      ),
      (
        'Claude no lo tradujo (422)',
        422,
        {'error': 'untranslatable'},
        TranslationFailureKind.untranslatable,
      ),
      (
        'la traducción está apagada (501)',
        501,
        {'error': 'notConfigured'},
        TranslationFailureKind.notConfigured,
      ),
      (
        'la cocina pasó su límite (429)',
        429,
        {'error': 'rateLimited'},
        TranslationFailureKind.rateLimited,
      ),
      // Demasiados pedidos de la plataforma, sin el código de la función.
      (
        'un 429 de la plataforma',
        429,
        {'message': 'Too many requests'},
        TranslationFailureKind.unavailable,
      ),
      (
        'sin sesión válida',
        401,
        {'error': 'unauthorized'},
        TranslationFailureKind.unauthorized,
      ),
      (
        'no es la cocinera ni un colaborador suyo',
        403,
        {'error': 'forbidden'},
        TranslationFailureKind.forbidden,
      ),
      (
        'un campo que no cumple',
        400,
        {
          'errors': {'name': 'tooLong'},
        },
        TranslationFailureKind.invalid,
      ),
      (
        'cuerpo de más de 8 KB',
        413,
        {'error': 'tooLarge'},
        TranslationFailureKind.invalid,
      ),
      (
        'un 422 sin el código de la función',
        422,
        {'message': 'Unprocessable'},
        TranslationFailureKind.invalid,
      ),
      // La función no está desplegada, o es de antes de /translate.
      (
        'función inexistente',
        404,
        {'message': 'Not found'},
        TranslationFailureKind.unavailable,
      ),
      (
        'ruta desconocida',
        404,
        {'error': 'notFound'},
        TranslationFailureKind.unavailable,
      ),
      (
        'un 501 sin el código de la función',
        501,
        'Not Implemented',
        TranslationFailureKind.server,
      ),
      // Algo roto o mal configurado (una clave inválida, el SDK que no
      // carga): reintentar no lo arregla.
      (
        'error del servidor',
        500,
        {'error': 'server'},
        TranslationFailureKind.server,
      ),
      (
        'la plataforma no llegó a la función (504)',
        504,
        'Gateway Timeout',
        TranslationFailureKind.unavailable,
      ),
      (
        'respuesta que no es JSON (502)',
        502,
        'Bad Gateway',
        TranslationFailureKind.unavailable,
      ),
    ];
    for (final (name, status, body, kind) in cases) {
      test(name, () async {
        server.handler = (_) async => body is String
            ? http.Response(
                body,
                status,
                headers: {'content-type': 'text/plain'},
              )
            : jsonResponse(body, status: status);
        await expectLater(repository.translate(milanesa), _failure(kind));
      });
    }

    test('sin conexión', () async {
      server.handler = (_) async => throw http.ClientException('offline');
      await expectLater(
        repository.translate(milanesa),
        _failure(TranslationFailureKind.offline),
      );
    });

    test('se puede reintentar solo lo de la red o del momento', () {
      expect(
        {
          for (final kind in TranslationFailureKind.values)
            if (kind.canRetry) kind,
        },
        {
          TranslationFailureKind.unavailable,
          TranslationFailureKind.offline,
          TranslationFailureKind.timeout,
        },
      );
    });
  });

  test('si no responde en el tiempo de espera, timeout', () async {
    final never = Completer<http.Response>();
    addTearDown(() => never.complete(jsonResponse(translated())));
    server.handler = (_) => never.future;
    final quick = SupabaseTranslationRepository(
      server.client,
      timeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      quick.translate(milanesa),
      _failure(TranslationFailureKind.timeout),
    );
  });

  // La función corta a los 40 s (contrato §12): la app espera más.
  test(
    'el tiempo de espera por defecto tolera la espera máxima de la función',
    () {
      expect(
        SupabaseTranslationRepository(server.client).timeout,
        const Duration(seconds: 60),
      );
    },
  );

  test('TranslationFailure no imprime nada más que el tipo', () {
    expect(
      const TranslationFailure(TranslationFailureKind.offline).toString(),
      'TranslationFailure(offline)',
    );
  });
}
