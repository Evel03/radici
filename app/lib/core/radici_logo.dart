// Logotipo de Radici en texto, como en la web y en los emails: el nombre en
// Cinzel (sus minúsculas son versalitas) sobre un filete del ancho del nombre
// y el rótulo CUCINA PRIVATA debajo. Es texto: se ve nítido en cualquier
// pantalla y en la web no carga ninguna imagen (la CSP de /gestione/ no se
// entera).
import 'package:flutter/material.dart';
import 'package:radici/core/brand.dart';
import 'package:radici/l10n/app_localizations.dart';

class RadiciLogo extends StatelessWidget {
  const RadiciLogo({super.key, this.size = 40});

  /// Cuerpo del nombre en dp: el rótulo, el filete y los espacios se escalan
  /// con él (proporciones de .logo__name y .logo__tag de la web).
  final double size;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = Theme.of(context).colorScheme.onSurface;
    final nameSpacing = size * 0.07;
    final tagSize = size * 0.27;
    final tagSpacing = tagSize * 0.26;
    TextStyle style(double fontSize, double letterSpacing) => TextStyle(
      fontFamily: brandDisplayFont,
      fontSize: fontSize,
      height: 1.2,
      fontWeight: FontWeight.w500,
      letterSpacing: letterSpacing,
      color: color,
    );

    // Un solo nodo para los lectores de pantalla. Es un logotipo: no crece con
    // el tamaño de letra del sistema (el nombre ya es grande) ni se engrosa con
    // el texto en negrita del sistema (Cinzel va solo en 500: sería una
    // negrita falsa).
    return Semantics(
      container: true,
      label: '${l10n.appTitle}, ${l10n.brandTagline}',
      child: ExcludeSemantics(
        child: MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.noScaling, boldText: false),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                key: const ValueKey('logo-rule'),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: color)),
                ),
                // Flutter deja el espaciado también después de la última
                // letra: el padding izquierdo lo compensa, así el filete
                // sobresale lo mismo a cada lado.
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    size * 0.12 + nameSpacing,
                    0,
                    size * 0.12,
                    size * 0.12,
                  ),
                  child: Text(
                    l10n.appTitle,
                    key: const ValueKey('logo-name'),
                    style: style(size, nameSpacing),
                  ),
                ),
              ),
              SizedBox(height: size * 0.18),
              Padding(
                padding: EdgeInsets.only(left: tagSpacing),
                child: Text(
                  l10n.brandTagline.toUpperCase(),
                  key: const ValueKey('logo-tagline'),
                  style: style(tagSize, tagSpacing),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
