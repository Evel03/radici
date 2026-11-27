// «Crear cuenta» (/crea-account, auth.md §19): los datos, el email y la contraseña (dos veces) en una sola pantalla, y
// después el código de 10 cifras que llega por email, sin salir de la app. Solo muestra el estado de SignUpController
// y le pasa lo que escribe la clienta: no llama a Supabase.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/core/web_links.dart';
import 'package:radici/features/auth/application/sign_up_controller.dart';
import 'package:radici/features/auth/domain/password_rules.dart';
import 'package:radici/features/auth/domain/sign_up_form.dart';
import 'package:radici/features/auth/presentation/auth_texts.dart';
import 'package:radici/features/auth/presentation/busy_button.dart';
import 'package:radici/l10n/app_localizations.dart';

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  late final SignUpController _controller;
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _phone = TextEditingController();
  final _birth = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  final _street = TextEditingController();
  final _city = TextEditingController();
  final _postal = TextEditingController();
  final _notes = TextEditingController();
  final _code = TextEditingController();
  bool _obscure = true;
  bool _privacy = false;
  Season? _season;
  HeardFrom? _heard;
  final Set<Interest> _interests = {};
  final Set<int> _days = {};
  HouseholdSize? _household;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(signUpControllerProvider.notifier);
  }

  @override
  void dispose() {
    for (final controller in [
      _firstName,
      _lastName,
      _phone,
      _birth,
      _email,
      _password,
      _repeat,
      _street,
      _city,
      _postal,
      _notes,
      _code,
    ]) {
      controller.dispose();
    }
    // Al salir de la pantalla se olvida todo (la contraseña incluida), salvo que esté terminando de guardar.
    Future.microtask(_controller.resetUnlessFinishing);
    super.dispose();
  }

  String get _locale => Localizations.localeOf(context).languageCode;

  SignUpForm get _form => SignUpForm(
    firstName: _firstName.text,
    lastName: _lastName.text,
    phone: _phone.text,
    birthDate: parseBirthDate(_birth.text),
    email: _email.text,
    password: _password.text,
    repeat: _repeat.text,
    privacyAccepted: _privacy,
    street: _street.text,
    city: _city.text,
    postalCode: _postal.text,
    notes: _notes.text,
    season: _season,
    heardFrom: _heard,
    interests: Set.of(_interests),
    days: Set.of(_days),
    household: _household,
  );

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate:
          parseBirthDate(_birth.text) ??
          DateTime(now.year - 30, now.month, now.day),
      firstDate: DateTime(1900),
      lastDate: now,
      initialDatePickerMode: DatePickerMode.year,
    );
    if (picked != null) setState(() => _birth.text = formatBirthDate(picked));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(signUpControllerProvider);
    ref.listen(signUpControllerProvider.select((s) => s.step), (_, step) {
      if (step != SignUpStep.done) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          key: const ValueKey('signup-done'),
          content: Text(l10n.signUpDone),
        ),
      );
      _controller.reset();
      context.go(AppRoutes.area);
    });

    final body = switch (state.step) {
      SignUpStep.form => _formStep(context, state),
      SignUpStep.code => _codeStep(context, state),
      SignUpStep.finishing || SignUpStep.done => _finishingStep(context, state),
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.signUpTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: body,
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 1. El formulario
  // ---------------------------------------------------------------------------

  Widget _formStep(BuildContext context, SignUpState state) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final problems = state.problems;
    String? requiredError(SignUpField field) =>
        problems.containsKey(field) ? l10n.signUpErrorRequired : null;
    final password = problems[SignUpField.password];
    void submit() {
      FocusScope.of(context).unfocus();
      _controller.submit(_form, locale: _locale);
    }

    Widget field(
      String key,
      TextEditingController controller,
      String label, {
      String? error,
      String? helper,
      TextInputType? keyboard,
      Iterable<String>? autofill,
      TextCapitalization capitalization = TextCapitalization.none,
      bool obscure = false,
      Widget? suffix,
      List<TextInputFormatter>? formatters,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: ValueKey(key),
        controller: controller,
        enabled: !state.busy,
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

    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.signUpIntro, style: theme.textTheme.bodyLarge),
          _Section(l10n.signUpSectionYou),
          field(
            'signup-first-name',
            _firstName,
            l10n.signUpFirstName,
            error: requiredError(SignUpField.firstName),
            autofill: const [AutofillHints.givenName],
            capitalization: TextCapitalization.words,
          ),
          field(
            'signup-last-name',
            _lastName,
            l10n.signUpLastName,
            error: requiredError(SignUpField.lastName),
            autofill: const [AutofillHints.familyName],
            capitalization: TextCapitalization.words,
          ),
          field(
            'signup-phone',
            _phone,
            l10n.signUpPhone,
            error: problems.containsKey(SignUpField.phone)
                ? l10n.signUpErrorPhone
                : null,
            helper: l10n.signUpPhoneHint,
            keyboard: TextInputType.phone,
            autofill: const [AutofillHints.telephoneNumber],
          ),
          field(
            'signup-birth-date',
            _birth,
            l10n.signUpBirthDate,
            error: problems.containsKey(SignUpField.underage)
                ? l10n.signUpErrorUnderage
                : problems.containsKey(SignUpField.birthDate)
                ? l10n.signUpErrorBirthDate
                : null,
            helper:
                '${l10n.signUpBirthDateChoose} · ${l10n.signUpBirthDateHint}',
            keyboard: TextInputType.datetime,
            autofill: const [AutofillHints.birthday],
            suffix: IconButton(
              key: const ValueKey('signup-birth-date-pick'),
              tooltip: l10n.signUpBirthDate,
              icon: const Icon(Icons.calendar_month_outlined),
              onPressed: state.busy ? null : _pickBirthDate,
            ),
          ),
          _Section(l10n.signUpSectionAccount),
          field(
            'signup-email',
            _email,
            l10n.loginEmailLabel,
            error: problems.containsKey(SignUpField.email)
                ? l10n.authErrorInvalidEmail
                : null,
            keyboard: TextInputType.emailAddress,
            autofill: const [AutofillHints.email],
          ),
          field(
            'signup-password',
            _password,
            l10n.loginPasswordLabel,
            error: password is PasswordProblem
                ? passwordProblemText(l10n, password)
                : null,
            helper: l10n.passwordHint,
            obscure: _obscure,
            autofill: const [AutofillHints.newPassword],
            suffix: IconButton(
              key: const ValueKey('signup-password-toggle'),
              tooltip: _obscure
                  ? l10n.loginPasswordShow
                  : l10n.loginPasswordHide,
              icon: Icon(
                _obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          field(
            'signup-repeat',
            _repeat,
            l10n.signUpRepeat,
            error: problems.containsKey(SignUpField.repeat)
                ? l10n.passwordMismatch
                : null,
            obscure: _obscure,
            autofill: const [AutofillHints.newPassword],
          ),
          _Section(l10n.signUpSectionAddress),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              l10n.signUpAddressHint,
              style: theme.textTheme.bodySmall,
            ),
          ),
          field(
            'signup-street',
            _street,
            l10n.signUpStreet,
            error: problems.containsKey(SignUpField.street)
                ? l10n.signUpErrorAddress
                : null,
            autofill: const [AutofillHints.streetAddressLine1],
            capitalization: TextCapitalization.words,
          ),
          field(
            'signup-city',
            _city,
            l10n.signUpCity,
            error: problems.containsKey(SignUpField.city)
                ? l10n.signUpErrorAddress
                : null,
            autofill: const [AutofillHints.addressCity],
            capitalization: TextCapitalization.words,
          ),
          field(
            'signup-postal',
            _postal,
            l10n.signUpPostalCode,
            error: problems.containsKey(SignUpField.postalCode)
                ? l10n.signUpErrorAddress
                : null,
            autofill: const [AutofillHints.postalCode],
            formatters: [LengthLimitingTextInputFormatter(10)],
          ),
          field(
            'signup-notes',
            _notes,
            l10n.signUpNotes,
            error: problems.containsKey(SignUpField.notes)
                ? l10n.signUpErrorAddress
                : null,
          ),
          _Section(l10n.signUpSectionExtra),
          _Question(l10n.signUpSeason),
          _Choices<Season>(
            keyPrefix: 'signup-season',
            values: Season.values,
            selected: {?_season},
            label: (s) => switch (s) {
              Season.spring => l10n.seasonSpring,
              Season.summer => l10n.seasonSummer,
              Season.autumn => l10n.seasonAutumn,
              Season.winter => l10n.seasonWinter,
              Season.any => l10n.seasonAny,
            },
            onTap: (s) => setState(() => _season = _season == s ? null : s),
          ),
          _Question(l10n.signUpHeardFrom),
          _Choices<HeardFrom>(
            keyPrefix: 'signup-heard',
            values: HeardFrom.values,
            selected: {?_heard},
            label: (h) => switch (h) {
              HeardFrom.instagram => l10n.heardInstagram,
              HeardFrom.google => l10n.heardGoogle,
              HeardFrom.wordOfMouth => l10n.heardWordOfMouth,
              HeardFrom.other => l10n.heardOther,
            },
            onTap: (h) => setState(() => _heard = _heard == h ? null : h),
          ),
          _Question(l10n.signUpInterests),
          _Choices<Interest>(
            keyPrefix: 'signup-interest',
            values: Interest.values,
            selected: _interests,
            multi: true,
            label: (i) => switch (i) {
              Interest.weekly => l10n.landingServicesWeekly,
              Interest.dinners => l10n.landingServicesDinners,
              Interest.events => l10n.landingServicesEvents,
            },
            onTap: (i) => setState(
              () => _interests.contains(i)
                  ? _interests.remove(i)
                  : _interests.add(i),
            ),
          ),
          _Question(l10n.signUpDays),
          _Choices<int>(
            keyPrefix: 'signup-day',
            values: signUpWeekdays,
            selected: _days,
            multi: true,
            // 1 de enero de 2024 fue lunes.
            label: (d) =>
                toBeginningOfSentenceCase(
                  DateFormat.EEEE(_locale).format(DateTime(2024, 1, d)),
                ) ??
                '',
            onTap: (d) => setState(
              () => _days.contains(d) ? _days.remove(d) : _days.add(d),
            ),
          ),
          _Question(l10n.signUpHousehold),
          _Choices<HouseholdSize>(
            keyPrefix: 'signup-household',
            values: HouseholdSize.values,
            selected: {?_household},
            label: (h) => switch (h) {
              HouseholdSize.oneTwo => l10n.householdOneTwo,
              HouseholdSize.threeFour => l10n.householdThreeFour,
              HouseholdSize.fivePlus => l10n.householdFivePlus,
            },
            onTap: (h) =>
                setState(() => _household = _household == h ? null : h),
          ),
          const SizedBox(height: 16),
          CheckboxListTile(
            key: const ValueKey('signup-privacy'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _privacy,
            onChanged: state.busy
                ? null
                : (value) => setState(() => _privacy = value ?? false),
            title: Text(l10n.signUpPrivacy),
            subtitle: problems.containsKey(SignUpField.privacy)
                ? Text(
                    l10n.signUpErrorPrivacy,
                    style: TextStyle(color: theme.colorScheme.error),
                  )
                : null,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('signup-privacy-link'),
              onPressed: () => ref
                  .read(linkLauncherProvider)
                  .openPage(privacyPolicyUri(_locale)),
              child: Text(l10n.signUpPrivacyLink),
            ),
          ),
          const SizedBox(height: 16),
          BusyButton(
            key: const ValueKey('signup-submit'),
            busy: state.busy,
            onPressed: submit,
            label: l10n.signUpSubmit,
          ),
          _ErrorLine(
            problems.isNotEmpty
                ? l10n.signUpErrorFix
                : (state.error != null
                      ? authErrorText(
                          l10n,
                          state.error!,
                          detail: state.errorDetail,
                        )
                      : null),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey('signup-have-account'),
            onPressed: state.busy
                ? null
                : () => context.canPop()
                      ? context.pop()
                      : context.go(AppRoutes.login),
            child: Text(l10n.signUpHaveAccount),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 2. El código del email
  // ---------------------------------------------------------------------------

  Widget _codeStep(BuildContext context, SignUpState state) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    void confirm() => _controller.verify(_code.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.signUpCodeTitle,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.signUpCodeBody(state.email),
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 8),
        Text(l10n.signUpCodeExisting, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 20),
        TextField(
          key: const ValueKey('signup-code'),
          controller: _code,
          enabled: !state.busy,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(10),
          ],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => confirm(),
          decoration: InputDecoration(
            labelText: l10n.loginCodeLabel,
            hintText: l10n.loginCodeHint,
          ),
        ),
        const SizedBox(height: 16),
        BusyButton(
          key: const ValueKey('signup-code-confirm'),
          busy: state.busy,
          onPressed: confirm,
          label: l10n.signUpCodeConfirm,
        ),
        _ErrorLine(
          state.error != null
              ? authErrorText(l10n, state.error!, detail: state.errorDetail)
              : null,
        ),
        if (state.resent) ...[
          const SizedBox(height: 8),
          Text(l10n.loginCodeResent, key: const ValueKey('signup-code-resent')),
        ],
        const SizedBox(height: 8),
        Text(l10n.loginSpamHint, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        TextButton(
          key: const ValueKey('signup-code-resend'),
          onPressed: state.busy ? null : _controller.resend,
          child: Text(l10n.loginResendCode),
        ),
        TextButton(
          key: const ValueKey('signup-edit'),
          onPressed: state.busy ? null : _controller.editForm,
          child: Text(l10n.signUpEditData),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 3. Guardando la contraseña y los datos
  // ---------------------------------------------------------------------------

  Widget _finishingStep(BuildContext context, SignUpState state) {
    final l10n = AppLocalizations.of(context);
    final error = state.error;
    return Column(
      key: const ValueKey('signup-finishing'),
      children: [
        const SizedBox(height: 32),
        if (state.busy || error == null) const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(l10n.signUpFinishing, textAlign: TextAlign.center),
        if (!state.busy && error != null) ...[
          _ErrorLine(authErrorText(l10n, error)),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('signup-retry'),
            onPressed: _controller.retryFinish,
            child: Text(l10n.actionRetry),
          ),
        ],
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Semantics(
      header: true,
      child: Text(text, style: Theme.of(context).textTheme.titleLarge),
    ),
  );
}

class _Question extends StatelessWidget {
  const _Question(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// Opciones en chips: una sola (vuelve a tocarla para sacarla) o varias.
class _Choices<T> extends StatelessWidget {
  const _Choices({
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

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);
  final String? text;

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
          key: const ValueKey('signup-error'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ),
    );
  }
}
