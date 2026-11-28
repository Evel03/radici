// Los campos de los datos de la cuenta (auth.md §18), compartidos por «Crear cuenta» (§19) y «Mi cuenta» (§20): los
// datos personales (nombre, apellido, teléfono, nacimiento) y lo demás (dirección y las respuestas opcionales). Lo
// escrito vive en un [AccountDetailsDraft]; los problemas vienen de las reglas del dominio (sign_up_form.dart).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:radici/features/auth/domain/sign_up_form.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Lo que se escribe en los campos de los datos de la cuenta.
class AccountDetailsDraft extends ChangeNotifier {
  final firstName = TextEditingController();
  final lastName = TextEditingController();
  final phone = TextEditingController();
  final birth = TextEditingController();
  final street = TextEditingController();
  final city = TextEditingController();
  final postal = TextEditingController();
  final notes = TextEditingController();
  Season? season;
  HeardFrom? heardFrom;
  final Set<Interest> interests = {};
  final Set<int> days = {};
  HouseholdSize? household;

  void update(VoidCallback change) {
    change();
    notifyListeners();
  }

  /// Los datos guardados (una fila de account_details), para corregirlos.
  void fill(Map<String, Object?> row) {
    String text(String key) => row[key] is String ? row[key]! as String : '';
    firstName.text = text('first_name');
    lastName.text = text('last_name');
    phone.text = text('phone');
    final birthDate = DateTime.tryParse(text('birth_date'));
    birth.text = birthDate == null ? '' : formatBirthDate(birthDate);
    street.text = text('address_street');
    city.text = text('address_city');
    postal.text = text('address_postal_code');
    notes.text = text('address_notes');
    season = Season.values.where((s) => s.name == row['favorite_season']).firstOrNull;
    heardFrom = HeardFrom.values.where((h) => h.code == row['heard_from']).firstOrNull;
    household = HouseholdSize.values.where((h) => h.code == row['household_size']).firstOrNull;
    interests
      ..clear()
      ..addAll(Interest.values.where((i) => (row['interests'] as List?)?.contains(i.name) ?? false));
    days
      ..clear()
      ..addAll([for (final d in (row['preferred_days'] as List?) ?? const []) if (d is num) d.toInt()]);
    notifyListeners();
  }

  /// Saca las respuestas opcionales (temporada, cómo nos conoció, intereses, días y personas).
  void clearOptional() => update(() {
    season = null;
    heardFrom = null;
    household = null;
    interests.clear();
    days.clear();
  });

  /// El formulario con lo escrito (más el email, la contraseña y la privacy de quien lo usa).
  SignUpForm toForm({String email = '', String password = '', String repeat = '', bool privacyAccepted = false}) => SignUpForm(
    firstName: firstName.text,
    lastName: lastName.text,
    phone: phone.text,
    birthDate: parseBirthDate(birth.text),
    email: email,
    password: password,
    repeat: repeat,
    privacyAccepted: privacyAccepted,
    street: street.text,
    city: city.text,
    postalCode: postal.text,
    notes: notes.text,
    season: season,
    heardFrom: heardFrom,
    interests: Set.of(interests),
    days: Set.of(days),
    household: household,
  );

  @override
  void dispose() {
    for (final controller in [firstName, lastName, phone, birth, street, city, postal, notes]) {
      controller.dispose();
    }
    super.dispose();
  }
}

/// Un campo de texto del formulario de la cuenta.
class AccountTextField extends StatelessWidget {
  const AccountTextField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.enabled,
    this.error,
    this.helper,
    this.keyboard,
    this.autofill,
    this.capitalization = TextCapitalization.none,
    this.obscure = false,
    this.suffix,
    this.formatters,
  });

  final String fieldKey;
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final String? error;
  final String? helper;
  final TextInputType? keyboard;
  final Iterable<String>? autofill;
  final TextCapitalization capitalization;
  final bool obscure;
  final Widget? suffix;
  final List<TextInputFormatter>? formatters;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: ValueKey(fieldKey),
      controller: controller,
      enabled: enabled,
      keyboardType: keyboard,
      autofillHints: autofill,
      textCapitalization: capitalization,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: !obscure,
      inputFormatters: formatters,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
        errorText: error,
        errorMaxLines: 4,
        suffixIcon: suffix,
      ),
    ),
  );
}

/// «Tus datos»: nombre, apellido, teléfono y fecha de nacimiento.
class AccountPersonalFields extends StatelessWidget {
  const AccountPersonalFields({super.key, required this.draft, required this.problems, required this.enabled});

