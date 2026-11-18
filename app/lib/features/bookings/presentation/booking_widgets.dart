// Piezas que comparten la hoja «Conferma prenotazione» y el formulario
// «Nuova cliente»: el título de una sección, la barra de abajo (va en el
// cuerpo: queda arriba del teclado) y una línea de esa barra con un botón que
// lleva hasta lo que dice.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Ancho máximo del contenido en pantallas anchas (como el detalle).
const double bookingMaxContentWidth = 720;

/// Título de una sección (un encabezado para el lector de pantalla).
class BookingSectionTitle extends StatelessWidget {
  const BookingSectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 4),
      child: Semantics(
        header: true,
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

/// Barra de abajo, a mano también con el teclado abierto en un teléfono en
/// vertical (en horizontal puede no entrar): la acción principal queda en el
/// tercio inferior.
class BookingBottomBar extends StatelessWidget {
  const BookingBottomBar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final side = math.max(16.0, (width - bookingMaxContentWidth) / 2);
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

/// Una línea de la barra de abajo, arriba del botón (o, con [padding], debajo
/// del botón al que se refiere), con un botón a la derecha que lleva hasta lo
/// que dice (deshabilitado mientras nada se puede cambiar). Con [liveRegion],
/// el lector de pantalla la anuncia al aparecer.
class BookingBarLine extends StatelessWidget {
  const BookingBarLine({
    super.key,
    required this.textKey,
    required this.text,
    required this.actionKey,
    required this.actionLabel,
    required this.onAction,
    this.color,
    this.padding = const EdgeInsets.only(bottom: 8),
    this.liveRegion = false,
  });

  final String textKey;
  final String text;
  final Color? color;
  final String actionKey;
  final String actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = Text(
      text,
      key: ValueKey(textKey),
      style: theme.textTheme.bodyMedium?.copyWith(color: color),
    );
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: liveRegion ? Semantics(liveRegion: true, child: line) : line,
          ),
          const SizedBox(width: 8),
          TextButton(
            key: ValueKey(actionKey),
            onPressed: onAction,
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}
