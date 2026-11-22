// «Mandar el menú» de una semana a la clienta (SPEC 5.8, «Envío del menú»):
// la vista previa del mensaje y el envío. Se abre encima del editor del menú
// o de la ficha de la sesión, sin ruta (como «Nuevo plato» en el editor: no
// deja una entrada en el historial del navegador).
//
// Al abrir pide la vista previa con la versión guardada del menú, traducida.
// Arriba, a quién va, en qué idioma y si la lista se tradujo sola; después,
// por dónde mandarlo (email y WhatsApp, cada uno deshabilitado con el porqué
// si el contacto no lo tiene) y lo que le llega, el WhatsApp o el email con
// su asunto, tal como lo arma la función: donde va el link, el texto de
// reemplazo que manda ella. Abajo, «Mandar» con los canales elegidos. Cada
// falla lo dice y ofrece lo que se puede hacer (reintentar, seguir sin
// traducir, otra vista previa, mandar solo por WhatsApp…); nada se reintenta
// solo. Después de mandar, cuándo y por dónde salió y, si fue por WhatsApp,
// el botón para abrirlo (en el teléfono se abre solo).
//
// La semana 1 de un presupuesto sin aceptar lo lleva (SPEC 5.8): arriba del
// mensaje, el presupuesto de la foto (la versión que sale, cada semana con su
// fecha, su llegada y su precio, el total y hasta cuándo lo puede aceptar si
// sale ahora). Si se cerró o cambió, lo dice y ofrece otra vista previa
// cuando sirve.
//
// Solo muestra providers: la lógica está en MenuSendController. Lleva el
// contacto de la clienta: nada se loguea.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/money.dart';
import 'package:radici/features/quotes/domain/preview_quote.dart';
import 'package:radici/features/quotes/presentation/quote_labels.dart';
import 'package:radici/features/requests/domain/chef_request.dart'
    show ClientLocale;
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/presentation/session_widgets.dart';
import 'package:radici/features/today/application/today_providers.dart'
    show todayNowProvider;
import 'package:radici/features/week_menu/application/menu_send_controller.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/presentation/week_menu_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Cómo se cerró «Mandar el menú».
enum MenuSendExit {
  /// Salió.
  sent,

  /// El menú se guardó en otro teléfono después de cargarlo: el editor lo
  /// vuelve a cargar.
  menuChanged,
}

/// Abre «Mandar el menú» de la sesión [sessionId] con la versión guardada
/// [menuVersion], a pantalla completa y sin ruta. [fromEditor]: se abre desde
/// el editor (si el menú cambió en otro teléfono, vuelve a él para cargarlo;
/// desde la ficha, ofrece la vista previa de lo guardado).
Future<MenuSendExit?> showMenuSendScreen(
  BuildContext context, {
  required String sessionId,
  required int menuVersion,
  bool fromEditor = false,
}) => Navigator.of(context).push<MenuSendExit>(
  MaterialPageRoute<MenuSendExit>(
    fullscreenDialog: true,
    builder: (_) => MenuSendScreen(
      sessionId: sessionId,
      menuVersion: menuVersion,
      fromEditor: fromEditor,
    ),
  ),
);

class MenuSendScreen extends ConsumerStatefulWidget {
  const MenuSendScreen({
    super.key,
    required this.sessionId,
    required this.menuVersion,
    this.fromEditor = false,
  });

  final String sessionId;
  final int menuVersion;
  final bool fromEditor;

  @override
  ConsumerState<MenuSendScreen> createState() => _MenuSendScreenState();
}

class _MenuSendScreenState extends ConsumerState<MenuSendScreen> {
  /// Avisos propios: quedan en esta pantalla.
  final GlobalKey<ScaffoldMessengerState> _messenger =
      GlobalKey<ScaffoldMessengerState>();

  /// Qué mensaje se ve; null: el del canal elegido (WhatsApp primero).
  MenuSendChannel? _view;

  MenuSendController get _controller =>
      ref.read(menuSendProvider(widget.sessionId).notifier);

