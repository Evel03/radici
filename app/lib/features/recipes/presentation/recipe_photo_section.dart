// La sección «Foto» del editor de un plato, también en uno nuevo: la vista
// previa (la foto elegida o la guardada), elegirla o cambiarla (en el teléfono,
// cámara o galería; en la web, un archivo: el iPhone ofrece ahí mismo sacar
// una foto) y sacarla. Lo elegido se sube al guardar. Dice cuándo prepara y
// cuándo sube, y si la foto no se pudo guardar (el plato sí), con «Riprova».
// Solo muestra providers: la lógica está en RecipeEditorController.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/platform.dart';
import 'package:radici/features/availability/presentation/availability_actions.dart';
import 'package:radici/features/recipes/application/recipe_editor_controller.dart';
import 'package:radici/features/recipes/data/recipe_photo_picker.dart';
import 'package:radici/features/recipes/data/recipe_photos_repository.dart';
import 'package:radici/features/recipes/domain/recipe_photo.dart';
import 'package:radici/features/recipes/presentation/recipe_photo_thumbnail.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Lado de la vista previa, con la foto grande (1200 px de lado mayor).
const double recipePhotoPreviewSize = 120;

/// El mensaje de una foto que no se pudo guardar (el plato sí).
String recipePhotoFailureMessage(
  AppLocalizations l10n,
  RecipePhotoFailureKind kind, {
  required bool removing,
}) => switch (kind) {
  RecipePhotoFailureKind.unavailable =>
    removing ? l10n.recipePhotoRemoveFailed : l10n.recipePhotoUploadFailed,
  RecipePhotoFailureKind.rejected => l10n.recipePhotoRejected,
  RecipePhotoFailureKind.notFound => l10n.recipeSaveNotFound,
};

class RecipePhotoSection extends ConsumerWidget {
  const RecipePhotoSection({
    super.key,
    required this.target,
    required this.onRetry,
  });

  final RecipeEditorTarget target;

  /// «Riprova» después de que falló la foto: vuelve a guardar (el editor).
  final VoidCallback onRetry;

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    // Los avisos, en el del editor (se busca antes de abrir el selector).
    final messenger = ScaffoldMessenger.of(context);
    final persist = MediaQuery.accessibleNavigationOf(context);
    final source = ref.read(isWebProvider)
        ? RecipePhotoSource.gallery
        : await _askSource(context, l10n);
    if (source == null || !context.mounted) return;
    final error = await ref
        .read(recipeEditorProvider(target).notifier)
        .pickPhoto(source);
    if (error == null || !context.mounted) return;
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(switch (error) {
            RecipePhotoPickError.unreadable => l10n.recipePhotoUnreadable,
            RecipePhotoPickError.permissionDenied =>
              l10n.recipePhotoPermissionDenied,
            RecipePhotoPickError.unavailable => l10n.recipePhotoPickFailed,
          }),
          duration: errorSnackBarDuration,
          persist: persist,
          showCloseIcon: persist,
        ),
      );
  }

  /// En el teléfono: cámara o galería.
  Future<RecipePhotoSource?> _askSource(
    BuildContext context,
    AppLocalizations l10n,
  ) => showModalBottomSheet<RecipePhotoSource>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('recipe-photo-camera'),
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(l10n.recipePhotoCamera),
            onTap: () =>
                Navigator.of(sheetContext).pop(RecipePhotoSource.camera),
          ),
          ListTile(
            key: const ValueKey('recipe-photo-gallery'),
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l10n.recipePhotoGallery),
            onTap: () =>
                Navigator.of(sheetContext).pop(RecipePhotoSource.gallery),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(recipeEditorProvider(target));
    final editor = ref.read(recipeEditorProvider(target).notifier);
    final newPhoto = state.newPhoto;
    final savedPhotoId = state.shownSavedPhotoId;
    final hasPhoto = newPhoto != null || savedPhotoId != null;
    final busy = state.saving || state.preparingPhoto;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final Widget? preview = switch ((newPhoto, savedPhotoId)) {
      (final NewRecipePhoto photo, _) => RecipePhotoSquare(
        key: const ValueKey('recipe-photo-preview'),
        image: MemoryImage(photo.photo.full),
        size: recipePhotoPreviewSize,
        semanticLabel: l10n.recipePhotoPreview,
      ),
      (null, final String photoId) => RecipePhotoThumbnail(
        key: const ValueKey('recipe-photo-preview'),
        recipeId: state.draft.id,
        photoId: photoId,
        thumb: false,
        size: recipePhotoPreviewSize,
        semanticLabel: l10n.recipePhotoPreview,
      ),
      _ => null,
    };

    final String? status = switch (state) {
      _ when state.preparingPhoto => l10n.recipePhotoPreparing,
      _ when state.photoInFlight is RemoveRecipePhoto =>
        l10n.recipePhotoRemoving,
      _ when state.uploadingPhoto => l10n.recipePhotoUploading,
      _ when state.photoError != null => null,
      _ when newPhoto != null => l10n.recipePhotoPending,
      _ when state.photoChange is RemoveRecipePhoto =>
        l10n.recipePhotoRemovePending,
      _ => null,
    };
    final working = state.preparingPhoto || state.uploadingPhoto;
    final error = state.photoError;

    return Column(
      key: const ValueKey('recipe-photo-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.recipePhotoHelp, style: muted),
        if (preview != null) ...[
          const SizedBox(height: 12),
          Align(alignment: AlignmentDirectional.centerStart, child: preview),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('recipe-photo-choose'),
              onPressed: busy ? null : () => unawaited(_choose(context, ref)),
              icon: Icon(
                hasPhoto ? Icons.photo_outlined : Icons.add_a_photo_outlined,
              ),
              label: Text(
                hasPhoto ? l10n.recipePhotoChange : l10n.recipePhotoAdd,
              ),
            ),
            if (hasPhoto)
              TextButton.icon(
                key: const ValueKey('recipe-photo-remove'),
                onPressed: busy ? null : editor.removePhoto,
                icon: const Icon(Icons.delete_outline),
                label: Text(l10n.recipePhotoRemove),
              ),
          ],
        ),
        if (working)
          // Lo dice el texto de abajo (que el lector de pantalla anuncia).
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: ExcludeSemantics(
              child: LinearProgressIndicator(
                key: ValueKey('recipe-photo-progress'),
              ),
            ),
          ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Semantics(
              liveRegion: true,
              child: Text(
                status,
                key: const ValueKey('recipe-photo-status'),
                style: muted,
              ),
            ),
          ),
        if (error != null)
          _PhotoError(
            message: recipePhotoFailureMessage(
              l10n,
              error,
              removing: state.photoChange is RemoveRecipePhoto,
            ),
            onRetry: error == RecipePhotoFailureKind.unavailable && !busy
                ? onRetry
                : null,
          ),
      ],
    );
  }
}

/// La foto no se guardó (el plato sí): queda a la vista hasta reintentar,
/// elegir otra o sacarla.
class _PhotoError extends StatelessWidget {
  const _PhotoError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onErrorContainer;
    return Container(
      key: const ValueKey('recipe-photo-error'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // El lector de pantalla lo anuncia (es el único aviso).
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(color: ink),
            ),
          ),
          if (onRetry != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                key: const ValueKey('recipe-photo-retry'),
                style: TextButton.styleFrom(foregroundColor: ink),
                onPressed: onRetry,
                child: Text(l10n.actionRetry),
              ),
            )
          else
            const SizedBox(height: 4),
        ],
      ),
    );
  }
}
