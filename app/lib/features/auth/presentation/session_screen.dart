// Pantalla de transición mientras se lee la cuenta después de entrar, o el
// error si no se pudo (con reintentar y salir).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/l10n/app_localizations.dart';

class SessionScreen extends ConsumerWidget {
  const SessionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final session = ref.watch(sessionControllerProvider);

    final Widget content = switch (session) {
      SessionFailed(:final kind) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 56,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            switch (kind) {
              AccountFailureKind.unavailable => l10n.sessionErrorUnavailable,
              AccountFailureKind.chefNotConfigured =>
                l10n.sessionErrorChefNotConfigured,
            },
            key: const ValueKey('session-error'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const ValueKey('session-retry'),
            onPressed: ref.read(sessionControllerProvider.notifier).retry,
            child: Text(l10n.actionRetry),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey('session-logout'),
            onPressed: ref.read(sessionControllerProvider.notifier).signOut,
            child: Text(l10n.actionLogout),
          ),
        ],
      ),
      _ => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(l10n.sessionLoading, style: theme.textTheme.bodyLarge),
        ],
      ),
    };

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
