// Agregar (o corregir) la dirección de la ficha de la clienta desde la ficha
// de la sesión: el formulario web no la pide, y sin ella «Cómo llegar» lleva,
// como mucho, hasta la zona. Se guarda con la RLS en clients.address
// (SessionCommands.updateAddress) y vale para todas sus sesiones. Si falla, el
// diálogo queda abierto con lo escrito. El campo tiene letra de 16 px (con
// menos, iOS agranda la página) y autofillHints: null (sin pasarlo, en
// /gestione/ sale con autocomplete="on" y Safari podría ofrecer la dirección
// de Evelyn). La dirección no se loguea.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Abre el diálogo para la clienta de [session] y, si se guardó, lo avisa en
/// el ScaffoldMessenger de [context].
Future<void> editClientAddress(
  BuildContext context,
  CookingSession session,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final message = AppLocalizations.of(context).sessionAddressSaved;
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => ClientAddressDialog(session: session),
  );
  if (saved == true && messenger.mounted) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

class ClientAddressDialog extends ConsumerStatefulWidget {
  const ClientAddressDialog({super.key, required this.session});

  final CookingSession session;

  @override
  ConsumerState<ClientAddressDialog> createState() =>
      _ClientAddressDialogState();
}

class _ClientAddressDialogState extends ConsumerState<ClientAddressDialog> {
  late final TextEditingController _address = TextEditingController(
    text: widget.session.address ?? '',
  );
  bool _saving = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // El botón se habilita con lo escrito; una falla anterior ya no vale.
    _address.addListener(() => setState(() => _failed = false));
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  /// Lo escrito, como se guarda; null si está vacío.
  String? get _value => normalizeClientAddress(_address.text);

  bool get _canSave {
    final value = _value;
    return !_saving && value != null && value != widget.session.address;
  }

  Future<void> _save() async {
    final value = _value;
    if (!_canSave || value == null) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await ref
          .read(sessionCommandsProvider)
          .updateAddress(widget.session, value);
      if (mounted) Navigator.of(context).pop(true);
    } on SessionFailure {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final adding = widget.session.address == null;

    // Como en el diálogo del rango a bloquear: el alto del teclado se
    // descuenta acá, en el mismo cuadro en que llega, y el campo enfocado
    // queda a la vista.
    return PopScope(
      // Mientras guarda no se cierra: el resultado llega igual.
      canPop: !_saving,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: MediaQuery.removeViewInsets(
          context: context,
          removeBottom: true,
          child: AlertDialog(
            key: const ValueKey('client-address-dialog'),
            alignment: Alignment.topCenter,
            scrollable: true,
            title: Text(adding ? l10n.sessionAddAddress : l10n.sessionEditAddress),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('client-address-field'),
                  controller: _address,
                  autofocus: true,
                  autofillHints: null,
                  enabled: !_saving,
                  maxLength: maxClientAddressLength,
                  minLines: 1,
                  maxLines: 3,
                  keyboardType: TextInputType.streetAddress,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _save(),
                  decoration: InputDecoration(
                    labelText: l10n.sessionAddress,
                    hintText: l10n.sessionAddressHint,
                    helperText: l10n.sessionAddressHelper,
                    // Al lado va el contador: a 375 px son tres renglones.
                    helperMaxLines: 3,
                  ),
                ),
                if (_failed) ...[
                  const SizedBox(height: 8),
                  // liveRegion: el lector de pantalla la anuncia al aparecer.
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      l10n.sessionAddressFailed,
                      key: const ValueKey('client-address-failed'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            actionsOverflowButtonSpacing: 8,
            actions: [
              TextButton(
                key: const ValueKey('client-address-cancel'),
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context).pop(false),
                child: Text(l10n.actionCancel),
              ),
              FilledButton(
                key: const ValueKey('client-address-save'),
                onPressed: _canSave ? _save : null,
                child: _saving
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Flexible(child: Text(l10n.actionSave)),
                        ],
                      )
                    : Text(l10n.actionSave),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
