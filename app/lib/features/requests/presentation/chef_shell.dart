// Estructura del área de la cocinera: Oggi (el inicio), Richieste, Agenda y
// Altro (platos, impostazioni y salir), con barra de navegación abajo
// (teléfono) o riel a la izquierda (pantallas anchas, como la web /gestione/
// en una computadora). Los destinos van en el orden de las ramas del router.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Ancho desde el que se usa el riel lateral en lugar de la barra inferior.
const double wideLayoutBreakpoint = 840;

class ChefShell extends ConsumerWidget {
  const ChefShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _goToBranch(int index) => navigationShell.goBranch(
    index,
    // Tocar la pestaña activa vuelve a su pantalla inicial.
    initialLocation: index == navigationShell.currentIndex,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final newCount = ref.watch(newRequestsCountProvider);

    final requestsIcon = _CountBadge(
      count: newCount,
      child: const Icon(Icons.inbox_outlined),
    );
    final requestsSelectedIcon = _CountBadge(
      count: newCount,
      child: const Icon(Icons.inbox),
    );
    final requestsLabel = newCount > 0
        ? l10n.navRequestsWithNew(newCount)
        : l10n.navRequests;

    final wide = MediaQuery.sizeOf(context).width >= wideLayoutBreakpoint;
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              key: const ValueKey('chef-nav-rail'),
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: _goToBranch,
              labelType: NavigationRailLabelType.all,
              destinations: [
                NavigationRailDestination(
                  icon: const Icon(Icons.today_outlined),
                  selectedIcon: const Icon(Icons.today),
                  label: Text(l10n.navToday),
                ),
                NavigationRailDestination(
                  icon: requestsIcon,
                  selectedIcon: requestsSelectedIcon,
                  label: Text(l10n.navRequests, semanticsLabel: requestsLabel),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.calendar_month_outlined),
                  selectedIcon: const Icon(Icons.calendar_month),
                  label: Text(l10n.navAgenda),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.more_horiz),
                  label: Text(l10n.navMore),
                ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: navigationShell),
          ],
        ),
      );
    }

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        key: const ValueKey('chef-nav-bar'),
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: _goToBranch,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.today_outlined),
            selectedIcon: const Icon(Icons.today),
            label: l10n.navToday,
          ),
          NavigationDestination(
            icon: requestsIcon,
            selectedIcon: requestsSelectedIcon,
            label: l10n.navRequests,
            tooltip: requestsLabel,
          ),
          NavigationDestination(
            icon: const Icon(Icons.calendar_month_outlined),
            selectedIcon: const Icon(Icons.calendar_month),
            label: l10n.navAgenda,
          ),
          NavigationDestination(
            icon: const Icon(Icons.more_horiz),
            label: l10n.navMore,
          ),
        ],
      ),
    );
  }
}

/// Ícono con el contador de pedidos nuevos.
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.child});

  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Badge.count(
      key: const ValueKey('new-requests-badge'),
      count: count,
      isLabelVisible: count > 0,
      child: child,
    );
  }
}

/// Menú de la cuenta en la barra superior: email, Impostazioni y "Esci". Solo
/// en pantallas anchas: en el teléfono lo reemplaza la pestaña «Altro».
class ChefAccountMenuButton extends ConsumerWidget {
  const ChefAccountMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (MediaQuery.sizeOf(context).width < wideLayoutBreakpoint) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final session = ref.watch(sessionControllerProvider);
    final email = switch (session) {
      ChefSession(:final user) => user.email,
      _ => null,
    };
    final chefName = switch (session) {
      ChefSession(:final chef) => chef.displayName,
      _ => null,
    };

    return PopupMenuButton<void>(
      key: const ValueKey('account-menu'),
      tooltip: l10n.accountMenu,
      icon: const Icon(Icons.account_circle_outlined),
      // `context` es el del botón (sigue montado al cerrarse el menú).
      itemBuilder: (_) => [
        if (email != null || chefName != null)
          PopupMenuItem<void>(
            enabled: false,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(chefName ?? ''),
              subtitle: email == null ? null : Text(l10n.signedInAs(email)),
            ),
          ),
        // El menú se cierra antes de onTap: se puede abrir otra ruta.
        PopupMenuItem<void>(
          key: const ValueKey('account-settings'),
          onTap: () => context.push(AppRoutes.settings),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.settings_outlined),
            title: Text(l10n.settingsTitle),
          ),
        ),
        PopupMenuItem<void>(
          key: const ValueKey('account-logout'),
          onTap: () =>
              ref.read(sessionControllerProvider.notifier).signOut(),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.logout),
            title: Text(l10n.actionLogout),
          ),
        ),
      ],
    );
  }
}
