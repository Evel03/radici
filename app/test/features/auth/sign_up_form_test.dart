// «Crear cuenta»: las reglas del formulario (las mismas que la base, 31_account_details), lo que se manda a
// save_account_details y la versión de la privacy (la de la web).
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/auth/domain/password_rules.dart';
import 'package:radici/features/auth/domain/sign_up_form.dart';

import '../../support/repo_files.dart';

final DateTime _today = DateTime(2026, 11, 27);

SignUpForm _valid({
  String phone = '340 123 4567',
  DateTime? birth,
  String password = 'Bergamo2027',
  String? repeat,
  String street = '',
  String city = '',
  String postal = '',
  String notes = '',
}) => SignUpForm(
  firstName: ' Anna ',
  lastName: 'Rota',
  phone: phone,
  birthDate: birth ?? DateTime(1990, 5, 17),
  email: ' Anna@Example.COM ',
  password: password,
  repeat: repeat ?? password,
  privacyAccepted: true,
  street: street,
  city: city,
  postalCode: postal,
  notes: notes,
);

void main() {
  test('la versión de la privacy es la vigente de la web (CONSENT_VERSION de public_request.ts)', () {
    final source = findRepoFile('supabase/functions/_shared/public_request.ts')
        .readAsStringSync();
    final version = RegExp(
      r'export const CONSENT_VERSION = "(\d{4}-\d{2}-\d{2})";',
    ).firstMatch(source)?.group(1);
    expect(accountPrivacyVersion, version);
  });

  test('un formulario completo no tiene problemas', () {
    expect(signUpProblems(_valid(), _today), isEmpty);
  });

  test('obligatorios: nombre, apellido, teléfono, nacimiento, email, contraseña dos veces y la privacy', () {
    final problems = signUpProblems(
      const SignUpForm(firstName: '  ', email: 'no-es-email'),
      _today,
    );
    expect(problems.keys.toSet(), {
      SignUpField.firstName,
      SignUpField.lastName,
      SignUpField.phone,
      SignUpField.birthDate,
      SignUpField.email,
      SignUpField.password,
      SignUpField.privacy,
    });
    expect(problems[SignUpField.password], PasswordProblem.tooShort);
  });

  test('la contraseña: primero la regla, después que las dos coincidan', () {
    expect(
      signUpProblems(
        _valid(password: 'corta1', repeat: 'otra'),
        _today,
      )[SignUpField.password],
      PasswordProblem.tooShort,
    );
    expect(
      signUpProblems(
        _valid(password: 'sololetrasaqui', repeat: 'x'),
        _today,
      )[SignUpField.password],
      PasswordProblem.lettersDigits,
    );
    expect(signUpProblems(_valid(repeat: 'Bergamo2072'), _today).keys, [
      SignUpField.repeat,
    ]);
  });

  test(
    'teléfono: un móvil italiano sin prefijo vale (se normaliza); uno raro, no',
    () {
      expect(
        signUpProblems(_valid(phone: '+34 600 11 22 33'), _today),
        isEmpty,
      );
      expect(signUpProblems(_valid(phone: '1234'), _today).keys, [
        SignUpField.phone,
      ]);
      expect(accountDetailsPayload(_valid())['phone'], '+393401234567');
    },
  );

  test('18 años cumplidos hoy (en Roma): el día justo sí, el día antes no; también el 29 de febrero', () {
    expect(
      signUpProblems(_valid(birth: DateTime(2008, 11, 27)), _today),
      isEmpty,
    );
    expect(signUpProblems(_valid(birth: DateTime(2008, 11, 28)), _today).keys, [
      SignUpField.underage,
    ]);
    expect(isAdult(DateTime(2008, 2, 29), DateTime(2026, 2, 28)), isFalse);
    expect(isAdult(DateTime(2008, 2, 29), DateTime(2026, 3, 1)), isTrue);
    expect(signUpProblems(_valid(birth: DateTime(1899, 12, 31)), _today).keys, [
      SignUpField.birthDate,
    ]);
  });

  test('la dirección: vacía, o calle, ciudad y código postal juntos', () {
    expect(signUpProblems(_valid(), _today), isEmpty);
    expect(
      signUpProblems(
        _valid(street: 'Via Pignolo 12', city: 'Bergamo', postal: '24121'),
        _today,
      ),
      isEmpty,
    );
    expect(signUpProblems(_valid(city: 'Bergamo'), _today).keys.toSet(), {
      SignUpField.street,
      SignUpField.postalCode,
    });
    expect(
      signUpProblems(
        _valid(street: 'Via Pignolo 12', city: 'Bergamo', postal: '2'),
        _today,
      ).keys,
      [SignUpField.postalCode],
    );
    expect(
      signUpProblems(
        _valid(
          street: 'Via Pignolo 12',
          city: 'Bergamo',
          postal: '24121',
          notes: 'x' * 201,
        ),
        _today,
      ).keys,
      [SignUpField.notes],
    );
  });

  test('lo que va a save_account_details: las claves de la base, listas ordenadas y sin la dirección vacía', () {
    final form = SignUpForm(
      firstName: ' Anna ',
      lastName: ' Rota ',
      phone: '3401234567',
      birthDate: DateTime(1990, 5, 7),
      email: 'anna@example.com',
      password: 'Bergamo2027',
      repeat: 'Bergamo2027',
      privacyAccepted: true,
      street: ' Via Pignolo 12 ',
      city: 'Bergamo',
      postalCode: 'ab12 3c',
      season: Season.autumn,
      heardFrom: HeardFrom.wordOfMouth,
      interests: {Interest.events, Interest.weekly},
      days: {5, 1, 3},
      household: HouseholdSize.fivePlus,
    );
    expect(accountDetailsPayload(form), {
      'first_name': 'Anna',
      'last_name': 'Rota',
      'phone': '+393401234567',
      'birth_date': '1990-05-07',
      'address_street': 'Via Pignolo 12',
      'address_city': 'Bergamo',
      'address_postal_code': 'AB12 3C',
      'address_notes': null,
      'favorite_season': 'autumn',
      'heard_from': 'word_of_mouth',
      'interests': ['weekly', 'events'],
      'preferred_days': [1, 3, 5],
      'household_size': '5+',
      'privacy_version': accountPrivacyVersion,
    });
    final minimal = accountDetailsPayload(_valid());
    for (final key in [
      'address_street',
      'address_city',
      'address_postal_code',
      'address_notes',
      'favorite_season',
      'heard_from',
      'interests',
      'preferred_days',
      'household_size',
    ]) {
      expect(minimal[key], isNull, reason: key);
    }
    expect(
      minimal.containsKey('email'),
      isFalse,
      reason: 'el email es de Auth, no va a la tabla',
    );
    expect(minimal.containsKey('password'), isFalse);
  });

  test('los campos que rechaza la base (el detalle del error) en las claves de la pantalla', () {
    expect(
      fieldsFromDetail('first_name,phone,underage,address_postal_code,otro'),
      {
        SignUpField.firstName,
        SignUpField.phone,
        SignUpField.underage,
        SignUpField.postalCode,
      },
    );
    expect(fieldsFromDetail(null), isEmpty);
  });

  test('la fecha escrita: día/mes/año (con / . o -) o año-mes-día; nada que no exista', () {
    expect(parseBirthDate('17/05/1990'), DateTime(1990, 5, 17));
    expect(parseBirthDate(' 7.5.1990 '), DateTime(1990, 5, 7));
    expect(parseBirthDate('1990-05-17'), DateTime(1990, 5, 17));
    for (final bad in ['31/02/1990', '17/13/1990', '1990/05/17', 'ayer', '']) {
      expect(parseBirthDate(bad), isNull, reason: bad);
    }
    expect(formatBirthDate(DateTime(1990, 5, 7)), '07/05/1990');
  });

  test('toString no lleva datos ni la contraseña', () {
    expect(_valid().toString(), isNot(contains('Anna')));
    expect(_valid().toString(), isNot(contains('Bergamo2027')));
  });
}
