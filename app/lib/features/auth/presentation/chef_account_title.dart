// El nombre con el que se muestra la cuenta del lado de la cocinera (Impostazioni
// y el menú de la cuenta): el de la cocinera o, si entró un colaborador suyo,
// «Colaborador de Evelyn». Un solo lugar, para que todas las pantallas digan lo
// mismo.
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/l10n/app_localizations.dart';

String chefAccountTitle(AppLocalizations l10n, ChefAccount chef) =>
    chef.collaborator
    ? l10n.settingsCollaboratorOf(chef.displayName)
    : chef.displayName;