  final AccountDetailsDraft draft;
  final Map<SignUpField, Object> problems;
  final bool enabled;

  Future<void> _pickBirthDate(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: parseBirthDate(draft.birth.text) ?? DateTime(now.year - 30, now.month, now.day),
      firstDate: DateTime(1900),
      lastDate: now,
      initialDatePickerMode: DatePickerMode.year,
    );
    if (picked != null) draft.update(() => draft.birth.text = formatBirthDate(picked));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String? missing(SignUpField field) => problems.containsKey(field) ? l10n.signUpErrorRequired : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AccountSection(l10n.signUpSectionYou),
        AccountTextField(
          fieldKey: 'signup-first-name',
          controller: draft.firstName,
          label: l10n.signUpFirstName,
          enabled: enabled,
          error: missing(SignUpField.firstName),
          autofill: const [AutofillHints.givenName],
          capitalization: TextCapitalization.words,
        ),
        AccountTextField(
          fieldKey: 'signup-last-name',
          controller: draft.lastName,
          label: l10n.signUpLastName,
          enabled: enabled,
          error: missing(SignUpField.lastName),
          autofill: const [AutofillHints.familyName],
          capitalization: TextCapitalization.words,
        ),
        AccountTextField(
          fieldKey: 'signup-phone',
          controller: draft.phone,
          label: l10n.signUpPhone,
          enabled: enabled,
          error: problems.containsKey(SignUpField.phone) ? l10n.signUpErrorPhone : null,
          helper: l10n.signUpPhoneHint,
          keyboard: TextInputType.phone,
          autofill: const [AutofillHints.telephoneNumber],
        ),
        AccountTextField(
          fieldKey: 'signup-birth-date',
          controller: draft.birth,
          label: l10n.signUpBirthDate,
          enabled: enabled,
          error: problems.containsKey(SignUpField.underage)
              ? l10n.signUpErrorUnderage
              : problems.containsKey(SignUpField.birthDate)
              ? l10n.signUpErrorBirthDate
              : null,
          helper: '${l10n.signUpBirthDateChoose} · ${l10n.signUpBirthDateHint}',
          keyboard: TextInputType.datetime,
          autofill: const [AutofillHints.birthday],
          suffix: IconButton(
            key: const ValueKey('signup-birth-date-pick'),
            tooltip: l10n.signUpBirthDate,
            icon: const Icon(Icons.calendar_month_outlined),
            onPressed: enabled ? () => _pickBirthDate(context) : null,
          ),
        ),
      ],
    );
  }
}

/// La dirección (opcional) y las respuestas para conocerla mejor (opcionales).
class AccountExtraFields extends StatelessWidget {
  const AccountExtraFields({super.key, required this.draft, required this.problems, required this.enabled});

