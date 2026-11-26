// Pestaña «Altro» (Más) de la cocinera: la cuenta, el catálogo de platos, los
// contactos para las ofertas, Impostazioni (idioma) y salir. En el teléfono reemplaza al menú de la cuenta
// de la barra superior. Cada destino aparece cuando su función existe: más
// adelante, Clientes y Mi horario.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/presentation/chef_account_title.dart';
import 'package:radici/l10n/app_localizations.dart';

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // Un colaborador ve «Colaborador de Evelyn», como en Impostazioni.
    final (name, email) = switch (ref.watch(sessionControllerProvider)) {
      ChefSession(:final chef, :final user) => (
        chefAccountTitle(l10n, chef),
        user.email,
      ),
      _ => (null, null),
    };

    return Scaffold(
      appBar: AppBar(title: Text(l10n.navMore)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            key: const ValueKey('more'),
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              if (name != null)
                ListTile(
                  leading: const Icon(Icons.account_circle_outlined),
                  title: Text(name),
                  subtitle: email == null ? null : Text(l10n.signedInAs(email)),
                ),
              const Divider(height: 1),
              ListTile(
                key: const ValueKey('more-recipes'),
                leading: const Icon(Icons.restaurant_menu),
                title: Text(l10n.recipesTitle),
                subtitle: Text(l10n.moreRecipesSubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go(AppRoutes.recipes),
              ),
              ListTile(
                key: const ValueKey('more-marketing'),
                leading: const Icon(Icons.campaign_outlined),
                title: Text(l10n.marketingTitle),
                subtitle: Text(l10n.moreMarketingSubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go(AppRoutes.marketing),
              ),
              ListTile(
                key: const ValueKey('more-settings'),
                leading: const Icon(Icons.settings_outlined),
                title: Text(l10n.settingsTitle),
                subtitle: Text(l10n.settingsLanguageSection),
                trailing: const Icon(Icons.chevron_right),
                // Impostazioni tapa la barra; al volver queda «Altro».
                onTap: () => context.push(AppRoutes.settings),
              ),
              const Divider(height: 1),
              ListTile(
                key: const ValueKey('more-logout'),
                leading: const Icon(Icons.logout),
                title: Text(l10n.actionLogout),
                onTap: ref.read(sessionControllerProvider.notifier).signOut,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
