// Fotos de los platos en los tests: el bucket y set_recipe_photo en memoria,
// un selector que devuelve lo que se le diga, un procesador instantáneo y las
// imágenes que cargan (o no) sin red.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:radici/features/recipes/data/recipe_photo_picker.dart';
import 'package:radici/features/recipes/data/recipe_photos_repository.dart';
import 'package:radici/features/recipes/domain/recipe_photo.dart';

/// Un JPEG de verdad, chiquito (4×3).
final Uint8List tinyJpeg = img.encodeJpg(img.Image(width: 4, height: 3));

/// Otro JPEG chiquito (2×2), para distinguir la miniatura de la grande.
final Uint8List tinyThumbJpeg = img.encodeJpg(img.Image(width: 2, height: 2));

/// Lo que devuelve [fakeProcessRecipePhoto].
final ProcessedRecipePhoto samplePhoto = ProcessedRecipePhoto(
  full: tinyJpeg,
  thumb: tinyThumbJpeg,
);

/// Bytes que [fakeProcessRecipePhoto] no puede abrir.
final Uint8List unreadablePhotoBytes = Uint8List.fromList([0, 0, 0]);

/// En lugar de processRecipePhoto (que en los tests de widgets correría en
/// otro isolate): [samplePhoto] enseguida, o RecipePhotoFormatException con
/// [unreadablePhotoBytes].
Future<ProcessedRecipePhoto> fakeProcessRecipePhoto(Uint8List bytes) async {
  if (listEquals(bytes, unreadablePhotoBytes)) {
    throw const RecipePhotoFormatException();
  }
  return samplePhoto;
}

/// El selector: devuelve [result] (null = canceló) o falla con [failure].
class FakeRecipePhotoPicker implements RecipePhotoPicker {
  Uint8List? result = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0]);
  RecipePhotoPickFailureKind? failure;

  /// Si no es null, [pick] espera a que se complete (el selector abierto).
  Completer<void>? pending;

  final List<RecipePhotoSource> calls = [];

  @override
  Future<Uint8List?> pick(RecipePhotoSource source) async {
    calls.add(source);
    final wait = pending;
    if (wait != null) await wait.future;
    final failure = this.failure;
    if (failure != null) throw RecipePhotoPickFailure(failure);
    return result;
  }
}

/// El bucket y recipes.photo_id "en el servidor", en memoria. Como la base:
/// set_recipe_photo exige los dos archivos subidos y devuelve la foto que
/// dejó de usarse (null si es la misma). Cada pedido se aplica en cuanto
/// llega: los `pending…` demoran solo la respuesta.
class FakeRecipePhotosRepository implements RecipePhotosRepository {
  /// La foto de cada plato en la base, por id de plato.
  final Map<String, String> photoOf = {};

  /// Fotos con sus dos archivos subidos: `'<plato>/<foto>'`.
  final Set<String> uploaded = {};

  /// Si no es null, [upload] falla con esto (y no sube nada).
  RecipePhotoFailureKind? uploadFailure;

  /// Si no es null, [setPhoto] falla con esto (y no cambia nada).
  RecipePhotoFailureKind? setFailure;
  bool failDelete = false;

  Completer<void>? pendingUpload;

  /// La foto de cada [upload], en orden (también las que fallaron).
  final List<String> uploadCalls = [];
  final List<({String recipeId, String? photoId})> setCalls = [];
  final List<({String recipeId, Set<String> photoIds})> deleteCalls = [];

  @override
  String publicUrl({
    required String chefId,
    required String recipeId,
    required String photoId,
    bool thumb = false,
  }) =>
      'https://fotos.test/${recipePhotoPath(chefId: chefId, recipeId: recipeId, photoId: photoId, thumb: thumb)}';

  @override
  Future<void> upload({
    required String chefId,
    required String recipeId,
    required NewRecipePhoto photo,
  }) async {
    uploadCalls.add(photo.photoId);
    final failure = uploadFailure;
    if (failure == null) uploaded.add('$recipeId/${photo.photoId}');
    final wait = pendingUpload;
    if (wait != null) await wait.future;
    if (failure != null) throw RecipePhotoFailure(failure);
  }

  @override
  Future<String?> setPhoto({required String recipeId, String? photoId}) async {
    setCalls.add((recipeId: recipeId, photoId: photoId));
    final failure = setFailure;
    if (failure != null) throw RecipePhotoFailure(failure);
    if (photoId != null && !uploaded.contains('$recipeId/$photoId')) {
      throw const RecipePhotoFailure(RecipePhotoFailureKind.rejected);
    }
    final previous = photoOf[recipeId];
    if (photoId == null) {
      photoOf.remove(recipeId);
    } else {
      photoOf[recipeId] = photoId;
    }
    return previous == photoId ? null : previous;
  }

  @override
  Future<void> delete({
    required String chefId,
    required String recipeId,
    required Iterable<String> photoIds,
  }) async {
    final ids = photoIds.toSet();
    deleteCalls.add((recipeId: recipeId, photoIds: ids));
    if (failDelete) {
      throw const RecipePhotoFailure(RecipePhotoFailureKind.unavailable);
    }
    uploaded.removeAll([for (final id in ids) '$recipeId/$id']);
  }
}

/// Una imagen que no carga (la foto se borró o no hay red), sin esperar a
/// nada: el error llega en el próximo microtask.
class FailingImageProvider extends ImageProvider<FailingImageProvider> {
  const FailingImageProvider();

  @override
  Future<FailingImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    FailingImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    Future<ImageInfo>.error(StateError('la foto no carga')),
  );
}
