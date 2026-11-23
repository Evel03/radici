// Textos del menú de una semana: cuántos platos y renglones tiene, por qué un
// plato choca con la reserva, las cantidades de la lista (1250 g como
// 1,25 kg, con los decimales del idioma) y, del envío a la clienta, por dónde
// salió y por qué falló. Solo presentación: los textos salen del ARB.
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/presentation/recipe_labels.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Desde cuántos gramos o mililitros la lista los muestra en kilos o litros.
const int _bigUnit = 1000;

extension WeekMenuLabels on AppLocalizations {
  /// «4 platos · 23 en la lista de compras».
  String weekMenuSummaryText(WeekMenuSummary summary) =>
      '${weekMenuDishCount(summary.dishes)} · ${weekMenuItemCount(summary.items)}';

  /// Por qué choca un plato: «Lleva: Gluten · Leche y lácteos · No está
  /// marcado como vegetariano».
  String dishConflictText(DishConflict conflict) => [
    if (conflict.allergens.isNotEmpty)
      weekMenuConflictAllergens(
        allergenList(conflict.allergens, separator: ' · '),
      ),
    for (final diet in conflict.diets)
      switch (diet) {
        Diet.vegetarian => weekMenuNotVegetarian,
        Diet.vegan => weekMenuNotVegan,
      },
  ].join(' · ');

  /// Por dónde salió (o sale) un envío: «por email», «por WhatsApp» o «por
  /// email y WhatsApp».
  String menuSendViaText(List<MenuSendChannel> via) {
    final email = via.contains(MenuSendChannel.email);
    final whatsapp = via.contains(MenuSendChannel.whatsapp);
    return email && whatsapp
        ? menuSendViaBoth
        : whatsapp
        ? menuSendViaWhatsApp
        : menuSendViaEmail;
  }

  /// Por qué no se pudo armar la vista previa o mandar el menú. [sending]:
  /// la falla es del envío (sin respuesta, no se sabe si salió; con el email
  /// ya salido, lo dice primero).
  String menuSendFailureText(MenuSendFailure failure, {required bool sending}) {
    final kind = failure.kind;
    if (sending && failure.emailSent) {
      return switch (kind) {
        MenuSendFailureKind.sessionNotEditable =>
          '$menuSendErrorEmailSent ${_notEditable(failure)}',
        MenuSendFailureKind.quoteClosed =>
          '$menuSendErrorEmailSent $menuSendErrorQuoteClosed',
        MenuSendFailureKind.menuChanged ||
        MenuSendFailureKind.quoteChanged => menuSendErrorEmailSent,
        _ => '$menuSendErrorEmailSent $menuSendEmailSentRetry',
      };
    }
    return switch (kind) {
      MenuSendFailureKind.offline ||
      MenuSendFailureKind.timeout ||
      MenuSendFailureKind.unavailable =>
        sending ? menuSendErrorUncertain : menuSendErrorPreviewUnavailable,
      MenuSendFailureKind.untranslatable => menuSendErrorUntranslatable,
      MenuSendFailureKind.notConfigured => menuSendErrorNotConfigured,
      MenuSendFailureKind.rateLimited => menuSendErrorRateLimited,
      MenuSendFailureKind.menuChanged =>
        sending ? menuSendErrorChangedSincePreview : menuSendErrorMenuChanged,
      MenuSendFailureKind.menuEmpty => menuSendErrorEmpty,
      MenuSendFailureKind.quoteClosed => menuSendErrorQuoteClosed,
      MenuSendFailureKind.quoteWeekNotFirst => menuSendErrorQuoteWeekNotFirst,
      MenuSendFailureKind.quoteChanged =>
        sending
            ? menuSendErrorQuoteChangedSincePreview
            : menuSendErrorQuoteChanged,
      MenuSendFailureKind.menuNotFound => menuSendErrorNoMenu,
      MenuSendFailureKind.sessionNotFound => sessionNotFound,
      MenuSendFailureKind.sessionNotEditable => _notEditable(failure),
      MenuSendFailureKind.sessionWithoutRequest => menuSendErrorNoRequest,
      MenuSendFailureKind.noEmail => menuSendErrorNoEmailNow,
      MenuSendFailureKind.noPhone => menuSendErrorNoPhoneNow,
      MenuSendFailureKind.emailFailed => menuSendErrorEmailFailed,
      MenuSendFailureKind.emailUnavailable => menuSendErrorEmailUnavailable,
      MenuSendFailureKind.unauthorized => menuSendErrorUnauthorized,
      MenuSendFailureKind.forbidden => menuSendErrorForbidden,
      MenuSendFailureKind.invalid => menuSendErrorInvalid,
      MenuSendFailureKind.sendNotFound ||
      MenuSendFailureKind.alreadySent ||
      MenuSendFailureKind.conflict ||
      MenuSendFailureKind.server => menuSendErrorServer,
    };
  }

  String _notEditable(MenuSendFailure failure) => switch (failure.status) {
    final status? => menuSendErrorNotEditable(sessionStatus(status)),
    null => menuSendErrorNotEditableUnknown,
  };
}

/// Las cantidades de la lista en el idioma de la interfaz.
class ShoppingFormats {
  ShoppingFormats(BuildContext context)
    : this.forLocale(
        AppLocalizations.of(context),
        Localizations.localeOf(context).toLanguageTag(),
      );

  ShoppingFormats.forLocale(this._l10n, String locale)
    : _number = NumberFormat.decimalPattern(locale);

  final AppLocalizations _l10n;
  final NumberFormat _number;

  /// «300 g», «1,25 kg», «1,5 l», «3 unid.» o «al gusto».
  String amount(IngredientAmount? amount) {
    if (amount == null) return _l10n.recipeUnitToTaste;
    final quantity = amount.quantity;
    final (num value, String unit) = switch (amount.unit) {
      IngredientUnit.g when quantity >= _bigUnit => (
        quantity / _bigUnit,
        _l10n.shoppingUnitKilograms,
      ),
      IngredientUnit.ml when quantity >= _bigUnit => (
        quantity / _bigUnit,
        _l10n.shoppingUnitLiters,
      ),
      IngredientUnit.g => (quantity, _l10n.recipeUnitGrams),
      IngredientUnit.ml => (quantity, _l10n.recipeUnitMilliliters),
      IngredientUnit.pcs => (quantity, _l10n.recipeUnitPieces),
    };
    return _l10n.shoppingAmount(_number.format(value), unit);
  }
}
