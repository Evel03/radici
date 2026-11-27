// Secciones de la portada sin sesión: las mismas de la portada web
// (web/index.html), en el mismo orden y con los mismos textos (landing* en
// los ARB, copiados de web/src/i18n; test/l10n/landing_texts_test.dart los
// compara). Sin precios: desde el 22/11/2026 Evelyn arma cada presupuesto a
// mano. Las acciones (abrir el formulario, la privacy, el login) llegan de
// HomeScreen.
import 'package:flutter/material.dart';
import 'package:radici/core/brand.dart';
import 'package:radici/core/radici_logo.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/quote/domain/quote.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Ancho máximo del contenido: en una tablet la portada no se estira.
const double landingMaxWidth = 560;

/// Fotos de la portada (las de la web, en assets/images/landing/).
abstract final class LandingPhotos {
  static const String kitchen = 'assets/images/landing/cocina.jpg';
  static const String apron = 'assets/images/landing/delantal.jpg';
  static const String menu = 'assets/images/landing/menu.jpg';
  static const String card = 'assets/images/landing/tarjeta.jpg';

  static const List<String> all = [kitchen, apron, menu, card];
}

/// Una franja de la portada a todo el ancho, con el contenido centrado.
class LandingBand extends StatelessWidget {
  const LandingBand({
    super.key,
    required this.child,
    this.color,
    this.vertical = 32,
  });

  final Widget child;
  final Color? color;
  final double vertical;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: color ?? Colors.transparent,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 24, vertical: vertical),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: landingMaxWidth),
          child: child,
        ),
      ),
    ),
  );
}

/// El rótulo chico en versalitas de la web (.eyebrow, .label).
class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontFamily: brandDisplayFont,
      fontSize: 13,
      fontWeight: FontWeight.w500,
      height: 1.5,
      letterSpacing: 3.2,
      color: color ?? Theme.of(context).colorScheme.primary,
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(
      text,
      style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: color),
    ),
  );
}

class _Intro extends StatelessWidget {
  const _Intro(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Una foto con las esquinas redondeadas y la proporción de la web.
class _Photo extends StatelessWidget {
  const _Photo(this.asset, {required this.aspectRatio, this.label});

  final String asset;
  final double aspectRatio;

  /// Lo que lee el lector de pantalla; null en una foto decorativa.
  final String? label;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: AspectRatio(
      aspectRatio: aspectRatio,
      child: Image.asset(
        asset,
        fit: BoxFit.cover,
        semanticLabel: label,
        excludeFromSemantics: label == null,
      ),
    ),
  );
}

/// Un título y su texto (pasos, qué incluye, para quién es).
class _TitledText extends StatelessWidget {
  const _TitledText({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.titleLarge),
        ),
        const SizedBox(height: 4),
        Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Ícono en un círculo, a la izquierda de un [_TitledText].
class _IconRow extends StatelessWidget {
  const _IconRow({required this.icon, required this.child});

  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          child: Icon(icon, size: 22),
        ),
        const SizedBox(width: 16),
        Expanded(child: child),
      ],
    );
  }
}

class LandingHero extends StatelessWidget {
  const LandingHero({super.key, required this.onRequest, required this.onHow});

