// Catálogo de platos de la cocinera: carga, búsqueda, guardar (el plato queda
// en la lista sin volver a leer), desactivar o reactivar (se ve enseguida y
// vuelve atrás si falla) y la foto (subir, set_recipe_photo y borrar la vieja).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/recipes/application/recipe_catalog_controller.dart';
import 'package:radici/features/recipes/data/recipe_photos_repository.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_photo.dart';

import '../../../support/fakes.dart';
import '../../../support/photo_fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeRecipesRepository repository;
  late FakeRecipePhotosRepository photos;
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
        recipePhotosRepositoryProvider.overrideWithValue(photos),
      ],
    );
    // Como en la pantalla: algo lo escucha todo el tiempo.
    container.listen(recipeCatalogProvider, (_, _) {});
    await pumpEventQueue();
  }

  setUp(() {
    auth = FakeAuthRepository(user: chefUser);
    repository = FakeRecipesRepository(sampleRecipes());
    photos = FakeRecipePhotosRepository();
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

  group('foto', () {
    const oldPhoto = 'f0000000-0000-4000-8000-0000000000aa';
    const newPhotoId = 'f0000000-0000-4000-8000-0000000000bb';
    final newPhoto = NewRecipePhoto(photoId: newPhotoId, photo: samplePhoto);

    /// La lasaña con [oldPhoto] en la lista y en la base.
    void lasagneWithPhoto() {
      repository.recipes[lasagneId] = lasagne().copyWith(photoId: oldPhoto);
      photos
        ..uploaded.add('$lasagneId/$oldPhoto')
        ..photoOf[lasagneId] = oldPhoto;
    }

    test('guardar el plato conserva su foto (save_recipe no la toca)', () async {
      lasagneWithPhoto();
      await start();

      final saved = await controller().save(lasagne().copyWith(nameIt: 'Lasagne verdi'));

      expect(saved.photoId, oldPhoto);
      expect(byId(lasagneId).photoId, oldPhoto);
      expect(repository.recipes[lasagneId]!.photoId, oldPhoto);
    });

    test('poner la primera foto: sube, la guarda y queda en la lista; nada que borrar', () async {
      await start();

      await controller().setPhoto(risottoId, newPhoto);

      expect(photos.uploadCalls, [newPhotoId]);
      expect(photos.setCalls, [(recipeId: risottoId, photoId: newPhotoId)]);
      expect(byId(risottoId).photoId, newPhotoId);
      expect(photos.deleteCalls, isEmpty);
    });

    test('cambiarla: después de guardar la nueva borra los archivos de la vieja', () async {
      lasagneWithPhoto();
      await start();

      await controller().setPhoto(lasagneId, newPhoto);

      expect(byId(lasagneId).photoId, newPhotoId);
      expect(photos.photoOf[lasagneId], newPhotoId);
      expect(photos.deleteCalls.single.recipeId, lasagneId);
      expect(photos.deleteCalls.single.photoIds, {oldPhoto});
      expect(photos.uploaded, {'$lasagneId/$newPhotoId'});
    });

    // Un intento anterior la guardó pero la respuesta se perdió: la base ya
    // no devuelve la vieja, pero la lista la conoce.
    test('si la base ya no devuelve la vieja, borra igual la que tenía la lista', () async {
      repository.recipes[lasagneId] = lasagne().copyWith(photoId: oldPhoto);
      photos.photoOf[lasagneId] = newPhotoId;
      await start();

      await controller().setPhoto(lasagneId, newPhoto);

      expect(photos.deleteCalls.single.photoIds, {oldPhoto});
    });

    test('sacarla: set_recipe_photo con null, la lista sin foto y los archivos borrados', () async {
      lasagneWithPhoto();
      await start();

      await controller().setPhoto(lasagneId, null);

      expect(photos.uploadCalls, isEmpty);
      expect(photos.setCalls, [(recipeId: lasagneId, photoId: null)]);
      expect(byId(lasagneId).photoId, isNull);
      expect(photos.deleteCalls.single.photoIds, {oldPhoto});
    });

    test('si falla la subida o set_recipe_photo, la lista no cambia, no borra nada y relanza', () async {
      lasagneWithPhoto();
      await start();
      Matcher failure(RecipePhotoFailureKind kind) =>
          throwsA(isA<RecipePhotoFailure>().having((f) => f.kind, 'kind', kind));

      photos.uploadFailure = RecipePhotoFailureKind.unavailable;
      await expectLater(controller().setPhoto(lasagneId, newPhoto), failure(RecipePhotoFailureKind.unavailable));
      expect(photos.setCalls, isEmpty);

      photos
        ..uploadFailure = null
        ..setFailure = RecipePhotoFailureKind.notFound;
      await expectLater(controller().setPhoto(lasagneId, newPhoto), failure(RecipePhotoFailureKind.notFound));

      expect(byId(lasagneId).photoId, oldPhoto);
      expect(photos.deleteCalls, isEmpty);
    });

    test('si no puede borrar la vieja, no avisa: la foto nueva ya quedó', () async {
      lasagneWithPhoto();
      photos.failDelete = true;
      await start();

      await controller().setPhoto(lasagneId, newPhoto);
      await pumpEventQueue();

      expect(byId(lasagneId).photoId, newPhotoId);
      expect(photos.deleteCalls, hasLength(1));
    });

    test('una lectura que se cruza con el cambio de foto no lo pisa', () async {
      await start();
      repository.pendingFetch = Completer<void>();
      final refresh = controller().refresh();
      await controller().setPhoto(risottoId, newPhoto);
      // La base ya la tiene; la lectura en vuelo es de antes.
      repository.recipes[risottoId] = risotto().copyWith(photoId: newPhotoId);
      repository.pendingFetch!.complete();
      repository.pendingFetch = null;
      await refresh;

      expect(byId(risottoId).photoId, newPhotoId);
    });
  });

  test('el aviso de guardado se publica y se limpia', () async {
    await start();
    final notice = container.read(recipeSavedNoticeProvider.notifier);
    notice.post(lasagne());
    expect(container.read(recipeSavedNoticeProvider), lasagne());
    notice.clear();
    expect(container.read(recipeSavedNoticeProvider), isNull);
  });
}
