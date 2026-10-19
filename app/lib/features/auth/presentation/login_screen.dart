// Login (placeholder de M0). En M2 se conecta al OTP por email de Supabase
// a través de un repositorio y un provider; el widget no llamará a Supabase.
import 'package:flutter/material.dart';
import 'package:mestolo/l10n/app_localizations.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.loginTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.loginBody, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 24),
                  TextField(
                    key: const ValueKey('login-email'),
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: l10n.loginEmailLabel,
                      hintText: l10n.loginEmailHint,
                      prefixIcon: const Icon(Icons.mail_outline),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('login-send-code'),
                    // Sin lógica todavía (M2): solo avisa que falta poco.
                    onPressed: () => ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(content: Text(l10n.loginComingSoon)),
                      ),
                    child: Text(l10n.loginSendCode),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