  final VoidCallback onRequest;
  final VoidCallback onHow;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return LandingBand(
      vertical: 24,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Eyebrow(l10n.landingHeroEyebrow),
          const SizedBox(height: 12),
          Semantics(
            header: true,
            child: Text(
              l10n.landingHeroTitle,
              style: theme.textTheme.headlineLarge,
            ),
          ),
          const SizedBox(height: 12),
          Text(l10n.landingHeroLead, style: muted),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const ValueKey('home-request'),
            onPressed: onRequest,
            icon: const Icon(Icons.edit_note),
            label: Text(l10n.landingHeroCta),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey('home-how'),
            onPressed: onHow,
            child: Text(l10n.landingHeroSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.landingHeroNote,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          _Photo(
            LandingPhotos.kitchen,
            aspectRatio: 452 / 372,
            label: l10n.landingHeroPhotoAlt,
          ),
          const SizedBox(height: 16),
          Semantics(
            container: true,
            label: l10n.landingHeroBenefitsLabel,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FridgeLabel(
                  title: l10n.landingHeroLabel1Title,
                  text: l10n.landingHeroLabel1Text,
                ),
                _FridgeLabel(
                  title: l10n.landingHeroLabel2Title,
                  text: l10n.landingHeroLabel2Text,
                  indent: 20,
                ),
                _FridgeLabel(
                  title: l10n.landingHeroLabel3Title,
                  text: l10n.landingHeroLabel3Text,
                  indent: 8,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Las etiquetas de heladera de la web (.fridge-label): borde fino con el
/// filo de arriba en oliva, título en itálica y el texto en versalitas.
class _FridgeLabel extends StatelessWidget {
  const _FridgeLabel({
    required this.title,
    required this.text,
    this.indent = 0,
  });

  final String title;
  final String text;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(left: indent, right: 28 - indent, top: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          border: Border(
            top: BorderSide(color: scheme.primary, width: 2),
            left: BorderSide(color: scheme.outlineVariant),
            right: BorderSide(color: scheme.outlineVariant),
            bottom: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontSize: 19,
                  fontStyle: FontStyle.italic,
                ),
              ),
              _Eyebrow(text, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class LandingServices extends StatelessWidget {
  const LandingServices({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget service(IconData icon, String name) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: scheme.primary, size: 28),
          const SizedBox(width: 16),
          Expanded(child: Text(name, style: theme.textTheme.titleLarge)),
        ],
      ),
    );
    return LandingBand(
      color: scheme.surfaceContainer,
      vertical: 24,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: _Eyebrow(l10n.landingServicesTitle)),
          const SizedBox(height: 8),
          service(Icons.soup_kitchen_outlined, l10n.landingServicesWeekly),
          service(Icons.room_service_outlined, l10n.landingServicesDinners),
          service(Icons.wine_bar_outlined, l10n.landingServicesEvents),
        ],
      ),
    );
  }
}

class LandingHow extends StatelessWidget {
  const LandingHow({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final steps = [
      (
        Icons.chat_bubble_outline,
        l10n.landingHowStep1Title,
        l10n.landingHowStep1Text,
      ),
      (
        Icons.receipt_long_outlined,
        l10n.landingHowStep2Title,
        l10n.landingHowStep2Text,
      ),
      (
        Icons.soup_kitchen_outlined,
        l10n.landingHowStep3Title,
        l10n.landingHowStep3Text,
      ),
      (
        Icons.kitchen_outlined,
        l10n.landingHowStep4Title,
        l10n.landingHowStep4Text,
      ),
    ];
    return LandingBand(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionTitle(
            l10n.landingHowTitle,
            key: const ValueKey('home-how-title'),
          ),
          _Intro(l10n.landingHowIntro),
          const SizedBox(height: 20),
          _Photo(
            LandingPhotos.apron,
            aspectRatio: 438 / 174,
            label: l10n.landingHowPhotoAlt(l10n.appTitle),
          ),
          for (final (icon, title, text) in steps) ...[
            const SizedBox(height: 24),
            _IconRow(
              icon: icon,
              child: _TitledText(title: title, text: text),
            ),
          ],
        ],
      ),
    );
  }
}

