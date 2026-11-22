// Hoy (/oggi), el inicio de la cocinera: la sesión de hoy (varias, con la
// próxima primero) o, si hoy no hay, la próxima; los pendientes de uno o dos
// toques (pedidos nuevos, que llevan a «Nuove»; reservas que terminan, que
// abren la ficha de su última semana o, con «Rinnova», la hoja de la
// renovación: renovar son dos toques; y los menús para mandar, las semanas de
// los próximos 7 días sin menú, sin mandar o con cambios pedidos, con el
// límite de 48 h antes de la llegada, que abren su menú) y la tira de 7 días
// (cada día abre la Agenda en ese día). Abajo, en el tercio inferior del
// teléfono, «Come arrivare» y WhatsApp de la sesión principal (sin
// dirección, WhatsApp y «Aggiungi indirizzo», como la ficha); sin ninguna
// sesión, «Vedi le richieste». «Hoy» es el día de Roma y cambia a la
// medianoche sin reabrir la app. Deslizar para actualizar (o «Ricarica»,
// arriba) vuelve a leer todo.
// Mientras las sesiones cargan, o si no se pudieron leer, la rueda o el aviso
// van en el lugar de la tarjeta: los pendientes y la tira siguen.
//
// Solo lee providers: la lógica está en today_providers.dart y en el dominio.
// Las sesiones llevan la dirección y datos de salud: nada se loguea.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/rome_time.dart';
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
import 'package:radici/features/today/application/today_menus_providers.dart';
import 'package:radici/features/today/application/today_providers.dart';
import 'package:radici/features/today/domain/pending_menus.dart';
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

/// Sin ninguna sesión, las acciones del estado vacío, «Vedi le richieste» y
/// «Nuova prenotazione» (cargar una a mano, como en «Prenotazioni»): abajo,
/// en el tercio inferior del teléfono, como los botones de una sesión.
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
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('today-empty-new-booking'),
          onPressed: () => context.push(AppRoutes.newBooking),
          icon: const Icon(Icons.add),
          label: Text(l10n.newBookingAction),
        ),
      ],
    );
  }
}

/// Los pendientes: pedidos nuevos (llevan a «Nuove»), reservas que terminan
/// o que terminaron hace hasta 7 días (abren la ficha de su última semana y
/// tienen «Rinnova», que abre la hoja prellenada) y los menús para mandar
/// (_PendingMenus). «Niente in sospeso» solo si no hay nada de eso.
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
    final today = ref.watch(romeTodayProvider);
    // La carga y el error pueden llegar con un valor de antes (la lista vacía
    // de cuando todavía no había cocinera: el aviso de pedidos nuevos arma la
    // bandeja desde el arranque), así que se miran sin él. Mientras se vuelve
    // a leer después de una falla (Riverpod reintenta solo, o «Riprova»), el
    // estado trae el error y sigue cargando: la barra, no el error.
    final inboxLoading = inbox.isLoading;
    final inboxFailed = inbox.hasError && !inbox.isLoading;
    // «Niente in sospeso» solo con la bandeja y las sesiones leídas, y los
    // menús de los próximos días leídos y sin ninguno que espere algo.
    final menus = ref.watch(todayPendingMenusProvider);
    final noMenus = menus.hasValue && !menus.hasError && menus.value!.isEmpty;
    final allRead =
        sessionsRead && !inbox.isLoading && !inbox.hasError && noMenus;

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
          // Si su última sesión ya pasó (hasta 7 días), dice que terminó.
          title: last.date.isBefore(today)
              ? l10n.todayBookingEnded(last.displayName)
              : l10n.todayBookingEnding(last.displayName),
          subtitle: l10n.todayBookingLastSession(formats.inText(last.date)),
          onTap: () =>
              unawaited(context.push(AppRoutes.sessionDetail(last.id))),
          // «Rinnova»: la hoja prellenada encima de Hoy (al cerrarla, Hoy).
          action: _RenewButton(
            key: ValueKey('today-renew-${last.requestId}'),
            semanticsLabel: l10n.todayRenewA11y(last.displayName),
            onPressed: () =>
                unawaited(context.push(AppRoutes.sessionRenew(last.id))),
          ),
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
        const _PendingMenus(),
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

/// «Menús para mandar», dentro de los pendientes: las semanas de los próximos
/// 7 días que esperan algo con su menú (todayPendingMenusProvider), por
/// fecha, cada una con su estado y el límite para mandarlo, resaltado si
/// faltan menos de 24 h o ya pasó. Tocar una abre su menú. Sin ninguna (o
/// mientras se leen por primera vez), nada; si no se pudieron leer, lo dice
/// con «Riprova».
class _PendingMenus extends ConsumerWidget {
  const _PendingMenus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final now = ref.watch(todayNowProvider);
    final title = _SubsectionTitle(
      l10n.todayMenusTitle,
      textKey: const ValueKey('today-menus-title'),
    );
    return ref
        .watch(todayPendingMenusProvider)
        .when(
          data: (menus) => menus.isEmpty
              ? const SizedBox.shrink()
              : Column(
                  key: const ValueKey('today-menus'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    title,
                    // Un nodo propio: sin esto se funde con el título.
                    MergeSemantics(
                      child: Text(
                        l10n.todayMenusHint,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    for (final menu in menus)
                      _PendingMenuTile(menu: menu, now: now),
                  ],
                ),
          loading: () => const SizedBox.shrink(),
          error: (_, _) => Column(
            key: const ValueKey('today-menus'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title,
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  MergeSemantics(
                    child: Text(
                      l10n.todayMenusError,
                      key: const ValueKey('today-menus-error'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('today-menus-retry'),
                    onPressed: () => ref.invalidate(todayMenusDataProvider),
                    child: Text(l10n.actionRetry),
                  ),
                ],
              ),
            ],
          ),
        );
  }
}

/// Una semana de «Menús para mandar»: la clienta, «Semana k de N», el día y
/// la llegada, qué le falta al menú y el límite para mandarlo (hora de
/// Roma). Tocarla abre su menú, encima de Hoy.
class _PendingMenuTile extends StatelessWidget {
  const _PendingMenuTile({required this.menu, required this.now});

