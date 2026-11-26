// Protocolo con la página /captcha/: qué se acepta de lo que dice la página y
// cómo se le pide un token. Lo que no encaja se ignora (null).
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/captcha/captcha_protocol.dart';

const id = '0123456789abcdef0123456789abcdef';

Map<String, Object?> message(String type, [Map<String, Object?> extra = const {}]) => {
  'source': 'radici-captcha',
  'v': 1,
  'type': type,
  ...extra,
};

void main() {
  group('isCaptchaId y newCaptchaId', () {
    test('32 hexadecimales en minúscula', () {
      expect(isCaptchaId(id), isTrue);
      for (final bad in <Object?>['', 'abc', id.toUpperCase(), '${id}0', id.substring(1), 'g' * 32, 12, null]) {
        expect(isCaptchaId(bad), isFalse, reason: '$bad');
      }
    });

    test('los ids nuevos son válidos y distintos', () {
      final ids = {for (var i = 0; i < 50; i++) newCaptchaId()};
      expect(ids, hasLength(50));
      expect(ids.every(isCaptchaId), isTrue);
      expect(newCaptchaId(Random(1)), newCaptchaId(Random(1)));
    });
  });

  group('parseCaptchaReply', () {
    test('ready, interactive, token y error (mapa o string JSON)', () {
      expect(parseCaptchaReply(message('ready')), isA<CaptchaReady>());
      expect(parseCaptchaReply(jsonEncode(message('ready'))), isA<CaptchaReady>());

      final interactive = parseCaptchaReply(message('interactive', {'id': id, 'visible': true}));
      expect(interactive, isA<CaptchaInteractive>().having((r) => r.visible, 'visible', isTrue).having((r) => r.id, 'id', id));

      final token = parseCaptchaReply(jsonEncode(message('token', {'id': id, 'token': '0.AbC-d_9'})));
      expect(token, isA<CaptchaToken>().having((r) => r.token, 'token', '0.AbC-d_9').having((r) => r.id, 'id', id));

      final error = parseCaptchaReply(message('error', {'id': id, 'code': '110200'}));
      expect(error, isA<CaptchaError>().having((r) => r.code, 'code', '110200'));
    });

    test('un mapa dinámico de postMessage (Map<Object?, Object?>) también vale', () {
      final dynamicMap = <Object?, Object?>{...message('token', {'id': id, 'token': 'abc'})};
      expect(parseCaptchaReply(dynamicMap), isA<CaptchaToken>());
    });

    test('ignora otra marca, otra versión, tipos desconocidos y campos con otra forma', () {
      final bad = <Object?>[
        null,
        42,
        'no es json',
        '[]',
        <Object?>[],
        {...message('ready'), 'source': 'otra-cosa'},
        {...message('ready'), 'v': 2},
        {...message('ready'), 'v': '1'},
        message('request', {'id': id}),
        message('desconocido'),
        message('token', {'token': 'abc'}),
        message('token', {'id': 'corto', 'token': 'abc'}),
        message('error', {'id': id, 'code': 'texto <libre>'}),
        message('error', {'id': id, 'code': 'x' * 33}),
        message('error', {'id': id}),
        message('interactive', {'id': id, 'visible': 'si'}),
        message('interactive', {'id': id}),
      ];
      for (final raw in bad) {
        expect(parseCaptchaReply(raw), isNull, reason: '$raw');
      }
    });

    test('un token con otra forma (con el id del pedido) termina el pedido con token-shape, para el diagnóstico', () {
      for (final token in <Object?>[null, '', 'con espacio', 'a' * 2049, 5]) {
        final raw = token == null ? message('token', {'id': id}) : message('token', {'id': id, 'token': token});
        expect(
          parseCaptchaReply(raw),
          isA<CaptchaError>().having((r) => r.code, 'code', 'token-shape').having((r) => r.id, 'id', id),
          reason: '$token',
        );
      }
    });

    test('el diagnóstico de una navegación frenada: esquema y host, sin ruta ni query', () {
      expect(captchaBlockedSummary('https://otro.example.com/a/b?c=d#e'), 'https:otro.example.com');
      expect(captchaBlockedSummary('blob:https://radicicucina.app/123'), 'blob');
      expect(captchaBlockedSummary('about:blank#x'), 'about');
      expect(captchaBlockedSummary('data:text/html,<b>'), 'data');
      expect(captchaBlockedSummary(''), 'unknown');
      expect(captchaBlockedSummary('https://${'a' * 80}.com/').length, 40);
    });

    test('un token acepta hasta 2048 caracteres', () {
      expect(parseCaptchaReply(message('token', {'id': id, 'token': 'a' * 2048})), isA<CaptchaToken>());
    });

    test('el token nunca aparece en toString (no se loguea)', () {
      final reply = parseCaptchaReply(message('token', {'id': id, 'token': 'secreto.123'}))!;
      expect(reply.toString(), isNot(contains('secreto')));
    });
  });

  group('captchaRequestMessage', () {
    test('es el JSON que espera la página', () {
      expect(jsonDecode(captchaRequestMessage(id)), {'source': 'radici-captcha', 'v': 1, 'type': 'request', 'id': id});
    });

    test('rechaza un id que no es un id (va dentro de código JavaScript)', () {
      expect(() => captchaRequestMessage("x');alert(1);('"), throwsArgumentError);
      expect(() => captchaRequestMessage(''), throwsArgumentError);
    });
  });

  group('captchaPageUri', () {
    test('web: la página del mismo origen, con el idioma', () {
      expect(captchaPageUri('https://radicicucina.app', locale: 'es').toString(), 'https://radicicucina.app/captcha/?lang=es');
      expect(captchaPageUri('https://radicicucina.app').toString(), 'https://radicicucina.app/captcha/');
      expect(captchaPageUri('http://localhost:5173', locale: 'it').toString(), 'http://localhost:5173/captcha/?lang=it');
    });

    test('nativa: channel=native; solo idiomas soportados', () {
      expect(
        captchaPageUri(captchaProductionOrigin, locale: 'en', native: true).toString(),
        'https://radicicucina.app/captcha/?channel=native&lang=en',
      );
      expect(captchaPageUri(captchaProductionOrigin, locale: 'fr', native: true).toString(), 'https://radicicucina.app/captcha/?channel=native');
    });
  });
}
