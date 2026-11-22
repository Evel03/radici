// Piezas de la ficha de la sesión, de la hoja «Sposta» y de Hoy: la barra de
// abajo (la acción principal en el tercio inferior del teléfono), los títulos
// de sección, una fila etiqueta–valor (también con el valor como enlace a
// Mapas), el texto de ayuda y las alergias.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Ancho máximo del contenido en pantallas anchas (como el detalle).
const double sessionMaxContentWidth = 720;

/// Barra de abajo, siempre a mano: en un teléfono, las acciones quedan en el
/// tercio inferior.
class SessionBottomBar extends StatelessWidget {
  const SessionBottomBar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final side = math.max(16.0, (width - sessionMaxContentWidth) / 2);
    return Material(
      color: colors.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(side, 12, side, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

/// Título de sección. Es un nodo propio para el lector de pantalla
/// (`container`): sin eso, en la ficha (una lista) se funde con los textos
/// sueltos de su sección, que VoiceOver leía como parte del título y antes de
/// lo demás (y en /gestione/ un encabezado con hijos no sale como
/// encabezado). Por lo mismo, en la ficha lo que va debajo tiene que ser
/// también un nodo propio (un botón, una fila o un texto con MergeSemantics).
class SessionSection extends StatelessWidget {
  const SessionSection(this.title, {super.key, this.top = 24});

  final String title;

  /// Espacio arriba del título (menos dentro de una tarjeta, como en Hoy).
  final double top;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 8),
      child: Semantics(
        header: true,
        container: true,
        child: Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Etiqueta y valor en una fila (o uno debajo del otro si no entran).
class SessionInfoRow extends StatelessWidget {
  const SessionInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.selectable = false,
    this.valueKey,
  });

  final String label;
  final String value;
  final bool selectable;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: MergeSemantics(
        child: Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 140),
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (selectable)
              SelectableText(value, key: valueKey, style: style)
            else
              Text(value, key: valueKey, style: style),
          ],
        ),
      ),
    );
  }
}

/// Etiqueta y valor en una fila, como [SessionInfoRow], con el valor como
/// enlace a Mapas («Come arrivare»): en el color de los enlaces, subrayado y
/// con el ícono de la ruta. Se toca toda la fila, de 48 dp de alto como
/// mínimo. Para el lector de pantalla, un solo nodo con [semanticsLabel]
/// («Come arrivare a …»), enlace y con la acción de tocar (en /gestione/ el
/// toque de VoiceOver solo llega a un nodo que la tiene).
class SessionDirectionsRow extends StatelessWidget {
  const SessionDirectionsRow({
    super.key,
    required this.label,
    required this.value,
    required this.semanticsLabel,
    required this.onTap,
    this.valueKey,
  });

  final String label;
  final String value;
  final String semanticsLabel;
  final VoidCallback onTap;

