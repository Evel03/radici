// Catálogo de platos de la cocinera: carga, búsqueda, guardar (el plato queda
// en la lista sin volver a leer) y desactivar o reactivar (se ve enseguida y
// vuelve atrás si falla).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';

import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeRecipesRepository repository;
  late ProviderContainer container;

  List<Recipe> catalog() => container.read(recipeCatalogProvider).requireValue;
  Recipe byId(String id) => catalog().singleWhere((r) => r.id == id);
  RecipeCatalogController controller() => container.read(recipeCatalogProvider.notifier);

  Future<void> start() async {
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        accountRepositoryProvider.overrideWithValue(FakeAccountRepository(chefAccountData)),
        recipesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    // Como en la pantalla: algo lo escucha todo el tiempo.
    container.listen(recipeCatalogProvider, (_, _) {});
    await pumpEventQueue();
  }

  setUp(() {
    auth = FakeAuthRepository(user: chefUser);
    repository = FakeRecipesRepository(sampleRecipes());
  });

  group('carga', () {
    test('lee el catálogo de la cocinera', () async {
      await start();
      expect(catalog().map((r) => r.id), unorderedEquals([lasagneId, risottoId, minestroneId, frittataId]));
      expect(repository.fetchCalls, 1);
    });

    test('sin sesión de cocinera queda vacío y no llama al servidor', () async {
      auth = FakeAuthRepository();
      await start();
      expect(catalog(), isEmpty);
      expect(repository.fetchCalls, 0);
    });

    test('si falla queda en error (la pantalla ofrece reintentar)', () async {
      repository.failFetch = true;
      await start();
      expect(container.read(recipeCatalogProvider).error, isA<RecipesFailure>());
    });

    test('refresh trae lo nuevo; si falla, queda lo que había y relanza', () async {
      await start();
      repository.recipes.remove(frittataId);
      await controller().refresh();
      expect(catalog().map((r) => r.id), isNot(contains(frittataId)));

      repository.failFetch = true;
      await expectLater(controller().refresh(), throwsA(isA<RecipesFailure>()));
      expect(catalog(), hasLength(3));
    });
  });

  group('vista con búsqueda', () {
    test('activos por nombre, desactivados al final; la búsqueda filtra', () async {
      await start();
      final sub = container.listen(recipeCatalogViewProvider, (_, _) {});
      addTearDown(sub.close);

      var view = container.read(recipeCatalogViewProvider).requireValue;
      expect(view.active.map((r) => r.id), [lasagneId, minestroneId, risottoId]);
      expect(view.inactive.map((r) => r.id), [frittataId]);

      container.read(recipeSearchQueryProvider.notifier).set('hongos');
      view = container.read(recipeCatalogViewProvider).requireValue;
      expect(view.active.map((r) => r.id), [risottoId]);
      expect(view.inactive, isEmpty);
      expect(view.total, 4);
    });
  });

  group('guardar', () {
    test('un plato nuevo queda en la lista sin volver a leer', () async {
      await start();
      const pesto = Recipe(id: '0e5b3c1a-2f4d-4a6b-8c9d-0123456789ab', nameIt: 'Pasta al pesto');

      final saved = await controller().save(pesto);

      expect(saved, pesto);
      expect(repository.saveCalls, [pesto]);
      expect(byId(pesto.id), pesto);
      expect(repository.fetchCalls, 1);
    });

    test('uno existente se reemplaza y conserva su estado (guardar no reactiva)', () async {
      await start();
      final edited = frittata().copyWith(nameIt: 'Frittata di zucchine e menta', active: true);

      final saved = await controller().save(edited);

      expect(saved.active, isFalse);
      expect(byId(frittataId).nameIt, 'Frittata di zucchine e menta');
      expect(byId(frittataId).active, isFalse);
    });

    test('si falla, la lista queda como estaba y se relanza el error', () async {
      await start();
      repository.saveFailure = RecipesFailureKind.unavailable;

      await expectLater(
        controller().save(lasagne().copyWith(nameIt: 'Lasagne verdi')),
        throwsA(isA<RecipesFailure>().having((f) => f.kind, 'kind', RecipesFailureKind.unavailable)),
      );
      expect(byId(lasagneId), lasagne());
    });

    test('una lectura que se cruza con un guardado no lo pisa', () async {
      await start();
      repository.pendingFetch = Completer<void>();
      final refresh = controller().refresh();
      await controller().save(lasagne().copyWith(nameIt: 'Lasagne verdi'));
      repository.pendingFetch!.complete();
      repository.pendingFetch = null;
      await refresh;

      expect(byId(lasagneId).nameIt, 'Lasagne verdi');
    });
  });

  group('desactivar y reactivar', () {
    test('se ve enseguida y queda guardado', () async {
      await start();
      repository.pendingSetActive = Completer<void>();

      final done = controller().setActive(lasagneId, active: false);
      await pumpEventQueue();
      expect(byId(lasagneId).active, isFalse, reason: 'optimista');

      repository.pendingSetActive!.complete();
      await done;
      expect(byId(lasagneId).active, isFalse);
      expect(repository.setActiveCalls, [(id: lasagneId, active: false)]);
      expect(repository.recipes[lasagneId]!.active, isFalse);
    });

    test('reactivar', () async {
      await start();
      await controller().setActive(frittataId, active: true);
      expect(byId(frittataId).active, isTrue);
    });

    test('si falla vuelve a como estaba y relanza', () async {
      await start();
      repository.failSetActive = true;
      await expectLater(
        controller().setActive(lasagneId, active: false),
        throwsA(isA<RecipesFailure>()),
      );
      expect(byId(lasagneId).active, isTrue);
    });

    // Como un servidor que contesta la lectura antes de aplicar el PATCH: la
    // lectura trae el plato activo mientras desactivar sigue en vuelo.
    test('si las dos lecturas se cruzan con un desactivar en vuelo, queda lo local', () async {
      await start();
      repository.pendingSetActive = Completer<void>();
      final deactivating = controller().setActive(lasagneId, active: false);
      await pumpEventQueue();
      repository.recipes[lasagneId] = lasagne();

      await controller().refresh();
      expect(repository.fetchCalls, 3, reason: 'la carga y dos lecturas descartadas');
      expect(byId(lasagneId).active, isFalse, reason: 'queda lo local');

      repository.pendingSetActive!.complete();
      await deactivating;
      expect(byId(lasagneId).active, isFalse);
    });

    test('un plato que ya no está en la lista no hace nada', () async {
      await start();
      await controller().setActive('no-existe', active: false);
      expect(repository.setActiveCalls, isEmpty);
    });
  });

  test('el aviso de guardado se publica y se limpia', () async {
    await start();
    final notice = container.read(recipeSavedNoticeProvider.notifier);
    notice.post(lasagne());
    expect(container.read(recipeSavedNoticeProvider), (recipe: lasagne(), untranslated: false));
    notice.post(lasagne(), untranslated: true);
    expect(container.read(recipeSavedNoticeProvider), (recipe: lasagne(), untranslated: true));
    notice.clear();
    expect(container.read(recipeSavedNoticeProvider), isNull);
  });
}
