// Selector del idioma de la app: Español, Italiano, English, cada uno escrito
// en su propio idioma (así se encuentra aunque la interfaz esté en otro). Lo
// usan Impostazioni y el área de clientes. Solo muestra el estado de
// LanguageController y le pasa la elección.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/settings/application/language_controller.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Orden del selector: español (el de Evelyn), italiano (el de los clientes)
/// e inglés.
const List<AppLanguage> languageOptions = [
  AppLanguage.es,
  AppLanguage.it,
  AppLanguage.en,
];

class LanguageSelector extends ConsumerWidget {
  const LanguageSelector({super.key});

  Future<void> _change(
    BuildContext context,
    WidgetRef ref,
    AppLanguage language,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(languageControllerProvider.notifier).setLanguage(language);
    } on AccountFailure {
      // La interfaz ya volvió al idioma anterior: el aviso sale en ese.
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).languageSaveFailed),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // Si el perfil no trae idioma se marca el que se ve (el del dispositivo).
    final current =
        ref.watch(languageControllerProvider) ??
        AppLanguage.fromCode(Localizations.localeOf(context).languageCode);

    return RadioGroup<AppLanguage>(
      groupValue: current,
      onChanged: (language) {
        if (language != null) unawaited(_change(context, ref, language));
      },
      child: Column(
        key: const ValueKey('language-selector'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final language in languageOptions)
            RadioListTile<AppLanguage>(
              key: ValueKey('language-${language.code}'),
              value: language,
              title: Text(switch (language) {
                AppLanguage.es => l10n.languageOptionEs,
                AppLanguage.it => l10n.languageOptionIt,
                AppLanguage.en => l10n.languageOptionEn,
              }),
            ),
        ],
      ),
    );
  }
}