class LandingIncluded extends StatelessWidget {
  const LandingIncluded({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final items = [
      (l10n.landingIncludedItem1Title, l10n.landingIncludedItem1Text),
      (l10n.landingIncludedItem2Title, l10n.landingIncludedItem2Text),
      (
        l10n.landingIncludedItem3Title,
        l10n.landingIncludedItem3Text(
          QuoteLimits.minRecipes,
          QuoteLimits.maxRecipes,
        ),
      ),
      (l10n.landingIncludedItem4Title, l10n.landingIncludedItem4Text),
      (l10n.landingIncludedItem5Title, l10n.landingIncludedItem5Text),
    ];
    return LandingBand(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Photo(
            LandingPhotos.menu,
            aspectRatio: 390 / 288,
            label: l10n.landingIncludedPhotoAlt(l10n.appTitle),
          ),
          const SizedBox(height: 24),
          _SectionTitle(l10n.landingIncludedTitle),
          for (final (title, text) in items) ...[
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: _TitledText(title: title, text: text),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class LandingPricing extends StatelessWidget {
  const LandingPricing({super.key, required this.onRequest});

  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget card({
      required String title,
      required String text,
      Color? color,
      Color? onColor,
      Widget? action,
    }) => Card(
      margin: const EdgeInsets.only(top: 16),
      color: color ?? scheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(color: onColor),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: onColor),
            ),
            ?action,
          ],
        ),
      ),
    );
    return LandingBand(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionTitle(l10n.landingPricingTitle),
          _Intro(l10n.landingPricingIntro),
          const SizedBox(height: 4),
          card(
            title: l10n.landingPricingServiceTitle,
            text: l10n.landingPricingServiceText,
          ),
          card(
            title: l10n.landingPricingShoppingTitle,
            text: l10n.landingPricingShoppingText,
            color: scheme.primaryContainer,
            onColor: scheme.onPrimaryContainer,
          ),
          card(
            title: l10n.landingPricingMethodsTitle,
            text: l10n.landingPricingMethodsText,
          ),
          card(
            title: l10n.landingPricingCtaTitle,
            text: l10n.landingPricingCtaText,
            color: scheme.tertiaryContainer,
            onColor: scheme.onTertiaryContainer,
            action: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton.icon(
                key: const ValueKey('home-request-pricing'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onTertiaryContainer,
                  padding: EdgeInsets.zero,
                ),
                onPressed: onRequest,
                icon: const Icon(Icons.arrow_forward),
                iconAlignment: IconAlignment.end,
                label: Text(l10n.landingPricingCtaLink),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LandingWho extends StatelessWidget {
  const LandingWho({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final who = [
      (
        Icons.home_outlined,
        l10n.landingWhoFamiliesTitle,
        l10n.landingWhoFamiliesText,
      ),
      (Icons.work_outline, l10n.landingWhoProsTitle, l10n.landingWhoProsText),
      (
        Icons.child_care_outlined,
        l10n.landingWhoKidsTitle,
        l10n.landingWhoKidsText,
      ),
    ];
    return LandingBand(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionTitle(l10n.landingWhoTitle),
          for (final (icon, title, text) in who) ...[
            const SizedBox(height: 20),
            _IconRow(
              icon: icon,
              child: _TitledText(title: title, text: text),
            ),
          ],
        ],
      ),
    );
  }
}

class LandingFaq extends StatelessWidget {
  const LandingFaq({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final faq = [
      (l10n.landingFaqQ1, l10n.landingFaqA1),
      (l10n.landingFaqQPrice, l10n.landingFaqAPrice),
      (l10n.landingFaqQWeeks, l10n.landingFaqAWeeks(maxBookingWeeks)),
      (l10n.landingFaqQ2, l10n.landingFaqA2),
      (l10n.landingFaqQ3, l10n.landingFaqA3),
      (l10n.landingFaqQ4, l10n.landingFaqA4),
      (l10n.landingFaqQ5, l10n.landingFaqA5),
      (l10n.landingFaqQ6, l10n.landingFaqA6),
    ];
    return LandingBand(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionTitle(l10n.landingFaqTitle),
          const SizedBox(height: 12),
          for (final (index, (question, answer)) in faq.indexed)
            ExpansionTile(
              key: ValueKey('home-faq-$index'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 16),
              expandedAlignment: Alignment.centerLeft,
              shape: const Border(),
              collapsedShape: Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              title: Text(question, style: theme.textTheme.titleMedium),
              children: [
                Text(
                  answer,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// El cierre en oliva (.final-cta): los valores, el título y el botón.
class LandingFinal extends StatelessWidget {
  const LandingFinal({super.key, required this.onRequest});

  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final values = [
      l10n.landingValuesV1,
      l10n.landingValuesV2,
      l10n.landingValuesV3,
      l10n.landingValuesV4,
    ];
    return LandingBand(
      color: scheme.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            label: l10n.landingValuesLabel,
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                for (final value in values)
                  _Eyebrow(value, color: scheme.onPrimary),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle(l10n.landingFinalTitle, color: scheme.onPrimary),
          const SizedBox(height: 8),
          Text(
            l10n.landingFinalText,
            style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onPrimary),
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const ValueKey('home-request-final'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.onPrimary,
              foregroundColor: scheme.primary,
            ),
            onPressed: onRequest,
            child: Text(l10n.landingFinalCta),
          ),
          const SizedBox(height: 24),
          const _Photo(LandingPhotos.card, aspectRatio: 562 / 174),
        ],
      ),
    );
  }
}

class LandingFooter extends StatelessWidget {
  const LandingFooter({
    super.key,
    required this.onPrivacy,
    required this.onLogin,
  });

  final VoidCallback onPrivacy;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return LandingBand(
      color: theme.colorScheme.surfaceContainer,
      child: Column(
        children: [
          const RadiciLogo(size: 32),
          const SizedBox(height: 16),
          Text(
            l10n.landingFooterSlogan,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            l10n.landingFooterTagline,
            textAlign: TextAlign.center,
            style: muted,
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            key: const ValueKey('home-login-footer'),
            onPressed: onLogin,
            icon: const Icon(Icons.login),
            label: Text(l10n.homeLoginCta),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey('home-privacy'),
            onPressed: onPrivacy,
            child: Text(l10n.landingFooterPrivacy),
          ),
        ],
      ),
    );
  }
}
