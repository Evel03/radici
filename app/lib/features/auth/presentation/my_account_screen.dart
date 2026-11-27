// «Mi cuenta» del área de la clienta (/area/account, auth.md §20): el email (no se cambia), los datos de la cuenta para
// corregirlos (los mismos campos que «Crear cuenta»), borrar las respuestas opcionales y borrar la cuenta. Solo
// muestra el estado de accountDetailsProvider y MyAccountController y les pasa lo que escribe la clienta: no llama a
// Supabase.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/web_links.dart';
import 'package:radici/features/auth/application/my_account_controller.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/domain/sign_up_form.dart';
import 'package:radici/features/auth/presentation/account_details_fields.dart';
import 'package:radici/features/auth/presentation/busy_button.dart';
import 'package:radici/l10n/app_localizations.dart';

class MyAccountScreen extends ConsumerStatefulWidget {
  const MyAccountScreen({super.key});

  @override
  ConsumerState<MyAccountScreen> createState() => _MyAccountScreenState();
}

class _MyAccountScreenState extends ConsumerState<MyAccountScreen> {
  final _draft = AccountDetailsDraft();
  bool _privacy = false;

  @override
  void initState() {
    super.initState();
    // Cada vez que llegan los datos guardados (al abrir y después de guardar) se escriben en los campos: así se ve lo
    // que quedó (el teléfono con el prefijo, por ejemplo).
    ref.listenManual(accountDetailsProvider, (_, next) {
      if (next case AsyncData(:final value?)) _draft.fill(value);
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  String get _locale => Localizations.localeOf(context).languageCode;

  MyAccountController get _controller => ref.read(myAccountControllerProvider.notifier);

  void _save(Map<String, Object?>? current) {
    FocusScope.of(context).unfocus();
    _controller.save(_draft.toForm(), current: current, privacyAccepted: _privacy);
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
    required String confirmKey,
  }) async {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.actionCancel)),
          TextButton(
            key: ValueKey(confirmKey),
            style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _clearOptional(Map<String, Object?>? current) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await _confirm(
      title: l10n.myAccountClearTitle,
      body: l10n.myAccountClearBody,
      action: l10n.myAccountClearConfirm,
      confirmKey: 'my-account-clear-confirm',
    );
    if (!confirmed || !mounted) return;
    _draft.clearOptional();
    _save(current);
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await _confirm(
      title: l10n.myAccountDeleteTitle,
      body: l10n.myAccountDeleteBody,
      action: l10n.myAccountDeleteConfirm,
      confirmKey: 'my-account-delete-confirm',
    );
    if (!confirmed || !mounted) return;
    await _controller.deleteAccount();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final details = ref.watch(accountDetailsProvider);
    ref.listen(myAccountControllerProvider, (previous, next) {
      final messenger = ScaffoldMessenger.of(context);
      if (next.saved && !(previous?.saved ?? false)) {
        messenger.showSnackBar(SnackBar(key: const ValueKey('my-account-saved'), content: Text(l10n.myAccountSaved)));
      }
      if (next.deleted && !(previous?.deleted ?? false)) {
        messenger.showSnackBar(
          SnackBar(key: const ValueKey('my-account-deleted'), content: Text(l10n.myAccountDeleted)),
        );
      }
    });

    // Mientras vuelve a leer los datos (después de guardar) el formulario sigue a la vista.
    final body = details.hasValue
        ? _form(context, details.value)
        : details.hasError && !details.isLoading
        ? _loadError(context)
        : const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: CircularProgressIndicator()),
          );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.myAccountTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: body),
          ),
        ),
      ),
    );
  }

  Widget _loadError(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      key: const ValueKey('my-account-load-error'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.myAccountLoadFailed, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('my-account-retry'),
          onPressed: () => ref.invalidate(accountDetailsProvider),
          child: Text(l10n.actionRetry),
        ),
      ],
    );
  }

  Widget _form(BuildContext context, Map<String, Object?>? current) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(myAccountControllerProvider);
    final problems = state.problems;
    final enabled = !state.busy && !state.deleted;
    final email = switch (ref.watch(sessionControllerProvider)) {
      ClientSession(:final user) => user.email,
      _ => null,
    };
    final askPrivacy = needsPrivacy(current);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (current == null)
            Text(l10n.myAccountEmpty, key: const ValueKey('my-account-empty'), style: theme.textTheme.bodyLarge),
          if (email != null) ...[
            AccountSection(l10n.signUpSectionAccount),
            Text(email, key: const ValueKey('my-account-email'), style: theme.textTheme.bodyLarge),
            const SizedBox(height: 4),
            Text(l10n.myAccountEmailFixed, style: muted),
          ],
          AccountPersonalFields(draft: _draft, problems: problems, enabled: enabled),
          AccountExtraFields(draft: _draft, problems: problems, enabled: enabled),
          if (askPrivacy) ...[
            const SizedBox(height: 16),
            CheckboxListTile(
              key: const ValueKey('my-account-privacy'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _privacy,
              onChanged: enabled ? (value) => setState(() => _privacy = value ?? false) : null,
              title: Text(l10n.myAccountPrivacy),
              subtitle: problems.containsKey(SignUpField.privacy)
                  ? Text(l10n.myAccountErrorPrivacy, style: TextStyle(color: theme.colorScheme.error))
                  : null,
            ),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('my-account-privacy-link'),
              onPressed: () => ref.read(linkLauncherProvider).openPage(privacyPolicyUri(_locale)),
              child: Text(l10n.signUpPrivacyLink),
            ),
          ),
          const SizedBox(height: 16),
          BusyButton(
            key: const ValueKey('my-account-save'),
            busy: state.busy,
            onPressed: () => _save(current),
            label: l10n.actionSave,
          ),
          AccountErrorLine(
            problems.isNotEmpty ? l10n.signUpErrorFix : (state.failed ? l10n.authErrorNetwork : null),
            lineKey: 'my-account-error',
          ),
          AccountSection(l10n.myAccountDangerSection),
          if (current != null) ...[
            OutlinedButton.icon(
              key: const ValueKey('my-account-clear-optional'),
              onPressed: enabled ? () => _clearOptional(current) : null,
              icon: const Icon(Icons.playlist_remove),
              label: Text(l10n.myAccountClearOptional),
            ),
            const SizedBox(height: 8),
          ],
          OutlinedButton.icon(
            key: const ValueKey('my-account-delete'),
            style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
            onPressed: enabled ? _delete : null,
            icon: const Icon(Icons.delete_forever_outlined),
            label: Text(l10n.myAccountDelete),
          ),
          const SizedBox(height: 8),
          Text(l10n.myAccountDeleteHint, style: muted),
        ],
      ),
    );
  }
}