  final AccountDetailsDraft draft;
  final Map<SignUpField, Object> problems;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    String? address(SignUpField field) => problems.containsKey(field) ? l10n.signUpErrorAddress : null;
    return ListenableBuilder(
      listenable: draft,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AccountSection(l10n.signUpSectionAddress),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(l10n.signUpAddressHint, style: theme.textTheme.bodySmall),
          ),
          AccountTextField(
            fieldKey: 'signup-street',
            controller: draft.street,
            label: l10n.signUpStreet,
            enabled: enabled,
            error: address(SignUpField.street),
            autofill: const [AutofillHints.streetAddressLine1],
            capitalization: TextCapitalization.words,
          ),
          AccountTextField(
            fieldKey: 'signup-city',
            controller: draft.city,
            label: l10n.signUpCity,
            enabled: enabled,
            error: address(SignUpField.city),
            autofill: const [AutofillHints.addressCity],
            capitalization: TextCapitalization.words,
          ),
          AccountTextField(
            fieldKey: 'signup-postal',
            controller: draft.postal,
            label: l10n.signUpPostalCode,
            enabled: enabled,
            error: address(SignUpField.postalCode),
            autofill: const [AutofillHints.postalCode],
            formatters: [LengthLimitingTextInputFormatter(10)],
          ),
          AccountTextField(
            fieldKey: 'signup-notes',
            controller: draft.notes,
            label: l10n.signUpNotes,
            enabled: enabled,
            error: address(SignUpField.notes),
          ),
          AccountSection(l10n.signUpSectionExtra),
          AccountQuestion(l10n.signUpSeason),
          AccountChoices<Season>(
            keyPrefix: 'signup-season',
            values: Season.values,
            selected: {?draft.season},
            label: (s) => switch (s) {
              Season.spring => l10n.seasonSpring,
              Season.summer => l10n.seasonSummer,
              Season.autumn => l10n.seasonAutumn,
              Season.winter => l10n.seasonWinter,
              Season.any => l10n.seasonAny,
            },
            onTap: (s) => draft.update(() => draft.season = draft.season == s ? null : s),
          ),
          AccountQuestion(l10n.signUpHeardFrom),
          AccountChoices<HeardFrom>(
            keyPrefix: 'signup-heard',
            values: HeardFrom.values,
            selected: {?draft.heardFrom},
            label: (h) => switch (h) {
              HeardFrom.instagram => l10n.heardInstagram,
              HeardFrom.google => l10n.heardGoogle,
              HeardFrom.wordOfMouth => l10n.heardWordOfMouth,
              HeardFrom.other => l10n.heardOther,
            },
            onTap: (h) => draft.update(() => draft.heardFrom = draft.heardFrom == h ? null : h),
          ),
          AccountQuestion(l10n.signUpInterests),
          AccountChoices<Interest>(
            keyPrefix: 'signup-interest',
            values: Interest.values,
            selected: draft.interests,
            multi: true,
            label: (i) => switch (i) {
              Interest.weekly => l10n.landingServicesWeekly,
              Interest.dinners => l10n.landingServicesDinners,
              Interest.events => l10n.landingServicesEvents,
            },
            onTap: (i) => draft.update(() => draft.interests.contains(i) ? draft.interests.remove(i) : draft.interests.add(i)),
          ),
          AccountQuestion(l10n.signUpDays),
          AccountChoices<int>(
            keyPrefix: 'signup-day',
            values: signUpWeekdays,
            selected: draft.days,
            multi: true,
            // 1 de enero de 2024 fue lunes.
            label: (d) => toBeginningOfSentenceCase(DateFormat.EEEE(locale).format(DateTime(2024, 1, d))) ?? '',
            onTap: (d) => draft.update(() => draft.days.contains(d) ? draft.days.remove(d) : draft.days.add(d)),
          ),
          AccountQuestion(l10n.signUpHousehold),
          AccountChoices<HouseholdSize>(
            keyPrefix: 'signup-household',
            values: HouseholdSize.values,
            selected: {?draft.household},
            label: (h) => switch (h) {
              HouseholdSize.oneTwo => l10n.householdOneTwo,
              HouseholdSize.threeFour => l10n.householdThreeFour,
              HouseholdSize.fivePlus => l10n.householdFivePlus,
            },
            onTap: (h) => draft.update(() => draft.household = draft.household == h ? null : h),
          ),
        ],
      ),
    );
  }
}

class AccountSection extends StatelessWidget {
  const AccountSection(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Semantics(header: true, child: Text(text, style: Theme.of(context).textTheme.titleLarge)),
  );
}

class AccountQuestion extends StatelessWidget {
  const AccountQuestion(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// Opciones en chips: una sola (vuelve a tocarla para sacarla) o varias.
class AccountChoices<T> extends StatelessWidget {
  const AccountChoices({
    super.key,
    required this.keyPrefix,
    required this.values,
    required this.selected,
    required this.label,
    required this.onTap,
    this.multi = false,
  });

  final String keyPrefix;
  final List<T> values;
  final Set<T> selected;
  final String Function(T value) label;
  final void Function(T value) onTap;
  final bool multi;

  String _keyOf(T value) => value is Enum ? value.name : '$value';

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final value in values)
        multi
            ? FilterChip(
                key: ValueKey('$keyPrefix-${_keyOf(value)}'),
                label: Text(label(value)),
                selected: selected.contains(value),
                onSelected: (_) => onTap(value),
              )
            : ChoiceChip(
                key: ValueKey('$keyPrefix-${_keyOf(value)}'),
                label: Text(label(value)),
                selected: selected.contains(value),
                onSelected: (_) => onTap(value),
              ),
    ],
  );
}

/// Un error debajo de un botón (lo lee el lector de pantalla).
class AccountErrorLine extends StatelessWidget {
  const AccountErrorLine(this.text, {super.key, this.lineKey = 'signup-error'});
  final String? text;
  final String lineKey;

  @override
  Widget build(BuildContext context) {
    final text = this.text;
    if (text == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        liveRegion: true,
        child: Text(
          text,
          key: ValueKey(lineKey),
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
        ),
      ),
    );
  }
}
