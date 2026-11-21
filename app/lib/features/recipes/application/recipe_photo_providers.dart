// Lo que necesitan las pantallas para las fotos de los platos sin tocar
// Supabase: la URL pública de cada archivo (armada por el repositorio con la
// cocina de la sesión), la imagen que la carga y cómo se prepara una foto
// elegida.
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/recipes/data/recipe_photos_repository.dart';
import 'package:radici/features/recipes/domain/recipe_photo.dart';

/// Qué archivo: la foto [photoId] del plato [recipeId], la miniatura o la
/// grande.
typedef RecipePhotoRef = ({String recipeId, String photoId, bool thumb});

/// La URL pública del archivo [RecipePhotoRef] de la cocina de la sesión; null
/// sin sesión de cocina o sin backend (entonces no se muestra la foto).
final recipePhotoUrlProvider = Provider.autoDispose
    .family<String?, RecipePhotoRef>((ref, photo) {
      final chefId = ref.watch(
        currentChefProvider.select((chef) => chef?.chefId),
      );
      if (chefId == null) return null;
      return ref
          .watch(recipePhotosRepositoryProvider)
          .publicUrl(
            chefId: chefId,
            recipeId: photo.recipeId,
            photoId: photo.photoId,
            thumb: photo.thumb,
          );
    });

/// La imagen de una URL pública de foto. En la web, Flutter la pide con
/// XMLHttpRequest (connect-src de /gestione/) y, en Safari y Firefox, la
/// decodifica en un `<img>` con una URL blob: (img-src blob:). Los tests la
/// reemplazan por una en memoria. La imagen ya cargada queda en el ImageCache
/// de Flutter: el provider se descarta cuando nadie la muestra.
final recipePhotoImageProvider = Provider.autoDispose
    .family<ImageProvider<Object>, String>((ref, url) => NetworkImage(url));

/// Prepara una foto elegida (processRecipePhoto). Lanza
/// [RecipePhotoFormatException].
typedef RecipePhotoProcessor = Future<ProcessedRecipePhoto> Function(
  Uint8List bytes,
);

final recipePhotoProcessorProvider = Provider<RecipePhotoProcessor>(
  (ref) => processRecipePhotoInBackground,
);

/// [processRecipePhoto] sin trabar la pantalla: en el teléfono, en otro
/// isolate. La web no tiene isolates: ahí corre en el hilo principal, después
/// de pintar el cuadro que dice que se está preparando (la foto ya llega
/// achicada por el navegador).
Future<ProcessedRecipePhoto> processRecipePhotoInBackground(
  Uint8List bytes,
) async {
  try {
    if (kIsWeb) {
      await SchedulerBinding.instance.endOfFrame;
      return processRecipePhoto(bytes);
    }
    return await compute(processRecipePhoto, bytes);
  } on RecipePhotoFormatException {
    rethrow;
  } on Object {
    throw const RecipePhotoFormatException();
  }
}
