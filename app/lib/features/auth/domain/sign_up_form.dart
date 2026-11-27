// «Crear cuenta» (pedido de Nicolas del 27/11/2026, contrato docs/contracts/auth.md §18 y §19): lo que la clienta carga
// en la app, sus reglas y lo que se manda a public.save_account_details. Dart puro: las mismas reglas que la base
// (la base decide; acá se avisa enseguida, campo por campo).
import 'package:radici/core/phone.dart';
import 'package:radici/features/auth/domain/password_rules.dart';

/// La versión de la privacy que acepta quien crea la cuenta: la vigente de la web (CONSENT_VERSION de
/// supabase/functions/_shared/public_request.ts; test/features/auth/sign_up_form_test.dart las compara).
const String accountPrivacyVersion = '2026-11-28';

/// Temporada preferida (account_details.favorite_season).
enum Season { spring, summer, autumn, winter, any }

/// Cómo nos conoció (account_details.heard_from).
enum HeardFrom {
  instagram('instagram'),
  google('google'),
  wordOfMouth('word_of_mouth'),
  other('other');

  const HeardFrom(this.code);
  final String code;
}

/// Qué le interesa (account_details.interests).
enum Interest { weekly, dinners, events }

/// Para cuántas personas (account_details.household_size).
enum HouseholdSize {
  oneTwo('1-2'),
  threeFour('3-4'),
  fivePlus('5+');

  const HouseholdSize(this.code);
  final String code;
}

/// Los días que puede elegir (lunes a viernes: el horario de Evelyn), con DateTime.monday = 1.
const List<int> signUpWeekdays = [
  DateTime.monday,
  DateTime.tuesday,
  DateTime.wednesday,
  DateTime.thursday,
  DateTime.friday,
];

/// Un campo con un problema (las claves de error de la pantalla).
enum SignUpField {
  firstName,
  lastName,
  phone,
  birthDate,
  underage,
  email,
  password,
  repeat,
  privacy,
  street,
  city,
  postalCode,
  notes,
}

final RegExp _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
final RegExp _postalCode = RegExp(
  r'^[0-9A-Za-z][0-9A-Za-z -]{1,8}[0-9A-Za-z]$',
);

/// Lo que se escribió en «Crear cuenta». La contraseña vive solo en memoria mientras dura el alta.
class SignUpForm {
  const SignUpForm({
    this.firstName = '',
    this.lastName = '',
    this.phone = '',
    this.birthDate,
    this.email = '',
    this.password = '',
    this.repeat = '',
    this.privacyAccepted = false,
    this.street = '',
    this.city = '',
    this.postalCode = '',
    this.notes = '',
    this.season,
    this.heardFrom,
    this.interests = const {},
    this.days = const {},
    this.household,
  });

  final String firstName;
  final String lastName;
  final String phone;
  final DateTime? birthDate;
  final String email;
  final String password;
  final String repeat;
  final bool privacyAccepted;
  final String street;
  final String city;
  final String postalCode;
  final String notes;
  final Season? season;
  final HeardFrom? heardFrom;
  final Set<Interest> interests;
  final Set<int> days;
  final HouseholdSize? household;

  /// El email como lo usa Auth: sin espacios y en minúsculas.
  String get normalizedEmail => email.trim().toLowerCase();

  bool get _hasAddress =>
      [street, city, postalCode, notes].any((value) => value.trim().isNotEmpty);

  // Nunca se loguean datos personales ni la contraseña.
  @override
  String toString() => 'SignUpForm(…)';
}

/// Los 18 años cumplidos el día [today] (en Roma).
bool isAdult(DateTime birthDate, DateTime today) {
  final eighteenth = DateTime(
    birthDate.year + 18,
    birthDate.month,
    birthDate.day,
  );
  final day = DateTime(today.year, today.month, today.day);
  // 29 de febrero: DateTime lo pasa al 1 de marzo de un año no bisiesto (como la base, que suma 18 años).
  return !eighteenth.isAfter(day);
}

