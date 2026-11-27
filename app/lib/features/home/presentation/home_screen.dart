// Inicio de la app sin sesión (iOS y Android; en la web la app empieza en el
// login): la portada de la web (landing_sections.dart), con «Chiedi il
// preventivo», que abre el formulario de la web sin salir de la app, y el
// login arriba y al final. Sin precios: desde el 22/11/2026 Evelyn arma cada
// presupuesto a mano y la tarifa es solo su referencia interna.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/radici_logo.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/core/web_links.dart';
import 'package:radici/features/home/presentation/landing_sections.dart';
import 'package:radici/l10n/app_localizations.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// «Come funziona» del principio baja hasta esta sección.
  final _howKey = GlobalKey();

  String get _language => Localizations.localeOf(context).languageCode;

  /// El formulario de pedido en una hoja de Safari o una pestaña de Chrome:
  /// el anti-spam y la casilla de ofertas funcionan como en la web.
  void _openRequest() =>
      ref.read(linkLauncherProvider).openPage(requestFormUri(_language));

  void _openPrivacy() =>
      ref.read(linkLauncherProvider).openPage(privacyPolicyUri(_language));

  void _goToLogin() => context.go(AppRoutes.login);

  void _showHow() {
    final target = _howKey.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Semantics(
          label: l10n.appTitle,
          child: const ExcludeSemantics(child: RadiciLogo(size: 26)),
        ),
        actions: [
          TextButton(
            key: const ValueKey('home-login'),
            onPressed: _goToLogin,
            child: Text(l10n.homeLoginCta),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        key: const ValueKey('home-scroll'),
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LandingHero(onRequest: _openRequest, onHow: _showHow),
              const LandingServices(),
              LandingHow(key: _howKey),
              const LandingIncluded(),
              LandingPricing(onRequest: _openRequest),
              const LandingWho(),
              const LandingFaq(),
              LandingFinal(onRequest: _openRequest),
              LandingFooter(onPrivacy: _openPrivacy, onLogin: _goToLogin),
            ],
          ),
        ),
      ),
    );
  }
}
