// Aviso emergente "Nuova richiesta da …" (MaterialBanner) en cualquier
// pantalla de la app, con botón para abrir el pedido. Si el cliente eligió
// platos en la web, lo dice.
//
// Va en el `builder` de MaterialApp, por encima de todas las rutas: así sigue
// escuchando aunque la cocinera esté en el detalle de otro pedido (las rutas
// tapadas quedan en pausa y sus providers no reciben avisos).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/application/new_request_alert.dart';
import 'package:radici/l10n/app_localizations.dart';

class NewRequestAlertListener extends ConsumerWidget {
  const NewRequestAlertListener({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Mantiene viva la lista de pedidos (y su canal de Realtime) mientras la
    // app esté abierta, aunque ninguna pantalla de la cocinera esté visible.
    ref.listen(chefInboxProvider, (_, _) {});

    ref.listen<NewRequestAlert?>(newRequestAlertProvider, (_, alert) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.clearMaterialBanners();
      if (alert != null) {
        messenger.showMaterialBanner(_buildBanner(context, ref, alert));
      }
    });

    return child;
  }

  MaterialBanner _buildBanner(
    BuildContext context,
    WidgetRef ref,
    NewRequestAlert alert,
  ) {
    final l10n = AppLocalizations.of(context);
    final single = alert.requests.length == 1;
    final name = alert.latest.client.displayName;
    final dishes = alert.latest.wishes.length;
    final count = alert.requests.length;
    final withMenu = alert.withMenu;
    final text = switch (single) {
      true when dishes > 0 => l10n.newRequestBannerWithMenu(dishes, name),
      true => l10n.newRequestBanner(name),
      false when withMenu > 0 => l10n.newRequestsBannerWithMenu(
        count,
        withMenu,
      ),
      false => l10n.newRequestsBanner(count),
    };

    void open() {
      final router = ref.read(routerProvider);
      ref.read(newRequestAlertProvider.notifier).dismiss();
      if (single) {
        // push: al volver, la cocinera sigue donde estaba.
        router.push(AppRoutes.requestDetail(alert.latest.id));
      } else {
        router.go(AppRoutes.requests);
      }
    }

    return MaterialBanner(
      key: const ValueKey('new-request-banner'),
      leading: const Icon(Icons.notifications_active_outlined),
      content: Semantics(
        liveRegion: true,
        child: Text(text, key: const ValueKey('new-request-banner-text')),
      ),
      actions: [
        TextButton(
          key: const ValueKey('new-request-banner-close'),
          onPressed: ref.read(newRequestAlertProvider.notifier).dismiss,
          child: Text(l10n.actionClose),
        ),
        FilledButton(
          key: const ValueKey('new-request-banner-open'),
          onPressed: open,
          child: Text(l10n.actionOpen),
        ),
      ],
    );
  }
}
