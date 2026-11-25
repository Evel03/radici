// Marco provisorio del área de la clienta (/area, entrada /app/): una pantalla
// sin datos todavía, con el idioma y salir. Sus pantallas (pedidos, reservas,
// menús, presupuestos, perfil) llegan en los PRs siguientes y cuelgan de acá.
// Como en Impostazioni, el idioma de la interfaz sale del perfil y se puede
// cambiar.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/client/application/client_providers.dart';
import 'package:radici/features/settings/presentation/language_selector.dart';
import 'package:radici/l10n/app_localizations.dart';

class ClientShell extends ConsumerWidget {
  const ClientShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Sin la cuenta de la clienta (mientras se sale) no hay nada que mostrar.
    if (ref.watch(clientAccountProvider) == null) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final email = switch (ref.watch(sessionControllerProvider)) {
      ClientSession(:final user) => user.email,
      _ => null,
    };

    return Scaffold(
      appBar: AppBar(title: Text(l10n.clientAreaTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      Icons.construction_outlined,
                      size: 64,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.clientAreaHeadline,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.clientAreaBody,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (email != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      l10n.signedInAs(email),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 24),
                  // Con el mismo margen que las opciones del selector.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Semantics(
                      header: true,
                      child: Text(
                        l10n.settingsLanguageSection,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                  const LanguageSelector(),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    key: const ValueKey('client-area-logout'),
                    onPressed: ref
                        .read(sessionControllerProvider.notifier)
                        .signOut,
                    icon: const Icon(Icons.logout),
                    label: Text(l10n.actionLogout),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
