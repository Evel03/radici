// Hoy (/oggi), el inicio de la cocinera: la sesión de hoy (varias, con la
// próxima primero) o, si hoy no hay, la próxima; los pendientes de uno o dos
// toques (pedidos nuevos, que llevan a «Nuove», y reservas que terminan, que
// abren la ficha de su última semana) y la tira de 7 días (cada día abre la
// Agenda en ese día). Abajo, en el tercio inferior del teléfono, «Come
// arrivare» y WhatsApp de la sesión principal (sin dirección, WhatsApp y
// «Aggiungi indirizzo», como la ficha); sin ninguna sesión, «Vedi le
// richieste». «Hoy» es el día de Roma y cambia a la medianoche sin reabrir la
// app. Deslizar para actualizar (o «Ricarica», arriba) vuelve a leer todo.
// Mientras las sesiones cargan, o si no se pudieron leer, la rueda o el aviso
// van en el lugar de la tarjeta: los pendientes y la tira siguen.
//
// Solo lee providers: la lógica está en today_providers.dart y en el dominio.
// Las sesiones llevan la dirección y datos de salud: nada se loguea.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/application/inbox_tab_request.dart';
import 'package:radici/features/requests/domain/inbox.dart';
import 'package:radici/features/requests/presentation/chef_refresh_button.dart';
import 'package:radici/features/requests/presentation/chef_shell.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/client_address_dialog.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/features/sessions/presentation/session_widgets.dart';
import 'package:radici/features/sessions/presentation/sessions_load_error.dart';
import 'package:radici/features/today/application/today_providers.dart';
import 'package:radici/features/today/domain/today.dart';
import 'package:radici/features/today/presentation/today_labels.dart';
import 'package:radici/features/today/presentation/today_session_card.dart';
import 'package:radici/features/today/presentation/today_strip.dart';
import 'package:radici/l10n/app_localizations.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final focus = ref.watch(todayFocusProvider);
    final value = focus.value;

    // Sus propios avisos: salen encima de los botones de abajo, sin taparlos
    // (con el ScaffoldMessenger de la app saldrían en el Scaffold de la barra
    // de navegación, sobre ellos).
    return ScaffoldMessenger(
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.navToday),
          // «Ricarica»: lo mismo que deslizar para actualizar, sin el gesto.
          actions: const [ChefRefreshButton(), ChefAccountMenuButton()],
        ),
        body: _TodayList(focus: focus),
        // «Come arrivare» y WhatsApp (o, sin ninguna sesión, «Vedi le
        // richieste»), abajo: la acción principal en el tercio inferior del
        // teléfono.
        bottomNavigationBar: switch (value) {
          null => null,
          TodayFocus(main: final main?) => _TodayActions(
            session: main,
            // Con varias sesiones, de quién son.
            showWhose: value.sessions.length > 1,
          ),
          TodayFocus() => const _NoSessionsActions(),
        },
      ),
    );
  }
}

class _TodayList extends ConsumerWidget {
  const _TodayList({required this.focus});

