// Impostazioni de la cocinera: idioma de la app (se guarda en su perfil y
// vale en todos sus dispositivos), cuenta y, en la web, la versión abierta.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/build_id.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/settings/presentation/language_selector.dart';
import 'package:radici/l10n/app_localizations.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (name, email) = switch (ref.watch(sessionControllerProvider)) {
      ChefSession(:final chef, :final user) => (chef.displayName, user.email),
      _ => (null, null),
    };
    final buildId = ref.watch(buildIdProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsTitle),
        // Abierta desde un enlace, sin nada debajo: vuelve al inicio (Hoy).
        leading: context.canPop()
            ? null
            : CloseButton(
                key: const ValueKey('settings-close'),
                onPressed: () => context.go(AppRoutes.today),
              ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            key: const ValueKey('settings'),
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _SectionTitle(l10n.settingsLanguageSection),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  l10n.settingsLanguageHelp,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const LanguageSelector(),
              _SectionTitle(l10n.settingsAccountSection),
              if (name != null)
                ListTile(
                  leading: const Icon(Icons.account_circle_outlined),
                  title: Text(name),
                  subtitle: email == null ? null : Text(l10n.signedInAs(email)),
                ),
              ListTile(
                key: const ValueKey('settings-logout'),
                leading: const Icon(Icons.logout),
                title: Text(l10n.actionLogout),
                onTap: ref.read(sessionControllerProvider.notifier).signOut,
              ),
              // Qué versión de /gestione/ está abierta (el id del build): para
              // comprobar que «Aggiorna» trajo la nueva.
              if (buildId.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                  child: Text(
                    l10n.settingsVersion(buildId),
                    key: const ValueKey('settings-version'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
