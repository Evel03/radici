// Textos de los valores de un pedido (tipo, estado, franja, alérgenos…) y
// formatos de fecha y hora de Roma. Solo presentación: los textos salen del ARB.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/l10n/app_localizations.dart';

extension RequestLabels on AppLocalizations {
  String requestType(RequestType type) => switch (type) {
    RequestType.week => requestTypeWeek,
    RequestType.extra => requestTypeExtra,
    RequestType.change => requestTypeChange,
  };

  /// Estado como lo ve la cocinera: un pedido nuevo ya abierto es "Vista".
  String requestStatus(ChefRequest request) => switch (request.status) {
    RequestStatus.newRequest =>
      request.seenAt == null ? requestStatusNew : requestStatusSeen,
    RequestStatus.quoted => requestStatusQuoted,
    RequestStatus.accepted => requestStatusAccepted,
    RequestStatus.declined => requestStatusDeclined,
    RequestStatus.rejected => requestStatusRejected,
    RequestStatus.expired => requestStatusExpired,
    RequestStatus.resolved => requestStatusResolved,
  };

  String slot(PreferredSlot slot) => switch (slot) {
    PreferredSlot.morning => slotMorning,
    PreferredSlot.afternoon => slotAfternoon,
  };

  /// "Pranzo", "Cena" o "Pranzo e cena".
  String meals(List<Meal> meals) {
    final lunch = meals.contains(Meal.lunch);
    final dinner = meals.contains(Meal.dinner);
    if (lunch && dinner) return mealLunchAndDinner;
    if (lunch) return mealLunch;
    return mealDinner;
  }

  String allergen(Allergen allergen) => switch (allergen) {
    Allergen.gluten => allergenGluten,
    Allergen.crustaceans => allergenCrustaceans,
    Allergen.eggs => allergenEggs,
    Allergen.fish => allergenFish,
    Allergen.peanuts => allergenPeanuts,
    Allergen.soy => allergenSoy,
    Allergen.milk => allergenMilk,
    Allergen.nuts => allergenNuts,
    Allergen.celery => allergenCelery,
    Allergen.mustard => allergenMustard,
    Allergen.sesame => allergenSesame,
    Allergen.sulphites => allergenSulphites,
    Allergen.lupin => allergenLupin,
    Allergen.molluscs => allergenMolluscs,
  };

  String diet(Diet diet) => switch (diet) {
    Diet.vegetarian => dietVegetarian,
    Diet.vegan => dietVegan,
  };

  String language(ClientLocale locale) => switch (locale) {
    ClientLocale.it => languageIt,
    ClientLocale.es => languageEs,
    ClientLocale.en => languageEn,
  };

  /// Resumen de una línea: "Settimana di pasti · 4 settimane · 4 persone ·
  /// 5 giorni · Cena". Las semanas, solo si son más de una.
  String requestSummary(ChefRequest request) => [
    requestType(request.type),
    if (request.weeks > 1) requestWeeksCount(request.weeks),
    if (request.people case final people?) requestPeopleCount(people),
    if (request.days case final days?) requestDaysCount(days),
    if (request.meals.isNotEmpty) meals(request.meals),
  ].join(' · ');

  /// Título del menú elegido: cuántos platos de cuántos días ("Menù scelto
  /// dal cliente (2 di 5 giorni)"). Si el pedido no dice los días, solo los
  /// platos ("(2 piatti)"): no se inventan días.
  String menuTitle(ChefRequest request) => switch (request.days) {
    final days? => detailMenuTitle(days, request.wishes.length),
    null => detailMenuTitleNoDays(request.wishes.length),
  };
}

/// Formatos de fecha y hora en el idioma de la interfaz. Las horas se
/// muestran siempre en hora de Roma.
class RequestFormats {
  RequestFormats(BuildContext context)
    : _locale = Localizations.localeOf(context).toLanguageTag();

  final String _locale;

  /// "mar 20 ott" (fecha corta con día de la semana).
  String shortDate(CalendarDate date) =>
      DateFormat.MMMEd(_locale).format(date.toDateTime());

  /// "martedì 20 ottobre 2026".
  String longDate(CalendarDate date) =>
      DateFormat.yMMMMEEEEd(_locale).format(date.toDateTime());

  /// "ottobre 2026".
  String monthTitle(CalendarDate date) =>
      DateFormat.yMMMM(_locale).format(date.toDateTime());

  /// "20 ott".
  String dayMonth(CalendarDate date) =>
      DateFormat.MMMd(_locale).format(date.toDateTime());

  /// "20 ott 2026".
  String dayMonthYear(CalendarDate date) =>
      DateFormat.yMMMd(_locale).format(date.toDateTime());

  /// "lun" (nombre corto del día).
  String weekdayShort(CalendarDate date) =>
      DateFormat.E(_locale).format(date.toDateTime());

  /// Fecha numérica de un instante, en hora de Roma ("19/10/2026").
  String instantDate(DateTime instant) =>
      DateFormat.yMd(_locale).format(romeWallClock(instant));

  /// Hora de un instante, en hora de Roma ("14:32").
  String instantTime(DateTime instant) =>
      DateFormat.Hm(_locale).format(romeWallClock(instant));
}
