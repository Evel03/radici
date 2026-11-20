// La app con la sesión de Evelyn abierta y repositorios falsos.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/router.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/availability/data/availability_repository.dart';
import 'package:radici/features/recipes/application/recipe_photo_providers.dart';
import 'package:radici/features/recipes/data/recipe_photo_picker.dart';
import 'package:radici/features/recipes/data/recipe_photos_repository.dart';
import 'package:radici/features/recipes/data/recipes_repository.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';

import 'fakes.dart';
import 'photo_fakes.dart';
import 'pump_app.dart';
import 'request_fixtures.dart';

class ChefApp {
  ChefApp(
    this.container,
    this.auth,
    this.accounts,
    this.requests,
    this.launcher,
    this.availability,
    this.recipes,
    this.photos,
    this.photoPicker,
  );

  final ProviderContainer container;
  final FakeAuthRepository auth;
  final FakeAccountRepository accounts;
  final FakeChefRequestsRepository requests;
  final FakeLinkLauncher launcher;
  final FakeAvailabilityRepository availability;
  final FakeRecipesRepository recipes;
  final FakeRecipePhotosRepository photos;
  final FakeRecipePhotoPicker photoPicker;

  /// Navega como si se abriera un enlace a [location].
  void go(String location) => container.read(routerProvider).go(location);
}

/// Monta la app con Evelyn logueada. [location] abre una ruta directa (como
/// el botón del email: `INBOX_URL#/richieste/<id>`). [accounts] es su perfil
/// (por defecto, sin idioma: manda el dispositivo). [availability] es su
/// horario y sus días bloqueados (por defecto, lunes a viernes de 9 a 15 y
/// sin bloqueos). [recipes] es su catálogo de platos (por defecto, vacío).
/// [photos] es el bucket de las fotos de los platos y [photoPicker] el
/// selector; las fotos se preparan al instante ([fakeProcessRecipePhoto]) y
/// [photoImage] es la imagen de cada URL (por defecto, un JPEG chiquito en
/// memoria: sin red).
Future<ChefApp> pumpChefApp(
  WidgetTester tester, {
  required FakeChefRequestsRepository requests,
  FakeAccountRepository? accounts,
  FakeAvailabilityRepository? availability,
  FakeRecipesRepository? recipes,
  FakeRecipePhotosRepository? photos,
  FakeRecipePhotoPicker? photoPicker,
  ImageProvider<Object> Function(String url)? photoImage,
  String? location,
  Size size = const Size(400, 900),
  List<Locale> deviceLocales = const [Locale('it', 'IT')],
  DateTime Function()? clock,
  List<Override> overrides = const [],
}) async {
  setSurfaceSize(tester, size);
  final auth = FakeAuthRepository(user: chefUser);
  final account = accounts ?? FakeAccountRepository(chefAccountData);
  final days = availability ?? FakeAvailabilityRepository();
  final catalog = recipes ?? FakeRecipesRepository();
  final bucket = photos ?? FakeRecipePhotosRepository();
  final picker = photoPicker ?? FakeRecipePhotoPicker();
  final launcher = FakeLinkLauncher();
  final container = await pumpRadiciApp(
    tester,
    deviceLocales: deviceLocales,
    clock: clock,
    overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      accountRepositoryProvider.overrideWithValue(account),
      chefRequestsRepositoryProvider.overrideWithValue(requests),
      availabilityRepositoryProvider.overrideWithValue(days),
      recipesRepositoryProvider.overrideWithValue(catalog),
      recipePhotosRepositoryProvider.overrideWithValue(bucket),
      recipePhotoPickerProvider.overrideWithValue(picker),
      recipePhotoProcessorProvider.overrideWithValue(fakeProcessRecipePhoto),
      recipePhotoImageProvider.overrideWith(
        (ref, url) => photoImage?.call(url) ?? MemoryImage(tinyJpeg),
      ),
      linkLauncherProvider.overrideWithValue(launcher),
      ...overrides,
    ],
  );
  final app = ChefApp(
    container,
    auth,
    account,
    requests,
    launcher,
    days,
    catalog,
    bucket,
    picker,
  );
  if (location != null) {
    app.go(location);
    await tester.pumpAndSettle();
  }
  return app;
}
