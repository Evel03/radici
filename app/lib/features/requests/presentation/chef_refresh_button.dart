// Volver a leer la bandeja, la disponibilidad y las sesiones desde Hoy y la
// Agenda: deslizar para actualizar y el botón «Ricarica» de la barra de
// arriba, que hace lo mismo sin un gesto (VoiceOver no desliza y, en
// /gestione/, el mouse tampoco). Si algo falla, queda lo que había y se avisa.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/requests/application/chef_data_refresh.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Vuelve a leer todo (refreshChefDataProvider) y, si alguna lectura falló,
/// lo avisa en el ScaffoldMessenger de [context].
Future<void> refreshChefData(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final message = AppLocalizations.of(context).inboxRefreshError;
  final ok = await ref.read(refreshChefDataProvider)();
  if (!ok && messenger.mounted) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// «Ricarica»: mientras lee, una rueda en lugar del ícono y deshabilitado (un
/// segundo toque leería todo otra vez).
class ChefRefreshButton extends ConsumerStatefulWidget {
  const ChefRefreshButton({super.key});

  @override
  ConsumerState<ChefRefreshButton> createState() => _ChefRefreshButtonState();
}

class _ChefRefreshButtonState extends ConsumerState<ChefRefreshButton> {
  bool _busy = false;

  Future<void> _reload() async {
    setState(() => _busy = true);
    try {
      await refreshChefData(context, ref);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return IconButton(
      key: const ValueKey('chef-reload'),
      tooltip: l10n.chefReload,
      onPressed: _busy ? null : _reload,
      icon: _busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
    );
  }
}
