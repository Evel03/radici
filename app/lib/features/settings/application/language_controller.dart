// Idioma de la interfaz. Con sesión manda el perfil (`profiles.locale`), que
// se cambia en Impostazioni; sin sesión, el dispositivo (italiano si el suyo
// no es it, es ni en).
//
// Arranque en frío: mientras se lee la cuenta se usa el idioma guardado en el
// dispositivo para ese mismo usuario (LanguageCache); al llegar el perfil, lo
// confirma o lo corrige. Al salir se borra.
import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/app_language.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/settings/data/language_cache.dart';

/// Idioma elegido por quien tiene la sesión, o null: manda el dispositivo.
final languageControllerProvider =
    NotifierProvider<LanguageController, AppLanguage?>(LanguageController.new);

/// Para `MaterialApp.locale`: null sigue al dispositivo.
final appLocaleProvider = Provider<Locale?>(
  (ref) => ref.watch(languageControllerProvider)?.locale,
);

class LanguageController extends Notifier<AppLanguage?> {
  /// Último idioma que el servidor tiene para el usuario actual: el del perfil
  /// al cargar la cuenta o el último guardado con éxito. Si un cambio no se
  /// puede guardar, la interfaz vuelve a este.
  AppLanguage? _confirmed;

  /// Guardados en curso, en fila: si se elige otro idioma antes de que
  /// termine el anterior, al servidor llega último el último elegido.
  Future<void> _saving = Future<void>.value();

  LanguageCache get _cache => ref.read(languageCacheProvider);

  @override
  AppLanguage? build() {
    ref.listen(sessionControllerProvider, _onSessionChanged);

    final session = ref.read(sessionControllerProvider);
    final user = sessionUserOf(session);
    if (user == null) {
      // También si la sesión guardada venció: lo guardado ya no corresponde.
      if (_cache.read() != null) unawaited(_cache.clear());
      return null;
    }
    final profile = _profileLanguageOf(session);
    if (profile != null) {
      _confirmed = profile;
      _remember(user.id, profile);
      return profile;
    }
    return _cachedFor(user.id);
  }

  /// Cambia el idioma: se ve enseguida y se guarda en el perfil. Si no se
  /// puede guardar, vuelve al último confirmado y relanza [AccountFailure].
  /// Sin una cuenta cargada no hace nada.
  Future<void> setLanguage(AppLanguage language) async {
    final session = ref.read(sessionControllerProvider);
    final user = sessionUserOf(session);
    if (user == null || !_isLoaded(session) || language == state) return;

    state = language;
    _remember(user.id, language);

    final repository = ref.read(accountRepositoryProvider);
    final save = _saving.then(
      (_) => repository.updateLanguage(userId: user.id, language: language),
    );
    // La fila sigue aunque un guardado falle.
    _saving = save.then<void>((_) {}, onError: (Object _) {});
    try {
      await save;
    } on AccountFailure {
      if (ref.mounted && _isCurrentUser(user.id) && state == language) {
        state = _confirmed;
        _remember(user.id, _confirmed);
      }
      rethrow;
    }
    if (ref.mounted && _isCurrentUser(user.id)) _confirmed = language;
  }

  void _onSessionChanged(SessionState? previous, SessionState next) {
    final user = sessionUserOf(next);
    if (user == null) {
      _confirmed = null;
      state = null;
      unawaited(_cache.clear());
      return;
    }

    final sameUser = previous != null && sessionUserOf(previous)?.id == user.id;
    final wasLoaded = previous != null && sameUser && _isLoaded(previous);
    final profile = _profileLanguageOf(next);
    if (profile != null && !wasLoaded) {
      // La cuenta se acaba de cargar: manda el perfil.
      _confirmed = profile;
      state = profile;
      _remember(user.id, profile);
    } else if (!sameUser) {
      // Otro usuario: nada de lo anterior le corresponde.
      _confirmed = null;
      state = _cachedFor(user.id);
    }
  }

  AppLanguage? _cachedFor(String userId) {
    final cached = _cache.read();
    return cached != null && cached.userId == userId ? cached.language : null;
  }

  void _remember(String userId, AppLanguage? language) => unawaited(
    language == null
        ? _cache.clear()
        : _cache.write((userId: userId, language: language)),
  );

  bool _isCurrentUser(String userId) =>
      sessionUserOf(ref.read(sessionControllerProvider))?.id == userId;

  static bool _isLoaded(SessionState session) =>
      session is ChefSession || session is ClientSession;

  static AppLanguage? _profileLanguageOf(SessionState session) =>
      switch (session) {
        ChefSession(:final language) ||
        ClientSession(:final language) => language,
        _ => null,
      };
}
