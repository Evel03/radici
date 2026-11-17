// Una sesión en la agenda: la clienta y sus horas («Spesa dalle 09:15 ·
// Arrivo 10:00 · fino alle 13:00», salidas de la sesión), y el estado si no
// es una confirmada. Toda la fila abre su ficha (un solo objetivo, también
// para el lector de pantalla: el nodo lleva la acción de tocar, porque en
// /gestione/ el clic de VoiceOver solo llega a un nodo que la tiene).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

class SessionBlock extends StatelessWidget {
  const SessionBlock({super.key, required this.session});

  final CookingSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final times = l10n.sessionTimesLine(session);
    final status = session.status == SessionStatus.confirmed
        ? null
        : l10n.sessionStatus(session.status);
    final name = session.displayName;
    void open() => unawaited(context.push(AppRoutes.sessionDetail(session.id)));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Semantics(
        // Un nodo propio (en la semana no se funde con el título del día) y
        // con la acción de tocar: excludeSemantics descarta la del InkWell.
        container: true,
        button: true,
        label: [name, times, ?status].join(', '),
        excludeSemantics: true,
        onTap: open,
        child: Material(
          // Sin transparencia: el texto queda con el contraste del tema.
          color: colors.primaryContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('session-${session.id}'),
            onTap: open,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Row(
                children: [
                  // La franja de color: una sesión, no un pedido.
                  Container(width: 4, color: colors.primary),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            times,
                            key: ValueKey('session-${session.id}-times'),
                            style: theme.textTheme.bodyMedium,
                          ),
                          if (status != null)
                            Text(
                              status,
                              key: ValueKey('session-${session.id}-status'),
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: colors.tertiary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(
                      Icons.chevron_right,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
