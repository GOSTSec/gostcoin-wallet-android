import 'package:cake_wallet/bitcoin/bitcoin.dart';
import 'package:cake_wallet/ethereum/ethereum.dart';
import 'package:cake_wallet/haven/haven.dart';
import 'package:cake_wallet/monero/monero.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/wallet_type.dart';

List<TransactionPriority> priorityForWalletType(WalletType type) {
  switch (type) {
    case WalletType.monero:
      return monero!.getTransactionPriorities();
    case WalletType.bitcoin:
      return bitcoin!.getTransactionPriorities();
    case WalletType.litecoin:
      return bitcoin!.getLitecoinTransactionPriorities();
    case WalletType.haven:
      return haven!.getTransactionPriorities();
    case WalletType.ethereum:
      return ethereum!.getTransactionPriorities();
    default:
      return [];
  }
}

