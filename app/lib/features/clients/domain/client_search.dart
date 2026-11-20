// Búsqueda de fichas en «Nuova prenotazione»: por nombre o por teléfono, el
// orden de la lista, el teléfono repetido de «Nuova cliente» y lo que se
// prellena desde la búsqueda. Dart puro.
import 'package:radici/core/phone.dart';
import 'package:radici/features/clients/domain/chef_client.dart';
import 'package:radici/features/recipes/domain/recipe.dart' show foldForSearch;

/// Lo que se escribe para buscar un teléfono: un «+» o una cifra y después
/// cifras, espacios, paréntesis, puntos, barras o guiones.
final RegExp _phoneLike = RegExp(r'^[+\d][\d\s().\/-]*$');
final RegExp _nonDigits = RegExp(r'\D');
final RegExp _spaces = RegExp(r'\s+');

/// Apóstrofos: el recto, los tipográficos (el iPhone escribe ’ con la
/// puntuación inteligente), el modificador, el acento grave y el agudo.
final RegExp _apostrophes = RegExp("['\u2019\u2018\u02bc`\u00b4]");

/// Cifras desde las que la búsqueda es por teléfono.
const int _minPhoneDigits = 3;

/// La búsqueda sin marcas invisibles (un número pegado del iPhone las trae).
String _cleanQuery(String query) => withoutFormatChars(cleanOneLine(query));

/// Para comparar nombres: sin mayúsculas, acentos ni apóstrofos.
String _foldName(String text) => foldForSearch(text).replaceAll(_apostrophes, '');

/// [client] coincide con [query]. Vacía: todas. Si parece un teléfono y
/// tiene 3 cifras o más, se busca en el teléfono (sin el 00 o el + del
/// prefijo); si no, cada palabra tiene que estar en el nombre, sin importar
/// mayúsculas, acentos ni apóstrofos.
bool clientMatchesQuery(ChefClient client, String query) {
  final clean = _cleanQuery(query);
  if (clean.isEmpty) return true;
  if (_phoneLike.hasMatch(clean)) {
    var digits = clean.replaceAll(_nonDigits, '');
    if (digits.length >= _minPhoneDigits) {
      if (digits.startsWith('00')) digits = digits.substring(2);
      final e164 = client.phoneE164;
      final own = e164 != null
          ? e164.substring(1)
          : (client.contactPhone ?? '').replaceAll(_nonDigits, '');
      return own.contains(digits);
    }
  }
  final name = _foldName(client.displayName);
  return _foldName(
    clean,
  ).split(' ').where((word) => word.isNotEmpty).every(name.contains);
}

/// El orden de la lista y del teléfono repetido: primero las fichas que no
/// son prospecto (tienen el historial); entre iguales, la del pedido semanal
/// más reciente (sin ninguno, al final); después el nombre y, al final, el id.
/// Así, entre una ficha y su prospecto gemelo (la misma persona que volvió a
/// pedir por la web), va primero la ficha.
int compareClientsForPicker(ChefClient a, ChefClient b) {
  if (a.isProspect != b.isProspect) return a.isProspect ? 1 : -1;
  final aWeekly = a.latestWeekly?.createdAt;
  final bWeekly = b.latestWeekly?.createdAt;
  if (aWeekly != bWeekly) {
    if (aWeekly == null) return 1;
    if (bWeekly == null) return -1;
    final byWeekly = bWeekly.compareTo(aWeekly);
    if (byWeekly != 0) return byWeekly;
  }
  final byName = foldForSearch(
    a.displayName,
  ).compareTo(foldForSearch(b.displayName));
  return byName != 0 ? byName : a.id.compareTo(b.id);
}

/// Lo que muestra la lista del elegir.
final class ClientPickerView {
  const ClientPickerView({required this.matches, required this.total});

  /// Las que coinciden con la búsqueda, en el orden de
  /// [compareClientsForPicker].
  final List<ChefClient> matches;

  /// Todas las fichas, coincidan o no (0: todavía no hay ninguna).
  final int total;
}

ClientPickerView clientPickerView(
  Iterable<ChefClient> clients, {
  String query = '',
}) {
  final all = clients.toList();
  return ClientPickerView(
    matches: [
      for (final client in all)
        if (clientMatchesQuery(client, query)) client,
    ]..sort(compareClientsForPicker),
    total: all.length,
  );
}

/// La ficha cuyo teléfono es [phoneE164]; con varias, la primera en el orden
/// de [compareClientsForPicker]. null si ninguna.
ChefClient? findClientByPhone(Iterable<ChefClient> clients, String phoneE164) {
  final found = [
    for (final client in clients)
      if (client.phoneE164 == phoneE164) client,
  ]..sort(compareClientsForPicker);
  return found.firstOrNull;
}

/// Lo que «Nuova cliente» prellena con lo que se buscó: lo que parece un
/// teléfono (con cualquier cantidad de cifras) va al teléfono, nunca al
/// nombre; cualquier otra cosa, al nombre.
({String? name, String? phone}) newClientPrefill(String query) {
  final clean = _cleanQuery(query);
  if (clean.isEmpty) return (name: null, phone: null);
  if (_phoneLike.hasMatch(clean)) return (name: null, phone: clean);
  return (name: clean.replaceAll(_spaces, ' ').trim(), phone: null);
}
