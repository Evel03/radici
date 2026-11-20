// Diálogos abiertos en el navegador (OpenDialogsObserver): cuenta los de
// showDialog y los selectores de fecha y hora desde que se abren hasta que
// terminan de cerrarse (también los que salen de la pila sin animación); las
// páginas y los menús no.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/open_dialogs.dart';

void main() {
  late ProviderContainer container;
  late GlobalKey<NavigatorState> navigator;

  int open() => container.read(openDialogsProvider);

  /// Una app con el observador en su navegador; devuelve un contexto de la
  /// pantalla de inicio. Con [menu], un menú en la barra.
  Future<BuildContext> pumpApp(WidgetTester tester, {bool menu = false}) async {
    container = ProviderContainer.test();
    navigator = GlobalKey<NavigatorState>();
    late BuildContext home;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [
          OpenDialogsObserver(container.read(openDialogsProvider.notifier)),
        ],
        home: Scaffold(
          appBar: AppBar(
            actions: [
              if (menu)
                PopupMenuButton<int>(
                  key: const ValueKey('menu'),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 1, child: Text('Uno')),
                  ],
                ),
            ],
          ),
          body: Builder(
            builder: (context) {
              home = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return home;
  }

  Future<void> showTestDialog(BuildContext context, {String text = 'Hola'}) =>
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(content: Text(text)),
      );

  testWidgets('un diálogo cuenta desde que se abre hasta que termina de '
      'cerrarse, no solo hasta que empieza a irse', (tester) async {
    final home = await pumpApp(tester);
    expect(open(), 0);

    unawaited(showTestDialog(home));
    expect(open(), 1, reason: 'al abrirlo, antes del primer cuadro');
    await tester.pumpAndSettle();
    expect(open(), 1);

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Hola'), findsOneWidget, reason: 'todavía se está yendo');
    expect(open(), 1);

    await tester.pumpAndSettle();
    expect(find.text('Hola'), findsNothing);
    expect(open(), 0);
  });

  testWidgets('el calendario y el reloj también', (tester) async {
    final home = await pumpApp(tester);
    unawaited(
      showDatePicker(
        context: home,
        initialDate: DateTime(2026, 12, 2),
        firstDate: DateTime(2026),
        lastDate: DateTime(2027),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(open(), 1);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(open(), 0);

    unawaited(
      showTimePicker(
        context: home,
        initialTime: const TimeOfDay(hour: 10, minute: 0),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    expect(open(), 1);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(open(), 0);
  });

  testWidgets('uno encima de otro, o uno que se abre mientras el anterior se '
      'va: cuenta los dos', (tester) async {
    final home = await pumpApp(tester);
    unawaited(showTestDialog(home, text: 'Primero'));
    await tester.pumpAndSettle();
    unawaited(showTestDialog(home, text: 'Segundo'));
    await tester.pumpAndSettle();
    expect(open(), 2);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(open(), 1);

    // Se cierra el primero y enseguida se abre otro.
    navigator.currentState!.pop();
    unawaited(showTestDialog(home, text: 'Tercero'));
    await tester.pump();
    expect(open(), 2);
    await tester.pumpAndSettle();
    expect(open(), 1);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(open(), 0);
  });

  testWidgets('uno que sale de la pila sin animación deja de contar', (
    tester,
  ) async {
    final home = await pumpApp(tester);
    // La misma ruta que arma showDialog.
    final dialog = DialogRoute<void>(
      context: home,
      builder: (_) => const AlertDialog(content: Text('Hola')),
    );
    unawaited(navigator.currentState!.push(dialog));
    await tester.pumpAndSettle();
    expect(open(), 1);

    navigator.currentState!.removeRoute(dialog);
    await tester.pumpAndSettle();
    expect(find.text('Hola'), findsNothing);
    expect(open(), 0);
  });

  testWidgets('las páginas y los menús no cuentan', (tester) async {
    final home = await pumpApp(tester, menu: true);
    await tester.tap(find.byKey(const ValueKey('menu')));
    await tester.pumpAndSettle();
    expect(find.text('Uno'), findsOneWidget);
    expect(open(), 0);
    await tester.tap(find.text('Uno'));
    await tester.pumpAndSettle();

    unawaited(
      Navigator.of(home)
          .push(MaterialPageRoute<void>(builder: (_) => const Scaffold())),
    );
    await tester.pumpAndSettle();
    expect(open(), 0);
  });

  testWidgets('si la app se cerró antes de que termine de irse, no falla', (
    tester,
  ) async {
    final home = await pumpApp(tester);
    unawaited(showTestDialog(home));
    await tester.pumpAndSettle();
    container.dispose();

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Hola'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
