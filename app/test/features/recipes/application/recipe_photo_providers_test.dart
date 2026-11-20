// La URL de cada foto, armada por el repositorio con la cocina de la sesión, y
// la preparación de una foto fuera del hilo de la pantalla.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/recipes/application/recipe_photo_providers.dart';
import 'package:radici/features/recipes/data/recipe_photos_repository.dart';
import 'package:radici/features/recipes/domain/recipe_photo.dart';

import '../../../support/fakes.dart';
import '../../../support/photo_fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';

const String _photoId = 'f0000000-0000-4000-8000-000000000001';

void main() {
  ProviderContainer containerFor(FakeAuthRepository auth) =>
      ProviderContainer.test(
        retry: noRetry,
        overrides: [
          authRepositoryProvider.overrideWithValue(auth),
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository(chefAccountData),
          ),
          recipePhotosRepositoryProvider.overrideWithValue(
            FakeRecipePhotosRepository(),
          ),
        ],
      );

  test('recipePhotoUrlProvider: la URL del repositorio, en la carpeta de la cocina de la sesión', () async {
    final container = containerFor(FakeAuthRepository(user: chefUser));
    const thumb = (recipeId: lasagneId, photoId: _photoId, thumb: true);
    const full = (recipeId: lasagneId, photoId: _photoId, thumb: false);
    container
      ..listen(recipePhotoUrlProvider(thumb), (_, _) {})
      ..listen(recipePhotoUrlProvider(full), (_, _) {});
    await pumpEventQueue();

    expect(
      container.read(recipePhotoUrlProvider(thumb)),
      'https://fotos.test/$testChefId/$lasagneId/$_photoId-thumb.jpg',
    );
    expect(
      container.read(recipePhotoUrlProvider(full)),
      'https://fotos.test/$testChefId/$lasagneId/$_photoId.jpg',
    );
  });

  test('recipePhotoUrlProvider: sin sesión de cocina, sin URL', () async {
    final container = containerFor(FakeAuthRepository());
    const thumb = (recipeId: lasagneId, photoId: _photoId, thumb: true);
    container.listen(recipePhotoUrlProvider(thumb), (_, _) {});
    await pumpEventQueue();
    expect(container.read(recipePhotoUrlProvider(thumb)), isNull);
  });

  group('processRecipePhotoInBackground (en otro isolate)', () {
    test('prepara la foto como processRecipePhoto', () async {
      final input = img.encodePng(img.Image(width: 1600, height: 800));
      final photo = await processRecipePhotoInBackground(input);
      final full = img.decodeJpg(photo.full)!;
      expect([full.width, full.height], [1200, 600]);
      expect(img.decodeJpg(photo.thumb)!.height, 320);
    });

    test('lo que no abre → RecipePhotoFormatException', () async {
      await expectLater(
        processRecipePhotoInBackground(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<RecipePhotoFormatException>()),
      );
    });
  });
}
