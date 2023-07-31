import 'dart:convert';

import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/pathForWallet.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_nano/file.dart';
import 'package:cw_nano/nano_balance.dart';
import 'package:cw_nano/nano_client.dart';
import 'package:cw_nano/nano_transaction_credentials.dart';
import 'package:cw_nano/nano_transaction_history.dart';
import 'package:cw_nano/nano_transaction_info.dart';
import 'package:cw_nano/nano_util.dart';
import 'package:cw_nano/nano_wallet_info.dart';
import 'package:cw_nano/nano_wallet_keys.dart';
import 'package:cw_nano/pending_nano_transaction.dart';
import 'package:mobx/mobx.dart';
import 'dart:async';
import 'package:cw_nano/nano_wallet_addresses.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:nanodart/nanodart.dart';
import 'package:web3dart/web3dart.dart';
import 'package:bip39/bip39.dart' as bip39;
import 'package:bip32/bip32.dart' as bip32;

part 'nano_wallet.g.dart';

class NanoWallet = NanoWalletBase with _$NanoWallet;

abstract class NanoWalletBase
    extends WalletBase<NanoBalance, NanoTransactionHistory, NanoTransactionInfo> with Store {
  NanoWalletBase({
    required NanoWalletInfo walletInfo,
    required String mnemonic,
    required String password,
    NanoBalance? initialBalance,
  })  : syncStatus = NotConnectedSyncStatus(),
        _password = password,
        _mnemonic = mnemonic,
        _derivationType = walletInfo.derivationType,
        _isTransactionUpdating = false,
        _client = NanoClient(),
        walletAddresses = NanoWalletAddresses(walletInfo),
        balance = ObservableMap<CryptoCurrency, NanoBalance>.of({
          CryptoCurrency.nano: initialBalance ??
              NanoBalance(currentBalance: BigInt.zero, receivableBalance: BigInt.zero)
        }),
        super(walletInfo) {
    this.walletInfo = walletInfo;
    transactionHistory = NanoTransactionHistory(walletInfo: walletInfo, password: password);
  }

  final String _mnemonic;
  final String _password;
  final DerivationType _derivationType;

  late final String _privateKey;
  late final String _publicAddress;
  late final String _seedKey;

  late NanoClient _client;
  bool _isTransactionUpdating;

  @override
  WalletAddresses walletAddresses;

  @override
  @observable
  SyncStatus syncStatus;

  @override
  @observable
  late ObservableMap<CryptoCurrency, NanoBalance> balance;

  // initialize the different forms of private / public key we'll need:
  Future<void> init() async {
    final String type = (_derivationType == DerivationType.nano) ? "standard" : "hd";

    _seedKey = bip39.mnemonicToEntropy(_mnemonic).toUpperCase();
    _privateKey = await NanoUtil.uniSeedToPrivate(_seedKey, 0, type);
    _publicAddress = await NanoUtil.uniSeedToAddress(_seedKey, 0, type);
    this.walletInfo.address = _publicAddress;

    await walletAddresses.init();
    await transactionHistory.init();
    await save();
  }

  @override
  int calculateEstimatedFee(TransactionPriority priority, int? amount) {
    return 0; // always 0 :)
  }

  @override
  Future<void> changePassword(String password) {
    print("e");
    throw UnimplementedError("changePassword");
  }

  @override
  void close() {
    _client.stop();
  }

  @action
  @override
  Future<void> connectToNode({required Node node}) async {
    try {
      syncStatus = ConnectingSyncStatus();
      final isConnected = _client.connect(node);
      if (!isConnected) {
        throw Exception("Ethereum Node connection failed");
      }
      // _client.setListeners(_privateKey.address, _onNewTransaction);
      _updateBalance();
      syncStatus = ConnectedSyncStatus();
    } catch (e) {
      syncStatus = FailedSyncStatus();
    }
  }

  @override
  Future<PendingTransaction> createTransaction(Object credentials) async {
    credentials = credentials as NanoTransactionCredentials;

    BigInt runningAmount = BigInt.zero;
    await _updateBalance();
    BigInt runningBalance = balance[currency]?.currentBalance ?? BigInt.zero;

    final List<Map<String, String>> blocks = [];
    String? previousHash;

    for (var txOut in credentials.outputs) {
      late BigInt amt;
      if (txOut.sendAll) {
        amt = balance[currency]?.currentBalance ?? BigInt.zero;
      } else {
        amt = BigInt.tryParse(
                NanoUtil.getAmountAsRaw(txOut.cryptoAmount ?? "0", NanoUtil.rawPerNano)) ??
            BigInt.zero;
      }

      runningBalance = runningBalance - amt;

      final block = await _client.constructSendBlock(
        amountRaw: amt.toString(),
        destinationAddress: txOut.address,
        privateKey: _privateKey,
        balanceAfterTx: runningBalance,
        previousHash: previousHash,
      );
      previousHash = NanoBlocks.computeStateHash(
        NanoAccountType.NANO,
        block["account"]!,
        block["previous"]!,
        block["representative"]!,
        BigInt.parse(block["balance"]!),
        block["link"]!,
      );

      blocks.add(block);
      runningAmount += amt;
    }

    try {
      if (runningAmount > balance[currency]!.currentBalance || runningBalance < BigInt.zero) {
        throw Exception(("Trying to send more than entire balance!"));
      }
    } catch (e) {
      rethrow;
    }

    return PendingNanoTransaction(
      amount: runningAmount,
      fee: 0,
      id: "",
      nanoClient: _client,
      blocks: blocks,
    );
  }

  Future<void> updateTransactions() async {
    try {
      if (_isTransactionUpdating) {
        return;
      }

      _isTransactionUpdating = true;
      final transactions = await fetchTransactions();
      transactionHistory.addMany(transactions);
      await transactionHistory.save();
      _isTransactionUpdating = false;
    } catch (_) {
      _isTransactionUpdating = false;
    }
  }

  @override
  Future<Map<String, NanoTransactionInfo>> fetchTransactions() async {
    String address = _publicAddress;

    final transactions = await _client.fetchTransactions(address);

    final Map<String, NanoTransactionInfo> result = {};

    for (var transactionModel in transactions) {
      result[transactionModel.hash] = NanoTransactionInfo(
        id: transactionModel.hash,
        amountRaw: transactionModel.amount,
        height: transactionModel.height,
        direction: transactionModel.account == address
            ? TransactionDirection.outgoing
            : TransactionDirection.incoming,
        confirmed: transactionModel.confirmed,
        date: transactionModel.date ?? DateTime.now(),
        confirmations: transactionModel.confirmed ? 1 : 0,
      );
    }

    return result;
  }

  @override
  NanoWalletKeys get keys {
    return NanoWalletKeys(seedKey: _seedKey);
  }

  @override
  Future<void> rescan({required int height}) async {
    fetchTransactions();
    _updateBalance();
    return;
  }

  @override
  Future<void> save() async {
    await walletAddresses.updateAddressesInBox();
    final path = await makePath();
    await write(path: path, password: _password, data: toJSON());
    await transactionHistory.save();
  }

  @override
  String get seed => _mnemonic;

  @action
  @override
  Future<void> startSync() async {
    try {
      syncStatus = AttemptingSyncStatus();
      await _updateBalance();
      await updateTransactions();

      syncStatus = SyncedSyncStatus();
    } catch (e) {
      syncStatus = FailedSyncStatus();
    }
  }

  Future<String> makePath() async => pathForWallet(name: walletInfo.name, type: walletInfo.type);

  String toJSON() => json.encode({
        'seedKey': _seedKey,
        'mnemonic': _mnemonic,
        // 'balance': balance[currency]!.toJSON(),
        'derivationType': _derivationType.toString()
      });

  static Future<NanoWallet> open({
    required String name,
    required String password,
    required WalletInfo walletInfo,
  }) async {
    final path = await pathForWallet(name: name, type: walletInfo.type);
    final jsonSource = await read(path: path, password: password);
    final data = json.decode(jsonSource) as Map;
    final mnemonic = data['mnemonic'] as String;
    final balance = NanoBalance.fromString(
        formattedCurrentBalance: data['balance'] as String? ?? "0",
        formattedReceivableBalance: "0");

    DerivationType derivationType = DerivationType.bip39;
    if (data['derivationType'] == "DerivationType.nano") {
      derivationType = DerivationType.nano;
    }

    final nanoWalletInfo = NanoWalletInfo(
      walletInfo: walletInfo,
      derivationType: derivationType,
    );

    return NanoWallet(
      walletInfo: nanoWalletInfo,
      password: password,
      mnemonic: mnemonic,
      initialBalance: balance,
    );
  }

  Future<void> _updateBalance() async {
    balance[currency] = await _client.getBalance(_publicAddress);
    await save();
  }

  Future<void>? updateBalance() async => await _updateBalance();

  void _onNewTransaction(FilterEvent event) {
    throw UnimplementedError();
  }

  @override
  Future<void> renameWalletFiles(String newWalletName) async {
    print("rename");
    throw UnimplementedError();
  }
}