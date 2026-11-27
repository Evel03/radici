// La lista de ofertas y novedades de la cocina (contrato public-request §13):
// leerla, exportarla y dar de baja a quien se lo pide a Evelyn.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/marketing/data/marketing_contacts_repository.dart';
import 'package:radici/features/marketing/domain/marketing_contact.dart';

/// Los pendientes y confirmados de la cocina de la sesión ([] sin cocina).
final marketingContactsProvider =
    FutureProvider.autoDispose<List<MarketingContact>>((ref) async {
      final chef = ref.watch(currentChefProvider);
      if (chef == null) return const [];
      return ref
          .watch(marketingContactsRepositoryProvider)
          .fetchContacts(chefId: chef.chefId);
    });

/// Los emails de los confirmados, separados por coma y espacio: se pegan tal
/// cual en el campo «Ccn» de un email. Los pendientes no aceptaron todavía.
String confirmedEmails(Iterable<MarketingContact> contacts) => contacts
    .where((c) => c.status == MarketingContactStatus.confirmed)
    .map((c) => c.email)
    .join(', ');

/// Dar de baja desde la app. Vuelve a leer la lista después.
final marketingContactsActionsProvider = Provider<MarketingContactsActions>(
  MarketingContactsActions.new,
);

class MarketingContactsActions {
  MarketingContactsActions(this._ref);

  final Ref _ref;

  /// true si estaba en la lista. Lanza [MarketingContactsFailure].
  Future<bool> withdraw(String email) async {
    try {
      return await _ref
          .read(marketingContactsRepositoryProvider)
          .withdraw(email);
    } finally {
      _ref.invalidate(marketingContactsProvider);
    }
  }
}
