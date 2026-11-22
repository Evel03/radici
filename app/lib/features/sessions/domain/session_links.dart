// «Cómo llegar»: el camino en la app de mapas, desde donde está el teléfono,
// hasta la dirección de la ficha o, si no tiene, hasta la zona del pedido (con
// la ciudad). Dart puro. La dirección y la zona son datos personales: se abren
// por un toque de quien usa la app (Evelyn o un colaborador suyo, que también
// las ve) y nunca se loguean.
//
// En un iPhone o una Mac (también /gestione/ en Safari, instalada en la
// pantalla de inicio), Apple Maps: iOS abre maps.apple.com en la app Mapas.
// En el resto, Google Maps (la app si está instalada, si no la web).

/// La ciudad de la cocina. Se suma a la zona, que la clienta escribe a su
/// manera («Città Alta», «Via Camozzi 50»), para que Mapas la busque ahí y no
/// en otra ciudad.
const String serviceCity = 'Bergamo';

/// Hasta dónde lleva «Cómo llegar».
enum DirectionsTarget {
  /// La dirección de la ficha de la clienta.
  address,

  /// La zona del pedido (o de la ficha), con la ciudad: la ficha no tiene
  /// dirección. No es una dirección verificada: la escribió la clienta en el
  /// formulario web y puede ser solo un barrio.
  zone,
}

/// «Cómo llegar»: el enlace a Mapas y hasta dónde lleva. Lleva la dirección o
/// la zona: no se imprime.
class SessionDirections {
  const SessionDirections({required this.uri, required this.target});

  final Uri uri;
  final DirectionsTarget target;

  @override
  bool operator ==(Object other) =>
      other is SessionDirections && other.uri == uri && other.target == target;

  @override
  int get hashCode => Object.hash(uri, target);

  @override
  String toString() => 'SessionDirections(${target.name})';
}

/// «Cómo llegar» de una sesión: hasta [address] (la de la ficha, como está)
/// o, si no hay, hasta [zone] con la ciudad ([zoneDestination]); null si no
/// hay ninguna.
SessionDirections? sessionDirections({
  required String? address,
  required String? zone,
  required bool apple,
}) {
  final toAddress = directionsUri(destination: address, apple: apple);
  if (toAddress != null) {
    return SessionDirections(uri: toAddress, target: DirectionsTarget.address);
  }
  final toZone = directionsUri(
    destination: zoneDestination(zone),
    apple: apple,
  );
  return toZone == null
      ? null
      : SessionDirections(uri: toZone, target: DirectionsTarget.zone);
}

/// [zone] como destino de Mapas: con «, Bergamo» ([serviceCity]) al final,
/// salvo que ya la nombre (sin mirar mayúsculas); null si está vacía.
String? zoneDestination(String? zone) {
  final text = zone?.trim() ?? '';
  if (text.isEmpty) return null;
  final named = text.toLowerCase().contains(serviceCity.toLowerCase());
  return named ? text : '$text, $serviceCity';
}

/// El enlace para ir hasta [destination], o null si está vacío.
Uri? directionsUri({required String? destination, required bool apple}) {
  final text = destination?.trim() ?? '';
  if (text.isEmpty) return null;
  final encoded = Uri.encodeComponent(text);
  return apple
      ? Uri.parse('https://maps.apple.com/?daddr=$encoded')
      : Uri.parse(
          'https://www.google.com/maps/dir/?api=1&destination=$encoded',
        );
}
