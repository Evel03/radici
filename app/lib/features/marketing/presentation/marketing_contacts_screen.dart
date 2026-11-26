// «Contatti per le offerte» (Altro, la cocina): quienes pidieron ofertas y
// novedades con la casilla del formulario y las confirmaron por email, para
// escribirles desde el programa de email de Evelyn (contrato public-request
// §13). Copiar los emails (para Ccn), descargar el CSV (en la web) y quitar a
// alguien de la lista cuando lo pide. Solo muestra el estado de los providers:
// no llama a Supabase.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/platform.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/marketing/application/marketing_contacts_providers.dart';
import 'package:radici/features/marketing/data/marketing_contacts_repository.dart';
import 'package:radici/features/marketing/domain/marketing_contact.dart';
import 'package:radici/l10n/app_localizations.dart';

class MarketingContactsScreen extends ConsumerWidget {
  const MarketingContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final contacts = ref.watch(marketingContactsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.marketingTitle)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: contacts.when(
            skipLoadingOnRefresh: true,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => _LoadFailed(
              onRetry: () => ref.invalidate(marketingContactsProvider),
            ),
            data: (list) => _ContactsList(contacts: list),
          ),
        ),
      ),
    );
  }
}

class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.marketingLoadFailed,
              key: const ValueKey('marketing-load-failed'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: Text(l10n.actionRetry)),
          ],
        ),
      ),
    );
  }
}

class _ContactsList extends ConsumerWidget {
  const _ContactsList({required this.contacts});

  final List<MarketingContact> contacts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final confirmed = contacts
        .where((c) => c.status == MarketingContactStatus.confirmed)
        .toList();
    final pending = contacts
        .where((c) => c.status == MarketingContactStatus.pending)
        .toList();
    final isWeb = ref.watch(isWebProvider);

    return ListView(
      key: const ValueKey('marketing-list'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(l10n.marketingIntro, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),
        Text(
          '${l10n.marketingConfirmedCount(confirmed.length)} · ${l10n.marketingPendingCount(pending.length)}',
          key: const ValueKey('marketing-counts'),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: const ValueKey('marketing-copy'),
              onPressed: confirmed.isEmpty
                  ? null
                  : () => _copy(context, confirmed),
              icon: const Icon(Icons.copy),
              label: Text(l10n.marketingCopy),
            ),
            if (isWeb)
              OutlinedButton.icon(
                key: const ValueKey('marketing-download'),
                onPressed: confirmed.isEmpty
                    ? null
                    : () => _download(context, ref, confirmed),
                icon: const Icon(Icons.download),
                label: Text(l10n.marketingDownload),
              ),
          ],
        ),
        if (contacts.isEmpty) ...[
          const SizedBox(height: 24),
          Text(
            l10n.marketingEmpty,
            key: const ValueKey('marketing-empty'),
            style: theme.textTheme.bodyLarge,
          ),
        ],
        if (confirmed.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionTitle(l10n.marketingConfirmedSection),
          for (final contact in confirmed) _ContactTile(contact: contact),
        ],
        if (pending.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionTitle(l10n.marketingPendingSection),
          Text(
            l10n.marketingPendingHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          for (final contact in pending) _ContactTile(contact: contact),
        ],
      ],
    );
  }

  Future<void> _copy(
    BuildContext context,
    List<MarketingContact> confirmed,
  ) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: confirmedEmails(confirmed)));
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.marketingCopied(confirmed.length))),
    );
  }

  void _download(
    BuildContext context,
    WidgetRef ref,
    List<MarketingContact> confirmed,
  ) {
    final l10n = AppLocalizations.of(context);
    final csv = marketingContactsCsv(
      confirmed,
      header: [
        l10n.marketingCsvEmail,
        l10n.marketingCsvName,
        l10n.marketingCsvLanguage,
        l10n.marketingCsvConfirmed,
      ],
    );
    final today = romeToday(ref.read(clockProvider)()).toIso();
    final ok = ref
        .read(browserProvider)
        .downloadText('radici-contatti-$today.csv', csv, 'text/csv;charset=utf-8');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? l10n.marketingDownloaded : l10n.marketingDownloadFailed,
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
    return Semantics(
      header: true,
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _ContactTile extends ConsumerWidget {
  const _ContactTile({required this.contact});

  final MarketingContact contact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final format = DateFormat.yMd(
      Localizations.localeOf(context).toLanguageTag(),
    );
    final confirmedAt = contact.confirmedAt;
    final when = confirmedAt != null
        ? l10n.marketingConfirmedOn(format.format(romeWallClock(confirmedAt)))
        : l10n.marketingPendingSince(
            format.format(romeWallClock(contact.requestedAt)),
          );
    final name = contact.firstName;
    return ListTile(
      key: ValueKey('marketing-contact-${contact.email}'),
      contentPadding: EdgeInsets.zero,
      title: Text(contact.email),
      subtitle: Text(
        [?name, contact.locale.toUpperCase(), when].join(' · '),
      ),
      trailing: IconButton(
        key: ValueKey('marketing-withdraw-${contact.email}'),
        tooltip: l10n.marketingWithdraw,
        icon: const Icon(Icons.person_remove_outlined),
        onPressed: () => _withdraw(context, ref),
      ),
    );
  }

  Future<void> _withdraw(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.marketingWithdrawTitle(contact.email)),
        content: Text(l10n.marketingWithdrawBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('marketing-withdraw-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.marketingWithdrawConfirm),
          ),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await ref.read(marketingContactsActionsProvider).withdraw(contact.email);
      messenger.showSnackBar(SnackBar(content: Text(l10n.marketingWithdrawn)));
    } on MarketingContactsFailure {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.marketingActionFailed)),
      );
    }
  }
}
