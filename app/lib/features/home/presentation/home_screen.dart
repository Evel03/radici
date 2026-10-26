// Inicio (M0): bienvenida y accesos a la calculadora y al login.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/brand_mark.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/l10n/app_localizations.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
                  const Center(child: RadiciMark(size: 88)),
                  const SizedBox(height: 24),
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
                    key: const ValueKey('home-quote'),
                    onPressed: () => context.go(AppRoutes.quote),
                    icon: const Icon(Icons.calculate_outlined),
                    label: Text(l10n.homeQuoteCta),
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
