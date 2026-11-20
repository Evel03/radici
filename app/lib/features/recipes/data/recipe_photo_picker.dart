// Elegir la foto de un plato con image_picker: la cámara o la galería en el
// teléfono; en la web (/gestione/), un archivo (el iPhone y Android ofrecen
// ahí mismo sacar una foto).
//
// Se le pide al selector la foto ya achicada a 1200 px de lado mayor: en el
// iPhone convierte HEIC a JPEG y en la web la achica el navegador, así la app
// no decodifica 12 MP en el hilo principal. Después processRecipePhoto la
// endereza, la achica de verdad y le saca los metadatos (el selector los
// conserva). requestFullMetadata: false: en el iPhone no pide permiso a la
// fototeca (no hace falta para elegir una foto).
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:radici/features/recipes/domain/recipe_photo.dart';

/// De dónde sale la foto.
enum RecipePhotoSource { camera, gallery }

enum RecipePhotoPickFailureKind {
  /// El teléfono no le dio permiso a la app (la cámara, en el iPhone).
  permissionDenied,

  /// El selector no se pudo abrir o no devolvió la foto.
  unavailable,
}

class RecipePhotoPickFailure implements Exception {
  const RecipePhotoPickFailure(this.kind);

  final RecipePhotoPickFailureKind kind;

  @override
  String toString() => 'RecipePhotoPickFailure(${kind.name})';
}

abstract interface class RecipePhotoPicker {
  /// Abre el selector y devuelve la foto elegida (null si se canceló). Lanza
  /// [RecipePhotoPickFailure].
  Future<Uint8List?> pick(RecipePhotoSource source);
}

final recipePhotoPickerProvider = Provider<RecipePhotoPicker>(
  (ref) => ImagePickerRecipePhotoPicker(ImagePicker()),
);

class ImagePickerRecipePhotoPicker implements RecipePhotoPicker {
  ImagePickerRecipePhotoPicker(this._picker);

  final ImagePicker _picker;

  @override
  Future<Uint8List?> pick(RecipePhotoSource source) async {
    try {
      final file = await _picker.pickImage(
        source: switch (source) {
          RecipePhotoSource.camera => ImageSource.camera,
          RecipePhotoSource.gallery => ImageSource.gallery,
        },
        maxWidth: recipePhotoMaxSide.toDouble(),
        maxHeight: recipePhotoMaxSide.toDouble(),
        requestFullMetadata: false,
      );
      if (file == null) return null;
      return await file.readAsBytes();
    } on PlatformException catch (error) {
      // No se loguea: el mensaje puede traer la ruta del archivo.
      throw RecipePhotoPickFailure(switch (error.code) {
        'camera_access_denied' ||
        'photo_access_denied' => RecipePhotoPickFailureKind.permissionDenied,
        _ => RecipePhotoPickFailureKind.unavailable,
      });
    } on Object {
      throw const RecipePhotoPickFailure(
        RecipePhotoPickFailureKind.unavailable,
      );
    }
  }
}
