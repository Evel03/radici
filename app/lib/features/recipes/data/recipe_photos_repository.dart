// Fotos de los platos en Supabase (migración 20261120100000_recipe_photos.sql):
// los dos archivos de cada foto en el bucket público recipe-photos y
// set_recipe_photo, que la pone, la cambia o la saca del plato.
//
// Un archivo nunca se pisa (sin upsert): cada foto lleva un uuid nuevo, así la
// caché puede ser larga. Las políticas solo dejan subir a la carpeta de la
// cocina y con la ruta exacta (recipePhotoPath). Nada de esto se loguea.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/recipes/domain/recipe_photo.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// El bucket público de las fotos de los platos.
const String recipePhotosBucket = 'recipe-photos';

/// Cache-Control de los archivos: una semana (604800 s). Nunca cambian (el uuid
/// es nuevo en cada foto) y una foto sacada deja de verse a la semana como
/// mucho en la caché de alguien.
const String recipePhotoCacheControl = '604800';

/// Cuánto se espera una subida antes de darla por fallida (una red móvil
/// mala). El reintento sube los mismos archivos.
const Duration recipePhotoUploadTimeout = Duration(seconds: 60);

abstract interface class RecipePhotosRepository {
  /// La URL pública de la foto [photoId] del plato [recipeId] de la cocina
  /// [chefId] (la miniatura con [thumb]); null sin backend.
  String? publicUrl({
    required String chefId,
    required String recipeId,
    required String photoId,
    bool thumb = false,
  });

  /// Sube los dos archivos de [photo] al plato [recipeId], en JPEG y sin pisar
  /// nada. Un archivo que ya está cuenta como subido: es de un intento
  /// anterior de esta misma foto (el uuid es nuevo en cada foto) cuya
  /// respuesta se perdió. Lanza [RecipePhotoFailure].
  Future<void> upload({
    required String chefId,
    required String recipeId,
    required NewRecipePhoto photo,
  });

  /// set_recipe_photo: pone [photoId] en el plato [recipeId] (los dos archivos
  /// tienen que estar subidos) o, con null, le saca la foto. Devuelve la foto
  /// que dejó de usarse (null si no tenía o si es la misma). Lanza
  /// [RecipePhotoFailure].
  Future<String?> setPhoto({required String recipeId, String? photoId});

  /// Borra los archivos de las fotos [photoIds] del plato [recipeId]. Lanza
  /// [RecipePhotoFailure].
  Future<void> delete({
    required String chefId,
    required String recipeId,
    required Iterable<String> photoIds,
  });
}

final recipePhotosRepositoryProvider = Provider<RecipePhotosRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendRecipePhotosRepository()
      : SupabaseRecipePhotosRepository(client);
});

enum RecipePhotoFailureKind {
  /// Sin conexión, el servidor no respondió a tiempo o falló.
  unavailable,

  /// El servidor no aceptó la foto (permisos, tamaño, tipo, los archivos no
  /// están). La app sube lo que exige la base: no debería pasar.
  rejected,

  /// El plato ya no existe, o es de otra cocinera.
  notFound,
}

class RecipePhotoFailure implements Exception {
  const RecipePhotoFailure(this.kind);

  final RecipePhotoFailureKind kind;

  @override
  String toString() => 'RecipePhotoFailure(${kind.name})';
}

class SupabaseRecipePhotosRepository implements RecipePhotosRepository {
  SupabaseRecipePhotosRepository(this._client);

  final SupabaseClient _client;

  StorageFileApi get _bucket => _client.storage.from(recipePhotosBucket);

  @override
  String publicUrl({
    required String chefId,
    required String recipeId,
    required String photoId,
    bool thumb = false,
  }) => _bucket.getPublicUrl(
    recipePhotoPath(
      chefId: chefId,
      recipeId: recipeId,
      photoId: photoId,
      thumb: thumb,
    ),
  );

