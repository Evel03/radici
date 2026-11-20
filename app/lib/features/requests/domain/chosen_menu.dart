// El menú que eligió el cliente en la pestaña «Menù» de la web
// (`requests.wishes`, migración 20261119150000_menu_web.sql): hasta un plato
// por día del pedido, opcional, en el orden en que los tildó. Evelyn tiene la
// última palabra (alergias, temporada).
//
// Los nombres se leen de `recipes` (los de hoy): `wishes` es un uuid[] sin FK,
// así que no se puede embeber en la fila del pedido. Un plato que después se
// borró del catálogo queda en su lugar, sin nombre. Los nombres de los platos
// no son datos de salud ni de contacto. Dart puro.
import 'package:freezed_annotation/freezed_annotation.dart';

part 'chosen_menu.freezed.dart';

/// Columnas de `recipes` que se leen para el menú elegido: solo los nombres.
const String menuDishColumns = 'id, name_it, name_es, name_en';

/// Los nombres de un plato del catálogo.
@Freezed(fromJson: false, toJson: false)
abstract class MenuDish with _$MenuDish {
  const factory MenuDish({
    required String id,
    required String nameIt,
    String? nameEs,
    String? nameEn,
  }) = _MenuDish;

  const MenuDish._();

  /// Una fila de PostgREST seleccionada con [menuDishColumns]. Lanza
  /// [FormatException] si está rota.
  factory MenuDish.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final nameIt = json['name_it'];
    if (id is! String || id.isEmpty || nameIt is! String) {
      throw const FormatException('Fila de recipes inválida');
    }
    return MenuDish(
      id: id,
      nameIt: nameIt,
      nameEs: _optionalText(json['name_es']),
      nameEn: _optionalText(json['name_en']),
    );
  }

  /// El nombre en [languageCode] (el idioma de la app), con el italiano si
  /// falta la traducción, como en la web.
  String name(String languageCode) => switch (languageCode) {
    'es' => nameEs ?? nameIt,
    'en' => nameEn ?? nameIt,
    _ => nameIt,
  };
}

/// Un plato del menú elegido, en su lugar. [dish] null = ya no existe.
typedef ChosenDish = ({String id, MenuDish? dish});

/// Los platos de [wishes], en ese orden, con los nombres de [found] (los que
/// todavía existen).
List<ChosenDish> chosenDishes(List<String> wishes, Iterable<MenuDish> found) {
  final byId = {for (final dish in found) dish.id: dish};
  return [for (final id in wishes) (id: id, dish: byId[id])];
}

String? _optionalText(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const FormatException('Texto inválido');
  return value.isEmpty ? null : value;
}
