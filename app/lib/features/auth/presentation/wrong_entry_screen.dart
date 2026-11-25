// «Esta cuenta es de la otra entrada»: una clienta que abre /gestione/ o la
// cocina que abre /app/. No se mezclan: la pantalla dice por dónde entrar y
// deja salir. El texto sale de la entrada, no de la cuenta: la sesión de cada
// entrada se guarda aparte (ver app_entry.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/app_entry.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/l10n/app_localizations.dart';

class WrongEntryScreen extends ConsumerWidget {
  const WrongEntryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final entry = ref.watch(appEntryProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.wrongEntryTitle)),
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
                      Icons.swap_horiz,
                      size: 64,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    key: const ValueKey('wrong-entry-body'),
                    switch (entry) {
                      AppEntry.kitchen => l10n.wrongEntryClientBody,
                      AppEntry.client => l10n.wrongEntryKitchenBody,
                    },
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    key: const ValueKey('wrong-entry-logout'),
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
