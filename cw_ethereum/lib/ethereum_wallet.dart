import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/node.dart';
import 'package:cw_core/pathForWallet.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:cw_core/wallet_addresses.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_ethereum/default_erc20_tokens.dart';
import 'package:cw_ethereum/erc20_balance.dart';
import 'package:cw_ethereum/ethereum_client.dart';
import 'package:cw_ethereum/ethereum_exceptions.dart';
import 'package:cw_ethereum/ethereum_formatter.dart';
import 'package:cw_ethereum/ethereum_transaction_credentials.dart';
import 'package:cw_ethereum/ethereum_transaction_history.dart';
import 'package:cw_ethereum/ethereum_transaction_info.dart';
import 'package:cw_ethereum/ethereum_transaction_model.dart';
import 'package:cw_ethereum/ethereum_transaction_priority.dart';
import 'package:cw_ethereum/ethereum_wallet_addresses.dart';
import 'package:cw_ethereum/file.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:hive/hive.dart';
import 'package:hex/hex.dart';
import 'package:mobx/mobx.dart';
import 'package:web3dart/web3dart.dart';
import 'package:bip39/bip39.dart' as bip39;
import 'package:bip32/bip32.dart' as bip32;

part 'ethereum_wallet.g.dart';

class EthereumWallet = EthereumWalletBase with _$EthereumWallet;

