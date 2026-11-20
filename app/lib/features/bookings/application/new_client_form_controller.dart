// Borrador del flujo «Nuova cliente»: lo que se escribe (nombre, teléfono,
// zona y dirección) y el hogar y el idioma de la reserva. Es una sola fuente
// para la ficha nueva: el formulario y la hoja leen y escriben acá.
//
// Vive mientras dure el flujo: el elegir lo escucha, así que volver del
// formulario al elegir (con la flecha o el gesto) no lo borra. Se descarta al
// cerrar el elegir, con «Fatto» y al confirmar una reserva a mano.
//
// Tiene datos de la clienta: toString no los muestra y nada se loguea.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/phone.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/clients/application/client_directory_controller.dart';
import 'package:radici/features/clients/domain/chef_client.dart';
import 'package:radici/features/clients/domain/client_search.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart'
    show maxClientAddressLength, normalizeClientAddress;

part 'new_client_form_controller.freezed.dart';

/// Largo máximo del nombre y de la zona (TEXT_LIMITS de
/// _shared/public_request.ts; el servidor cuenta unidades UTF-16 después de
/// cleanOneLine).
const int maxClientNameLength = 80;
const int maxClientZoneLength = 80;

/// Largo máximo del teléfono escrito (TEXT_LIMITS.phone).
const int maxClientPhoneLength = 30;

/// Los campos de texto del formulario.
enum NewClientField { name, phone, zone, address }

/// Lo que dice la línea de la barra de abajo, arriba de «Continua».
enum NewClientBlocker {
  /// Falta el nombre: «Continua» deshabilitado.
  nameMissing,

  /// Después de «Continua»: el teléfono escrito no se puede normalizar.
  phoneInvalid,

  /// Después de «Continua»: un texto pasa el límite del servidor.
  tooLong,
}

@Freezed(toStringOverride: false)
abstract class NewClientForm with _$NewClientForm {
  const factory NewClientForm({
    @Default('') String name,
    @Default('') String phoneText,
    @Default('') String zone,
    @Default('') String address,

    /// Adultos y niños (los muestra el formulario) y días y comidas (solo la
    /// hoja).
    @Default(defaultManualHousehold) BookingHousehold household,
    @Default(ClientLocale.it) ClientLocale locale,

    /// Evelyn tocó los contadores o los chips (en el formulario o en la hoja).
    @Default(false) bool householdTouched,
    @Default(false) bool localeTouched,

    /// Ya tocó «Continua» una vez: desde ahí se muestran los errores.
    @Default(false) bool submitted,
  }) = _NewClientForm;

  const NewClientForm._();

  String get cleanName => cleanOneLine(name);

  String get cleanZone => cleanOneLine(zone);

  /// La dirección como se guarda; null si queda vacía.
  String? get cleanAddress => normalizeClientAddress(cleanOneLine(address));

  /// El teléfono como se escribió, limpio; null si no hay.
  String? get cleanPhone {
    final text = withoutFormatChars(cleanOneLine(phoneText));
    return text.isEmpty ? null : text;
  }

  /// En E.164 (también pegado con las marcas invisibles del iPhone).
  String? get phoneE164 => cleanPhone == null ? null : phoneFromInput(phoneText);

  /// Hay un teléfono escrito que no se puede normalizar.
  bool get phoneInvalid => cleanPhone != null && phoneE164 == null;

  /// Los campos cuyo texto limpio pasa su límite contado como el servidor
  /// (unidades UTF-16): el formateador del campo cuenta grafemas, y un nombre
  /// con emojis puede pasar.
  Set<NewClientField> get tooLong => {
    if (cleanName.length > maxClientNameLength) NewClientField.name,
    if (cleanZone.length > maxClientZoneLength) NewClientField.zone,
    if ((cleanAddress?.length ?? 0) > maxClientAddressLength)
      NewClientField.address,
  };

  /// Nada escrito ni tocado (se puede prellenar desde la búsqueda).
  bool get isEmpty =>
      name.isEmpty &&
      phoneText.isEmpty &&
      zone.isEmpty &&
      address.isEmpty &&
      !householdTouched &&
      !localeTouched;

  bool get canContinue => cleanName.isNotEmpty;