  @override
  void initState() {
    super.initState();
    // Después de armar la pantalla: un provider no cambia mientras se arma.
    Future.microtask(() {
      if (mounted) unawaited(_controller.start(widget.menuVersion));
    });
  }

  /// El idioma de la clienta, de la ficha (null si no se puede leer).
  ClientLocale? get _clientLocale =>
      ref.read(sessionDetailProvider(widget.sessionId)).value?.session.locale;

  void _close([MenuSendExit? exit]) => Navigator.of(context).pop(exit);

  Future<void> _openWhatsApp() async {
    final messenger = _messenger.currentState;
    final message = AppLocalizations.of(context).launchFailed;
    // Directo desde el toque: en la web, esperar algo antes haría que el
    // navegador bloquee la ventana nueva.
    final opened = await _controller.openWhatsApp();
    if (!opened && messenger != null && messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(menuSendProvider(widget.sessionId));
    final sending = state.step == MenuSendStep.sending;
    final Widget body = switch (state.step) {
      MenuSendStep.idle ||
      MenuSendStep.previewing => _Previewing(locale: _clientLocale),
      MenuSendStep.previewFailed => _PreviewFailed(
        state: state,
        clientLocale: _clientLocale,
        fromEditor: widget.fromEditor,
        onRetry: () => unawaited(_controller.retryPreview()),
        onWithoutTranslation: () =>
            unawaited(_controller.previewWithoutTranslation()),
        onPreviewSaved: () => unawaited(_controller.previewSaved()),
        onBackToMenu: () => _close(MenuSendExit.menuChanged),
        onClose: _close,
      ),
      MenuSendStep.ready ||
      MenuSendStep.sending ||
      MenuSendStep.sendFailed => _PreviewView(
        state: state,
        now: ref.watch(todayNowProvider),
        view: _view,
        onView: (view) => setState(() => _view = view),
        onEmail: _controller.setEmail,
        onWhatsapp: _controller.setWhatsapp,
        onRetrySend: () => unawaited(_controller.send()),
        onSendOnly: (channel) => unawaited(_controller.sendOnly(channel)),
        onNewPreview: () => unawaited(_controller.newPreview()),
      ),
      MenuSendStep.sent => _SentView(
        state: state,
        onNewPreview: () => unawaited(_controller.newPreview()),
      ),
    };
    return PopScope<Object?>(
      // Mientras manda no se cierra: tiene que saber cómo salió.
      canPop: !sending,
      child: ScaffoldMessenger(
        key: _messenger,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              key: const ValueKey('menu-send-close'),
              icon: const Icon(Icons.close),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: sending
                  ? null
                  : () => _close(
                      state.step == MenuSendStep.sent
                          ? MenuSendExit.sent
                          : null,
                    ),
            ),
            title: Text(l10n.menuSendTitle),
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: sessionMaxContentWidth,
              ),
              child: body,
            ),
          ),
          bottomNavigationBar: switch (state.step) {
            MenuSendStep.ready ||
            MenuSendStep.sending ||
            MenuSendStep.sendFailed => _BottomBar(
              children: [
                _SendButton(
                  state: state,
                  onSend: () => unawaited(_controller.send()),
                ),
              ],
            ),
            MenuSendStep.sent => _BottomBar(
              children: [
                if (state.whatsAppLink != null) ...[
                  FilledButton.icon(
                    key: const ValueKey('menu-send-open-whatsapp'),
                    onPressed: () => unawaited(_openWhatsApp()),
                    icon: const Icon(Icons.chat_outlined),
                    label: Text(l10n.menuSendOpenWhatsApp),
                  ),
                  const SizedBox(height: 8),
                ],
                OutlinedButton(
                  key: const ValueKey('menu-send-done'),
                  onPressed: () => _close(MenuSendExit.sent),
                  child: Text(l10n.actionClose),
                ),
              ],
            ),
            _ => null,
          },
        ),
      ),
    );
  }
}

