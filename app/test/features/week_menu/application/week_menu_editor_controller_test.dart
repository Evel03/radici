// Editor del menú de una semana: abrir uno guardado (la lista sigue a los
// platos o está a mano), la semana 1 con los platos que eligió la clienta,
// agregar, mover y quitar platos (con la lista que los sigue), cambiar la
// lista a mano y rehacerla, guardar con la versión cargada y la confirmación
// de alérgenos, y cada falla sin perder lo escrito (otro teléfono lo cambió,
// una respuesta perdida, sin conexión, una sesión que ya no se puede cambiar).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/week_menu/application/week_menu_editor_controller.dart';
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/shopping_list.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

import '../../../support/fakes.dart';
import '../../../support/menu_fakes.dart';
import '../../../support/menu_fixtures.dart';
import '../../../support/pump_app.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  late FakeSessionsRepository sessions;
  late FakeSessionMenusRepository menus;
  late FakeRecipesRepository recipes;
  late ProviderContainer container;

  /// La reserva de 4 semanas (sesiones 1 a 4) y sus menús.
  Future<void> start({
    List<CookingSession>? booking,
    Map<String, SavedWeekMenu> saved = const {},
  }) async {
    sessions = FakeSessionsRepository(booking ?? buildBooking());
    menus = FakeSessionMenusRepository(menus: saved);
    recipes = FakeRecipesRepository(sampleRecipes());
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(user: chefUser),
        ),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        sessionsRepositoryProvider.overrideWithValue(sessions),
        sessionMenusRepositoryProvider.overrideWithValue(menus),
        recipesRepositoryProvider.overrideWithValue(recipes),
      ],
    );
    // La sesión de Evelyn, cargada.
    container.listen(sessionControllerProvider, (_, _) {});
    await pumpEventQueue();
  }

  /// El editor de la sesión [n], abierto (como la pantalla, lo escucha) y
  /// cargado.
  Future<WeekMenuEditorController> open(int n) async {
    container.listen(weekMenuEditorProvider(sessionId(n)), (_, _) {});
    await container.read(weekMenuEditorProvider(sessionId(n)).future);
    return container.read(weekMenuEditorProvider(sessionId(n)).notifier);
  }

  WeekMenuEditorState stateOf(int n) =>
      container.read(weekMenuEditorProvider(sessionId(n))).requireValue;

  List<ShoppingItem> itemsOf(int n) => [
    for (final row in stateOf(n).orderedItems) row.item,
  ];

  List<(String, int)> dishesOf(int n) => [
    for (final d in stateOf(n).dishes) (d.recipe.id, d.portions),
  ];

  group('al abrir', () {
    test('un menú guardado: platos, lista, nota y versión; la lista sigue a los platos si es la que sale de ellos', () async {
      await start(
        saved: {
          sessionId(2): savedLasagneMenu(
            version: 3,
            portions: 6,
            note: 'Tené listos 4 táperes',
          ),
        },
      );
      await open(2);
      final state = stateOf(2);
      expect(state.version, 3);
      expect(dishesOf(2), [(lasagneId, 6)]);
      expect(itemsOf(2), lasagneList(6));
      expect(state.note, 'Tené listos 4 táperes');
      expect(state.manualList, isFalse);
      expect(state.dirty, isFalse);
      expect(state.canSave, isFalse);
      expect(state.readOnly, isFalse);
    });

    test(
      'una lista guardada distinta de la que sale de los platos está a mano',
      () async {
        await start(
          saved: {
            sessionId(2): savedLasagneMenu(
              items: [toTasteItem('Sale'), item('Pane', 1, IngredientUnit.pcs)],
            ),
          },
        );
        await open(2);
        expect(stateOf(2).manualList, isTrue);
        // Por sección, como se muestra y se guarda.
        expect(itemsOf(2), [
          toTasteItem('Sale'),
          item('Pane', 1, IngredientUnit.pcs),
        ]);
        expect(stateOf(2).dirty, isFalse);
      },
    );

    test('la semana 1 sin menú empieza con los platos que eligió la clienta (los activos que siguen), sin guardar', () async {
      await start(
        booking: buildBooking(
          wishes: [risottoId, frittataId, 'borrado', lasagneId],
        ),
      );
      await open(1);
      final state = stateOf(1);
      expect(state.version, isNull);
      // 4 personas que cenan: 4 porciones cada uno. La frittata está desactivada.
      expect(dishesOf(1), [(risottoId, 4), (lasagneId, 4)]);
      expect(state.fromWishes, isTrue);
      expect(state.manualList, isFalse);
      expect(itemsOf(1), buildShoppingList(state.dishes).items);
      // No hay nada que descartar, pero se puede guardar como está.
      expect(state.dirty, isFalse);
      expect(state.canSave, isTrue);
    });

    test('la semana 2 no toma los platos de la web', () async {
      await start(booking: buildBooking(wishes: [risottoId]));
      await open(2);
      expect(stateOf(2).dishes, isEmpty);
      expect(stateOf(2).fromWishes, isFalse);
      expect(stateOf(2).canSave, isFalse);
    });

    test(
      'la semana 1 con menú guardado no vuelve a tomar los de la web',
      () async {
        await start(
          booking: buildBooking(wishes: [risottoId]),
          saved: {sessionId(1): savedLasagneMenu()},
        );
        await open(1);
        expect(dishesOf(1), [(lasagneId, 4)]);
        expect(stateOf(1).fromWishes, isFalse);
      },
    );

    test('una sesión cocinada se abre solo para mirar: no se guarda', () async {
      await start(
        booking: buildBooking(statuses: const {2: SessionStatus.cooked}),
      );
      final editor = await open(2);
      expect(stateOf(2).readOnly, isTrue);
      editor.addDishes([lasagne()]);
      expect(stateOf(2).canSave, isFalse);
      expect(
        await editor.save(allergensConfirmed: false),
        WeekMenuSaveResult.busy,
      );
      expect(menus.saves, isEmpty);
    });

    test('si no se puede leer, el editor queda con el error', () async {
      await start();
      menus.fetchFailure = const MenuFailure(MenuFailureKind.unavailable);
      container.listen(weekMenuEditorProvider(sessionId(2)), (_, _) {});
      await expectLater(
        container.read(weekMenuEditorProvider(sessionId(2)).future),
        throwsA(isA<MenuFailure>()),
      );
    });
  });

  group('los platos', () {
    test('agregar: al final, con las porciones por defecto, sin repetir; la lista los sigue', () async {
      await start();
      final editor = await open(2);
      expect(editor.addDishes([lasagne(), risotto(), lasagne()]), 2);
      expect(dishesOf(2), [(lasagneId, 4), (risottoId, 4)]);
      expect(editor.addDishes([lasagne()]), 0);
      expect(itemsOf(2), lasagneList(4));
      expect(stateOf(2).dirty, isTrue);
    });

    test('como mucho 30 platos', () async {
      await start();
      final editor = await open(2);
      final many = [for (var n = 1; n <= 35; n++) dishWith(n, const [])];
      expect(editor.addDishes(many), maxMenuDishes);
      expect(stateOf(2).canAddDish, isFalse);
      expect(editor.addDishes([lasagne()]), 0);
    });

    test('las porciones (de 1 a 500) rehacen la lista', () async {
      await start();
      final editor = await open(2);
      editor
        ..addDishes([lasagne()])
        ..setPortions(lasagneId, 10);
      expect(dishesOf(2), [(lasagneId, 10)]);
      expect(itemsOf(2), lasagneList(10));
      editor.setPortions(lasagneId, 0);
      expect(dishesOf(2), [(lasagneId, 1)]);
      editor.setPortions(lasagneId, 900);
      expect(dishesOf(2), [(lasagneId, maxDishPortions)]);
    });

    test('mover y quitar (con deshacer)', () async {
      await start();
      final editor = await open(2);
      editor
        ..addDishes([lasagne(), risotto(), minestrone()])
        ..moveDish(minestroneId, -1);
      expect(
        [for (final d in dishesOf(2)) d.$1],
        [lasagneId, minestroneId, risottoId],
      );
      editor.moveDish(lasagneId, -1);
      expect(dishesOf(2).first.$1, lasagneId);
      final removed = editor.removeDish(lasagneId)!;
      expect([for (final d in dishesOf(2)) d.$1], [minestroneId, risottoId]);
      expect(
        itemsOf(2).any((i) => i.name == 'Carne macinata di manzo'),
        isFalse,
      );
      editor.restoreDish(removed);
      expect(
        [for (final d in dishesOf(2)) d.$1],
        [lasagneId, minestroneId, risottoId],
      );
      expect(itemsOf(2), lasagneList(4));
    });

    test('volver a los platos guardados deja de tener cambios', () async {
      await start(saved: {sessionId(2): savedLasagneMenu()});
      final editor = await open(2);
      editor.setPortions(lasagneId, 8);
      expect(stateOf(2).dirty, isTrue);
      editor.setPortions(lasagneId, 4);
      expect(stateOf(2).dirty, isFalse);
    });
  });

  group('la lista', () {
    test('cambiar, quitar o agregar un renglón la deja a mano: los platos ya no la tocan', () async {
      await start();
      final editor = await open(2);
      editor.addDishes([lasagne()]);
      final carne = stateOf(2).orderedItems.first;
      editor.updateItem(
        carne.key,
        item(
          'Carne di manzo',
          500,
          IngredientUnit.g,
          section: ShoppingSection.meatFish,
        ),
      );
      expect(stateOf(2).manualList, isTrue);
      editor.setPortions(lasagneId, 8);
      expect(
        itemsOf(2).first,
        item(
          'Carne di manzo',
          500,
          IngredientUnit.g,
          section: ShoppingSection.meatFish,
        ),
      );
      expect(itemsOf(2), hasLength(3));
    });

    test('un renglón nuevo va al final de su sección', () async {
      await start();
      final editor = await open(2);
      editor.addDishes([lasagne()]);
      editor.addItem(
        item(
          'Mozzarella',
          250,
          IngredientUnit.g,
          section: ShoppingSection.dairyEggs,
        ),
      );
      editor.addItem(
        item('Olio', 50, IngredientUnit.ml, section: ShoppingSection.pantry),
      );
      expect(
        [for (final i in itemsOf(2)) i.name],
        [
          'Carne macinata di manzo',
          'Mozzarella',
          'Passata di pomodoro',
          'Sale',
          'Olio',
        ],
      );
      expect(stateOf(2).manualList, isTrue);
    });

    test('quitar un renglón (con deshacer)', () async {
      await start();
      final editor = await open(2);
      editor.addDishes([lasagne()]);
      final sale = stateOf(2).orderedItems.last;
      final removed = editor.removeItem(sale.key)!;
      expect(itemsOf(2), lasagneList(4).sublist(0, 2));
      expect(removed.wasManual, isFalse);
      editor.restoreItem(removed);
      expect(itemsOf(2), lasagneList(4));
    });

    test('«Rehacer la lista con los platos» la vuelve a sacar de los platos y los sigue otra vez', () async {
      await start();
      final editor = await open(2);
      editor.addDishes([lasagne()]);
      editor.addItem(toTasteItem('Pepe'));
      editor.setPortions(lasagneId, 8);
      expect(itemsOf(2), isNot(lasagneList(8)));
      editor.rebuildList();
      expect(stateOf(2).manualList, isFalse);
      expect(itemsOf(2), lasagneList(8));
      editor.setPortions(lasagneId, 4);
      expect(itemsOf(2), lasagneList(4));
    });

    test('con más de 150 renglones quedan los primeros y lo dice', () async {
      await start();
      final editor = await open(2);
      editor.addDishes([
        for (var n = 1; n <= 4; n++)
          dishWith(n, [
            for (var i = 1; i <= 40; i++)
              ingredient('Cosa $n-$i', 1, IngredientUnit.pcs),
          ]),
      ]);
      expect(stateOf(2).items, hasLength(maxShoppingItems));
      expect(stateOf(2).listTruncated, isTrue);
      expect(stateOf(2).canAddItem, isFalse);
    });
  });

  group('guardar', () {
    test('un menú nuevo: version null, los platos, la lista por sección, la nota normalizada y la confirmación', () async {
      await start();
      final editor = await open(2);
      editor
        ..addDishes([lasagne()])
        ..setNote('  Tené listos\r\n4 táperes  ');
      expect(
        await editor.save(allergensConfirmed: true),
        WeekMenuSaveResult.saved,
      );
      final sent = menus.saves.single;
      expect(sent.sessionId, sessionId(2));
      expect(sent.version, isNull);
      expect(sent.note, 'Tené listos\n4 táperes');
      expect(sent.allergensConfirmed, isTrue);
      expect(
        [for (final d in sent.dishes) (d.recipe.id, d.portions)],
        [(lasagneId, 4)],
      );
      expect(sent.items, lasagneList(4));
      final state = stateOf(2);
      expect(state.version, 1);
      expect(state.dirty, isFalse);
      expect(state.canSave, isFalse);
      expect(state.saving, isFalse);
    });

    test(
      'uno guardado manda la versión cargada, y la siguiente vez la nueva',
      () async {
        await start(saved: {sessionId(2): savedLasagneMenu(version: 4)});
        final editor = await open(2);
        editor.setPortions(lasagneId, 6);
        expect(
          await editor.save(allergensConfirmed: false),
          WeekMenuSaveResult.saved,
        );
        editor.setPortions(lasagneId, 8);
        expect(
          await editor.save(allergensConfirmed: false),
          WeekMenuSaveResult.saved,
        );
        expect([for (final s in menus.saves) s.version], [4, 5]);
        expect(stateOf(2).version, 6);
      },
    );

    test(
      'los platos de la web se guardan como están y dejan de ser «de la web»',
      () async {
        await start(booking: buildBooking(wishes: [risottoId]));
        final editor = await open(1);
        expect(
          await editor.save(allergensConfirmed: false),
          WeekMenuSaveResult.saved,
        );
        expect(
          [for (final d in menus.saves.single.dishes) d.recipe.id],
          [risottoId],
        );
        expect(stateOf(1).fromWishes, isFalse);
      },
    );

    test(
      'después de guardar, la ficha y la reserva vuelven a contar el menú',
      () async {
        await start();
        container.listen(weekMenuSummaryProvider(sessionId(2)), (_, _) {});
        expect(
          await container.read(weekMenuSummaryProvider(sessionId(2)).future),
          const WeekMenuSummary(),
        );
        final editor = await open(2);
        editor.addDishes([lasagne()]);
        await editor.save(allergensConfirmed: false);
        expect(
          await container.read(weekMenuSummaryProvider(sessionId(2)).future),
          const WeekMenuSummary(saved: true, dishes: 1, items: 3),
        );
      },
    );

    test(
      'mientras guarda no se puede cambiar nada ni volver a guardar',
      () async {
        await start();
        final editor = await open(2);
        editor.addDishes([lasagne()]);
        menus.pendingSave = Completer<void>();
        final saving = editor.save(allergensConfirmed: false);
        expect(stateOf(2).saving, isTrue);
        expect(editor.addDishes([risotto()]), 0);
        expect(
          await editor.save(allergensConfirmed: false),
          WeekMenuSaveResult.busy,
        );
        menus.pendingSave!.complete();
        expect(await saving, WeekMenuSaveResult.saved);
        expect(menus.saves, hasLength(1));
      },
    );

    test('si otro teléfono lo guardó en el medio: no se guarda, lo escrito queda y se puede recargar', () async {
      await start(saved: {sessionId(2): savedLasagneMenu(version: 1)});
      final editor = await open(2);
      editor
        ..addDishes([risotto()])
        ..setNote('Mía');
      // Otro teléfono guarda otra cosa.
      menus.menus[sessionId(2)] = savedLasagneMenu(version: 2, portions: 8);
      expect(
        await editor.save(allergensConfirmed: false),
        WeekMenuSaveResult.failed,
      );
      final state = stateOf(2);
      expect(state.saveError?.kind, MenuFailureKind.changed);
      expect(dishesOf(2), [(lasagneId, 4), (risottoId, 4)]);
      expect(state.note, 'Mía');
      expect(state.dirty, isTrue);

      expect(await editor.reload(), isTrue);
      final reloaded = stateOf(2);
      expect(reloaded.version, 2);
      expect(dishesOf(2), [(lasagneId, 8)]);
      expect(reloaded.note, '');
      expect(reloaded.dirty, isFalse);
      expect(reloaded.saveError, isNull);
      expect(reloaded.generation, state.generation + 1);
    });

    test('una respuesta perdida: al reintentar, la base ya lo tiene y queda guardado', () async {
      await start(saved: {sessionId(2): savedLasagneMenu(version: 1)});
      final editor = await open(2);
      editor.setPortions(lasagneId, 6);
      menus.loseSaveResponse = true;
      expect(
        await editor.save(allergensConfirmed: false),
        WeekMenuSaveResult.failed,
      );
      expect(stateOf(2).saveError?.kind, MenuFailureKind.unavailable);
      expect(stateOf(2).dirty, isTrue);
      menus.loseSaveResponse = false;
      // El reintento manda la versión 1, pero la base ya está en la 2 con esto.
      expect(
        await editor.save(allergensConfirmed: false),
        WeekMenuSaveResult.saved,
      );
      expect(stateOf(2).version, 2);
      expect(stateOf(2).dirty, isFalse);
      expect(stateOf(2).saveError, isNull);
    });

    test('sin conexión: lo escrito queda para reintentar', () async {
      await start();
      final editor = await open(2);
      editor.addDishes([lasagne()]);
      menus.saveFailure = const MenuFailure(MenuFailureKind.unavailable);
      expect(
        await editor.save(allergensConfirmed: false),
        WeekMenuSaveResult.failed,
      );
      expect(stateOf(2).saveError?.kind, MenuFailureKind.unavailable);
      expect(dishesOf(2), [(lasagneId, 4)]);
      expect(stateOf(2).saving, isFalse);
      menus.saveFailure = null;
      expect(
        await editor.save(allergensConfirmed: false),
        WeekMenuSaveResult.saved,
      );
    });

    test('una sesión que se cocinó mientras tanto: session_not_editable, y lo escrito queda', () async {
      await start();
      final editor = await open(2);
      editor.addDishes([lasagne()]);
      menus.statuses[sessionId(2)] = SessionStatus.cooked;
      expect(
        await editor.save(allergensConfirmed: false),
        WeekMenuSaveResult.failed,
      );
      expect(stateOf(2).saveError?.kind, MenuFailureKind.notEditable);
      expect(dishesOf(2), [(lasagneId, 4)]);
    });

    test('una nota de más de 1000 caracteres no se manda', () async {
      await start();
      final editor = await open(2);
      editor.setNote('a' * 1001);
      expect(stateOf(2).noteTooLong, isTrue);
      expect(stateOf(2).canSave, isFalse);
      expect(
        await editor.save(allergensConfirmed: false),
        WeekMenuSaveResult.invalid,
      );
      expect(menus.saves, isEmpty);
    });
  });

  test('los choques: los platos del menú que la reserva no admite', () async {
    await start(
      booking: buildBooking(
        restrictions: const RequestRestrictions(
          allergens: [Allergen.gluten],
          diets: [Diet.vegetarian],
        ),
      ),
    );
    final editor = await open(2);
    container.listen(weekMenuConflictsProvider(sessionId(2)), (_, _) {});
    editor.addDishes([lasagne(), risotto(), minestrone()]);
    expect(container.read(weekMenuConflictsProvider(sessionId(2))), {
      lasagneId: const DishConflict(
        allergens: [Allergen.gluten],
        diets: [Diet.vegetarian],
      ),
    });
  });

  test('allowLeave deja salir sin guardar', () async {
    await start();
    final editor = await open(2);
    editor.addDishes([lasagne()]);
    editor.allowLeave();
    expect(stateOf(2).leaving, isTrue);
    expect(stateOf(2).dirty, isTrue);
  });
}
