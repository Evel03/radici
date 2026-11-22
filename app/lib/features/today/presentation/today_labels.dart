// Fechas y textos de Hoy en el idioma de la interfaz: el día y, en «Menús
// para mandar», qué le falta al menú de cada semana y su límite (el del menú
// o el plazo del presupuesto). Solo presentación: los textos salen del ARB.
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/today/domain/pending_menus.dart';
import 'package:radici/l10n/app_localizations.dart';

class TodayFormats {
  TodayFormats(BuildContext context)
    : _locale = Localizations.localeOf(context).toLanguageTag();

  final String _locale;

  /// El día sin el año: «martedì 17 novembre», «martes, 17 de noviembre»,
  /// «Tuesday, November 17».
  String day(CalendarDate date) =>
      DateFormat.MMMMEEEEd(_locale).format(date.toDateTime());
}

extension TodayLabels on AppLocalizations {
  /// Qué le falta al menú de una semana de «Menús para mandar».
  String pendingMenuState(PendingMenuState state) => switch (state) {
    PendingMenuState.noMenu => todayMenuNoMenu,
    PendingMenuState.notSent => todayMenuNotSent,
    PendingMenuState.changedSinceSent => todayMenuChangedSinceSent,
    PendingMenuState.changesRequested => todayMenuChangesRequested,
    PendingMenuState.sentWithEarlierQuote => todayMenuSentWithOldQuote,
  };

  /// El límite de [menu] ([day] y [time], de Roma): «Límite: …» (o «vencido»
  /// si ya pasó: [passed]); si es el plazo del presupuesto
  /// ([PendingMenu.quoteExpires]), «El presupuesto vence: …».
  String pendingMenuDeadline(
    PendingMenu menu, {
    required String day,
    required String time,
    required bool passed,
  }) => switch ((menu.quoteExpires, passed)) {
    (true, true) => todayMenuQuoteExpired(day, time),
    (true, false) => todayMenuQuoteExpires(day, time),
    (false, true) => todayMenuDeadlinePassed(day, time),
    (false, false) => todayMenuDeadline(day, time),
  };

  /// Lo que oye el lector de pantalla cuando faltan menos de 24 h para el
  /// límite de [menu] (el color y el ícono no se leen).
  String pendingMenuDeadlineNearA11y(
    PendingMenu menu, {
    required String day,
    required String time,
  }) => menu.quoteExpires
      ? todayMenuQuoteExpiresNearA11y(day, time)
      : todayMenuDeadlineNearA11y(day, time);
}