/// Mientras se arma la vista previa (con la traducción de la lista puede
/// tardar hasta un minuto).
class _Previewing extends StatelessWidget {
  const _Previewing({required this.locale});

  final ClientLocale? locale;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = this.locale;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              locale == null
                  ? l10n.menuSendTitle
                  : l10n.menuSendPreviewing(l10n.language(locale)),
              key: const ValueKey('menu-send-previewing'),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// No se pudo armar la vista previa: por qué y qué se puede hacer.
class _PreviewFailed extends StatelessWidget {
  const _PreviewFailed({
    required this.state,
    required this.clientLocale,
    required this.fromEditor,
    required this.onRetry,
    required this.onWithoutTranslation,
    required this.onPreviewSaved,
    required this.onBackToMenu,
    required this.onClose,
  });

  final MenuSendState state;
  final ClientLocale? clientLocale;
  final bool fromEditor;
  final VoidCallback onRetry;
  final VoidCallback onWithoutTranslation;
  final VoidCallback onPreviewSaved;
  final VoidCallback onBackToMenu;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final failure = state.failure;
    if (failure == null) return const SizedBox.shrink();
    final kind = failure.kind;
    // Seguir sin traducir, si la traducción pudo ser lo que falló: lo pide
    // la clienta que no lee español, mientras se traducía.
    final translating = state.translate && clientLocale != ClientLocale.es;
    final translationFailed =
        kind == MenuSendFailureKind.untranslatable ||
        kind == MenuSendFailureKind.notConfigured ||
        kind == MenuSendFailureKind.rateLimited;
    final withoutTranslation = Text(l10n.menuSendWithoutTranslation);
    const withoutTranslationKey = ValueKey('menu-send-without-translation');
    final actions = <Widget>[
      if (kind.canRetry)
        FilledButton(
          key: const ValueKey('menu-send-retry-preview'),
          onPressed: onRetry,
          child: Text(l10n.actionRetry),
        ),
      // La acción principal si la traducción no salió; al lado de
      // «Reintentar», la otra opción.
      if (translationFailed)
        FilledButton(
          key: withoutTranslationKey,
          onPressed: onWithoutTranslation,
          child: withoutTranslation,
        )
      else if (kind.canRetry && translating)
        OutlinedButton(
          key: withoutTranslationKey,
          onPressed: onWithoutTranslation,
          child: withoutTranslation,
        ),
      if (kind == MenuSendFailureKind.menuChanged)
        fromEditor
            ? FilledButton(
                key: const ValueKey('menu-send-back-to-menu'),
                onPressed: onBackToMenu,
                child: Text(l10n.menuSendBackToMenu),
              )
            : FilledButton(
                key: const ValueKey('menu-send-preview-saved'),
                onPressed: onPreviewSaved,
                child: Text(l10n.menuSendPreviewSaved),
              ),
      // El presupuesto cambió mientras se armaba: otra vista previa, con los
      // términos de ahora.
      if (kind == MenuSendFailureKind.quoteChanged)
        FilledButton(
          key: const ValueKey('menu-send-preview-again'),
          onPressed: onRetry,
          child: Text(l10n.menuSendNewPreview),
        ),
      OutlinedButton(
        key: const ValueKey('menu-send-failed-close'),
        onPressed: onClose,
        child: Text(l10n.actionClose),
      ),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
          const SizedBox(height: 12),
          // liveRegion: el lector de pantalla lo anuncia (la ruedita ya no
          // está).
          Semantics(
            liveRegion: true,
            child: Text(
              l10n.menuSendFailureText(failure, sending: false),
              key: const ValueKey('menu-send-preview-error'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
          ),
          const SizedBox(height: 16),
          for (final (index, action) in actions.indexed) ...[
            if (index > 0) const SizedBox(height: 8),
            action,
          ],
        ],
      ),
    );
  }
}

/// La vista previa: a quién va, en qué idioma, por dónde mandarlo y lo que le
/// llega. Con una falla del envío, arriba dice por qué y qué se puede hacer.
class _PreviewView extends StatelessWidget {
  const _PreviewView({
    required this.state,
    required this.now,
    required this.view,
    required this.onView,
    required this.onEmail,
    required this.onWhatsapp,
    required this.onRetrySend,
    required this.onSendOnly,
    required this.onNewPreview,
  });

