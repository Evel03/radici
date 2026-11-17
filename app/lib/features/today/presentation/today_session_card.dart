// Una sesión en Hoy: la clienta, sus horas («Spesa dalle 09:15 · Arrivo
// 10:00 · fino alle 13:00», salidas de la sesión), las personas, el estado si
// no está confirmada, las alergias resaltadas (con la nota de contaminación
// cruzada si hay gluten, SPEC §5.6, como en la ficha) y las notas de cocina.
// Toda la tarjeta abre la ficha; para el lector de pantalla, la cabecera es el
// botón (con la acción de tocar en su nodo: en /gestione/ el clic de
// VoiceOver solo llega a un nodo que la tiene) y las alergias se leen aparte.
// La dirección no se muestra: la usa «Come arrivare».
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/features/sessions/presentation/session_widgets.dart';
import 'package:radici/l10n/app_localizations.dart';

class TodaySessionCard extends StatelessWidget {
  const TodaySessionCard({super.key, required this.session});

  final CookingSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final id = session.id;
    final name = session.displayName;
    final times = l10n.sessionTimesLine(session);
    final people = switch (session.people) {
      final count? => l10n.requestPeopleCount(count),
      null => null,
    };
    final status = session.status == SessionStatus.confirmed
        ? null
        : l10n.sessionStatus(session.status);
    final kitchen = session.client.kitchenNotes;
    void open() => unawaited(context.push(AppRoutes.sessionDetail(id)));

    return Card(
      key: ValueKey('today-session-$id'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: open,
        // La acción va en el nodo de la cabecera.
        excludeFromSemantics: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                key: ValueKey('today-session-$id-header'),
                container: true,
                button: true,
                label: [name, times, ?people, ?status].join(', '),
                excludeSemantics: true,
                onTap: open,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            key: ValueKey('today-session-$id-name'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            times,
                            key: ValueKey('today-session-$id-times'),
                            style: theme.textTheme.bodyLarge,
                          ),
                          if (people != null)
                            Text(
                              people,
                              key: ValueKey('today-session-$id-people'),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          if (status != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                status,
                                key: ValueKey('today-session-$id-status'),
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: colors.tertiary,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
                  ],
                ),
              ),
              SessionAllergies(session: session, dense: true),
              if (kitchen != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SessionInfoRow(
                    label: l10n.sessionKitchenNotes,
                    value: kitchen,
                    valueKey: ValueKey('today-session-$id-kitchen'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
