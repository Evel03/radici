// La foto en el editor de un plato: elegirla al crear el plato (en el teléfono,
// cámara o galería; en /gestione/, un archivo), verla, guardarla con el plato,
// lo que pasa si no se sube (el plato queda guardado y «Riprova» sube solo la
// foto), cambiarla o sacarla en un plato guardado, una foto que no carga, y
// los tamaños con letra grande en los tres idiomas.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/uuid.dart';
import 'package:radici/features/recipes/data/recipe_photo_picker.dart';
import 'package:radici/features/recipes/data/recipe_photos_repository.dart';
import 'package:radici/features/recipes/presentation/recipe_editor_screen.dart';
import 'package:radici/features/recipes/presentation/recipes_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/photo_fakes.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';

const String _newId = '0e5b3c1a-2f4d-4a6b-8c9d-000000000001';
const String _photoId = '0e5b3c1a-2f4d-4a6b-8c9d-000000000002';
const String _otherPhotoId = '0e5b3c1a-2f4d-4a6b-8c9d-000000000003';
const String _savedPhoto = 'f0000000-0000-4000-8000-0000000000aa';

void main() {
  Finder byKey(String key) => find.byKey(ValueKey(key));
  Finder tile(String id) => byKey('recipe-$id');

  late FakeRecipesRepository repository;
  late FakeRecipePhotosRepository photos;
  late FakeRecipePhotoPicker picker;

  setUp(() {
    repository = FakeRecipesRepository(sampleRecipes());
    photos = FakeRecipePhotosRepository();
    picker = FakeRecipePhotoPicker();
  });

  /// La lasaña con [_savedPhoto], en el catálogo y en el bucket.
  void lasagneWithPhoto() {
    repository.recipes[lasagneId] = lasagne().copyWith(photoId: _savedPhoto);
    photos
      ..uploaded.add('$lasagneId/$_savedPhoto')
      ..photoOf[lasagneId] = _savedPhoto;
  }

  /// La lista de platos con el editor de [location] encima.
  Future<ChefApp> openEditor(
    WidgetTester tester, {
    String location = '/altro/piatti/nuovo',
    Size size = const Size(400, 900),
    Locale locale = const Locale('it', 'IT'),
    bool isWeb = false,
    ImageProvider<Object> Function(String url)? photoImage,
  }) async {
    final ids = [_newId, _photoId, _otherPhotoId];
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      recipes: repository,
      photos: photos,
      photoPicker: picker,
      photoImage: photoImage,
      isWeb: isWeb,
      location: '/altro/piatti',
      size: size,
      deviceLocales: [locale],
      overrides: [newIdProvider.overrideWithValue(() => ids.removeAt(0))],
    );
    app.go(location);
    await tester.pumpAndSettle();
    expect(find.byType(RecipeEditorScreen), findsOneWidget);
    return app;
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.pumpAndSettle();
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// «Aggiungi foto» (o «Cambia foto») y, en el teléfono, [option] en la hoja.
  Future<void> choosePhoto(
    WidgetTester tester, {
    String option = 'recipe-photo-gallery',
  }) async {
    await tapVisible(tester, byKey('recipe-photo-choose'));
    await tester.tap(byKey(option));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(byKey('recipe-save'));
    await tester.pumpAndSettle();
  }

  String? statusText(WidgetTester tester) {
    final status = byKey('recipe-photo-status');
    return status.evaluate().isEmpty ? null : tester.widget<Text>(status).data;
  }

  testWidgets(
    'en «Nuovo piatto», a 375×667: elegir la foto de la galería, verla y guardarla con el plato',
    (tester) async {
      await openEditor(tester, size: const Size(375, 667));
      expect(find.text('Foto'), findsOneWidget);
      expect(byKey('recipe-photo-preview'), findsNothing);
      expect(
        byKey('recipe-photo-remove'),
        findsNothing,
        reason: 'sin foto no hay qué sacar',
      );
      await tester.enterText(byKey('recipe-name-it'), 'Pasta al pesto');

      await tapVisible(tester, byKey('recipe-photo-choose'));
      // En el teléfono, cámara o galería, con objetivos de 48 dp o más.
      for (final key in ['recipe-photo-camera', 'recipe-photo-gallery']) {
        expect(
          tester.getSize(byKey(key)).height,
          greaterThanOrEqualTo(48),
          reason: key,
        );
      }
      expect(find.text('Scatta una foto'), findsOneWidget);
      await tester.tap(find.text('Scegli dalla galleria'));
      await tester.pumpAndSettle();

      expect(picker.calls, [RecipePhotoSource.gallery]);
      await tester.ensureVisible(byKey('recipe-photo-preview'));
      await tester.pumpAndSettle();
      // La vista previa, con la foto grande (la miniatura es para la lista).
      final preview = tester.widget<Image>(
        find.descendant(
          of: byKey('recipe-photo-preview'),
          matching: find.byType(Image),
        ),
      );
      expect((preview.image as MemoryImage).bytes, same(samplePhoto.full));
      expect(
        tester.getSemantics(byKey('recipe-photo-preview')),
        matchesSemantics(label: 'Foto del piatto', isImage: true),
      );
      expect(statusText(tester), 'La foto si carica quando salvi.');
      expect(
        find.widgetWithText(OutlinedButton, 'Cambia foto'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Togli foto'), findsOneWidget);

      await save(tester);

      expect(repository.saveCalls.single.id, _newId);
      expect(photos.uploadCalls, [_photoId]);
      expect(photos.setCalls, [(recipeId: _newId, photoId: _photoId)]);
      expect(find.byType(RecipesScreen), findsOneWidget);
      expect(find.text('«Pasta al pesto» salvato.'), findsOneWidget);
      expect(
        find.descendant(
          of: tile(_newId),
          matching: byKey('recipe-photo-$_newId'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('la cámara del teléfono también', (tester) async {
    await openEditor(tester);
    await choosePhoto(tester, option: 'recipe-photo-camera');
    expect(picker.calls, [RecipePhotoSource.camera]);
    expect(byKey('recipe-photo-preview'), findsOneWidget);
  });

  testWidgets(
    'en /gestione/ elige un archivo enseguida, sin preguntar cámara o galería',
    (tester) async {
      await openEditor(tester, isWeb: true);
      await tapVisible(tester, byKey('recipe-photo-choose'));

      expect(find.text('Scatta una foto'), findsNothing);
      expect(picker.calls, [RecipePhotoSource.gallery]);
      expect(byKey('recipe-photo-preview'), findsOneWidget);
    },
  );

  testWidgets('mientras sube la foto lo dice, y después vuelve a la lista', (
    tester,
  ) async {
    await openEditor(tester);
    await tester.enterText(byKey('recipe-name-it'), 'Pasta al pesto');
    await choosePhoto(tester);
    photos.pendingUpload = Completer<void>();

    await tester.tap(byKey('recipe-save'));
    await tester.pump();
    await tester.pump();
    expect(statusText(tester), 'Carico la foto…');
    expect(byKey('recipe-photo-progress'), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(byKey('recipe-photo-choose')).onPressed,
      isNull,
    );

    photos.pendingUpload!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(RecipesScreen), findsOneWidget);
  });

  testWidgets(
    'si la foto no se sube: el plato queda guardado, lo dice y «Riprova» sube solo la foto',
    (tester) async {
      photos.uploadFailure = RecipePhotoFailureKind.unavailable;
      await openEditor(tester);
      await tester.enterText(byKey('recipe-name-it'), 'Pasta al pesto');
      await choosePhoto(tester);
      await save(tester);

      const message =
          'Il piatto è salvato, ma la foto non è stata caricata. Controlla la connessione e riprova.';
      expect(
        find.byType(RecipeEditorScreen),
        findsOneWidget,
        reason: 'no se cierra',
      );
      // Lo dice la sección, a la vista (el editor la lleva ahí), y el lector de
      // pantalla lo anuncia.
      expect(
        find.descendant(
          of: byKey('recipe-photo-error'),
          matching: find.text(message),
        ),
        findsOneWidget,
      );
      expect(
        byKey('recipe-photo-error').hitTestable(),
        findsOneWidget,
        reason: 'a la vista',
      );
      expect(byKey('recipe-photo-retry').hitTestable(), findsOneWidget);
      expect(
        tester.getSemantics(find.text(message)),
        matchesSemantics(label: message, isLiveRegion: true),
      );
      expect(
        repository.recipes[_newId],
        isNotNull,
        reason: 'el plato está guardado',
      );
      expect(
        byKey('recipe-photo-preview'),
        findsOneWidget,
        reason: 'la foto sigue',
      );

      photos.uploadFailure = null;
      await tapVisible(tester, byKey('recipe-photo-retry'));

      expect(
        repository.saveCalls,
        hasLength(1),
        reason: 'el plato no se vuelve a mandar',
      );
      expect(photos.uploadCalls, [_photoId, _photoId]);
      expect(find.byType(RecipesScreen), findsOneWidget);
      expect(
        find.descendant(
          of: tile(_newId),
          matching: byKey('recipe-photo-$_newId'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'si el servidor no acepta la foto lo dice, sin «Riprova» (otra foto o sacarla)',
    (tester) async {
      photos.uploadFailure = RecipePhotoFailureKind.rejected;
      await openEditor(tester);
      await tester.enterText(byKey('recipe-name-it'), 'Pasta al pesto');
      await choosePhoto(tester);
      await save(tester);

      expect(
        find.descendant(
          of: byKey('recipe-photo-error'),
          matching: find.text(
            "Il piatto è salvato, ma il server non ha accettato la foto. Prova con un'altra.",
          ),
        ),
        findsOneWidget,
      );
      expect(byKey('recipe-photo-retry'), findsNothing);

      // Sacarla deja el plato como quedó: nada más que guardar.
      await tapVisible(tester, byKey('recipe-photo-remove'));
      expect(byKey('recipe-photo-error'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(
        find.byType(RecipesScreen),
        findsOneWidget,
        reason: 'sin cambios pendientes, sale directo',
      );
      expect(
        find.descendant(
          of: tile(_newId),
          matching: find.text('Pasta al pesto'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'un plato con foto: la muestra (la grande) con «Cambia foto» y «Togli foto»; sacarla se aplica al guardar',
    (tester) async {
      lasagneWithPhoto();
      final urls = <String>[];
      await openEditor(
        tester,
        location: '/altro/piatti/$lasagneId',
        photoImage: (url) {
          urls.add(url);
          return MemoryImage(tinyJpeg);
        },
      );

      expect(byKey('recipe-photo-preview'), findsOneWidget);
      expect(
        urls,
        contains('https://fotos.test/$testChefId/$lasagneId/$_savedPhoto.jpg'),
        reason: 'la vista previa usa la foto grande',
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Cambia foto'),
        findsOneWidget,
      );
      expect(statusText(tester), isNull);

      await tapVisible(tester, byKey('recipe-photo-remove'));
      expect(byKey('recipe-photo-preview'), findsNothing);
      expect(statusText(tester), 'La foto si toglie quando salvi.');
      expect(
        find.widgetWithText(OutlinedButton, 'Aggiungi foto'),
        findsOneWidget,
      );

      await save(tester);

      expect(repository.saveCalls, isEmpty, reason: 'solo cambió la foto');
      expect(photos.setCalls, [(recipeId: lasagneId, photoId: null)]);
      expect(photos.deleteCalls.single.photoIds, {_savedPhoto});
      expect(find.byType(RecipesScreen), findsOneWidget);
      expect(byKey('recipe-photo-$lasagneId'), findsNothing);
    },
  );

  testWidgets(
    'cambiar la foto de un plato guardado: la lista muestra la nueva',
    (tester) async {
      lasagneWithPhoto();
      final urls = <String>[];
      await openEditor(
        tester,
        location: '/altro/piatti/$lasagneId',
        photoImage: (url) {
          urls.add(url);
          return MemoryImage(tinyJpeg);
        },
      );
      await choosePhoto(tester, option: 'recipe-photo-camera');
      expect(statusText(tester), 'La foto si carica quando salvi.');
      await save(tester);

      expect(photos.setCalls, [(recipeId: lasagneId, photoId: _newId)]);
      expect(photos.deleteCalls.single.photoIds, {_savedPhoto});
      expect(find.byType(RecipesScreen), findsOneWidget);
      expect(
        urls.last,
        'https://fotos.test/$testChefId/$lasagneId/$_newId-thumb.jpg',
      );
    },
  );

  testWidgets('duplicar un plato con foto: la copia empieza sin foto', (
    tester,
  ) async {
    lasagneWithPhoto();
    await openEditor(tester, location: '/altro/piatti/nuovo?copia=$lasagneId');
    expect(byKey('recipe-photo-preview'), findsNothing);
    expect(
      find.widgetWithText(OutlinedButton, 'Aggiungi foto'),
      findsOneWidget,
    );
  });

  testWidgets(
    'al elegir: sin permiso de la cámara y una foto que no se abre, lo dice y no cambia nada',
    (tester) async {
      await openEditor(tester);
      picker.failure = RecipePhotoPickFailureKind.permissionDenied;
      await choosePhoto(tester, option: 'recipe-photo-camera');
      expect(
        find.text(
          'Radici non ha il permesso di usare la fotocamera. Puoi darlo nelle impostazioni del telefono.',
        ),
        findsOneWidget,
      );

      picker
        ..failure = null
        ..result = unreadablePhotoBytes;
      await choosePhoto(tester);
      expect(
        find.text("Non riesco ad aprire questa foto. Prova con un'altra."),
        findsOneWidget,
      );
      expect(byKey('recipe-photo-preview'), findsNothing);

      picker.failure = RecipePhotoPickFailureKind.unavailable;
      await choosePhoto(tester);
      expect(find.text('Impossibile aprire le foto. Riprova.'), findsOneWidget);
    },
  );

  testWidgets('cancelar el selector no cambia nada', (tester) async {
    await openEditor(tester);
    picker.result = null;
    await choosePhoto(tester);
    expect(byKey('recipe-photo-preview'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('salir con una foto elegida sin guardar pide confirmación', (
    tester,
  ) async {
    await openEditor(tester, location: '/altro/piatti/$risottoId');
    await choosePhoto(tester);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Scartare le modifiche?'), findsOneWidget);
  });

  testWidgets(
    'una foto guardada que no carga: un cuadrado neutro, sin error a la vista',
    (tester) async {
      lasagneWithPhoto();
      await openEditor(
        tester,
        location: '/altro/piatti/$lasagneId',
        photoImage: (_) => const FailingImageProvider(),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: byKey('recipe-photo-preview'),
          matching: byKey('recipe-photo-placeholder'),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.broken_image), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  // Texto grande: en el iPhone, los tamaños de accesibilidad empiezan en ≈1.65.
  for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
    testWidgets(
      'a 375×667 con el texto al doble, la sección con foto y error entra y sus botones miden 48 dp (${locale.languageCode})',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        photos.uploadFailure = RecipePhotoFailureKind.unavailable;
        await openEditor(tester, size: const Size(375, 667), locale: locale);
        await tester.enterText(byKey('recipe-name-it'), 'Pasta al pesto');
        await choosePhoto(tester);
        await save(tester);
        await tester.ensureVisible(byKey('recipe-photo-section'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        for (final key in [
          'recipe-photo-choose',
          'recipe-photo-remove',
          'recipe-photo-retry',
        ]) {
          await tester.ensureVisible(byKey(key));
          await tester.pumpAndSettle();
          expect(
            tester.getSize(byKey(key)).height,
            greaterThanOrEqualTo(48),
            reason: key,
          );
          expect(byKey(key).hitTestable(), findsOneWidget, reason: key);
        }
      },
    );
  }
}
