// Consultas reales del SDK de Supabase contra un servidor HTTP simulado: la
// lectura del catálogo (con alérgenos e ingredientes embebidos, sin las
// recetas de eventos), el guardado entero por save_recipe, desactivar y los
// errores.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';

import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/supabase_http_fake.dart';

Matcher _failure(RecipesFailureKind kind) => throwsA(
  isA<RecipesFailure>().having((f) => f.kind, 'kind', kind),
);

http.Response _postgrestError(String code, {int status = 400}) => jsonResponse(
  {'code': code, 'message': 'error', 'details': null, 'hint': null},
  status: status,
);

void main() {
  late FakeSupabaseHttp server;
  late SupabaseRecipesRepository repository;

  setUp(() {
    server = FakeSupabaseHttp((_) async => jsonResponse(<Object>[]));
    repository = SupabaseRecipesRepository(server.client);
  });

  tearDown(() => server.dispose());

  group('fetchCatalog', () {
    test('lee los platos del catálogo de la cocinera, con alérgenos e ingredientes', () async {
      server.handler = (_) async => jsonResponse([
        recipeRow(),
        recipeRow(
          id: risottoId,
          nameIt: 'Risotto ai funghi porcini',
          diet: 'vegetarian',
          seasonMonths: [9, 10, 11],
          allergens: const <Object>[],
          ingredients: const <Object>[],
        ),
      ]);

      final recipes = await repository.fetchCatalog(chefId: testChefId);

      expect(recipes.first, lasagne());
      expect(recipes.last.seasonMonths, [9, 10, 11]);
      final request = server.last;
      expect(request.method, 'GET');
      expect(request.url.path, '/rest/v1/recipes');
      final query = request.url.queryParameters;
      // Las notas, de recipe_notes (solo de la cocinera): recipes ya no las
      // tiene, porque el cliente lee la fila entera. Las descripciones de la
      // web, de recipes (20261119150000_menu_web.sql), y la foto
      // (20261120100000_recipe_photos.sql).
      expect(
        query['select'],
        'id,name_it,name_es,name_en,description_it,description_es,description_en,'
        'diet,season_months,fridge_days,freezable,'
        'freezer_days,active,photo_id,allergens:recipe_allergens(allergen),'
        'ingredients:recipe_ingredients(position,name,section,quantity,unit),'
        'notes:recipe_notes(notes)',
      );
      expect(query['chef_id'], 'eq.$testChefId');
      // Las recetas de un evento (M3b) no son del catálogo.
      expect(query['catalog_visible'], 'eq.true');
      expect(query['order'], 'name_it.asc.nullslast');
      expect(request.headers['apikey'], 'sb_publishable_test');
    });

    test('un 500 da RecipesFailure.unavailable', () async {
      server.handler = (_) async => _postgrestError('XX000', status: 500);
      await expectLater(
        repository.fetchCatalog(chefId: testChefId),
        _failure(RecipesFailureKind.unavailable),
      );
    });

    test('una fila rota también da unavailable', () async {
      server.handler = (_) async => jsonResponse([recipeRow(allergens: const [{'allergen': 'kiwi'}])]);
      await expectLater(
        repository.fetchCatalog(chefId: testChefId),
        _failure(RecipesFailureKind.unavailable),
      );
    });

    test('sin conexión da unavailable', () async {
      server.handler = (_) async => throw http.ClientException('offline');
      await expectLater(
        repository.fetchCatalog(chefId: testChefId),
        _failure(RecipesFailureKind.unavailable),
      );
    });
  });

  group('save', () {
    test('POST a save_recipe con el plato entero en p', () async {
      server.handler = (_) async => jsonResponse(lasagneId);

      await repository.save(lasagne());

      final request = server.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/save_recipe');
      expect(jsonBodyOf(request), {'p': recipeSavePayload(lasagne())});
      final p = jsonBodyOf(request)['p'] as Map<String, dynamic>;
      expect(p.containsKey('active'), isFalse);
      expect(p.containsKey('catalog_visible'), isFalse);
    });

    for (final (code, kind) in [
      ('22023', RecipesFailureKind.invalid),
      ('23514', RecipesFailureKind.invalid),
      ('P0002', RecipesFailureKind.notFound),
      ('42501', RecipesFailureKind.unavailable),
    ]) {
      test('un error $code de la base da $kind', () async {
        server.handler = (_) async => _postgrestError(code);
        await expectLater(repository.save(lasagne()), _failure(kind));
      });
    }

    test('P0002 con 404 también es notFound', () async {
      server.handler = (_) async => _postgrestError('P0002', status: 404);
      await expectLater(repository.save(lasagne()), _failure(RecipesFailureKind.notFound));
    });

    test('sin conexión o un 503 da unavailable', () async {
      server.handler = (_) async => throw http.ClientException('offline');
      await expectLater(repository.save(lasagne()), _failure(RecipesFailureKind.unavailable));
      server.handler = (_) async => http.Response('Service Unavailable', 503);
      await expectLater(repository.save(lasagne()), _failure(RecipesFailureKind.unavailable));
    });
  });

  group('setActive', () {
    test('PATCH solo de active, de ese plato y de la cocinera', () async {
      server.handler = (_) async => jsonResponse([
        {'id': lasagneId},
      ]);

      await repository.setActive(chefId: testChefId, id: lasagneId, active: false);

      final request = server.last;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/rest/v1/recipes');
      expect(request.url.queryParameters['id'], 'eq.$lasagneId');
      expect(request.url.queryParameters['chef_id'], 'eq.$testChefId');
      expect(request.url.queryParameters['select'], 'id');
      expect(jsonBodyOf(request), {'active': false});
    });

    test('reactivar manda true', () async {
      server.handler = (_) async => jsonResponse([
        {'id': frittataId},
      ]);
      await repository.setActive(chefId: testChefId, id: frittataId, active: true);
      expect(jsonBodyOf(server.last), {'active': true});
    });

    test('si el plato no existe (o no es suyo) da notFound', () async {
      server.handler = (_) async => jsonResponse(<Object>[]);
      await expectLater(
        repository.setActive(chefId: testChefId, id: lasagneId, active: false),
        _failure(RecipesFailureKind.notFound),
      );
    });

    test('sin conexión da unavailable', () async {
      server.handler = (_) async => throw http.ClientException('offline');
      await expectLater(
        repository.setActive(chefId: testChefId, id: lasagneId, active: false),
        _failure(RecipesFailureKind.unavailable),
      );
    });
  });

  test('RecipesFailure no imprime nada más que el tipo', () {
    expect(
      const RecipesFailure(RecipesFailureKind.invalid).toString(),
      'RecipesFailure(invalid)',
    );
  });
}
