// Ficha de una clienta de la cocinera (`public.clients`), como la lee el
// directorio de «Nuova prenotazione» para elegirla o encontrar un teléfono
// repetido: solo el nombre, el teléfono, la zona, adultos y niños, el estado
// y su último pedido semanal (para el hogar y el idioma de la reserva). Nada
// de dirección, email, preferencias ni restricciones (la consulta no las
// pide). Dart puro.
//
// Tiene datos de contacto: toString no los muestra y nada se loguea.
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/phone.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

part 'chef_client.freezed.dart';

@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class ChefClient with _$ChefClient {
  const factory ChefClient({
    required String id,
    required String displayName,

    /// Como está guardado (como lo escribió la clienta o la cocinera); para
    /// WhatsApp y para compararlo, [phoneE164].
    String? contactPhone,
    String? zone,
    @Default(1) int adults,
    @Default(0) int kids,

    /// null si es un estado que esta versión no conoce.
    ClientStatus? status,

    /// El último pedido semanal de la ficha; null si no tiene ninguno.
    ClientLatestRequest? latestWeekly,
  }) = _ChefClient;

  const ChefClient._();

  /// Una fila de PostgREST con el pedido embebido (`requests`, una lista de
  /// uno como mucho). Lanza [FormatException] si falta el id o el nombre; un
  /// pedido embebido roto se ignora (vale lo de la ficha).
  factory ChefClient.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['display_name'];
    if (id is! String || id.isEmpty || name is! String || name.trim().isEmpty) {
      throw const FormatException('Ficha inválida');
    }
    return ChefClient(
      id: id,
      displayName: name.trim(),
      contactPhone: _text(json['contact_phone']),
      zone: _text(json['zone']),
      adults: _int(json['adults']) ?? 1,
      kids: _int(json['kids']) ?? 0,
      status: ClientStatus.values
          .where((status) => status.name == json['status'])
          .firstOrNull,
      latestWeekly: _latestWeekly(json['requests']),
    );
  }

  /// El teléfono en E.164 (también si se guardó con las marcas invisibles de
  /// un número pegado), o null si falta o no se puede normalizar.
  String? get phoneE164 {
    final phone = contactPhone;
    return phone == null ? null : phoneFromInput(phone);
  }

  /// Todavía no tuvo una reserva (pidió por la web).
  bool get isProspect => status == ClientStatus.prospect;

  /// Primer nombre, para saludar ("Giulia Rossi" → "Giulia").
  String get firstName {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  /// Solo el id: nada de la clienta.
  @override
  String toString() => 'ChefClient($id)';
}

/// El último pedido semanal de una ficha: de ahí salen el hogar (adultos,
/// niños, días y comidas) y el idioma de una reserva a mano.
@Freezed(fromJson: false, toJson: false)
abstract class ClientLatestRequest with _$ClientLatestRequest {
  const factory ClientLatestRequest({
    required RequestType type,

    /// Un idioma desconocido se lee como italiano.
    @Default(ClientLocale.it) ClientLocale locale,
    int? adults,
    int? kids,
    int? days,

    /// En el orden del enum, sin repetir (como `requests.meals`).
    @Default(<Meal>[]) List<Meal> meals,
    required DateTime createdAt,
  }) = _ClientLatestRequest;
}

ClientLatestRequest? _latestWeekly(Object? json) {
  if (json is! List || json.isEmpty) return null;
  final row = json.first;
  if (row is! Map) return null;
  final type = RequestType.values
      .where((type) => type.name == row['type'])
      .firstOrNull;
  final createdAt = row['created_at'];
  final created = createdAt is String ? DateTime.tryParse(createdAt) : null;
  if (type == null || created == null) return null;
  return ClientLatestRequest(
    type: type,
    locale:
        ClientLocale.values
            .where((locale) => locale.name == row['locale'])
            .firstOrNull ??
        ClientLocale.it,
    adults: _int(row['adults']),
    kids: _int(row['kids']),
    days: _int(row['days']),
    meals: _meals(row['meals']),
    createdAt: created,
  );
}

/// Las comidas conocidas, en el orden del enum y sin repetir (como
/// `_knownValues` de chef_request.dart).
List<Meal> _meals(Object? json) {
  if (json is! List) return const [];
  final names = json.whereType<String>().toSet();
  return [
    for (final meal in Meal.values)
      if (names.contains(meal.name)) meal,
  ];
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Un entero de JSON (puede llegar como 2.0).
int? _int(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}
