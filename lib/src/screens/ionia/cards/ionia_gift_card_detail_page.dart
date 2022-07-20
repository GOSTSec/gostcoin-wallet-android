import 'package:cake_wallet/core/execution_state.dart';
import 'package:cake_wallet/ionia/ionia_gift_card.dart';
import 'package:cake_wallet/src/screens/base_page.dart';
import 'package:cake_wallet/src/screens/ionia/widgets/ionia_tile.dart';
import 'package:cake_wallet/src/screens/ionia/widgets/text_icon_button.dart';
import 'package:cake_wallet/src/widgets/alert_background.dart';
import 'package:cake_wallet/src/widgets/alert_with_one_action.dart';
import 'package:cake_wallet/src/widgets/primary_button.dart';
import 'package:cake_wallet/src/widgets/scollable_with_bottom_section.dart';
import 'package:cake_wallet/typography.dart';
import 'package:cake_wallet/utils/show_bar.dart';
import 'package:cake_wallet/utils/show_pop_up.dart';
import 'package:cake_wallet/view_model/ionia/ionia_gift_card_details_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/src/widgets/framework.dart';
import 'package:cake_wallet/generated/i18n.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:mobx/mobx.dart';

class IoniaGiftCardDetailPage extends BasePage {
  IoniaGiftCardDetailPage(this.viewModel);

  final IoniaGiftCardDetailsViewModel viewModel;

  @override
  Widget leading(BuildContext context) {
    if (ModalRoute.of(context).isFirst) {
      return null;
    }

    final _backButton = Icon(
      Icons.arrow_back_ios,
      color: Theme.of(context).primaryTextTheme.title.color,
      size: 16,
    );
    return Padding(
      padding: const EdgeInsets.only(left: 10.0),
      child: SizedBox(
        height: 37,
        width: 37,
        child: ButtonTheme(
          minWidth: double.minPositive,
          child: FlatButton(
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              padding: EdgeInsets.all(0),
              onPressed: () => onClose(context),
              child: _backButton),
        ),
      ),
    );
  }

  @override
  Widget middle(BuildContext context) {
    return Text(
      viewModel.giftCard.legalName,
      style: textLargeSemiBold(color: Theme.of(context).accentTextTheme.display4.backgroundColor),
    );
  }

  @override
  Widget body(BuildContext context) {
    reaction((_) => viewModel.redeemState, (ExecutionState state) {
      if (state is FailureState) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          showPopUp<void>(
              context: context,
              builder: (BuildContext context) {
                return AlertWithOneAction(
                    alertTitle: S.of(context).error,
                    alertContent: state.error,
                    buttonText: S.of(context).ok,
                    buttonAction: () => Navigator.of(context).pop());
              });
        });
      }
    });

    return ScrollableWithBottomSection(
      contentPadding: EdgeInsets.all(24),
      content: Column(
        children: [
          if (viewModel.giftCard.barcodeUrl != null && viewModel.giftCard.barcodeUrl.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 24.0,
                vertical: 24,
              ),
              child: SizedBox(height: 96, width: double.infinity, child: Image.network(viewModel.giftCard.barcodeUrl)),
            ),
          SizedBox(height: 24),
          buildIoniaTile(
            context,
            title: S.of(context).gift_card_number,
            subTitle: viewModel.giftCard.cardNumber,
          ),
          Divider(height: 30),
          buildIoniaTile(
            context,
            title: S.of(context).pin_number,
            subTitle: viewModel.giftCard.cardPin ?? '',
          ),
          Divider(height: 30),
          Observer(builder: (_) =>
            buildIoniaTile(
              context,
              title: S.of(context).amount,
              subTitle: viewModel.giftCard.remainingAmount.toStringAsFixed(2) ?? '0.00',
            )),
          Divider(height: 50),
          TextIconButton(
            label: S.of(context).how_to_use_card,
            onTap: () => _showHowToUseCard(context, viewModel.giftCard),
          ),
        ],
      ),
      bottomSection: Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Observer(builder: (_) {
             if (!viewModel.giftCard.isEmpty) {
              return LoadingPrimaryButton(
                isLoading: viewModel.redeemState is IsExecutingState,
                onPressed: () => viewModel.redeem(),
                text: S.of(context).mark_as_redeemed,
                color: Theme.of(context).accentTextTheme.body2.color,
                textColor: Colors.white);
              }

              return Container();
            })),
    );
  }

  Widget buildIoniaTile(BuildContext context, {@required String title, @required String subTitle}) {
    return IoniaTile(
      title: title,
      subTitle: subTitle,
      onTap: () {
        Clipboard.setData(ClipboardData(text: subTitle));
        showBar<void>(context,
            S.of(context).transaction_details_copied(title));
        });
  }

  void _showHowToUseCard(
    BuildContext context,
    IoniaGiftCard merchant,
  ) {
    showPopUp<void>(
        context: context,
        builder: (BuildContext context) {
          return AlertBackground(
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  SizedBox(height: 10),
                  Container(
                    padding: EdgeInsets.only(top: 24, left: 24, right: 24),
                    margin: EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Theme.of(context).backgroundColor,
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Column(
                      children: [
                        Text(
                          S.of(context).how_to_use_card,
                          style: textLargeSemiBold(
                            color: Theme.of(context).textTheme.body1.color,
                          ),
                        ),
                        Align(
                            alignment: Alignment.bottomLeft,
                            child: Container(
                              constraints: BoxConstraints(
                                maxHeight: MediaQuery.of(context).size.height * 0.5),
                                child: SingleChildScrollView(
                                    child: Column(children: viewModel.giftCard.usageInstructions.map((instruction) {
                                      return [
                                         Padding(
                                            padding: EdgeInsets.all(10),
                                            child: Text(
                                            instruction.header,
                                            style: textLargeSemiBold(
                                              color: Theme.of(context).textTheme.display2.color,
                                            ),
                                          )),
                                          Text(
                                            instruction.body,
                                            style: textMedium(
                                              color: Theme.of(context).textTheme.display2.color,
                                            ),
                                          )
                                      ];
                                    }).expand((e) => e).toList())
                              )
                          )),
                        SizedBox(height: 35),
                        PrimaryButton(
                          onPressed: () => Navigator.pop(context),
                          text: S.of(context).send_got_it,
                          color: Theme.of(context).accentTextTheme.caption.color,
                          textColor: Theme.of(context).primaryTextTheme.title.color,
                        ),
                        SizedBox(height: 21),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      margin: EdgeInsets.only(bottom: 40),
                      child: CircleAvatar(
                        child: Icon(
                          Icons.close,
                          color: Colors.black,
                        ),
                        backgroundColor: Colors.white,
                      ),
                    ),
                  )
                ],
              ),
            ),
          );
        });
  }
}