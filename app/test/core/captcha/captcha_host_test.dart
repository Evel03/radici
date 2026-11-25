// CaptchaHost sin WebView abierta: solo el hijo, y su estado no se pierde cuando
// el captcha aparece o desaparece (el Stack no cambia de forma).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/captcha/captcha_host.dart';
import 'package:radici/core/captcha/captcha_ui.dart';

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: () => setState(() => taps++), child: Text('taps $taps'));
}

void main() {
  testWidgets('sin pedido en curso dibuja solo la app, que sigue tocable', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: CaptchaHost(child: _Counter())),
      ),
    );
    expect(find.text('taps 0'), findsOneWidget);
    await tester.tap(find.text('taps 0'));
    await tester.pump();
    expect(find.text('taps 1'), findsOneWidget);
    // Ningún marco de la WebView.
    expect(find.byKey(const ValueKey('captcha-webview-box')), findsNothing);
  });

  test('el estado de la WebView: abrir, agrandar y cerrar solo la propia', () {
    final container = ProviderContainer.test();
    final ui = container.read(captchaUiProvider.notifier);
    expect(container.read(captchaUiProvider).controller, isNull);
    // Agrandar sin WebView abierta no hace nada.
    ui.setInteractive(visible: true);
    expect(container.read(captchaUiProvider).interactive, isFalse);
  });
}
