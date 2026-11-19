// Bandeja "Richieste": nuevas, vistas y rechazadas (contrato §7).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/domain/inbox.dart';
import 'package:radici/features/requests/presentation/chef_shell.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final inbox = ref.watch(chefInboxProvider);
    final newCount = ref.watch(newRequestsCountProvider);

    return DefaultTabController(
      length: InboxTab.values.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.navRequests),
          actions: const [ChefAccountMenuButton()],
          bottom: TabBar(
            tabs: [
              Tab(
                key: const ValueKey('inbox-tab-new'),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        l10n.inboxTabNew,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (newCount > 0) ...[
                      const SizedBox(width: 6),
                      Badge.count(
                        key: const ValueKey('inbox-new-count'),
                        count: newCount,
                      ),
                    ],
                  ],
                ),
              ),
              Tab(
                key: const ValueKey('inbox-tab-seen'),
                text: l10n.inboxTabSeen,
              ),
              Tab(
                key: const ValueKey('inbox-tab-rejected'),
                text: l10n.inboxTabRejected,
              ),
            ],
          ),
        ),
        body: inbox.when(
          data: (requests) => TabBarView(
            children: [
              for (final tab in InboxTab.values)
                _RequestList(tab: tab, requests: requestsInTab(requests, tab)),
            ],
          ),
          error: (_, _) => LoadErrorView(
            message: l10n.inboxLoadError,
            onRetry: () => ref.invalidate(chefInboxProvider),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }
}

class _RequestList extends ConsumerWidget {
  const _RequestList({required this.tab, required this.requests});

  final InboxTab tab;
  final List<ChefRequest> requests;

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = AppLocalizations.of(context).inboxRefreshError;
    try {
      await ref.read(chefInboxProvider.notifier).refresh();
    } on RequestsFailure {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final empty = switch (tab) {
      InboxTab.fresh => l10n.inboxEmptyNew,
      InboxTab.seen => l10n.inboxEmptySeen,
      InboxTab.rejected => l10n.inboxEmptyRejected,
    };

    return RefreshIndicator(
      onRefresh: () => _refresh(context, ref),
      child: requests.isEmpty
          ? ListView(
              // Deslizar para actualizar también con la lista vacía.
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    empty,
                    key: ValueKey('inbox-empty-${tab.name}'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              ],
            )
          : ListView.separated(
              key: ValueKey('inbox-list-${tab.name}'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: requests.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  RequestTile(request: requests[index]),
            ),
    );
  }
}

/// Fila de un pedido: nombre, resumen y fecha preferida, con las marcas de
/// platos elegidos en la web («menù», debajo del resumen) y de restricciones
/// (al lado de la fecha). Se usa en la bandeja y en la agenda.
class RequestTile extends StatelessWidget {
  const RequestTile({
    super.key,
    required this.request,
    this.showSlotOnly = false,
  });

  final ChefRequest request;

  /// En la agenda el día ya se ve: alcanza con la franja.
  final bool showSlotOnly;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final isNew = request.isNew;

    final date = request.preferredDate;
    final slot = request.preferredSlot;
    final String when;
    if (showSlotOnly) {
      when = slot == null ? '' : l10n.slot(slot);
    } else {
      when = [
        date == null ? l10n.requestNoDate : formats.shortDate(date),
        if (slot != null) l10n.slot(slot),
      ].join(' · ');
    }

    return ListTile(
      key: ValueKey('request-${request.id}'),
      onTap: () => context.push(AppRoutes.requestDetail(request.id)),
      leading: Badge(
        isLabelVisible: isNew,
        smallSize: 10,
        child: CircleAvatar(
          backgroundColor: isNew
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          foregroundColor: isNew
              ? theme.colorScheme.onPrimaryContainer
              : theme.colorScheme.onSurfaceVariant,
          child: Text(_initials(request.client.displayName)),
        ),
      ),
      title: Text(
        request.client.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isNew ? const TextStyle(fontWeight: FontWeight.w700) : null,
      ),
      subtitle: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [l10n.requestSummary(request), if (when.isNotEmpty) when].join('\n'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          // La marca va acá y no al lado de la fecha: ListTile le da al
          // trailing hasta 56 px de alto y, con el texto grande, no entraba.
          if (request.hasMenu)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _MenuMark(requestId: request.id),
            ),
        ],
      ),
      isThreeLine: when.isNotEmpty || request.hasMenu,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            formats.instantDate(request.createdAt),
            style: theme.textTheme.labelSmall,
          ),
          if (request.hasRestrictions) ...[
            const SizedBox(height: 4),
            Icon(
              Icons.health_and_safety_outlined,
              size: 18,
              color: theme.colorScheme.tertiary,
              semanticLabel: l10n.detailSectionRestrictions,
            ),
          ],
        ],
      ),
    );
  }
}

/// Marca «menù»: el cliente eligió platos en la pestaña «Menù» de la web. Es
/// el aviso que pidió Evelyn: se ve en la lista sin abrir el pedido. El
/// lector de pantalla lee la frase entera.
class _MenuMark extends StatelessWidget {
  const _MenuMark({required this.requestId});

  final String requestId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onPrimaryContainer;
    return Semantics(
      key: ValueKey('request-menu-$requestId'),
      label: l10n.requestMenuTagA11y,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.restaurant_menu, size: 14, color: ink),
              const SizedBox(width: 3),
              // Con el texto muy grande en un teléfono angosto, se corta
              // antes que desbordar (el ícono y el lector de pantalla quedan).
              Flexible(
                child: Text(
                  l10n.requestMenuTag,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  final letters = parts.take(2).map((p) => p.characters.first.toUpperCase());
  return letters.join();
}

/// Error de carga con botón para reintentar.
class LoadErrorView extends StatelessWidget {
  const LoadErrorView({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                key: const ValueKey('load-error'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('load-error-retry'),
                onPressed: onRetry,
                child: Text(l10n.actionRetry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
