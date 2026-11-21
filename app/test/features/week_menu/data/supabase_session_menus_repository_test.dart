// Consultas reales del SDK de Supabase contra un servidor HTTP simulado: el
// menú de una semana en una sola lectura de sessions (la fila de
// session_menus, los platos con su receta y la lista), los conteos para la
// ficha y la reserva, el guardado por save_session_menu y cada error de la
// función.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

import '../../../support/menu_fixtures.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';
import '../../../support/supabase_http_fake.dart';

Matcher _failure(MenuFailureKind kind, {int? dishIndex}) => throwsA(
  isA<MenuFailure>()
      .having((f) => f.kind, 'kind', kind)
      .having((f) => f.dishIndex, 'dishIndex', dishIndex),
);

http.Response _postgrestError(
  String code, {
  String message = 'error',
  String? details,
  int status = 400,
}) => jsonResponse({
  'code': code,
  'message': message,
  'details': details,
  'hint': null,
}, status: status);

void main() {
  late FakeSupabaseHttp server;
  late SupabaseSessionMenusRepository repository;

  setUp(() {
    server = FakeSupabaseHttp((_) async => jsonResponse(<Object>[]));
    repository = SupabaseSessionMenusRepository(server.client);
  });

  tearDown(() => server.dispose());

  group('fetchMenu', () {
    test('una sola lectura de sessions con el menú, los platos (con su receta) y la lista embebidos', () async {
      server.handler = (_) async => jsonResponse([
        {
          'id': sessionId(1),
          'menu': {
            'version': 2,
            'note': 'Tené listos 4 táperes',
            'allergens_confirmed': false,
          },
          'dishes': [
            {'position': 1, 'portions': 4, 'recipe': menuRecipeRow()},
          ],
          'items': const [
            {
              'position': 1,
              'name': 'Carne',
              'section': 'meat_fish',
              'quantity': 400,
              'unit': 'g',
            },
          ],
        },
      ]);

      final menu = await repository.fetchMenu(
        chefId: testChefId,
        sessionId: sessionId(1),
      );

      expect(menu.version, 2);
      expect(menu.note, 'Tené listos 4 táperes');
      expect(menu.dishes.single.recipe.id, lasagneId);
      expect(menu.items, [
        item('Carne', 400, IngredientUnit.g, section: ShoppingSection.meatFish),
      ]);
      final request = server.last;
      expect(request.method, 'GET');
      expect(request.url.path, '/rest/v1/sessions');
      final query = request.url.queryParameters;
      expect(
        query['select'],
        'id,menu:session_menus(version,note,allergens_confirmed),'
        'dishes:session_menu(position,portions,recipe:recipes(id,name_it,name_es,name_en,diet,'
        'fridge_days,freezable,freezer_days,active,photo_id,allergens:recipe_allergens(allergen),'
        'ingredients:recipe_ingredients(position,name,section,quantity,unit))),'
        'items:session_shopping_items(position,name,section,quantity,unit)',
      );
      expect(query['chef_id'], 'eq.$testChefId');
      expect(query['id'], 'eq.${sessionId(1)}');
    });

    test('una sesión sin menú: sin versión, sin platos ni lista', () async {
      server.handler = (_) async => jsonResponse([
        {
          'id': sessionId(1),
          'menu': <Object>[],
          'dishes': <Object>[],
          'items': <Object>[],
        },
      ]);
      final menu = await repository.fetchMenu(
        chefId: testChefId,
        sessionId: sessionId(1),
      );
      expect(menu.exists, isFalse);
      expect(menu.dishes, isEmpty);
    });

    test('una sesión que no se ve (no existe o es de otra cocina) da sessionNotFound', () async {
      server.handler = (_) async => jsonResponse(<Object>[]);
      await expectLater(
        repository.fetchMenu(chefId: testChefId, sessionId: sessionId(1)),
        _failure(MenuFailureKind.sessionNotFound),
      );
    });

    // Sin red no: el SDK reintenta los GET con esperas de segundos; la
    // traducción es la misma (_guard).
    test('una fila rota o un 500 dan unavailable', () async {
      server.handler = (_) async => jsonResponse([
        {'id': sessionId(1), 'menu': null, 'dishes': null, 'items': null},
      ]);
      await expectLater(
        repository.fetchMenu(chefId: testChefId, sessionId: sessionId(1)),
        _failure(MenuFailureKind.unavailable),
      );
      server.handler = (_) async => _postgrestError('XX000', status: 500);
      await expectLater(
        repository.fetchMenu(chefId: testChefId, sessionId: sessionId(1)),
        _failure(MenuFailureKind.unavailable),
      );
    });
  });

  group('fetchSummaries', () {
    test(
      'cuenta platos y renglones de cada sesión, sin traer las recetas',
      () async {
        server.handler = (_) async => jsonResponse([
          {
            'id': sessionId(1),
            'menu': {'version': 1},
            'dishes': const [
              {'recipe_id': lasagneId},
            ],
            'items': const [
              {'position': 1},
              {'position': 2},
            ],
          },
          {
            'id': sessionId(2),
            'menu': null,
            'dishes': <Object>[],
            'items': <Object>[],
          },
        ]);

        final summaries = await repository.fetchSummaries(
          chefId: testChefId,
          sessionIds: [sessionId(1), sessionId(2)],
        );

        expect(summaries, {
          sessionId(1): const WeekMenuSummary(saved: true, dishes: 1, items: 2),
          sessionId(2): const WeekMenuSummary(),
        });
        final query = server.last.url.queryParameters;
        expect(
          query['select'],
          'id,menu:session_menus(version),dishes:session_menu(recipe_id),items:session_shopping_items(position)',
        );
        expect(query['chef_id'], 'eq.$testChefId');
        expect(query['id'], 'in.("${sessionId(1)}","${sessionId(2)}")');
      },
    );

    test('sin sesiones no consulta nada', () async {
      expect(
        await repository.fetchSummaries(
          chefId: testChefId,
          sessionIds: const [],
        ),
        isEmpty,
      );
      expect(server.requests, isEmpty);
    });
  });

  group('save', () {
    final menu = WeekMenuSave(
      sessionId: sessionId(1),
      version: 2,
      note: 'Tené listos 4 táperes',
      allergensConfirmed: true,
      dishes: [WeekMenuDish(recipe: lasagne(), portions: 4)],
      items: lasagneList(4),
    );

    test('POST a save_session_menu con el menú entero en p; devuelve la versión nueva', () async {
      server.handler = (_) async => jsonResponse(3);

      expect(await repository.save(menu), 3);

      final request = server.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/save_session_menu');
      expect(jsonBodyOf(request), {'p': weekMenuSavePayload(menu)});
    });

    for (final (code, message, kind) in [
      ('40001', 'menu_changed', MenuFailureKind.changed),
      ('55000', 'session_not_editable', MenuFailureKind.notEditable),
      ('P0002', 'session_not_found', MenuFailureKind.sessionNotFound),
      ('22023', 'invalid_payload', MenuFailureKind.invalid),
      ('23514', 'new row violates check constraint', MenuFailureKind.invalid),
      ('42501', 'not_a_chef', MenuFailureKind.forbidden),
    ]) {
      test('$code $message da $kind', () async {
        server.handler = (_) async => _postgrestError(
          code,
          message: message,
          status: code == '40001' ? 409 : 400,
        );
        await expectLater(repository.save(menu), _failure(kind));
      });
    }

    test(
      'recipe_not_found dice qué plato (DETAIL dishes[i].recipe_id)',
      () async {
        server.handler = (_) async => _postgrestError(
          'P0002',
          message: 'recipe_not_found',
          details: 'dishes[2].recipe_id',
          status: 404,
        );
        await expectLater(
          repository.save(menu),
          _failure(MenuFailureKind.recipeNotFound, dishIndex: 2),
        );
        server.handler = (_) async =>
            _postgrestError('P0002', message: 'recipe_not_found', status: 404);
        await expectLater(
          repository.save(menu),
          _failure(MenuFailureKind.recipeNotFound),
        );
      },
    );

    test('sin conexión, un 503 o una respuesta que no es la versión dan unavailable', () async {
      server.handler = (_) async => throw http.ClientException('offline');
      await expectLater(
        repository.save(menu),
        _failure(MenuFailureKind.unavailable),
      );
      server.handler = (_) async => http.Response('Service Unavailable', 503);
      await expectLater(
        repository.save(menu),
        _failure(MenuFailureKind.unavailable),
      );
      server.handler = (_) async => jsonResponse('3');
      await expectLater(
        repository.save(menu),
        _failure(MenuFailureKind.unavailable),
      );
    });
  });
}