  /// Las sesiones: leídas, cargando o con error (ver todayFocusProvider).
  final AsyncValue<TodayFocus> focus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = TodayFormats(context);
    final today = ref.watch(romeTodayProvider);
    final muted = theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: sessionMaxContentWidth),
        child: RefreshIndicator(
          // Deslizar para actualizar: si algo falla, queda lo que había y
          // se avisa.
          onRefresh: () => refreshChefData(context, ref),
          child: ListView(
            key: const ValueKey('today'),
            // Deslizar para actualizar aunque todo entre en la pantalla.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Semantics(
                header: true,
                child: Text(
                  formats.day(today),
                  key: const ValueKey('today-date'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              // Si la última lectura de las sesiones falló, lo dice con
              // «Riprova»: sin sesiones leídas, en lugar de la tarjeta; con
              // sesiones de antes, encima (lo que se ve puede ser de antes).
              const SessionsLoadError(),
              const SizedBox(height: 4),
              ...switch (focus) {
                AsyncData(:final value) => [
                  if (value.sessions.isEmpty)
                    const _NoSessions()
                  else if (value.isToday)
                    for (final (i, session) in value.sessions.indexed)
                      TodaySessionCard(
                        session: session,
                        finished: value.finishedAt(i),
                      )
                  else ...[
                    Text(
                      l10n.todayNoSessionToday,
                      key: const ValueKey('today-none-today'),
                      style: muted,
                    ),
                    _SectionTitle(
                      l10n.todayNextSession(
                        formats.day(value.sessions.first.date),
                      ),
                      textKey: const ValueKey('today-next-title'),
                    ),
                    TodaySessionCard(session: value.sessions.first),
                  ],
                ],
                AsyncError() => const <Widget>[],
                _ => const [
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: CircularProgressIndicator(
                        key: ValueKey('today-loading'),
                      ),
                    ),
                  ),
                ],
              },
              // Sin las sesiones leídas no se sabe qué reservas terminan.
              _Pending(sessionsRead: focus.hasValue),
              _SectionTitle(l10n.todayStripTitle),
              Text(
                l10n.todayStripHint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              const TodayStrip(key: ValueKey('today-strip')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sin ninguna sesión desde hoy: lo dice y de dónde salen; la acción (ir a
/// las solicitudes: una reserva se confirma desde un pedido) va abajo, en
/// _NoSessionsActions.
class _NoSessions extends StatelessWidget {
  const _NoSessions();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.todayEmptyTitle,
              key: const ValueKey('today-empty'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.todayEmptyBody,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sin ninguna sesión, la acción del estado vacío, «Vedi le richieste»:
/// abajo, en el tercio inferior del teléfono, como los botones de una sesión.
class _NoSessionsActions extends StatelessWidget {
  const _NoSessionsActions();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SessionBottomBar(
      key: const ValueKey('today-empty-actions'),
      children: [
        FilledButton.icon(
          key: const ValueKey('today-empty-action'),
          onPressed: () => context.go(AppRoutes.requests),
          icon: const Icon(Icons.inbox_outlined),
          label: Text(l10n.todayEmptyAction),
        ),
      ],
    );
  }
}

/// Los pendientes: pedidos nuevos (llevan a «Nuove») y reservas que terminan
/// (abren la ficha de su última semana). «Renovar» llega con el PR 8.
class _Pending extends ConsumerWidget {
  const _Pending({required this.sessionsRead});

  /// Las sesiones ya se leyeron (las reservas que terminan salen de ellas):
  /// sin eso, nada de «Niente in sospeso».
  final bool sessionsRead;

  void _openNewRequests(BuildContext context, WidgetRef ref) {
    ref.read(inboxTabRequestProvider.notifier).show(InboxTab.fresh);
    context.go(AppRoutes.requests);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final formats = SessionFormats(context);
    final inbox = ref.watch(chefInboxProvider);
    final newCount = ref.watch(newRequestsCountProvider);
    final ending = ref.watch(todayEndingBookingsProvider);
    // La carga y el error pueden llegar con un valor de antes (la lista vacía
    // de cuando todavía no había cocinera: el aviso de pedidos nuevos arma la
    // bandeja desde el arranque), así que se miran sin él. Mientras se vuelve
    // a leer después de una falla (Riverpod reintenta solo, o «Riprova»), el
    // estado trae el error y sigue cargando: la barra, no el error.
    final inboxLoading = inbox.isLoading;
    final inboxFailed = inbox.hasError && !inbox.isLoading;
    // «Niente in sospeso» solo con la bandeja y las sesiones leídas.
    final allRead = sessionsRead && !inbox.isLoading && !inbox.hasError;

    final items = <Widget>[
      if (newCount > 0)
        _PendingTile(
          key: const ValueKey('today-new-requests'),
          icon: Icons.inbox_outlined,
          title: l10n.todayNewRequests(newCount),
          onTap: () => _openNewRequests(context, ref),
        ),
      for (final last in ending)
        _PendingTile(
          key: ValueKey('today-ending-${last.requestId}'),
          icon: Icons.event_repeat_outlined,
          title: l10n.todayBookingEnding(last.displayName),
          subtitle: l10n.todayBookingLastSession(formats.inText(last.date)),
          onTap: () =>
              unawaited(context.push(AppRoutes.sessionDetail(last.id))),
        ),
    ];

    return Column(
      key: const ValueKey('today-pending'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(l10n.todayPendingTitle),
        if (inboxFailed)
          Padding(
            key: const ValueKey('today-requests-error'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // Un nodo propio: sin esto se funde con el título de arriba.
                MergeSemantics(
                  child: Text(
                    l10n.todayRequestsError,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('today-requests-retry'),
                  onPressed: () => ref.invalidate(chefInboxProvider),
                  child: Text(l10n.actionRetry),
                ),
              ],
            ),
          ),
        if (inboxLoading)
          const Padding(
            key: ValueKey('today-pending-loading'),
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
        ...items,
        if (items.isEmpty && allRead)
          // Un nodo propio: sin esto se funde con el título de arriba.
          MergeSemantics(
            child: Text(
              l10n.todayPendingNone,
              key: const ValueKey('today-pending-empty'),
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _PendingTile extends StatelessWidget {
  const _PendingTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Título de sección. Como SessionSection, es un nodo propio para el lector de
/// pantalla (`container`): sin eso, el de los pendientes se fundía con lo que
/// tiene abajo en su columna (VoiceOver leía «Da fare / Niente in sospeso.»
/// como encabezado) y en /gestione/ un encabezado con hijos sale como
/// <header> y no como encabezado. Lo que va debajo, en la misma columna,
/// también tiene que ser un nodo propio (un botón, una tarjeta o un texto con
/// MergeSemantics).
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.textKey});

  final String text;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Semantics(
        header: true,
        container: true,
        child: Text(
          text,
          key: textKey,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// «Come arrivare» y WhatsApp de la sesión principal. Sin dirección (las
/// reservas que llegan por la web), WhatsApp pasa a ser el principal y en lugar
/// de «Come arrivare» va «Aggiungi indirizzo», que la guarda en la ficha.
class _TodayActions extends ConsumerWidget {
  const _TodayActions({required this.session, required this.showWhose});

  final CookingSession session;
  final bool showWhose;

  Future<void> _launch(BuildContext context, WidgetRef ref, Uri uri) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = AppLocalizations.of(context).launchFailed;
    // Directo desde el toque: en la web, esperar algo antes haría que el
    // navegador bloquee la ventana nueva.
    final opened = await ref.read(linkLauncherProvider).launch(uri);
    if (!opened && messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final links = ref.watch(todayLinksProvider);
    VoidCallback? launch(Uri? uri) =>
        uri == null ? null : () => unawaited(_launch(context, ref, uri));
    const whatsAppKey = ValueKey('today-whatsapp');
    const whatsAppIcon = Icon(Icons.chat_outlined);
    final whatsAppLabel = Text(l10n.actionWhatsApp);

    final Widget primary;
    final Widget secondary;
    if (session.address != null) {
      primary = FilledButton.icon(
        key: const ValueKey('today-directions'),
        onPressed: launch(links?.directions),
        icon: const Icon(Icons.directions_outlined),
        label: Text(l10n.sessionDirections),
      );
      secondary = OutlinedButton.icon(
        key: whatsAppKey,
        onPressed: launch(links?.whatsApp),
        icon: whatsAppIcon,
        label: whatsAppLabel,
      );
    } else {
      primary = FilledButton.icon(
        key: whatsAppKey,
        onPressed: launch(links?.whatsApp),
        icon: whatsAppIcon,
        label: whatsAppLabel,
      );
      secondary = OutlinedButton.icon(
        key: const ValueKey('today-add-address'),
        onPressed: () => unawaited(editClientAddress(context, session)),
        icon: const Icon(Icons.add_location_alt_outlined),
        label: Text(l10n.sessionAddAddress),
      );
    }

    return SessionBottomBar(
      key: const ValueKey('today-actions'),
      children: [
        if (showWhose) ...[
          Text(
            l10n.todayActionsFor(session.displayName, session.start.toHhMm()),
            key: const ValueKey('today-actions-for'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(child: primary),
            const SizedBox(width: 12),
            Expanded(child: secondary),
          ],
        ),
      ],
    );
  }
}
