// Textos de la disponibilidad: nombres de los feriados y horario de un día.
// Solo presentación: los textos salen del ARB.
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';
import 'package:radici/l10n/app_localizations.dart';

extension AvailabilityLabels on AppLocalizations {
  String holidayName(ItalianHoliday holiday) => switch (holiday) {
    ItalianHoliday.newYear => holidayNewYear,
    ItalianHoliday.epiphany => holidayEpiphany,
    ItalianHoliday.easterMonday => holidayEasterMonday,
    ItalianHoliday.liberation => holidayLiberation,
    ItalianHoliday.labour => holidayLabour,
    ItalianHoliday.republic => holidayRepublic,
    ItalianHoliday.assumption => holidayAssumption,
    ItalianHoliday.saintAlexander => holidaySaintAlexander,
    ItalianHoliday.saintFrancis => holidaySaintFrancis,
    ItalianHoliday.allSaints => holidayAllSaints,
    ItalianHoliday.immaculate => holidayImmaculate,
    ItalianHoliday.christmas => holidayChristmas,
    ItalianHoliday.stStephen => holidayStStephen,
  };

  /// "Festività: Natale"; el patrono de Bergamo, que no es feriado nacional,
  /// va como "Festività locale: …".
  String holidayLine(ItalianHoliday holiday) => holiday.isNational
      ? availabilityHoliday(holidayName(holiday))
      : availabilityLocalHoliday(holidayName(holiday));
}

/// Horario de un día: "09:00–15:00", o "09:00–12:00, 14:00–18:00" con varias
/// franjas. En 24 horas, como DateFormat.Hm en los tres idiomas de la app.
String formatHours(List<AvailabilityRule> rules) =>
    rules.map((r) => '${_hourMinute(r.start)}–${_hourMinute(r.end)}').join(', ');

String _hourMinute(Duration sinceMidnight) {
  final hours = sinceMidnight.inHours;
  final minutes = sinceMidnight.inMinutes % 60;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}';
}
