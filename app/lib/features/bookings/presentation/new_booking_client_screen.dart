// «Nuova prenotazione», a pantalla completa (con X): elegir la clienta de una
// reserva a mano. Arriba, el buscador (por nombre o teléfono, sin autofoco:
// el teclado taparía la lista); en el medio, las fichas; abajo, «Nuova
// cliente», en el tercio inferior también con el teclado abierto. Tocar una
// ficha abre su hoja «Conferma prenotazione».
//
// Mientras esté abierta mantiene vivo el borrador de «Nuova cliente»: volver
// del formulario no lo borra, y se descarta al cerrar esta pantalla.
// Ningún campo lleva autofillHints (Safari ofrecería los datos de Evelyn).
// Solo lee providers: la búsqueda y el orden están en client_search.dart.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/bookings/application/new_client_form_controller.dart';
import 'package:radici/features/bookings/presentation/booking_widgets.dart';
import 'package:radici/features/clients/application/client_directory_controller.dart';
import 'package:radici/features/clients/domain/chef_client.dart';
import 'package:radici/features/clients/domain/client_search.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart'
    show LoadErrorView;
import 'package:radici/features/requests/presentation/request_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

class NewBookingClientScreen extends ConsumerStatefulWidget {
  const NewBookingClientScreen({super.key});

  @override
  ConsumerState<NewBookingClientScreen> createState() =>
      _NewBookingClientScreenState();
}

class _NewBookingClientScreenState
    extends ConsumerState<NewBookingClientScreen> {
  late final TextEditingController _search = TextEditingController(
    text: ref.read(clientSearchQueryProvider),
  );

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setQuery(String text) =>
      ref.read(clientSearchQueryProvider.notifier).set(text);

  void _clearSearch() {
    _search.clear();
    _setQuery('');
  }

  /// «Nuova cliente»: con el borrador vacío, prellenado con lo que se buscó.
  void _newClient() {
    ref
        .read(newClientFormProvider.notifier)
        .prefillIfEmpty(ref.read(clientSearchQueryProvider));
    context.push(AppRoutes.newBookingNewClient);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // El borrador vive mientras esta pantalla esté en la pila.
    ref.listen(newClientFormProvider, (_, _) {});
    final view = ref.watch(clientPickerViewProvider);
    final query = ref.watch(clientSearchQueryProvider);
    final width = MediaQuery.sizeOf(context).width;
    final side = math.max(16.0, (width - bookingMaxContentWidth) / 2);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('new-booking-close'),
          icon: const Icon(Icons.close),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.newBookingAction),
      ),
      // La barra va en el cuerpo: queda arriba del teclado.
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(side, 8, side, 8),
            child: TextField(
              key: const ValueKey('client-search'),
              controller: _search,
              // Sin autofoco (el teclado taparía la lista) ni autofillHints.
              textInputAction: TextInputAction.search,
              // 16 px o más: con menos, iOS agranda la página al enfocar.
              style: theme.textTheme.bodyLarge,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.clientSearchHint,
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        key: const ValueKey('client-search-clear'),
                        tooltip: l10n.clientSearchClear,
                        icon: const Icon(Icons.clear),
                        onPressed: _clearSearch,
                      ),
              ),
              onChanged: _setQuery,
            ),
          ),
          Expanded(
            child: view.when(
              data: (picker) => _ClientList(
                view: picker,
                query: query,
                onClear: _clearSearch,
                side: side,
              ),
              error: (_, _) => LoadErrorView(
                message: l10n.clientsLoadFailed,
                onRetry: () => ref.invalidate(clientDirectoryProvider),
              ),
              loading: () => const Center(
                child: CircularProgressIndicator(
                  key: ValueKey('client-picker-loading'),
                ),
              ),
            ),
          ),
          // «Nuova cliente», siempre habilitado (también si las fichas
          // cargan o no se pudieron leer).
          BookingBottomBar(
            children: [
              FilledButton.icon(
                key: const ValueKey('new-booking-new-client'),
                onPressed: _newClient,
                icon: const Icon(Icons.person_add_alt),
                label: Text(l10n.newClientAction),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ClientList extends StatelessWidget {
  const _ClientList({
    required this.view,
    required this.query,
    required this.onClear,
    required this.side,
  });

  final ClientPickerView view;
  final String query;
  final VoidCallback onClear;
  final double side;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (view.total == 0 || view.matches.isEmpty) {
      final empty = view.total == 0;
      return ListView(
        padding: EdgeInsets.fromLTRB(side + 16, 24, side + 16, 24),
        children: [
          Text(
            empty ? l10n.clientPickerEmpty : l10n.clientPickerNoMatches(query),
            key: ValueKey(
              empty ? 'client-picker-empty' : 'client-picker-no-matches',
            ),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
          if (!empty) ...[
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                key: const ValueKey('client-picker-no-matches-clear'),
                onPressed: onClear,
                child: Text(l10n.clientSearchClear),
              ),
            ),
          ],
        ],
      );
    }
    return ListView.separated(
      key: const ValueKey('client-picker-list'),
      padding: EdgeInsets.symmetric(horizontal: side - 16, vertical: 8),
      itemCount: view.matches.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) => _ClientTile(client: view.matches[index]),
    );
  }
}

/// Una ficha: el nombre; debajo, el teléfono como está guardado y la zona y,
/// si es un prospecto, que todavía no es clienta (separa dos fichas de la
/// misma persona).
class _ClientTile extends StatelessWidget {
  const _ClientTile({required this.client});

  final ChefClient client;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final formats = RequestFormats(context);
    final contact = [
      ?client.contactPhone,
      ?client.zone,
    ].where((part) => part.trim().isNotEmpty).join(' · ');
    final weekly = client.latestWeekly;
    final prospect = !client.isProspect
        ? null
        : weekly == null
        ? l10n.clientPickerProspect
        : l10n.clientPickerProspectSince(
            formats.instantDayMonth(weekly.createdAt),
          );
    final lines = [
      if (contact.isNotEmpty) Text(contact),
      if (prospect != null)
        Text(prospect, key: ValueKey('client-${client.id}-prospect')),
    ];
    return ListTile(
      key: ValueKey('client-${client.id}'),
      title: Text(client.displayName),
      subtitle: lines.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lines,
            ),
      isThreeLine: lines.length > 1,
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(AppRoutes.newBookingSheet(clientId: client.id)),
    );
  }
}
