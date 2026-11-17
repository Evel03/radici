// build.json: dónde se pide, cómo se lee y cuándo hay una versión nueva.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/web_app/domain/published_build.dart';

void main() {
  final now = DateTime.utc(2026, 11, 16, 9);

  group('publishedBuildUri', () {
    test('build.json junto a la app, con ?t= en milisegundos', () {
      expect(
        publishedBuildUri(Uri.parse('https://radicicucina.app/gestione/'), now)
            .toString(),
        'https://radicicucina.app/gestione/build.json?t=1794819600000',
      );
    });

    test('se resuelve contra la base de la página: sin la ruta del fragmento '
        'ni la query de la página', () {
      expect(
        publishedBuildUri(
          Uri.parse('https://radicicucina.app/gestione/?a=1#/richieste/abc'),
          now,
        ).toString(),
        'https://radicicucina.app/gestione/build.json?t=1794819600000',
      );
      // En local (flutter run) la app está en la raíz.
      expect(
        publishedBuildUri(Uri.parse('http://localhost:8080/'), now).toString(),
        'http://localhost:8080/build.json?t=1794819600000',
      );
    });
  });

  group('parsePublishedBuildId', () {
    test('lee el id que escribe deploy-web.yml', () {
      expect(parsePublishedBuildId('{"buildId":"abc1234"}\n'), 'abc1234');
      expect(parsePublishedBuildId(' { "buildId" : "0f3e9a1" } '), '0f3e9a1');
    });

    test('una respuesta rara no es un id', () {
      for (final body in [
        '',
        'null',
        '[]',
        '"abc1234"',
        '{}',
        '{"buildId":null}',
        '{"buildId":1234567}',
        '{"buildId":""}',
        '{"buildId":"abc 1234"}',
        '{"buildId":"<script>"}',
        '{"buildId":"${'a' * 65}"}',
        '{"buildId":"abc1234"',
        // La página de 404 de Pages, si build.json no está.
        '<!DOCTYPE html><html lang="it"><head><title>404</title></head></html>',
        // Algo enorme nunca es build.json.
        '{"buildId":"abc1234","x":"${'x' * 2000}"}',
      ]) {
        expect(parsePublishedBuildId(body), isNull, reason: body);
      }
    });
  });

  group('hasNewBuild', () {
    test('otro id publicado: hay una versión nueva', () {
      expect(hasNewBuild(compiled: 'abc1234', published: 'def5678'), isTrue);
    });

    test('el mismo id: no', () {
      expect(hasNewBuild(compiled: 'abc1234', published: 'abc1234'), isFalse);
    });

    test('sin id compilado (flutter run, tests, iOS y Android): nunca', () {
      expect(hasNewBuild(compiled: '', published: 'def5678'), isFalse);
    });
  });
}
