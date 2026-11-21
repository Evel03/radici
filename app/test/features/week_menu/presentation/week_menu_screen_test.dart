// El menú de una semana en la app (/sessioni/:id/menu): la clienta, «Semana k
// de N», el día y las personas, las alergias resaltadas como en la ficha; los
// platos en el idioma de la app (con el italiano si falta), las porciones, el
// selector del catálogo (sin los que ya están ni los desactivados, con los
// que chocan marcados) y «Nuevo plato»; la lista por sección con las
// cantidades legibles, que sigue a los platos hasta que se cambia a mano; la
// nota para la clienta; guardar (con la confirmación de los choques) y cada
// falla sin perder lo escrito; volver con cambios sin guardar (también un go,
// como el atrás del navegador en /gestione/).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/recipes/data/translation_repository.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/presentation/recipe_editor_screen.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';
import 'package:radici/features/week_menu/presentation/week_menu_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/menu_fakes.dart';
import '../../../support/menu_fixtures.dart';
import '../../../support/plain_text.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/session_fixtures.dart';
import '../../../support/text_input_guard.dart';

void main() {
  Finder byKey(String key) => find.byKey(ValueKey(key));

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(byKey(key)).data!;

  VoidCallback? onPressedOf(WidgetTester tester, String key) =>
      tester.widget<ButtonStyleButton>(byKey(key)).onPressed;

  /// Lleva [finder] a la vista y lo toca.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// El menú de la semana [n] de una reserva de 4 (25/11, 2/12, 9/12 y
  /// 16/12), abierto con un enlace directo (la ficha queda debajo). Por
  /// defecto, en español (el idioma de Evelyn).
  Future<ChefApp> openMenu(
    WidgetTester tester, {
    int n = 2,
    List<CookingSession>? booking,
    Map<String, SavedWeekMenu> saved = const {},
    List<Recipe>? recipes,
    Locale locale = const Locale('es'),
    bool isWeb = false,
  }) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      sessions: FakeSessionsRepository(booking ?? buildBooking()),
      recipes: FakeRecipesRepository(recipes ?? sampleRecipes()),
      menus: FakeSessionMenusRepository(menus: saved),
      location: '/sessioni/${sessionId(n)}/menu',
      deviceLocales: [locale],
      isWeb: isWeb,
      overrides: [
        translationRepositoryProvider.overrideWithValue(
          FakeTranslationRepository(),
        ),
      ],
    );
    expect(find.byType(WeekMenuScreen), findsOneWidget);
    return app;
  }

  /// Abre el selector, marca [names] y los agrega.
  Future<void> addDishes(WidgetTester tester, List<String> names) async {
    await tapVisible(tester, byKey('week-menu-add-dish'));
    for (final name in names) {
      await tester.tap(find.text(name));
      await tester.pump();
    }
    await tester.tap(byKey('menu-picker-add'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'arriba la clienta, «Semana k de N», el día con la llegada y las personas; sin datos de alergias, la advertencia (nunca «sin alergias»)',
    (tester) async {
      await openMenu(tester);
      expect(find.widgetWithText(AppBar, 'Menú de la semana'), findsOneWidget);
      expect(textOf(tester, 'week-menu-client'), 'Giulia Rossi');
      expect(textOf(tester, 'week-menu-week'), 'Semana 2 de 4');
      expect(textOf(tester, 'week-menu-date'), contains('diciembre'));
      expect(
        plainSpaces(textOf(tester, 'week-menu-times')),
        'Llega 10:00 · hasta 13:00',
      );
      expect(textOf(tester, 'week-menu-people'), '4 personas');
      expect(
        textOf(tester, 'session-allergies-unknown'),
        'Alergias: sin datos en la app, pregúntale',
      );
      expect(byKey('session-no-allergies'), findsNothing);
      expect(textOf(tester, 'week-menu-no-dishes'), 'Todavía no hay platos.');
      expect(textOf(tester, 'week-menu-list-empty'), 'La lista está vacía.');
      // Nada para guardar todavía.
      expect(onPressedOf(tester, 'week-menu-save'), isNull);
    },
  );

  testWidgets(
    'las alergias de la reserva, como en la ficha: la nota resaltada y, con gluten, la contaminación cruzada',
    (tester) async {
      await openMenu(
        tester,
        booking: buildBooking(
          restrictions: const RequestRestrictions(
            allergens: [Allergen.gluten],
            note: 'El niño es celíaco',
          ),
        ),
      );
      expect(textOf(tester, 'session-allergy-note'), 'El niño es celíaco');
      expect(byKey('session-cross-contamination'), findsOneWidget);
      expect(byKey('session-allergies-unknown'), findsNothing);
    },
  );

  testWidgets(
    'un menú guardado: los platos en español, las porciones, la lista por sección con cantidades legibles y la nota',
    (tester) async {
      await openMenu(
        tester,
        saved: {
          sessionId(2): savedLasagneMenu(
            portions: 12,
            note: 'Ten listos 4 táperes',
          ),
        },
      );
      expect(
        textOf(tester, 'week-menu-dish-name-$lasagneId'),
        'Lasaña a la boloñesa',
      );
      expect(
        textOf(tester, 'week-menu-dish-portions-$lasagneId'),
        '12 porciones',
      );
      expect(
        textOf(tester, 'week-menu-section-meat_fish'),
        'Carnes y pescados',
      );
      expect(textOf(tester, 'week-menu-section-pantry'), 'Almacén');
      // 400 g × 12 / 4 = 1200 g; 700 ml × 12 / 4 = 2100 ml; la sal, q.b.
      expect(find.text('1,2 kg'), findsOneWidget);
      expect(find.text('2,1 l'), findsOneWidget);
      expect(find.text('al gusto'), findsOneWidget);
      expect(
        textOf(tester, 'week-menu-list-mode'),
        'Sale sola de los ingredientes de los platos, por sus porciones. Si la cambias, deja de seguir a los platos.',
      );
      expect(byKey('week-menu-rebuild'), findsNothing);
      expect(
        tester.widget<TextField>(byKey('week-menu-note')).controller!.text,
        'Ten listos 4 táperes',
      );
      expect(
        find.text(
          'La lee la clienta: no escribas datos de salud ni direcciones.',
        ),
        findsOneWidget,
      );
      // Sin cambios, nada para guardar.
      expect(onPressedOf(tester, 'week-menu-save'), isNull);
    },
  );

  testWidgets('en inglés, un plato sin nombre en inglés sale con el italiano', (
    tester,
  ) async {
    await openMenu(tester, locale: const Locale('en'));
    await addDishes(tester, [
      'Minestrone di verdure',
      'Porcini mushroom risotto',
    ]);
    expect(
      textOf(tester, 'week-menu-dish-name-$minestroneId'),
      'Minestrone di verdure',
    );
    expect(
      textOf(tester, 'week-menu-dish-name-$risottoId'),
      'Porcini mushroom risotto',
    );
  });

  group('el selector de platos', () {
    testWidgets(
      'sin los que ya están ni los desactivados; los que chocan, marcados con el porqué; agrega varios juntos',
      (tester) async {
        await openMenu(
          tester,
          booking: buildBooking(
            restrictions: const RequestRestrictions(
              allergens: [Allergen.gluten],
              diets: [Diet.vegetarian],
            ),
          ),
          saved: {
            sessionId(2): SavedWeekMenu(
              version: 1,
              dishes: [WeekMenuDish(recipe: risotto(), portions: 4)],
            ),
          },
        );
        await tapVisible(tester, byKey('week-menu-add-dish'));
        expect(find.widgetWithText(AppBar, 'Agregar platos'), findsOneWidget);
        // El risotto ya está y la tortilla está desactivada.
        expect(byKey('menu-picker-$risottoId'), findsNothing);
        expect(byKey('menu-picker-$frittataId'), findsNothing);
        expect(byKey('menu-picker-$lasagneId'), findsOneWidget);
        expect(byKey('menu-picker-$minestroneId'), findsOneWidget);
        expect(
          textOf(tester, 'menu-picker-conflict-$lasagneId'),
          'Lleva: Gluten · No está marcado como vegetariano',
        );
        expect(byKey('menu-picker-conflict-$minestroneId'), findsNothing);
        expect(byKey('menu-picker-conflicts'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(byKey('menu-picker-add')).onPressed,
          isNull,
        );

        await tester.tap(find.text('Minestrone de verduras'));
        await tester.pump();
        await tester.tap(find.text('Lasaña a la boloñesa'));
        await tester.pump();
        expect(find.text('Agregar 2 platos'), findsOneWidget);
        await tester.tap(byKey('menu-picker-add'));
        await tester.pumpAndSettle();

        // En el orden en que se marcaron, con las porciones por defecto.
        final names = tester
            .widgetList<Text>(
              find.byWidgetPredicate(
                (w) =>
                    w is Text &&
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith(
                      'week-menu-dish-name-',
                    ),
              ),
            )
            .map((t) => t.data)
            .toList();
        expect(names, [
          'Risotto de hongos porcini',
          'Minestrone de verduras',
          'Lasaña a la boloñesa',
        ]);
        expect(
          textOf(tester, 'week-menu-dish-portions-$lasagneId'),
          '4 porciones',
        );
        expect(
          textOf(tester, 'week-menu-dish-conflict-$lasagneId'),
          'Lleva: Gluten · No está marcado como vegetariano',
        );
        expect(byKey('week-menu-dish-conflict-$risottoId'), findsNothing);
        // La lista sale de los ingredientes (el risotto y el minestrone no
        // tienen): lo dice.
        expect(find.text('400 g'), findsOneWidget);
        expect(
          textOf(tester, 'week-menu-no-ingredients'),
          contains('Risotto de hongos porcini, Minestrone de verduras'),
        );
      },
    );

    testWidgets('busca en los nombres; sin coincidencias, lo dice', (
      tester,
    ) async {
      await openMenu(tester);
      await tapVisible(tester, byKey('week-menu-add-dish'));
      await tester.enterText(byKey('menu-picker-search'), 'MINES');
      await tester.pump();
      expect(byKey('menu-picker-$minestroneId'), findsOneWidget);
      expect(byKey('menu-picker-$lasagneId'), findsNothing);
      await tester.enterText(byKey('menu-picker-search'), 'zzz');
      await tester.pump();
      expect(
        textOf(tester, 'menu-picker-empty'),
        'Ningún plato coincide con «zzz».',
      );
      await tester.tap(byKey('menu-picker-close'));
      await tester.pumpAndSettle();
      expect(byKey('week-menu-no-dishes'), findsOneWidget);
    });
  });

  testWidgets('las porciones rehacen la lista mientras la sigue', (
    tester,
  ) async {
    await openMenu(tester);
    await addDishes(tester, ['Lasaña a la boloñesa']);
    expect(find.text('400 g'), findsOneWidget);
    await tapVisible(tester, byKey('week-menu-dish-more-$lasagneId'));
    expect(textOf(tester, 'week-menu-dish-portions-$lasagneId'), '5 porciones');
    // 400 × 5 / 4 = 500 g; 700 × 5 / 4 = 875 → 880 ml.
    expect(find.text('500 g'), findsOneWidget);
    expect(find.text('880 ml'), findsOneWidget);
  });

  testWidgets(
    'cambiar un renglón deja la lista a mano; «Rehacer la lista con los platos», con confirmación, la vuelve a sacar de los platos',
    (tester) async {
      await openMenu(tester);
      await addDishes(tester, ['Lasaña a la boloñesa']);
      await tapVisible(
        tester,
        find.byTooltip('Cambiar Carne macinata di manzo'),
      );
      expect(byKey('shopping-item-dialog'), findsOneWidget);
      expect(find.text('Cambiar en la lista'), findsOneWidget);
      await tester.enterText(byKey('shopping-item-quantity'), '450');
      await tester.tap(byKey('shopping-item-save'));
      await tester.pumpAndSettle();
      expect(find.text('450 g'), findsOneWidget);
      expect(
        textOf(tester, 'week-menu-list-mode'),
        'La cambiaste a mano: ya no sigue a los platos.',
      );
      // Los platos ya no la tocan.
      await tapVisible(tester, byKey('week-menu-dish-more-$lasagneId'));
      expect(find.text('450 g'), findsOneWidget);

      await tapVisible(tester, byKey('week-menu-rebuild'));
      expect(byKey('week-menu-rebuild-dialog'), findsOneWidget);
      await tester.tap(byKey('week-menu-rebuild-cancel'));
      await tester.pumpAndSettle();
      expect(find.text('450 g'), findsOneWidget);
      await tapVisible(tester, byKey('week-menu-rebuild'));
      await tester.tap(byKey('week-menu-rebuild-confirm'));
      await tester.pumpAndSettle();
      expect(find.text('500 g'), findsOneWidget);
      expect(byKey('week-menu-rebuild'), findsNothing);
    },
  );

  testWidgets(
    'agregar a la lista: valida como la base, q.b. sin cantidad, y queda en su sección',
    (tester) async {
      await openMenu(tester);
      await tapVisible(tester, byKey('week-menu-add-item'));
      expect(byKey('shopping-item-dialog'), findsOneWidget);
      await tester.tap(byKey('shopping-item-save'));
      await tester.pumpAndSettle();
      expect(find.text('Escribe el ingrediente.'), findsOneWidget);
      expect(
        find.text('Escribe la cantidad o elige «al gusto».'),
        findsOneWidget,
      );

      await tester.enterText(byKey('shopping-item-name'), 'Mozzarella');
      await tester.enterText(byKey('shopping-item-quantity'), '250');
      await tester.tap(byKey('shopping-item-section'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lácteos y huevos').last);
      await tester.pumpAndSettle();
      await tester.tap(byKey('shopping-item-save'));
      await tester.pumpAndSettle();
      expect(byKey('shopping-item-dialog'), findsNothing);
      expect(
        textOf(tester, 'week-menu-section-dairy_eggs'),
        'Lácteos y huevos',
      );
      expect(find.text('Mozzarella'), findsOneWidget);
      expect(find.text('250 g'), findsOneWidget);

      // q.b.: la cantidad se apaga y no hace falta.
      await tapVisible(tester, byKey('week-menu-add-item'));
      await tester.enterText(byKey('shopping-item-name'), 'Sal gruesa');
      await tester.tap(byKey('shopping-item-unit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('al gusto').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(byKey('shopping-item-quantity')).enabled,
        isFalse,
      );
      await tester.tap(byKey('shopping-item-save'));
      await tester.pumpAndSettle();
      expect(find.text('Sal gruesa'), findsOneWidget);
      expect(find.text('al gusto'), findsOneWidget);
    },
  );

  testWidgets('quitar un plato o un renglón, con «Deshacer»', (tester) async {
    await openMenu(tester);
    await addDishes(tester, ['Lasaña a la boloñesa']);
    await tapVisible(tester, find.byTooltip('Quitar Sale'));
    expect(find.text('Quitado de la lista.'), findsOneWidget);
    expect(find.text('al gusto'), findsNothing);
    await tester.tap(find.text('Deshacer'));
    await tester.pumpAndSettle();
    expect(find.text('al gusto'), findsOneWidget);

    await tapVisible(tester, byKey('week-menu-dish-remove-$lasagneId'));
    expect(find.text('Plato quitado del menú.'), findsOneWidget);
    expect(byKey('week-menu-dish-$lasagneId'), findsNothing);
    await tester.tap(find.text('Deshacer'));
    await tester.pumpAndSettle();
    expect(byKey('week-menu-dish-$lasagneId'), findsOneWidget);
  });

  group('guardar', () {
    testWidgets(
      'un menú nuevo: version null, sin choques allergens_confirmed false, la nota normalizada',
      (tester) async {
        final app = await openMenu(tester);
        await addDishes(tester, ['Lasaña a la boloñesa']);
        await tester.enterText(
          byKey('week-menu-note'),
          '  Ten listos 4 táperes  ',
        );
        await tester.pump();
        await tapVisible(tester, byKey('week-menu-save'));
        expect(find.text('Menú guardado.'), findsOneWidget);
        final sent = app.menus.saves.single;
        expect(sent.sessionId, sessionId(2));
        expect(sent.version, isNull);
        expect(sent.allergensConfirmed, isFalse);
        expect(sent.note, 'Ten listos 4 táperes');
        expect(sent.items, lasagneList(4));
        // Guardado: no queda nada por guardar.
        expect(onPressedOf(tester, 'week-menu-save'), isNull);
      },
    );

    testWidgets(
      'con platos que chocan, pide confirmarlos; «Revisar» no guarda y «Guardar igual» guarda con allergens_confirmed',
      (tester) async {
        final app = await openMenu(
          tester,
          booking: buildBooking(
            restrictions: const RequestRestrictions(allergens: [Allergen.milk]),
          ),
        );
        await addDishes(tester, [
          'Lasaña a la boloñesa',
          'Minestrone de verduras',
        ]);
        await tapVisible(tester, byKey('week-menu-save'));
        expect(byKey('week-menu-conflicts-dialog'), findsOneWidget);
        expect(find.text('Platos que chocan con la reserva'), findsOneWidget);
        expect(
          textOf(tester, 'week-menu-conflicts-$lasagneId'),
          'Lasaña a la boloñesa: Lleva: Leche y lácteos',
        );
        expect(byKey('week-menu-conflicts-$minestroneId'), findsNothing);
        await tester.tap(byKey('week-menu-conflicts-review'));
        await tester.pumpAndSettle();
        expect(app.menus.saves, isEmpty);

        await tapVisible(tester, byKey('week-menu-save'));
        await tester.tap(byKey('week-menu-conflicts-confirm'));
        await tester.pumpAndSettle();
        expect(app.menus.saves.single.allergensConfirmed, isTrue);
        expect(find.text('Menú guardado.'), findsOneWidget);
      },
    );

    testWidgets(
      'si otro teléfono lo guardó en el medio: lo dice, «Seguir viendo lo mío» deja lo escrito y «Cargar el guardado» trae el guardado',
      (tester) async {
        final app = await openMenu(
          tester,
          saved: {sessionId(2): savedLasagneMenu()},
        );
        await tapVisible(tester, byKey('week-menu-dish-more-$lasagneId'));
        app.menus.menus[sessionId(2)] = savedLasagneMenu(
          version: 2,
          portions: 8,
        );
        await tapVisible(tester, byKey('week-menu-save'));
        expect(byKey('week-menu-changed-dialog'), findsOneWidget);
        expect(find.text('Otro teléfono cambió este menú'), findsOneWidget);
        await tester.tap(byKey('week-menu-changed-keep'));
        await tester.pumpAndSettle();
        expect(
          textOf(tester, 'week-menu-dish-portions-$lasagneId'),
          '5 porciones',
        );

        await tapVisible(tester, byKey('week-menu-save'));
        await tester.tap(byKey('week-menu-changed-reload'));
        await tester.pumpAndSettle();
        expect(
          textOf(tester, 'week-menu-dish-portions-$lasagneId'),
          '8 porciones',
        );
        expect(onPressedOf(tester, 'week-menu-save'), isNull);
        expect(app.menus.saves.map((s) => s.version), [1, 1]);
      },
    );

    testWidgets('sin conexión: lo dice con «Reintentar» y lo escrito queda', (
      tester,
    ) async {
      final app = await openMenu(tester);
      await addDishes(tester, ['Lasaña a la boloñesa']);
      app.menus.saveFailure = const MenuFailure(MenuFailureKind.unavailable);
      await tapVisible(tester, byKey('week-menu-save'));
      expect(
        find.text(
          'No se pudo guardar. Revisa la conexión y vuelve a intentarlo: lo que escribiste sigue aquí.',
        ),
        findsOneWidget,
      );
      expect(byKey('week-menu-dish-$lasagneId'), findsOneWidget);
      app.menus.saveFailure = null;
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();
      expect(find.text('Menú guardado.'), findsOneWidget);
      expect(app.menus.saves, hasLength(2));
    });

    testWidgets('una sesión que ya no se puede cambiar: lo dice', (
      tester,
    ) async {
      final app = await openMenu(tester);
      await addDishes(tester, ['Lasaña a la boloñesa']);
      app.menus.statuses[sessionId(2)] = SessionStatus.cooked;
      await tapVisible(tester, byKey('week-menu-save'));
      expect(
        find.text(
          'Esta sesión ya no admite cambios de menú (está cancelada, cocinada o cobrada): no se guardó.',
        ),
        findsOneWidget,
      );
      expect(byKey('week-menu-dish-$lasagneId'), findsOneWidget);
    });
  });

  testWidgets(
    'la semana 1 empieza con los platos que eligió la clienta en la web y se puede guardar así',
    (tester) async {
      final app = await openMenu(
        tester,
        n: 1,
        booking: buildBooking(wishes: [risottoId, lasagneId]),
      );
      expect(
        textOf(tester, 'week-menu-from-wishes'),
        'Son los platos que eligió la clienta en la web. Revísalos y guarda el menú.',
      );
      expect(byKey('week-menu-dish-$risottoId'), findsOneWidget);
      expect(byKey('week-menu-dish-$lasagneId'), findsOneWidget);
      expect(onPressedOf(tester, 'week-menu-save'), isNotNull);
      await tapVisible(tester, byKey('week-menu-save'));
      expect(
        [for (final d in app.menus.saves.single.dishes) d.recipe.id],
        [risottoId, lasagneId],
      );
      expect(byKey('week-menu-from-wishes'), findsNothing);
    },
  );

  testWidgets(
    '«Nuevo plato» abre el editor de platos y el plato guardado entra al menú',
    (tester) async {
      final app = await openMenu(tester);
      await tapVisible(tester, byKey('week-menu-add-dish'));
      await tester.tap(byKey('menu-picker-new'));
      await tester.pumpAndSettle();
      expect(find.byType(RecipeEditorScreen), findsOneWidget);
      await tester.enterText(byKey('recipe-name-es'), 'Pastel de choclo');
      await tester.tap(byKey('recipe-save'));
      await tester.pumpAndSettle();

      expect(find.byType(RecipeEditorScreen), findsNothing);
      expect(find.byType(WeekMenuScreen), findsOneWidget);
      final created = app.recipes.saveCalls.single;
      expect(
        textOf(tester, 'week-menu-dish-name-${created.id}'),
        'Pastel de choclo',
      );
      expect(
        find.text('«Pastel de choclo» guardado y agregado al menú.'),
        findsOneWidget,
      );
      expect(onPressedOf(tester, 'week-menu-save'), isNotNull);
    },
  );

  group('volver con cambios sin guardar', () {
    testWidgets(
      'pregunta: «Seguir editando» queda y «Descartar» vuelve a la ficha',
      (tester) async {
        await openMenu(tester);
        await addDishes(tester, ['Lasaña a la boloñesa']);
        await tester.tap(byKey('week-menu-back'));
        await tester.pumpAndSettle();
        expect(byKey('week-menu-discard-dialog'), findsOneWidget);
        await tester.tap(byKey('week-menu-discard-keep'));
        await tester.pumpAndSettle();
        expect(find.byType(WeekMenuScreen), findsOneWidget);

        await tester.tap(byKey('week-menu-back'));
        await tester.pumpAndSettle();
        await tester.tap(byKey('week-menu-discard-confirm'));
        await tester.pumpAndSettle();
        expect(find.byType(WeekMenuScreen), findsNothing);
        expect(find.byType(CookingSessionScreen), findsOneWidget);
        // Una sola vez: el onExit de la ruta no vuelve a preguntar.
        expect(byKey('week-menu-discard-dialog'), findsNothing);
      },
    );

    testWidgets('sin cambios vuelve directo', (tester) async {
      await openMenu(tester);
      await tester.tap(byKey('week-menu-back'));
      await tester.pumpAndSettle();
      expect(byKey('week-menu-discard-dialog'), findsNothing);
      expect(find.byType(CookingSessionScreen), findsOneWidget);
    });

    testWidgets(
      'en /gestione/, irse con un go (como el atrás del navegador) también pregunta',
      (tester) async {
        final app = await openMenu(tester, isWeb: true);
        await addDishes(tester, ['Lasaña a la boloñesa']);
        app.go('/agenda');
        await tester.pumpAndSettle();
        expect(byKey('week-menu-discard-dialog'), findsOneWidget);
        await tester.tap(byKey('week-menu-discard-keep'));
        await tester.pumpAndSettle();
        expect(find.byType(WeekMenuScreen), findsOneWidget);
        expect(byKey('week-menu-dish-$lasagneId'), findsOneWidget);

        app.go('/agenda');
        await tester.pumpAndSettle();
        await tester.tap(byKey('week-menu-discard-confirm'));
        await tester.pumpAndSettle();
        expect(find.byType(WeekMenuScreen), findsNothing);
        expect(find.byType(AgendaScreen), findsOneWidget);
      },
    );
  });

  testWidgets(
    'una sesión cocinada se ve pero no se cambia: el aviso y sin «Guardar»',
    (tester) async {
      await openMenu(
        tester,
        booking: buildBooking(statuses: const {2: SessionStatus.cooked}),
        saved: {sessionId(2): savedLasagneMenu()},
      );
      expect(
        find.text('Sesión «Cocinada»: el menú ya no se puede cambiar.'),
        findsOneWidget,
      );
      expect(byKey('week-menu-save'), findsNothing);
      expect(onPressedOf(tester, 'week-menu-add-dish'), isNull);
      expect(onPressedOf(tester, 'week-menu-add-item'), isNull);
    },
  );

  testWidgets(
    'los campos tienen letra de 16 px y la nota no pide autocompletar',
    (tester) async {
      await openMenu(tester);
      expectReadableInputs(tester);
      await expectNoBrowserAutofill(tester, byKey('week-menu-note'));
      await tapVisible(tester, byKey('week-menu-add-item'));
      expectReadableInputs(tester);
      await expectNoBrowserAutofill(
        tester,
        byKey('shopping-item-name'),
        tap: false,
      );
    },
  );
}
