// «Cómo llegar»: la dirección de la ficha en la app de mapas, con el camino
// desde donde está el teléfono. Dart puro. La dirección es un dato personal:
// se abre por un toque de Evelyn y nunca se loguea.
//
// En un iPhone o una Mac (también /gestione/ en Safari, instalada en la
// pantalla de inicio), Apple Maps: iOS abre maps.apple.com en la app Mapas.
// En el resto, Google Maps (la app si está instalada, si no la web).

/// El enlace para ir hasta [address], o null si no hay dirección.
Uri? directionsUri({required String? address, required bool apple}) {
  final destination = address?.trim() ?? '';
  if (destination.isEmpty) return null;
  final encoded = Uri.encodeComponent(destination);
  return apple
      ? Uri.parse('https://maps.apple.com/?daddr=$encoded')
      : Uri.parse(
          'https://www.google.com/maps/dir/?api=1&destination=$encoded',
        );
}
