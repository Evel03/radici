// Avisos de la ficha de la sesión: «Sesión movida… · Deshacer» (mover es
// reversible), «Sesión cancelada» (cancelar no: se confirma antes) y las
// fallas, con «Riprova» cuando se puede reintentar (un 409 hasPayments lo
// explica la ficha, también si llega en el reintento). La lógica está en
// SessionCommands; acá solo se arma lo que se muestra.
//
// Todo lo que hace falta se toma al crear el objeto: el aviso de «Annulla» o
// «Riprova» puede tocarse cuando la ficha que lo lanzó ya se cerró.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/presentation/availability_actions.dart'
    show errorSnackBarDuration, undoSnackBarDuration;
import 'package:radici/features/sessions/application/move_session_controller.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

class SessionActions {
  SessionActions.of(BuildContext context)
    : _container = ProviderScope.containerOf(context, listen: false),
      _messenger = ScaffoldMessenger.of(context),
      _l10n = AppLocalizations.of(context),
      _formatDate = SessionFormats(context).inText,
      // Con VoiceOver o TalkBack el aviso no se va solo: se cierra con la X.
      _persist = MediaQuery.accessibleNavigationOf(context);

  final ProviderContainer _container;
  final ScaffoldMessengerState _messenger;
  final AppLocalizations _l10n;
  final String Function(CalendarDate date) _formatDate;
  final bool _persist;

  SessionCommands get _commands => _container.read(sessionCommandsProvider);

  /// La sesión se movió: el aviso con «Annulla», que la vuelve a su fecha y
  /// hora de antes.
  void showMoved(MoveOutcome outcome) {
    final moved = outcome.moved;
    _show(
      SnackBar(
        content: Text(
          _l10n.sessionMovedDone(_formatDate(moved.date), moved.start.toHhMm()),
        ),
        duration: undoSnackBarDuration,
        persist: _persist,
        showCloseIcon: _persist,
        action: SnackBarAction(
          label: _l10n.actionUndo,
          onPressed: () => unawaited(_undo(outcome)),
        ),
      ),
    );
  }

  Future<void> _undo(MoveOutcome outcome) async {
    try {
      await _commands.move(
        outcome.moved,
        date: outcome.previousDate,
        start: outcome.previousStart,
      );
      _show(SnackBar(content: Text(_l10n.sessionMoveUndone)));
    } on SessionFailure {
      _failed(_l10n.sessionMoveUndoFailed, retry: () => _undo(outcome));
    }
  }

  /// Cancela [sessions] con [reason] y avisa. Un 409 hasPayments (también el
  /// que llega al tocar «Riprova») va a [onHasPayments], que lo explica con
  /// un diálogo; si devuelve false (la ficha ya no está), se avisa acá. Las
  /// demás fallas se avisan acá, con «Riprova» si se puede reintentar; si
  /// algo cambió en otro dispositivo, se vuelve a leer la ficha [detailId]
  /// (por defecto, la de la primera).
  Future<void> cancel(
    List<CookingSession> sessions, {
    required CancelReason reason,
    required Future<bool> Function(SessionFailure failure) onHasPayments,
    String? detailId,
  }) async {
    try {
      final result = await _commands.cancel(sessions, reason: reason);
      _show(
        SnackBar(
          content: Text(_l10n.cancelSessionDone(result.allCancelled.length)),
        ),
      );
    } on SessionFailure catch (failure) {
      if (failure.kind == SessionFailureKind.hasPayments &&
          await onHasPayments(failure)) {
        return;
      }
      final message = _l10n.sessionFailure(
        failure,
        operation: SessionOperation.cancel,
        formatDate: _formatDate,
      );
      switch (failure.kind) {
        case SessionFailureKind.unavailable:
          _failed(
            message,
            retry: () => cancel(
              sessions,
              reason: reason,
              onHasPayments: onHasPayments,
              detailId: detailId,
            ),
          );
        case SessionFailureKind.hasPayments:
          // No se canceló nada y no cambió nada que la ficha muestre.
          _show(SnackBar(content: Text(message)));
        case _:
          _show(SnackBar(content: Text(message)));
          // Cambió en otro dispositivo: la ficha muestra lo que hay ahora.
          _reload(detailId ?? sessions.first.id);
      }
    }
  }

  void _reload(String sessionId) {
    final provider = sessionDetailProvider(sessionId);
    if (_container.exists(provider)) {
      unawaited(_container.read(provider.notifier).reloadQuietly());
    }
  }

  void _failed(String message, {required Future<Object?> Function() retry}) {
    _show(
      SnackBar(
        content: Text(message),
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