/// Los problemas del formulario, campo por campo (vacío: se puede mandar). [today] es el día en Roma.
Map<SignUpField, Object> signUpProblems(SignUpForm form, DateTime today) {
  final problems = <SignUpField, Object>{};
  final first = form.firstName.trim();
  final last = form.lastName.trim();
  if (first.isEmpty || first.length > 60) {
    problems[SignUpField.firstName] = true;
  }
  if (last.isEmpty || last.length > 80) problems[SignUpField.lastName] = true;
  if (normalizePhone(form.phone) == null) problems[SignUpField.phone] = true;
  final birth = form.birthDate;
  if (birth == null || birth.isBefore(DateTime(1900))) {
    problems[SignUpField.birthDate] = true;
  } else if (!isAdult(birth, today)) {
    problems[SignUpField.underage] = true;
  }
  final email = form.normalizedEmail;
  if (email.length > 254 || !_email.hasMatch(email)) {
    problems[SignUpField.email] = true;
  }
  final password = passwordProblem(form.password);
  if (password != null) {
    problems[SignUpField.password] = password;
  } else if (form.repeat != form.password) {
    problems[SignUpField.repeat] = true;
  }
  if (!form.privacyAccepted) problems[SignUpField.privacy] = true;
  if (form._hasAddress) {
    final street = form.street.trim();
    final city = form.city.trim();
    if (street.length < 3 || street.length > 120) {
      problems[SignUpField.street] = true;
    }
    if (city.length < 2 || city.length > 80) problems[SignUpField.city] = true;
    if (!_postalCode.hasMatch(form.postalCode.trim())) {
      problems[SignUpField.postalCode] = true;
    }
    if (form.notes.trim().length > 200) problems[SignUpField.notes] = true;
  }
  return problems;
}

String _date(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// Lo que va a public.save_account_details (las claves de la base). Solo con un formulario sin problemas.
Map<String, Object?> accountDetailsPayload(SignUpForm form) {
  String? text(String value) => value.trim().isEmpty ? null : value.trim();
  final address = form._hasAddress;
  return {
    'first_name': form.firstName.trim(),
    'last_name': form.lastName.trim(),
    'phone': normalizePhone(form.phone),
    'birth_date': _date(form.birthDate!),
    'address_street': address ? text(form.street) : null,
    'address_city': address ? text(form.city) : null,
    'address_postal_code': address
        ? text(form.postalCode)?.toUpperCase()
        : null,
    'address_notes': address ? text(form.notes) : null,
    'favorite_season': form.season?.name,
    'heard_from': form.heardFrom?.code,
    'interests': form.interests.isEmpty
        ? null
        : [
            for (final interest in Interest.values)
              if (form.interests.contains(interest)) interest.name,
          ],
    'preferred_days': form.days.isEmpty
        ? null
        : [
            for (final day in signUpWeekdays)
              if (form.days.contains(day)) day,
          ],
    'household_size': form.household?.code,
    'privacy_version': accountPrivacyVersion,
  };
}

/// Los campos que la base rechazó (el detalle de 22023 invalid_account_details), en las claves de la pantalla.
Set<SignUpField> fieldsFromDetail(String? detail) {
  const byColumn = {
    'first_name': SignUpField.firstName,
    'last_name': SignUpField.lastName,
    'phone': SignUpField.phone,
    'birth_date': SignUpField.birthDate,
    'underage': SignUpField.underage,
    'address_street': SignUpField.street,
    'address_city': SignUpField.city,
    'address_postal_code': SignUpField.postalCode,
    'address_notes': SignUpField.notes,
  };
  return {
    for (final column in (detail ?? '').split(',')) ?byColumn[column.trim()],
  };
}

final RegExp _dmy = RegExp(r'^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4})$');
final RegExp _ymd = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$');

/// Una fecha escrita a mano: día/mes/año (con / . o -) o año-mes-día. Null si no es una fecha real.
DateTime? parseBirthDate(String raw) {
  final text = raw.trim();
  int day;
  int month;
  int year;
  if (_dmy.firstMatch(text) case final m?) {
    day = int.parse(m.group(1)!);
    month = int.parse(m.group(2)!);
    year = int.parse(m.group(3)!);
  } else if (_ymd.firstMatch(text) case final m?) {
    year = int.parse(m.group(1)!);
    month = int.parse(m.group(2)!);
    day = int.parse(m.group(3)!);
  } else {
    return null;
  }
  final date = DateTime(year, month, day);
  // DateTime pasa el 31/02 al 3 de marzo: no es una fecha real.
  if (date.year != year || date.month != month || date.day != day) return null;
  return date;
}

/// La fecha como se muestra en el campo: dd/mm/aaaa.
String formatBirthDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
