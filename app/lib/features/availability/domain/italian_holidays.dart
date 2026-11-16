// Feriados que marca la agenda: los nacionales de Italia y el patrono de
// Bergamo. Dart puro, solo con enteros.
//
// Nacionales: los de los arts. 1 y 2 de la legge 27 maggio 1949, n. 260, con
// sus modificaciones. El 4 de octubre (San Francesco d'Assisi, patrono de
// Italia) volvió a ser feriado nacional por la legge 8 ottobre 2025, n. 151
// (GU n. 236 del 10/10/2025): el art. 1, c. 2, lo suma al art. 2 de la
// 260/1949 y el art. 3, c. 3, pone la ley en vigor el 1/1/2026. Verificado en
// normattiva.it el 16/11/2026. Antes de 2026 no se marca.
//
// Local: Sant'Alessandro (26/8), patrono de Bergamo, es feriado solo en el
// municipio. Si el servicio llega a otro municipio, su patrono es otro.
import 'package:radici/core/rome_time.dart';

/// Feriados que muestra la agenda, en el orden del año.
enum ItalianHoliday {
  newYear,
  epiphany,
  easterMonday,
  liberation,
  labour,
  republic,
  assumption,
  saintAlexander,
  saintFrancis,
  allSaints,
  immaculate,
  christmas,
  stStephen;

  /// Feriado en toda Italia. Si no, es solo de Bergamo (su patrono).
  bool get isNational => this != ItalianHoliday.saintAlexander;
}

/// Primer año en que el 4 de octubre es feriado nacional (legge n. 151/2025).
const int saintFrancisHolidayFrom = 2026;

/// Domingo de Pascua de [year] en el calendario gregoriano, con el algoritmo
/// gregoriano anónimo (Meeus/Jones/Butcher).
CalendarDate easterSunday(int year) {
  final a = year % 19;
  final b = year ~/ 100;
  final c = year % 100;
  final d = b ~/ 4;
  final e = b % 4;
  final f = (b + 8) ~/ 25;
  final g = (b - f + 1) ~/ 3;
  final h = (19 * a + b - d - g + 15) % 30;
  final i = c ~/ 4;
  final k = c % 4;
  final l = (32 + 2 * e + 2 * i - h - k) % 7;
  final m = (a + 11 * h + 22 * l) ~/ 451;
  final month = (h + l - 7 * m + 114) ~/ 31;
  final day = (h + l - 7 * m + 114) % 31 + 1;
  return CalendarDate(year, month, day);
}

/// Feriados nacionales de [year], por fecha. Si Pasquetta cae el 25/4, ese
/// día queda como Festa della Liberazione.
Map<CalendarDate, ItalianHoliday> italianHolidays(int year) => {
  CalendarDate(year, 1, 1): ItalianHoliday.newYear,
  CalendarDate(year, 1, 6): ItalianHoliday.epiphany,
  easterSunday(year).addDays(1): ItalianHoliday.easterMonday,
  CalendarDate(year, 4, 25): ItalianHoliday.liberation,
  CalendarDate(year, 5, 1): ItalianHoliday.labour,
  CalendarDate(year, 6, 2): ItalianHoliday.republic,
  CalendarDate(year, 8, 15): ItalianHoliday.assumption,
  if (year >= saintFrancisHolidayFrom)
    CalendarDate(year, 10, 4): ItalianHoliday.saintFrancis,
  CalendarDate(year, 11, 1): ItalianHoliday.allSaints,
  CalendarDate(year, 12, 8): ItalianHoliday.immaculate,
  CalendarDate(year, 12, 25): ItalianHoliday.christmas,
  CalendarDate(year, 12, 26): ItalianHoliday.stStephen,
};

/// Feriados de [year] en Bergamo: los nacionales y el patrono (26/8).
Map<CalendarDate, ItalianHoliday> bergamoHolidays(int year) => {
  ...italianHolidays(year),
  CalendarDate(year, 8, 26): ItalianHoliday.saintAlexander,
};

/// El feriado de [date] en Bergamo, o null si es un día común.
ItalianHoliday? bergamoHolidayOn(CalendarDate date) =>
    bergamoHolidays(date.year)[date];
