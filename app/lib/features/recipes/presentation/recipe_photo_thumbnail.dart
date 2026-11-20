// La foto de un plato en un cuadrado (recortada, como la miniatura del menù de
// la web): en la lista de platos, en el editor y en el menù elegido del
// detalle de un pedido. Mientras carga, si no carga o sin URL (sin backend),
// un cuadrado neutro: nunca un ícono de error. Solo muestra providers.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/recipes/application/recipe_photo_providers.dart';

/// La foto guardada [photoId] del plato [recipeId] (la miniatura, salvo
/// [thumb] false). Decorativa salvo que tenga [semanticLabel]: en una lista el
/// nombre del plato está al lado.
class RecipePhotoThumbnail extends ConsumerWidget {
  const RecipePhotoThumbnail({
    super.key,
    required this.recipeId,
    required this.photoId,
    required this.size,
    this.thumb = true,
    this.semanticLabel,
  });

  final String recipeId;
  final String photoId;
  final double size;
  final bool thumb;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(
      recipePhotoUrlProvider((
        recipeId: recipeId,
        photoId: photoId,
        thumb: thumb,
      )),
    );
    return RecipePhotoSquare(
      image: url == null ? null : ref.watch(recipePhotoImageProvider(url)),
      size: size,
      semanticLabel: semanticLabel,
    );
  }
}

/// [image] en un cuadrado de [size] con las esquinas casi rectas del tema,
/// recortada para llenarlo. Sin [image], mientras carga o si falla, el
/// cuadrado neutro.
class RecipePhotoSquare extends StatelessWidget {
  const RecipePhotoSquare({
    super.key,
    required this.image,
    required this.size,
    this.semanticLabel,
  });

  final ImageProvider<Object>? image;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      key: const ValueKey('recipe-photo-placeholder'),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SizedBox.square(dimension: size),
    );
    final image = this.image;
    final square = ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox.square(
        dimension: size,
        child: image == null
            ? placeholder
            : Image(
                image: image,
                width: size,
                height: size,
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, synchronous) =>
                    frame == null && !synchronous ? placeholder : child,
                errorBuilder: (context, error, stackTrace) => placeholder,
              ),
      ),
    );
    // El nombre lo dice también mientras carga o si no carga.
    final label = semanticLabel;
    return label == null
        ? square
        : Semantics(label: label, image: true, child: square);
  }
}