abstract class EthereumWalletBase
    extends WalletBase<ERC20Balance, EthereumTransactionHistory, EthereumTransactionInfo>
    with Store {
  EthereumWalletBase({
    required WalletInfo walletInfo,
    required String mnemonic,
    required String password,
    ERC20Balance? initialBalance,
  })  : syncStatus = NotConnectedSyncStatus(),
        _password = password,
        _mnemonic = mnemonic,
        _priorityFees = [],
        _isTransactionUpdating = false,
        _client = EthereumClient(),
        walletAddresses = EthereumWalletAddresses(walletInfo),
        balance = ObservableMap<CryptoCurrency, ERC20Balance>.of(
            {CryptoCurrency.eth: initialBalance ?? ERC20Balance(BigInt.zero)}),
        super(walletInfo) {
    this.walletInfo = walletInfo;
    transactionHistory = EthereumTransactionHistory(walletInfo: walletInfo, password: password);

    if (!Hive.isAdapterRegistered(Erc20Token.typeId)) {
      Hive.registerAdapter(Erc20TokenAdapter());
    }
  }

  final String _mnemonic;
  final String _password;

  late final Box<Erc20Token> erc20TokensBox;

  late final EthPrivateKey _privateKey;

  late EthereumClient _client;

  List<int> _priorityFees;
  int? _gasPrice;
  bool _isTransactionUpdating;

  @override
  WalletAddresses walletAddresses;

  @override
  @observable
  SyncStatus syncStatus;

  @override
  @observable
  late ObservableMap<CryptoCurrency, ERC20Balance> balance;

  Future<void> init() async {
    erc20TokensBox = await Hive.openBox<Erc20Token>(Erc20Token.boxName);
    await walletAddresses.init();
    await transactionHistory.init();
    _privateKey = await getPrivateKey(_mnemonic, _password);
    walletAddresses.address = _privateKey.address.toString();
    await save();
  }

  @override
  int calculateEstimatedFee(TransactionPriority priority, int? amount) {
    try {
      if (priority is EthereumTransactionPriority) {
        return _gasPrice! * _priorityFees[priority.raw];
      }

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

      _client.setListeners(_privateKey.address, _onNewTransaction);
      _updateBalance();

      syncStatus = ConnectedSyncStatus();
    } catch (e) {
      syncStatus = FailedSyncStatus();
    }
  }

  @override
  Future<PendingTransaction> createTransaction(Object credentials) async {
    final _credentials = credentials as EthereumTransactionCredentials;
    final outputs = _credentials.outputs;
    final hasMultiDestination = outputs.length > 1;
    final _erc20Balance = balance[_credentials.currency]!;
    BigInt totalAmount = BigInt.zero;
    BigInt amountToEthereumMultiplier = BigInt.from(pow(10, 18 - ethereumAmountLength));

    if (hasMultiDestination) {
      if (outputs.any((item) => item.sendAll || (item.formattedCryptoAmount ?? 0) <= 0)) {
        throw EthereumTransactionCreationException();
      }

      totalAmount =
          BigInt.from(outputs.fold(0, (acc, value) => acc + (value.formattedCryptoAmount ?? 0))) *
              amountToEthereumMultiplier;

      if (_erc20Balance.balance < totalAmount) {
        throw EthereumTransactionCreationException();
      }
    } else {
      final output = outputs.first;
      final BigInt allAmount = _erc20Balance.balance - BigInt.from(feeRate(_credentials.priority!));
      totalAmount = output.sendAll
          ? allAmount
          : BigInt.from(output.formattedCryptoAmount ?? 0) * amountToEthereumMultiplier;

      if ((output.sendAll && _erc20Balance.balance < totalAmount) ||
          (!output.sendAll && _erc20Balance.balance <= BigInt.zero)) {
        throw EthereumTransactionCreationException();
      }
    }

    final pendingEthereumTransaction = await _client.signTransaction(
      privateKey: _privateKey,
      toAddress: _credentials.outputs.first.address,
      amount: totalAmount.toString(),
      gas: _priorityFees[_credentials.priority!.raw],
      priority: _credentials.priority!,
      currency: _credentials.currency,
      contractAddress: _credentials.currency is Erc20Token
          ? (_credentials.currency as Erc20Token).contractAddress
          : null,
    );

    return pendingEthereumTransaction;
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
  Future<Map<String, EthereumTransactionInfo>> fetchTransactions() async {
    final address = _privateKey.address.hex;
    final transactions = await _client.fetchTransactions(address);

    final List<Future<List<EthereumTransactionModel>>> erc20TokensTransactions = [];

    for (var token in balance.keys) {
      if (token is Erc20Token) {
        erc20TokensTransactions.add(_client.fetchTransactions(
          address,
          contractAddress: token.contractAddress,
        ));
      }
    }

    final tokensTransaction = await Future.wait(erc20TokensTransactions);
    transactions.addAll(tokensTransaction.expand((element) => element));

    final Map<String, EthereumTransactionInfo> result = {};

    for (var transactionModel in transactions) {
      if (transactionModel.isError) {
        continue;
      }

      result[transactionModel.hash] = EthereumTransactionInfo(
        id: transactionModel.hash,
        height: transactionModel.blockNumber,
        ethAmount: transactionModel.amount,
        direction: transactionModel.from == address
            ? TransactionDirection.outgoing
            : TransactionDirection.incoming,
        isPending: false,
        date: transactionModel.date,
        confirmations: transactionModel.confirmations,
        ethFee: BigInt.from(transactionModel.gasUsed) * transactionModel.gasPrice,
        exponent: transactionModel.tokenDecimal ?? 18,
        tokenSymbol: transactionModel.tokenSymbol ?? "ETH",
      );
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
  String get seed => _mnemonic;

  @action
  @override
  Future<void> startSync() async {
    try {
      syncStatus = AttemptingSyncStatus();
      await _updateBalance();
      await updateTransactions();
      _gasPrice = await _client.getGasUnitPrice();
      _priorityFees = await _client.getEstimatedGasForPriorities();

      Timer.periodic(
          const Duration(minutes: 1), (timer) async => _gasPrice = await _client.getGasUnitPrice());
      Timer.periodic(const Duration(minutes: 1),
          (timer) async => _priorityFees = await _client.getEstimatedGasForPriorities());

      syncStatus = SyncedSyncStatus();
    } catch (e) {
      syncStatus = FailedSyncStatus();
    }
  }

  int feeRate(TransactionPriority priority) {
    try {
      if (priority is EthereumTransactionPriority) {
        return _priorityFees[priority.raw];
      }

      return 0;
    } catch (e) {
      return 0;
    }
  }

  Future<String> makePath() async => pathForWallet(name: walletInfo.name, type: walletInfo.type);

  String toJSON() => json.encode({
        'mnemonic': _mnemonic,
        'balance': balance[currency]!.toJSON(),
      });

  static Future<EthereumWallet> open({
    required String name,
    required String password,
    required WalletInfo walletInfo,
  }) async {
    final path = await pathForWallet(name: name, type: walletInfo.type);
    final jsonSource = await read(path: path, password: password);
    final data = json.decode(jsonSource) as Map;
    final mnemonic = data['mnemonic'] as String;
    final balance = ERC20Balance.fromJSON(data['balance'] as String) ?? ERC20Balance(BigInt.zero);

    return EthereumWallet(
      walletInfo: walletInfo,
      password: password,
      mnemonic: mnemonic,
      initialBalance: balance,
    );
  }

  Future<void> _updateBalance() async {
    balance[currency] = await _fetchEthBalance();

    await _fetchErc20Balances();
    await save();
  }

  Future<ERC20Balance> _fetchEthBalance() async {
    final balance = await _client.getBalance(_privateKey.address);
    return ERC20Balance(balance.getInWei);
  }

  Future<void> _fetchErc20Balances() async {
    for (var token in erc20TokensBox.values) {
      try {
        if (token.enabled) {
          balance[token] = await _client.fetchERC20Balances(
            _privateKey.address,
            token.contractAddress,
          );
        } else {
          balance.remove(token);
        }
      } catch (_) {}
    }
  }

  Future<EthPrivateKey> getPrivateKey(String mnemonic, String password) async {
    final seed = bip39.mnemonicToSeed(mnemonic);

    final root = bip32.BIP32.fromSeed(seed);

    const _hdPathEthereum = "m/44'/60'/0'/0";
    const index = 0;
    final addressAtIndex = root.derivePath("$_hdPathEthereum/$index");

    return EthPrivateKey.fromHex(HEX.encode(addressAtIndex.privateKey as List<int>));
  }

  Future<void>? updateBalance() async => await _updateBalance();

  List<Erc20Token> get erc20Currencies => erc20TokensBox.values.toList();

  Future<void> addErc20Token(Erc20Token token) async {
    String? iconPath;
    try {
      iconPath = CryptoCurrency.all
          .firstWhere((element) => element.title.toUpperCase() == token.symbol.toUpperCase())
          .iconPath;
    } catch (_) {}

    final _token = Erc20Token(
      name: token.name,
      symbol: token.symbol,
      contractAddress: token.contractAddress,
      decimal: token.decimal,
      enabled: token.enabled,
      iconPath: iconPath,
    );

    await erc20TokensBox.put(_token.contractAddress, _token);

    if (_token.enabled) {
      balance[_token] = await _client.fetchERC20Balances(
        _privateKey.address,
        _token.contractAddress,
      );
    } else {
      balance.remove(_token);
    }
  }

  Future<void> deleteErc20Token(Erc20Token token) async {
    await token.delete();

    balance.remove(token);
    _updateBalance();
  }

  Future<Erc20Token?> getErc20Token(String contractAddress) async =>
      await _client.getErc20Token(contractAddress);

  void _onNewTransaction(FilterEvent event) {
    _updateBalance();
    // TODO: Add in transaction history
  }

  void addInitialTokens() {
    final initialErc20Tokens = DefaultErc20Tokens().initialErc20Tokens;

    initialErc20Tokens.forEach((token) => erc20TokensBox.put(token.contractAddress, token));
  }

  @override
  Future<void> renameWalletFiles(String newWalletName) async {
    final currentWalletPath = await pathForWallet(name: walletInfo.name, type: type);
    final currentWalletFile = File(currentWalletPath);

    final currentDirPath = await pathForWalletDir(name: walletInfo.name, type: type);
    final currentTransactionsFile = File('$currentDirPath/$transactionsHistoryFileName');

    // Copies current wallet files into new wallet name's dir and files
    if (currentWalletFile.existsSync()) {
      final newWalletPath = await pathForWallet(name: newWalletName, type: type);
      await currentWalletFile.copy(newWalletPath);
    }
    if (currentTransactionsFile.existsSync()) {
      final newDirPath = await pathForWalletDir(name: newWalletName, type: type);
      await currentTransactionsFile.copy('$newDirPath/$transactionsHistoryFileName');
    }

    // Delete old name's dir and files
    await Directory(currentDirPath).delete(recursive: true);
  }
}
