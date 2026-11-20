// Piezas de la ficha de la sesión y de la hoja «Sposta»: la barra de abajo
// (la acción principal en el tercio inferior del teléfono), los títulos de
// sección, una fila etiqueta–valor y el texto de ayuda.
import 'dart:math' as math;

import 'package:flutter/material.dart';

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
  const SessionSection(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
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
