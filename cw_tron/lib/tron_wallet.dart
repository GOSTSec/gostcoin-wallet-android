import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:cw_core/cake_hive.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/pathForWallet.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_evm/evm_chain_wallet_addresses.dart';
import 'package:cw_evm/pending_evm_chain_transaction.dart';
import 'package:cw_tron/default_tron_tokens.dart';
import 'package:cw_tron/file.dart';
import 'package:cw_tron/tron_balance.dart';
import 'package:cw_tron/tron_client.dart';
import 'package:cw_tron/tron_exception.dart';
import 'package:cw_tron/tron_token.dart';
import 'package:cw_tron/tron_transaction_credentials.dart';
import 'package:cw_tron/tron_transaction_history.dart';
import 'package:cw_tron/tron_transaction_info.dart';
import 'package:cw_tron/tron_transaction_model.dart';
import 'package:hive/hive.dart';
import 'package:mobx/mobx.dart';
import 'package:on_chain/tron/tron.dart';
import 'package:bip39/bip39.dart' as bip39;
import 'package:shared_preferences/shared_preferences.dart';

part 'tron_wallet.g.dart';

class TronWallet = TronWalletBase with _$TronWallet;

abstract class TronWalletBase
    extends WalletBase<TronBalance, TronTransactionHistory, TronTransactionInfo> with Store {
  TronWalletBase({
    required WalletInfo walletInfo,
    String? mnemonic,
    String? privateKey,
    required String password,
    TronBalance? initialBalance,
  })  : syncStatus = const NotConnectedSyncStatus(),
        _password = password,
        _mnemonic = mnemonic,
        _hexPrivateKey = privateKey,
        _isTransactionUpdating = false,
        _client = TronClient(),
        walletAddresses = EVMChainWalletAddresses(walletInfo),
        balance = ObservableMap<CryptoCurrency, TronBalance>.of(
          {CryptoCurrency.trx: initialBalance ?? TronBalance(BigInt.zero)},
        ),
        super(walletInfo) {
    this.walletInfo = walletInfo;
    transactionHistory = setUpTransactionHistory(walletInfo, password);

    if (!CakeHive.isAdapterRegistered(TronToken.typeId)) {
      CakeHive.registerAdapter(TronTokenAdapter());
    }

    sharedPrefs.complete(SharedPreferences.getInstance());
  }

  final String? _mnemonic;
  final String? _hexPrivateKey;
  final String _password;

  late final Box<TronToken> tronTokensBox;

  late final TronPrivateKey _tronPrivateKey;

  late final TronPublicKey _tronPublicKey;

  TronPublicKey get tronPublicKey => _tronPublicKey;

  TronPrivateKey get tronPrivateKey => _tronPrivateKey;

  late String _tronAddress;

  late TronClient _client;

  int? _gasPrice;
  int? _estimatedGas;
  bool _isTransactionUpdating;

  // TODO: remove after integrating our own node and having eth_newPendingTransactionFilter
  Timer? _transactionsUpdateTimer;

  @override
  WalletAddresses walletAddresses;

  @override
  @observable
  SyncStatus syncStatus;

  @override
  @observable
  late ObservableMap<CryptoCurrency, TronBalance> balance;

  Completer<SharedPreferences> sharedPrefs = Completer();

  static Future<TronWallet> open({
    required String name,
    required String password,
    required WalletInfo walletInfo,
  }) async {
    final path = await pathForWallet(name: name, type: walletInfo.type);
    final jsonSource = await read(path: path, password: password);
    final data = json.decode(jsonSource) as Map;
    final mnemonic = data['mnemonic'] as String?;
    final privateKey = data['private_key'] as String?;
    final balance = TronBalance.fromJSON(data['balance'] as String) ?? TronBalance(BigInt.zero);

    return TronWallet(
      walletInfo: walletInfo,
      password: password,
      mnemonic: mnemonic,
      privateKey: privateKey,
      initialBalance: balance,
    );
  }

  void addInitialTokens() {
    final initialTronTokens = DefaultTronTokens().initialTronTokens;

    for (var token in initialTronTokens) {
      tronTokensBox.put(token.contractAddress, token);
    }
  }

  Future<void> initTronTokensBox() async {
    final boxName = "${walletInfo.name.replaceAll(" ", "_")}_ ${TronToken.boxName}";
    if (await CakeHive.boxExists(boxName)) {
      tronTokensBox = await CakeHive.openBox<TronToken>(boxName);
    } else {
      tronTokensBox = await CakeHive.openBox<TronToken>(boxName.replaceAll(" ", ""));
    }
  }

  // Future<bool> checkIfScanProviderIsEnabled() async {
  //   bool isPolygonScanEnabled = (await sharedPrefs.future).getBool("use_polygonscan") ?? true;
  //   return isPolygonScanEnabled;
  // }

  TronTransactionInfo getTransactionInfo(TronTransactionModel transactionModel, String address) {
    final model = TronTransactionInfo(
      id: transactionModel.hash,
      tronAmount: transactionModel.amount,
      direction: transactionModel.from == address
          ? TransactionDirection.outgoing
          : TransactionDirection.incoming,
      isPending: false,
      txDate: transactionModel.date,
      txFee: BigInt.from(transactionModel.gasUsed) * transactionModel.gasPrice,
      tokenSymbol: transactionModel.tokenSymbol ?? "TRX",
      to: transactionModel.to,
      from: transactionModel.from,
    );
    return model;
  }

  String idFor(String name, WalletType type) => '${walletTypeToString(type).toLowerCase()}_$name';

  TronTransactionHistory setUpTransactionHistory(WalletInfo walletInfo, String password) {
    return TronTransactionHistory(walletInfo: walletInfo, password: password);
  }

  Future<TronPrivateKey> getPrivateKey({
    String? mnemonic,
    String? privateKey,
    required String password,
  }) async {
    assert(mnemonic != null || privateKey != null);

    if (privateKey != null) {
      return TronPrivateKey(privateKey);
    }

    final seed = bip39.mnemonicToSeed(mnemonic!);

    // Derive a TRON private key from the seed
    final bip44 = Bip44.fromSeed(seed, Bip44Coins.tron);

    // Derive a child key using the default path (first account)
    final childKey = bip44.deriveDefaultPath;

    return TronPrivateKey.fromBytes(childKey.privateKey.raw);
  }

  Future<void> init() async {
    await initTronTokensBox();

    await walletAddresses.init();
    await transactionHistory.init();
    _tronPrivateKey = await getPrivateKey(
      mnemonic: _mnemonic,
      privateKey: _hexPrivateKey,
      password: _password,
    );

    _tronPublicKey = _tronPrivateKey.publicKey();

    _tronAddress = _tronPublicKey.toAddress().toString();

    walletAddresses.address = _tronAddress;

    print('Base58 address: $_tronAddress');
    await save();
  }

  @override
  int calculateEstimatedFee(TransactionPriority priority, int? amount) {
    try {
      // if (priority is EVMChainTransactionPriority) {
      //   final priorityFee = EtherAmount.fromInt(EtherUnit.gwei, priority.tip).getInWei.toInt();
      //   return (_gasPrice! + priorityFee) * (_estimatedGas ?? 0);
      // }

      return 0;
    } catch (e) {
      return 0;
    }
  }

  @override
  Future<void> changePassword(String password) {
    throw UnimplementedError("changePassword");
  }

  @override
  void close() {
    _client.stop();
    _transactionsUpdateTimer?.cancel();
  }

  @action
  @override
  Future<void> connectToNode({required Node node}) async {
    try {
      syncStatus = ConnectingSyncStatus();

      final isConnected = _client.connect(node);

      if (!isConnected) {
        throw Exception("${walletInfo.type.name.toUpperCase()} Node connection failed");
      }

      _setTransactionUpdateTimer();

      syncStatus = ConnectedSyncStatus();
    } catch (e) {
      syncStatus = FailedSyncStatus();
    }
  }

  @action
  @override
  Future<void> startSync() async {
    try {
      syncStatus = AttemptingSyncStatus();
      await _updateBalance();
      await _updateTransactions();
      _gasPrice = await _client.getGasUnitPrice();
      _estimatedGas = await _client.getEstimatedGas();

      Timer.periodic(
          const Duration(minutes: 1), (timer) async => _gasPrice = await _client.getGasUnitPrice());
      Timer.periodic(const Duration(seconds: 10),
          (timer) async => _estimatedGas = await _client.getEstimatedGas());

      syncStatus = SyncedSyncStatus();
    } catch (e) {
      syncStatus = FailedSyncStatus();
    }
  }

  @override
  Future<PendingTransaction> createTransaction(Object credentials) async {
    final _credentials = credentials as TronTransactionCredentials;
    final outputs = _credentials.outputs;
    final hasMultiDestination = outputs.length > 1;

    // final CryptoCurrency transactionCurrency =
    //     balance.keys.firstWhere((element) => element.title == _credentials.currency.title);

    // final _erc20Balance = balance[transactionCurrency]!;
    // BigInt totalAmount = BigInt.zero;
    // int exponent = transactionCurrency is Erc20Token ? transactionCurrency.decimal : 18;
    // num amountToEVMChainMultiplier = pow(10, exponent);

    // // so far this can not be made with Ethereum as Ethereum does not support multiple recipients
    // if (hasMultiDestination) {
    //   if (outputs.any((item) => item.sendAll || (item.formattedCryptoAmount ?? 0) <= 0)) {
    //     throw TronTransactionCreationException(transactionCurrency);
    //   }

    //   final totalOriginalAmount = TronFormatter.parseEVMChainAmountToDouble(
    //       outputs.fold(0, (acc, value) => acc + (value.formattedCryptoAmount ?? 0)));
    //   totalAmount = BigInt.from(totalOriginalAmount * amountToEVMChainMultiplier);

    //   if (_erc20Balance.balance < totalAmount) {
    //     throw TronTransactionCreationException(transactionCurrency);
    //   }
    // } else {
    //   final output = outputs.first;
    //   // since the fees are taken from Ethereum
    //   // then no need to subtract the fees from the amount if send all
    //   final BigInt allAmount;
    //   if (transactionCurrency is Erc20Token) {
    //     allAmount = _erc20Balance.balance;
    //   } else {
    //     allAmount = _erc20Balance.balance -
    //         BigInt.from(calculateEstimatedFee(_credentials.priority!, null));
    //   }
    //   final totalOriginalAmount =
    //       EVMChainFormatter.parseEVMChainAmountToDouble(output.formattedCryptoAmount ?? 0);
    //   totalAmount = output.sendAll
    //       ? allAmount
    //       : BigInt.from(totalOriginalAmount * amountToEVMChainMultiplier);

    //   if (_erc20Balance.balance < totalAmount) {
    //     throw EVMChainTransactionCreationException(transactionCurrency);
    //   }
    // }

    // final pendingEVMChainTransaction = await _client.signTransaction(
    //   privateKey: _tronPrivateKey,
    //   toAddress: _credentials.outputs.first.isParsedAddress
    //       ? _credentials.outputs.first.extractedAddress!
    //       : _credentials.outputs.first.address,
    //   amount: totalAmount.toString(),
    //   gas: _estimatedGas!,
    //   priority: _credentials.priority!,
    //   currency: transactionCurrency,
    //   exponent: exponent,
    //   contractAddress:
    //       transactionCurrency is Erc20Token ? transactionCurrency.contractAddress : null,
    // );

    return PendingEVMChainTransaction(
      sendTransaction: () {},
      signedTransaction: Uint8List(2),
      fee: BigInt.zero,
      amount: '10',
      exponent: 8,
    );
  }

  Future<void> _updateTransactions() async {
    try {
      if (_isTransactionUpdating) {
        return;
      }

      // final isProviderEnabled = await checkIfScanProviderIsEnabled();

      // if (!isProviderEnabled) {
      //   return;
      // }

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
  Future<Map<String, TronTransactionInfo>> fetchTransactions() async {
    final address = _tronAddress;

    final transactions = await _client.fetchTransactions(address);

    final List<Future<List<TronTransactionModel>>> tronTokensTransactions = [];

    for (var token in balance.keys) {
      if (token is TronToken) {
        tronTokensTransactions.add(_client.fetchTransactions(
          address,
          contractAddress: token.contractAddress,
        ));
      }
    }

    final tokensTransaction = await Future.wait(tronTokensTransactions);
    transactions.addAll(tokensTransaction.expand((element) => element));

    final Map<String, TronTransactionInfo> result = {};

    for (var transactionModel in transactions) {
      if (transactionModel.isError) {
        continue;
      }

      result[transactionModel.hash] = getTransactionInfo(transactionModel, address);
    }

    return result;
  }

  @override
  Object get keys => throw UnimplementedError("keys");

  @override
  Future<void> rescan({required int height}) {
    throw UnimplementedError("rescan");
  }

  @override
  Future<void> save() async {
    await walletAddresses.updateAddressesInBox();
    final path = await makePath();
    await write(path: path, password: _password, data: toJSON());
    await transactionHistory.save();
  }

  @override
  String? get seed => _mnemonic;

  @override
  String get privateKey => _tronPrivateKey.toHex();

  Future<String> makePath() async => pathForWallet(name: walletInfo.name, type: walletInfo.type);

  String toJSON() => json.encode({
        'mnemonic': _mnemonic,
        'private_key': privateKey,
        'balance': balance[currency]!.toJSON(),
      });

  Future<void> _updateBalance() async {
    balance[currency] = await _fetchTronBalance();

    await _fetchTronTokenBalances();
    await save();
  }

  Future<TronBalance> _fetchTronBalance() async {
    final balance = await _client.getBalance(_tronAddress);
    return TronBalance(balance.getInWei);
  }

  Future<void> _fetchTronTokenBalances() async {
    for (var token in tronTokensBox.values) {
      try {
        if (token.enabled) {
          balance[token] = await _client.fetchTronTokenBalances(
            _tronAddress,
            token.contractAddress,
          );
        } else {
          balance.remove(token);
        }
      } catch (_) {}
    }
  }

  Future<void>? updateBalance() async => await _updateBalance();

  List<TronToken> get tronCurrencies => tronTokensBox.values.toList();

  Future<void> addTronToken(TronToken token) async {
    String? iconPath;
    try {
      iconPath = CryptoCurrency.all
          .firstWhere((element) => element.title.toUpperCase() == token.symbol.toUpperCase())
          .iconPath;
    } catch (_) {}

    final newToken = TronToken(
      name: token.name,
      symbol: token.symbol,
      contractAddress: token.contractAddress,
      decimal: token.decimal,
      enabled: token.enabled,
      tag: token.tag ?? "TRX",
      iconPath: iconPath,
    );

    await tronTokensBox.put(newToken.contractAddress, newToken);

    if (newToken.enabled) {
      balance[newToken] = await _client.fetchTronTokenBalances(
        _tronAddress,
        newToken.contractAddress,
      );
    } else {
      balance.remove(newToken);
    }
  }

  Future<void> deleteTronToken(TronToken token) async {
    await token.delete();

    balance.remove(token);
    _updateBalance();
  }

  Future<TronToken?> getTronToken(String contractAddress) async =>
      await _client.getTronToken(contractAddress);

  void _onNewTransaction() {
    _updateBalance();
    _updateTransactions();
  }

  @override
  Future<void> renameWalletFiles(String newWalletName) async {
    String transactionHistoryFileNameForWallet = 'tron_transactions.json';

    final currentWalletPath = await pathForWallet(name: walletInfo.name, type: type);
    final currentWalletFile = File(currentWalletPath);

    final currentDirPath = await pathForWalletDir(name: walletInfo.name, type: type);
    final currentTransactionsFile = File('$currentDirPath/$transactionHistoryFileNameForWallet');

    // Copies current wallet files into new wallet name's dir and files
    if (currentWalletFile.existsSync()) {
      final newWalletPath = await pathForWallet(name: newWalletName, type: type);
      await currentWalletFile.copy(newWalletPath);
    }
    if (currentTransactionsFile.existsSync()) {
      final newDirPath = await pathForWalletDir(name: newWalletName, type: type);
      await currentTransactionsFile.copy('$newDirPath/$transactionHistoryFileNameForWallet');
    }

    // Delete old name's dir and files
    await Directory(currentDirPath).delete(recursive: true);
  }

  void _setTransactionUpdateTimer() {
    if (_transactionsUpdateTimer?.isActive ?? false) {
      _transactionsUpdateTimer!.cancel();
    }

    _transactionsUpdateTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _updateTransactions();
      _updateBalance();
    });
  }

  /// Scan Providers:
  ///
  /// EtherScan for Ethereum.
  ///
  /// PolygonScan for Polygon.
  // void updateScanProviderUsageState(bool isEnabled) {
  //   if (isEnabled) {
  //     _updateTransactions();
  //     _setTransactionUpdateTimer();
  //   } else {
  //     _transactionsUpdateTimer?.cancel();
  //   }
  // }

  @override
  String signMessage(String message, {String? address}) =>
      _tronPrivateKey.signPersonalMessage(ascii.encode(message));
}