  final MenuSendState state;

  /// Ahora: el plazo del presupuesto, si sale en este momento.
  final DateTime now;
  final MenuSendChannel? view;
  final ValueChanged<MenuSendChannel> onView;
  final ValueChanged<bool> onEmail;
  final ValueChanged<bool> onWhatsapp;
  final VoidCallback onRetrySend;
  final ValueChanged<MenuSendChannel> onSendOnly;
  final VoidCallback onNewPreview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final preview = state.preview;
    if (preview == null) return const SizedBox.shrink();
    final contact = preview.contact;
    final shown =
        view ??
        (state.whatsapp || !state.email
            ? MenuSendChannel.whatsapp
            : MenuSendChannel.email);
    final sending = state.step == MenuSendStep.sending;
    final translationLine = preview.translated
        ? l10n.menuSendTranslated
        : !state.translate && preview.locale != ClientLocale.es
        ? l10n.menuSendNotTranslated
        : null;

    return SingleChildScrollView(
      key: const ValueKey('menu-send-preview'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      // Mientras manda, nada se puede tocar.
      child: AbsorbPointer(
        absorbing: sending,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.step == MenuSendStep.sendFailed && state.failure != null)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: _SendFailure(
                  state: state,
                  onRetry: onRetrySend,
                  onSendOnly: onSendOnly,
                  onNewPreview: onNewPreview,
                ),
              ),
            MergeSemantics(
              child: Text(
                l10n.menuSendTo(contact.name),
                key: const ValueKey('menu-send-to'),
                style: theme.textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 4),
            MergeSemantics(
              child: Text(
                l10n.menuSendLanguage(l10n.language(preview.locale)),
                key: const ValueKey('menu-send-language'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (translationLine != null)
              MergeSemantics(
                child: Text(
                  translationLine,
                  key: const ValueKey('menu-send-translation'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            SessionSection(l10n.menuSendChannelsSection),
            CheckboxListTile(
              key: const ValueKey('menu-send-email'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: state.email,
              onChanged: state.emailAvailable
                  ? (value) => onEmail(value ?? false)
                  : null,
              title: Text(l10n.menuSendByEmail),
              subtitle: Text(switch (contact.emailIssue) {
                null => contact.usableEmail ?? '',
                ContactIssue.missing => l10n.menuSendNoEmail,
                ContactIssue.invalid => l10n.menuSendBadEmail(
                  contact.email ?? '',
                ),
              }, key: const ValueKey('menu-send-email-detail')),
            ),
            CheckboxListTile(
              key: const ValueKey('menu-send-whatsapp'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: state.whatsapp,
              onChanged: state.whatsappAvailable
                  ? (value) => onWhatsapp(value ?? false)
                  : null,
              title: Text(l10n.menuSendByWhatsApp),
              subtitle: Text(switch (contact.phoneIssue) {
                null => l10n.menuSendWhatsAppHint(contact.phone ?? ''),
                ContactIssue.missing => l10n.menuSendNoPhone,
                ContactIssue.invalid => l10n.menuSendBadPhone(
                  contact.phone ?? '',
                ),
              }, key: const ValueKey('menu-send-whatsapp-detail')),
            ),
            if (!state.emailAvailable && !state.whatsappAvailable)
              MergeSemantics(
                child: Text(
                  l10n.menuSendNoChannel,
                  key: const ValueKey('menu-send-no-channel'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            // La semana 1 de un presupuesto sin aceptar lo lleva: arriba del
            // mensaje, lo que va a ver la clienta.
            if (state.quote case final quote?) ...[
              SessionSection(l10n.menuSendQuoteSection(quote.version)),
              _PreviewQuoteView(quote: quote, now: now),
            ],
            SessionSection(l10n.menuSendMessageSection),
            SegmentedButton<MenuSendChannel>(
              key: const ValueKey('menu-send-view'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: MenuSendChannel.whatsapp,
                  label: Text(l10n.actionWhatsApp),
                  icon: const Icon(Icons.chat_outlined),
                ),
                ButtonSegment(
                  value: MenuSendChannel.email,
                  label: Text(l10n.actionEmail),
                  icon: const Icon(Icons.mail_outline),
                ),
              ],
              selected: {shown},
              onSelectionChanged: (selection) => onView(selection.single),
            ),
            const SizedBox(height: 12),
            if (shown == MenuSendChannel.email)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SelectableText(
                  l10n.menuSendSubject(preview.subject),
                  key: const ValueKey('menu-send-subject'),
                  style: theme.textTheme.titleSmall,
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  shown == MenuSendChannel.email
                      ? preview.emailText
                      : preview.whatsappText,
                  key: const ValueKey('menu-send-message'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 8),
            MergeSemantics(
              child: Text(
                l10n.menuSendLinkNote,
                key: const ValueKey('menu-send-link-note'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// El presupuesto que va con el menú: cada semana con su fecha, su llegada y
/// su precio, el total, hasta cuándo puede aceptarlo la clienta si sale ahora
/// y qué puede hacer desde el enlace. Sale de la foto de la vista previa.
class _PreviewQuoteView extends StatelessWidget {
  const _PreviewQuoteView({required this.quote, required this.now});

  final PreviewQuote quote;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final locale = Localizations.localeOf(context).toString();
    final weeks = quote.weeks;
    return Column(
      key: const ValueKey('menu-send-quote'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, week) in weeks.indexed)
          MergeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${l10n.quoteWeekTitle(index + 1, weeks.length, week.date, formats)}'
                ' · '
                '${l10n.quoteWeekDetail(week.start.toHhMm(), formatCents(week.serviceCents, locale: locale))}',
                key: ValueKey('menu-send-quote-week-$index'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
        SessionInfoRow(
          label: l10n.quoteServiceTotal(weeks.length),
          value: formatCents(quote.totalCents, locale: locale),
          valueKey: const ValueKey('menu-send-quote-total'),
        ),
        MergeSemantics(
          child: Text(
            l10n.quoteDeadlineText(quote.deadlineAt(now), formats),
            key: const ValueKey('menu-send-quote-deadline'),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 4),
        MergeSemantics(
          child: Text(
            l10n.menuSendQuoteHint,
            key: const ValueKey('menu-send-quote-hint'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// El envío falló o no se sabe si salió: por qué y qué se puede hacer con
/// esta vista previa (o con otra).
class _SendFailure extends StatelessWidget {
  const _SendFailure({
    required this.state,
    required this.onRetry,
    required this.onSendOnly,
    required this.onNewPreview,
  });

  final MenuSendState state;
  final VoidCallback onRetry;
  final ValueChanged<MenuSendChannel> onSendOnly;
  final VoidCallback onNewPreview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final failure = state.failure!;
    final kind = failure.kind;
    final retry =
        state.canResend &&
        (failure.emailSent ||
            kind.canRetry ||
            kind == MenuSendFailureKind.emailFailed);
    final onlyWhatsApp =
        !failure.emailSent &&
        state.whatsappAvailable &&
        (kind == MenuSendFailureKind.emailFailed ||
            kind == MenuSendFailureKind.emailUnavailable ||
            kind == MenuSendFailureKind.noEmail);
    final onlyEmail =
        !failure.emailSent &&
        state.emailAvailable &&
        kind == MenuSendFailureKind.noPhone;
    final newPreview =
        kind == MenuSendFailureKind.menuChanged ||
        kind == MenuSendFailureKind.quoteChanged ||
        (!failure.emailSent &&
            (kind == MenuSendFailureKind.noEmail ||
                kind == MenuSendFailureKind.noPhone));
    return DecoratedBox(
      key: const ValueKey('menu-send-failure'),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                l10n.menuSendFailureText(failure, sending: true),
                key: const ValueKey('menu-send-error'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onErrorContainer,
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                if (retry)
                  TextButton(
                    key: const ValueKey('menu-send-retry'),
                    onPressed: onRetry,
                    child: Text(l10n.actionRetry),
                  ),
                if (onlyWhatsApp)
                  TextButton(
                    key: const ValueKey('menu-send-only-whatsapp'),
                    onPressed: () => onSendOnly(MenuSendChannel.whatsapp),
                    child: Text(l10n.menuSendOnlyWhatsApp),
                  ),
                if (onlyEmail)
                  TextButton(
                    key: const ValueKey('menu-send-only-email'),
                    onPressed: () => onSendOnly(MenuSendChannel.email),
                    child: Text(l10n.menuSendOnlyEmail),
                  ),
                if (newPreview)
                  TextButton(
                    key: const ValueKey('menu-send-new-preview'),
                    onPressed: onNewPreview,
                    child: Text(l10n.menuSendNewPreview),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Salió: a quién, cuándo y por dónde; si fue por WhatsApp, qué falta.
class _SentView extends StatelessWidget {
  const _SentView({required this.state, required this.onNewPreview});

  final MenuSendState state;
  final VoidCallback onNewPreview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = RequestFormats(context);
    final result = state.result;
    if (result == null) return const SizedBox.shrink();
    final name = state.preview?.contact.name ?? '';
    final whatsApp = state.whatsAppLink;
    return SingleChildScrollView(
      key: const ValueKey('menu-send-sent'),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            Icons.mark_email_read_outlined,
            size: 48,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 12),
          // liveRegion: el lector de pantalla anuncia que salió (el botón que
          // tenía el foco ya no está).
          Semantics(
            liveRegion: true,
            child: Text(
              l10n.menuSendDone(
                name,
                formats.instantDayMonth(result.sentAt),
                formats.instantTime(result.sentAt),
                l10n.menuSendViaText(result.via),
              ),
              key: const ValueKey('menu-send-done-text'),
              style: theme.textTheme.bodyLarge,
            ),
          ),
          if (state.quote case final quote?) ...[
            const SizedBox(height: 8),
            Text(
              l10n.menuSendDoneQuote(quote.version),
              key: const ValueKey('menu-send-done-quote'),
              style: theme.textTheme.bodyLarge,
            ),
          ],
          if (state.recovered) ...[
            const SizedBox(height: 8),
            Text(
              l10n.menuSendDoneRecovered,
              key: const ValueKey('menu-send-recovered'),
            ),
          ],
          if (whatsApp != null) ...[
            const SizedBox(height: 16),
            Text(
              state.whatsAppOpened ?? false
                  ? l10n.menuSendDoneWhatsApp
                  : l10n.menuSendDoneOpenWhatsApp,
              key: const ValueKey('menu-send-whatsapp-next'),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (state.whatsAppLost) ...[
            const SizedBox(height: 16),
            Text(
              l10n.menuSendWhatsAppLost,
              key: const ValueKey('menu-send-whatsapp-lost'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const ValueKey('menu-send-whatsapp-new-preview'),
                onPressed: onNewPreview,
                child: Text(l10n.menuSendNewPreview),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// «Mandar por …» con los canales elegidos; mientras manda, la ruedita.
class _SendButton extends StatelessWidget {
  const _SendButton({required this.state, required this.onSend});

  final MenuSendState state;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sending = state.step == MenuSendStep.sending;
    final channels = state.channels;
    return FilledButton(
      key: const ValueKey('menu-send-submit'),
      onPressed: state.canSend ? onSend : null,
      child: sending
          // La ruedita sola no dice nada al lector de pantalla.
          ? Semantics(
              label: l10n.menuSending,
              child: const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Text(
              channels.isEmpty
                  ? l10n.menuSendChooseChannel
                  : l10n.menuSendButton(l10n.menuSendViaText(channels)),
            ),
    );
  }
}

/// La barra de abajo, a lo ancho: a mano con el pulgar.
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: sessionMaxContentWidth,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