  final PendingMenu menu;

  /// «Ahora», al minuto: el límite se resalta si faltan menos de 24 h.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final formats = SessionFormats(context);
    final session = menu.session;
    final id = session.id;
    final position = menu.position;
    final when = [
      if (position != null) l10n.sessionWeekOf(position.week, position.weeks),
      formats.inText(session.date),
      l10n.todayMenusArrives(session.start.toHhMm()),
    ].join(' · ');
    final deadlineWall = romeWallClock(menu.deadline);
    final deadlineDay = formats.inText(CalendarDate.fromDateTime(deadlineWall));
    final deadlineTime = ClockTime.hm(
      deadlineWall.hour,
      deadlineWall.minute,
    ).toHhMm();
    final deadline = menu.deadlinePassed(now)
        ? l10n.todayMenuDeadlinePassed(deadlineDay, deadlineTime)
        : l10n.todayMenuDeadline(deadlineDay, deadlineTime);
    final near = menu.deadlineNear(now);
    final changes = menu.state == PendingMenuState.changesRequested;
    final state = switch (menu.state) {
      PendingMenuState.noMenu => l10n.todayMenuNoMenu,
      PendingMenuState.notSent => l10n.todayMenuNotSent,
      PendingMenuState.changedSinceSent => l10n.todayMenuChangedSinceSent,
      PendingMenuState.changesRequested => l10n.todayMenuChangesRequested,
    };
    return Card(
      key: ValueKey('today-menu-$id'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.restaurant_menu),
        title: Text(session.displayName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(when, key: ValueKey('today-menu-when-$id')),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _Pill(
                  key: ValueKey('today-menu-state-$id'),
                  text: state,
                  background: changes
                      ? colors.tertiaryContainer
                      : colors.secondaryContainer,
                  foreground: changes
                      ? colors.onTertiaryContainer
                      : colors.onSecondaryContainer,
                ),
                _Pill(
                  key: ValueKey('today-menu-deadline-$id'),
                  text: deadline,
                  icon: near ? Icons.warning_amber_rounded : Icons.schedule,
                  background: near
                      ? colors.errorContainer
                      : colors.surfaceContainerHighest,
                  foreground: near
                      ? colors.onErrorContainer
                      : colors.onSurfaceVariant,
                ),
              ],
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => unawaited(context.push(AppRoutes.sessionMenu(id))),
      ),
    );
  }
}

/// Una etiqueta chica de color, con un ícono opcional (que el lector de
/// pantalla no lee: el texto dice lo mismo).
class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.text,
    required this.background,
    required this.foreground,
    this.icon,
  });

  final String text;
  final Color background;
  final Color foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = this.icon;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              ExcludeSemantics(child: Icon(icon, size: 16, color: foreground)),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                text,
                style: theme.textTheme.labelMedium?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Un pendiente: tocarlo lo abre. Con [action] (el «Rinnova» de una reserva
/// que termina), el botón va debajo, a la derecha, y el resto de la tarjeta
/// sigue abriendo lo suyo.
class _PendingTile extends StatelessWidget {
  const _PendingTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    final action = this.action;
    final tile = ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: action == null
          ? tile
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                tile,
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: action,
                  ),
                ),
              ],
            ),
    );
  }
}

/// «Rinnova» de una reserva que termina. Para el lector de pantalla es un
/// solo nodo con la etiqueta que dice de quién es, el botón y la acción de
/// tocar (en /gestione/ el toque de VoiceOver solo llega a un nodo que tiene
/// la acción, como la cabecera de TodaySessionCard), sin repetir «Rinnova».
class _RenewButton extends StatelessWidget {
  const _RenewButton({
    super.key,
    required this.semanticsLabel,
    required this.onPressed,
  });

  final String semanticsLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      container: true,
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: onPressed,
      child: FilledButton.tonal(
        onPressed: onPressed,
        child: Text(l10n.actionRenew),
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

/// Título de una parte dentro de una sección (los menús para mandar, dentro
/// de los pendientes): más chico que [_SectionTitle] y, como él, un nodo
/// propio para el lector de pantalla.
class _SubsectionTitle extends StatelessWidget {
  const _SubsectionTitle(this.text, {this.textKey});

  final String text;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Semantics(
        header: true,
        container: true,
        child: Text(
          text,
          key: textKey,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
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