  /// Lo que dice la barra: sin nombre, siempre; el teléfono y los largos,
  /// después del primer «Continua». null: se puede seguir.
  NewClientBlocker? get blocker {
    if (!canContinue) return NewClientBlocker.nameMissing;
    if (!submitted) return null;
    if (phoneInvalid) return NewClientBlocker.phoneInvalid;
    if (tooLong.isNotEmpty) return NewClientBlocker.tooLong;
    return null;
  }

  bool get showPhoneError => submitted && phoneInvalid;

  /// La ficha nueva para el POST (con los textos limpios y el E.164).
  NewClientData toNewClientData() => NewClientData(
    name: cleanName,
    phone: phoneE164,
    zone: cleanZone.isEmpty ? null : cleanZone,
    address: cleanAddress,
  );

  @override
  String toString() => 'NewClientForm(<oculto>)';
}

final newClientFormProvider =
    NotifierProvider.autoDispose<NewClientFormController, NewClientForm>(
      NewClientFormController.new,
    );

class NewClientFormController extends Notifier<NewClientForm> {
  @override
  NewClientForm build() => const NewClientForm();

  void setName(String value) => state = state.copyWith(name: value);

  void setPhone(String value) => state = state.copyWith(phoneText: value);

  void setZone(String value) => state = state.copyWith(zone: value);

  void setAddress(String value) => state = state.copyWith(address: value);

  void stepAdults(int direction) => _step(HouseholdCounter.adults, direction);

  void stepKids(int direction) => _step(HouseholdCounter.kids, direction);

  void _step(HouseholdCounter counter, int direction) {
    final next = state.household.stepped(counter, direction);
    if (next == state.household) return;
    state = state.copyWith(household: next, householdTouched: true);
  }

  /// El hogar que eligió Evelyn en la hoja (con días y comidas).
  void setHousehold(BookingHousehold household) =>
      state = state.copyWith(household: household, householdTouched: true);

  void setLocale(ClientLocale locale) =>
      state = state.copyWith(locale: locale, localeTouched: true);

  /// Con el borrador vacío, lo que se buscó en el elegir: un teléfono va al
  /// teléfono y cualquier otra cosa, al nombre. Si ya tiene algo, no lo toca.
  void prefillIfEmpty(String query) {
    if (!state.isEmpty) return;
    final prefill = newClientPrefill(query);
    state = state.copyWith(
      name: prefill.name ?? '',
      phoneText: prefill.phone ?? '',
    );
  }

  /// «Continua»: desde ahora se muestran los errores. true si se puede seguir.
  bool submit() {
    state = state.copyWith(submitted: true);
    return state.blocker == null;
  }
}

/// El teléfono del formulario contra el directorio.
sealed class PhoneMatch {
  const PhoneMatch();
}

/// Sin teléfono válido o sin coincidencia.
final class NoPhoneMatch extends PhoneMatch {
  const NoPhoneMatch();
}

/// Ya es de esta ficha (la primera en el orden del elegir).
final class PhoneMatchFound extends PhoneMatch {
  const PhoneMatchFound(this.client);

  final ChefClient client;
}

/// El directorio está cargando.
final class PhoneMatchChecking extends PhoneMatch {
  const PhoneMatchChecking();
}

/// El directorio no se pudo leer.
final class PhoneMatchUnchecked extends PhoneMatch {
  const PhoneMatchUnchecked();
}

/// Si el teléfono escrito ya es de una ficha. Con el directorio cargando o
/// con error, lo dice (con una lista de antes, una coincidencia vale igual).
final newClientPhoneMatchProvider = Provider.autoDispose<PhoneMatch>((ref) {
  final phone = ref.watch(newClientFormProvider.select((f) => f.phoneE164));
  if (phone == null) return const NoPhoneMatch();
  final directory = ref.watch(clientDirectoryProvider);
  final clients = directory.value;
  final found = clients == null ? null : findClientByPhone(clients, phone);
  if (found != null) return PhoneMatchFound(found);
  if (directory.isLoading) return const PhoneMatchChecking();
  if (directory.hasError) return const PhoneMatchUnchecked();
  return const NoPhoneMatch();
});
