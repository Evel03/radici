// Si no se pudieron leer las sesiones, el aviso con «Riprova» (sin él, la
// agenda o Hoy parecerían vacíos). Mientras cargan, nada: aparecen solas.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/l10n/app_localizations.dart';

class SessionsLoadError extends ConsumerWidget {
  const SessionsLoadError({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failed = ref.watch(
      sessionsControllerProvider.select(
        (sessions) => sessions.hasError && !sessions.isLoading,
      ),
    );
    if (!failed) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('sessions-load-error'),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            l10n.sessionsLoadFailed,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          TextButton(
            key: const ValueKey('sessions-retry'),
            onPressed: () => ref.invalidate(sessionsControllerProvider),
            child: Text(l10n.actionRetry),
          ),
        ],
      ),
    );
  }
}
