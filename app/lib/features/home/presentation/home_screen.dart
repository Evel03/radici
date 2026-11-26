// Inicio de la app sin sesión: bienvenida, «Pedir presupuesto» (el formulario
// de la web) y el login. Sin precios: desde el 22/11/2026 Evelyn arma cada
// presupuesto a mano y la tarifa es solo su referencia interna, así que la
// app ya no tiene la calculadora pública.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/radici_logo.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/core/web_links.dart';
import 'package:radici/l10n/app_localizations.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: RadiciLogo(size: 44)),
                  const SizedBox(height: 32),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.homeHeadline,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.homeBody,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    key: const ValueKey('home-request'),
                    // Directo desde el toque: en la web, el navegador
                    // bloquea la pestaña nueva si antes se espera otra cosa.
                    onPressed: () => ref
                        .read(linkLauncherProvider)
                        .launch(
                          requestFormUri(
                            Localizations.localeOf(context).languageCode,
                          ),
                        ),
                    icon: const Icon(Icons.edit_note),
                    label: Text(l10n.homeRequestCta),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('home-login'),
                    onPressed: () => context.go(AppRoutes.login),
                    icon: const Icon(Icons.login),
                    label: Text(l10n.homeLoginCta),
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