  /// La del `Text` del valor.
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      container: true,
      link: true,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        // La acción va en el nodo de arriba.
        excludeFromSemantics: true,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          padding: const EdgeInsets.symmetric(vertical: 4),
          alignment: AlignmentDirectional.centerStart,
          child: Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 140),
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.directions_outlined,
                    size: 20,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      value,
                      key: valueKey,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colors.primary,
                        decoration: TextDecoration.underline,
                        decorationColor: colors.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SessionHelp extends StatelessWidget {
  const SessionHelp(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Alergias y dietas de la ficha y del pedido, la nota del pedido resaltada
/// y, con gluten, la nota de contaminación cruzada (SPEC §5.6). En una sesión
/// semanal cuyo pedido no responde (una renovación), lo del último pedido
/// semanal de la web que se reservó, con la fecha de ese pedido (nunca en una
/// extra: CookingSession.earlierAllergyAnswer). Sin ningún dato, una
/// advertencia que pide preguntarle, nunca «sin alergias»; una dieta sola no
/// es un dato de alergias: se muestra debajo de la advertencia. Cada pieza es
/// un nodo propio del lector de pantalla, en el orden en que se ve: el título
/// primero (ver SessionSection). La ficha de la sesión y Hoy (con [dense],
/// dentro de una tarjeta) muestran lo mismo.
class SessionAllergies extends StatelessWidget {
  const SessionAllergies({super.key, required this.session, this.dense = false});

  final CookingSession session;

  /// Con menos espacio arriba del título.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final note = session.allergyNote;
    final earlierAt = session.earlierAnswerAt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SessionSection(l10n.sessionSectionAllergies, top: dense ? 12 : 24),
        // Lo que sigue sale de otro pedido de la clienta: de cuándo es.
        if (earlierAt != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: MergeSemantics(
              child: Text(
                l10n.sessionAllergiesEarlierRequest(
                  RequestFormats(context).instantDayMonthYear(earlierAt),
                ),
                key: const ValueKey('session-allergies-earlier'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ...switch (session.allergyAnswer) {
          AllergyAnswer.none => [
            MergeSemantics(
              child: Text(
                l10n.detailNoAllergies,
                key: const ValueKey('session-no-allergies'),
              ),
            ),
          ],
          // Ningún dato (ni alérgenos de la ficha, ni nota o alérgenos de un
          // pedido de la clienta, ni «nadie tiene»): que le pregunte antes de
          // cocinar. Una reserva cargada a mano no guarda alergias (falta el
          // consentimiento de salud, M2): cae acá salvo que la ficha tenga
          // alérgenos o, si es semanal, responda el último pedido semanal de
          // la web que se reservó.
          AllergyAnswer.unknown => [
            _WarningBox(
              boxKey: const ValueKey('session-allergies-unknown-box'),
              textKey: const ValueKey('session-allergies-unknown'),
              text: l10n.sessionAllergiesNoData,
            ),
          ],
          AllergyAnswer.listed => [
            if (session.allergens.isNotEmpty)
              _Chips(
                keyName: 'session-allergens',
                label: l10n.detailAllergens,
                values: [for (final a in session.allergens) l10n.allergen(a)],
              ),
          ],
        },
        // Las dietas, con cualquier respuesta: no dicen nada de alergias.
        if (session.diets.isNotEmpty)
          _Chips(
            keyName: 'session-diets',
            label: l10n.detailDiets,
            values: [for (final d in session.diets) l10n.diet(d)],
          ),
        // Solo con alergias indicadas hay nota (la nota es una respuesta).
        if (note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.tertiaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: MergeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.sessionAllergyNote,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colors.onTertiaryContainer,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        note,
                        key: const ValueKey('session-allergy-note'),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colors.onTertiaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (session.needsCrossContaminationNote)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _WarningBox(
              textKey: const ValueKey('session-cross-contamination'),
              text: l10n.sessionCrossContamination,
            ),
          ),
      ],
    );
  }
}

/// Advertencia resaltada: fondo de error con el ícono de aviso y el texto en
/// negrita. Para el lector de pantalla, un solo nodo con el texto (el ícono no
/// se lee).
class _WarningBox extends StatelessWidget {
  const _WarningBox({required this.textKey, required this.text, this.boxKey});

  /// La del `Text` (los tests lo leen por ahí).
  final Key textKey;
  final String text;

  /// La de la caja.
  final Key? boxKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      key: boxKey,
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: MergeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Icon(
                  Icons.warning_amber_rounded,
                  color: colors.onErrorContainer,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  key: textKey,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colors.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chips extends StatelessWidget {
  const _Chips({
    required this.keyName,
    required this.label,
    required this.values,
  });

  final String keyName;
  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey(keyName),
      padding: const EdgeInsets.symmetric(vertical: 4),
      // La etiqueta y sus valores, un solo nodo («Alérgenos que evitar,
      // Gluten, Leche»): sin esto la etiqueta se leía antes del título.
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final value in values)
                  Chip(
                    label: Text(value),
                    backgroundColor: theme.colorScheme.tertiaryContainer,
                    labelStyle: TextStyle(
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
