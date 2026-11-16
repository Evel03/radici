// Bloquear y desbloquear días desde la agenda, con el aviso de «Annulla»
// (deshacer) o, si falla, el de error con «Riprova». Lo usan la tarjeta del
// día, la vista de semana y el botón «Blocca giorni». La lógica (optimista y
// con vuelta atrás) está en AvailabilityController.
//
// Todo lo que hace falta se toma al crear el objeto: el aviso de «Riprova» o
// «Annulla» puede tocarse cuando la tarjeta que lo lanzó ya no está.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/application/availability_controller.dart';
import 'package:radici/features/availability/data/availability_repository.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Cuánto queda a la vista el aviso con «Annulla».
const Duration undoSnackBarDuration = Duration(seconds: 6);

/// Cuánto queda a la vista un aviso de error con «Riprova».
const Duration errorSnackBarDuration = Duration(seconds: 10);

class AvailabilityActions {
  /// [context] tiene que estar dentro del ScaffoldMessenger de la agenda.
  AvailabilityActions.of(BuildContext context)
    : _container = ProviderScope.containerOf(context, listen: false),
      _messenger = ScaffoldMessenger.of(context),
      _l10n = AppLocalizations.of(context),
      // Con VoiceOver o TalkBack el aviso no se va solo: se cierra con la X.
      _persist = MediaQuery.accessibleNavigationOf(context);

  final ProviderContainer _container;
  final ScaffoldMessengerState _messenger;
  final AppLocalizations _l10n;
  final bool _persist;

  AvailabilityController get _controller =>
      _container.read(availabilityControllerProvider.notifier);

  /// Bloquea [dates] con [note] y avisa.
  Future<void> block(List<CalendarDate> dates, {String? note}) async {
    try {
      final created = await _controller.block(dates, note: note);
      _done(
        _l10n.availabilityBlockedDone(dates.length),
        undo: created.isEmpty
            ? null
            : () => _attempt(() => _controller.undoBlock(created)),
      );
    } on AvailabilityFailure {
      _failed(() => block(dates, note: note));
    }
  }

  /// Desbloquea [dates] y avisa.
  Future<void> unblock(List<CalendarDate> dates) async {
    try {
      final removed = await _controller.unblock(dates);
      if (removed.isEmpty) return;
      _done(
        _l10n.availabilityUnblockedDone(removed.length),
        undo: () => _attempt(() => _controller.undoUnblock(removed)),
      );
    } on AvailabilityFailure {
      _failed(() => unblock(dates));
    }
  }

  /// Guarda la nota de [date] (vacía = sin nota). Solo avisa si falla.
  Future<void> setNote(CalendarDate date, String? note) async {
    try {
      await _controller.setNote(date, note);
    } on AvailabilityFailure {
      _failed(() => setNote(date, note));
    }
  }

  /// «Annulla»: si falla, avisa con «Riprova».
  Future<void> _attempt(Future<Object?> Function() action) async {
    try {
      await action();
    } on AvailabilityFailure {
      _failed(() => _attempt(action));
    }
  }

  void _done(String message, {Future<void> Function()? undo}) {
    _show(
      SnackBar(
        content: Text(message),
        duration: undoSnackBarDuration,
        persist: _persist && undo != null,
        showCloseIcon: _persist && undo != null,
        action: undo == null
            ? null
            : SnackBarAction(
                label: _l10n.actionUndo,
                onPressed: () => unawaited(undo()),
              ),
      ),
    );
  }

  void _failed(Future<void> Function() retry) {
    _show(
      SnackBar(
        content: Text(_l10n.availabilitySaveFailed),
        duration: errorSnackBarDuration,
        persist: _persist,
        showCloseIcon: _persist,
        action: SnackBarAction(
          label: _l10n.actionRetry,
          onPressed: () => unawaited(retry()),
        ),
      ),
    );
  }

  /// Un aviso a la vez: el nuevo reemplaza al anterior.
  void _show(SnackBar snackBar) {
    if (!_messenger.mounted) return;
    _messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(snackBar);
  }
}
