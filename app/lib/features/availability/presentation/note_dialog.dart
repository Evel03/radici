// Nota privada de un día bloqueado ("ferie", "dal medico"…): solo la ve
// Evelyn. Va arriba de la pantalla para que el teclado de iOS no la tape
// (Flutter web no siempre sabe cuánto ocupa el teclado: probarlo en el iPhone).
import 'package:flutter/material.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Pide la nota de un día bloqueado. Devuelve el texto escrito (vacío = sin
/// nota), o null si se canceló.
Future<String?> showNoteDialog(BuildContext context, {String? initial}) =>
    showDialog<String>(
      context: context,
      builder: (_) => NoteDialog(initial: initial),
    );

class NoteDialog extends StatefulWidget {
  const NoteDialog({super.key, this.initial});

  /// La nota actual, si tiene.
  final String? initial;

  @override
  State<NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<NoteDialog> {
  late final TextEditingController _note = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(_note.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      key: const ValueKey('availability-note-dialog'),
      alignment: Alignment.topCenter,
      title: Text(
        widget.initial == null ? l10n.availabilityAddNote : l10n.availabilityEditNote,
      ),
      content: TextField(
        key: const ValueKey('availability-note-field'),
        controller: _note,
        autofocus: true,
        maxLength: maxNoteLength,
        minLines: 1,
        maxLines: 3,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(
          labelText: l10n.availabilityNoteLabel,
          hintText: l10n.availabilityNoteHint,
          // Fuera de la pista: se ve siempre, también sin foco.
          helperText: l10n.availabilityNoteHelper,
          helperMaxLines: 2,
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('availability-note-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(
          key: const ValueKey('availability-note-save'),
          onPressed: _save,
          child: Text(l10n.actionSave),
        ),
      ],
    );
  }
}