  @override
  Future<void> upload({
    required String chefId,
    required String recipeId,
    required NewRecipePhoto photo,
  }) async {
    String path({required bool thumb}) => recipePhotoPath(
      chefId: chefId,
      recipeId: recipeId,
      photoId: photo.photoId,
      thumb: thumb,
    );
    // Las dos a la vez; si una falla, el error llega cuando terminan las dos.
    await Future.wait([
      _put(path(thumb: false), photo.photo.full),
      _put(path(thumb: true), photo.photo.thumb),
    ]);
  }

  Future<void> _put(String path, Uint8List bytes) async {
    try {
      await _bucket
          .uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              cacheControl: recipePhotoCacheControl,
            ),
          )
          .timeout(recipePhotoUploadTimeout);
    } on StorageException catch (error) {
      if (_isDuplicate(error)) return;
      throw RecipePhotoFailure(_storageFailure(error));
    } on Object {
      throw const RecipePhotoFailure(RecipePhotoFailureKind.unavailable);
    }
  }

  @override
  Future<String?> setPhoto({required String recipeId, String? photoId}) async {
    final Object? previous;
    try {
      previous = await _client.rpc<dynamic>(
        'set_recipe_photo',
        params: {'p_recipe_id': recipeId, 'p_photo_id': photoId},
      );
    } on PostgrestException catch (error) {
      // 22023 photo_not_found, 42501 not_a_chef, P0002 recipe_not_found. No
      // se loguea el detalle (trae las rutas).
      throw RecipePhotoFailure(switch (error.code) {
        'P0002' => RecipePhotoFailureKind.notFound,
        '22023' || '42501' => RecipePhotoFailureKind.rejected,
        _ => RecipePhotoFailureKind.unavailable,
      });
    } on Object {
      throw const RecipePhotoFailure(RecipePhotoFailureKind.unavailable);
    }
    // Para borrar sus archivos: algo que no sea un id no se usa.
    return previous is String && previous.isNotEmpty ? previous : null;
  }

  @override
  Future<void> delete({
    required String chefId,
    required String recipeId,
    required Iterable<String> photoIds,
  }) async {
    final paths = [
      for (final photoId in photoIds)
        for (final thumb in const [false, true])
          recipePhotoPath(
            chefId: chefId,
            recipeId: recipeId,
            photoId: photoId,
            thumb: thumb,
          ),
    ];
    if (paths.isEmpty) return;
    try {
      await _bucket.remove(paths);
    } on Object {
      throw const RecipePhotoFailure(RecipePhotoFailureKind.unavailable);
    }
  }

  /// Storage responde 409 Duplicate (o 400 con statusCode 409 en el cuerpo)
  /// si el archivo ya existe.
  static bool _isDuplicate(StorageException error) =>
      error.statusCode == '409' || error.error?.toLowerCase() == 'duplicate';

  /// Un 4xx (salvo 401, 408 y 429, que un reintento puede resolver) es que no
  /// la acepta; lo demás (5xx, sin respuesta), que no está disponible.
  static RecipePhotoFailureKind _storageFailure(StorageException error) {
    final status = int.tryParse(error.statusCode ?? '');
    if (status != null &&
        status >= 400 &&
        status < 500 &&
        !const {401, 408, 429}.contains(status)) {
      return RecipePhotoFailureKind.rejected;
    }
    return RecipePhotoFailureKind.unavailable;
  }
}

class _NoBackendRecipePhotosRepository implements RecipePhotosRepository {
  const _NoBackendRecipePhotosRepository();

  static const _failure = RecipePhotoFailure(
    RecipePhotoFailureKind.unavailable,
  );

  @override
  String? publicUrl({
    required String chefId,
    required String recipeId,
    required String photoId,
    bool thumb = false,
  }) => null;

  @override
  Future<void> upload({
    required String chefId,
    required String recipeId,
    required NewRecipePhoto photo,
  }) => Future.error(_failure);

  @override
  Future<String?> setPhoto({required String recipeId, String? photoId}) =>
      Future.error(_failure);

  @override
  Future<void> delete({
    required String chefId,
    required String recipeId,
    required Iterable<String> photoIds,
  }) => Future.error(_failure);
}
