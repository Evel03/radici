// Fechas de Hoy en el idioma de la interfaz. Solo presentación.
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:radici/core/rome_time.dart';

class TodayFormats {
  TodayFormats(BuildContext context)
    : _locale = Localizations.localeOf(context).toLanguageTag();

  final String _locale;

  /// El día sin el año: «martedì 17 novembre», «martes, 17 de noviembre»,
  /// «Tuesday, November 17».
  String day(CalendarDate date) =>
      DateFormat.MMMMEEEEd(_locale).format(date.toDateTime());
}
