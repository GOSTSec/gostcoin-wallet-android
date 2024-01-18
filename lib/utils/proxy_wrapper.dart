import 'dart:io';

import 'package:cake_wallet/store/settings_store.dart';
import 'package:cake_wallet/view_model/settings/tor_connection.dart';
import 'package:socks5_proxy/socks.dart';
import 'package:tor/tor.dart';

// this is the only way to ensure we're making a non-tor connection:
class NullOverrides extends HttpOverrides {
  NullOverrides();

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

class ProxyWrapper {
  ProxyWrapper({
    this.settingsStore,
  });

  SettingsStore? settingsStore;

  HttpClient? _torClient;

  static int get port => Tor.instance.port;

  static bool get enabled => Tor.instance.enabled;

  bool started = false;

  // Method to get or create the Tor proxy instance
  Future<HttpClient> getProxyHttpClient({int? portOverride}) async {
    portOverride = (portOverride == -1 || portOverride == null) ? Tor.instance.port : portOverride;

    if (!started) {
      started = true;
      _torClient = HttpClient();

      // Assign connection factory.
      SocksTCPClient.assignToHttpClient(_torClient!, [
        ProxySettings(
          InternetAddress.loopbackIPv4,
          portOverride,
          password: null,
        ),
      ]);
    }

    return _torClient!;
  }

  Future<HttpClientResponse> makeGet({
    required HttpClient client,
    required Uri uri,
    required Map<String, String>? headers,
  }) async {
    final request = await client.getUrl(uri);
    if (headers != null) {
      headers.forEach((key, value) {
        request.headers.add(key, value);
      });
    }
    return await request.close();
  }

  Future<HttpClientResponse> makePost({
    required HttpClient client,
    required Uri uri,
    required Map<String, String>? headers,
  }) async {
    final request = await client.postUrl(uri);
    if (headers != null) {
      headers.forEach((key, value) {
        request.headers.add(key, value);
      });
    }
    return await request.close();
  }

  Future<HttpClientResponse> get({
    Map<String, String>? headers,
    int? portOverride,
    bool torOnly = false,
    TorConnectionMode? torConnectionMode,
    Uri? clearnetUri,
    Uri? onionUri,
  }) async {
    HttpClient? torClient;
    late bool torEnabled;
    torConnectionMode ??= settingsStore?.torConnectionMode ?? TorConnectionMode.disabled;
    if (torConnectionMode == TorConnectionMode.onionOnly ||
        torConnectionMode == TorConnectionMode.enabled) {
      torEnabled = true;
    } else {
      torEnabled = false;
    }

    if (torConnectionMode == TorConnectionMode.onionOnly && onionUri == null) {
      throw Exception("Cannot connect to clearnet");
    }

    // if tor is enabled, try to connect to the onion url first:
    if (torEnabled) {
      try {
        torClient = await getProxyHttpClient(portOverride: portOverride);
      } catch (_) {}

      if (onionUri != null) {
        try {
          return makeGet(
            client: torClient!,
            uri: onionUri,
            headers: headers,
          );
        } catch (_) {}
      }

      if (clearnetUri != null && torConnectionMode != TorConnectionMode.onionOnly) {
        try {
          return makeGet(
            client: torClient!,
            uri: clearnetUri,
            headers: headers,
          );
        } catch (_) {}
      }
    }

    if (clearnetUri != null && !torOnly && torConnectionMode != TorConnectionMode.onionOnly) {
      try {
        return HttpOverrides.runZoned(
          () {
            return makeGet(
              client: HttpClient(),
              uri: clearnetUri,
              headers: headers,
            );
          },
          createHttpClient: NullOverrides().createHttpClient,
        );
      } catch (_) {
        // we weren't able to get a response:
        rethrow;
      }
    }

    throw Exception("Unable to connect to server");
  }

  Future<HttpClientResponse> post({
    Map<String, String>? headers,
    int? portOverride,
    bool torOnly = false,
    TorConnectionMode? torConnectionMode,
    Uri? clearnetUri,
    Uri? onionUri,
  }) async {
    HttpClient? torClient;
    late bool torEnabled;
    torConnectionMode ??= settingsStore?.torConnectionMode ?? TorConnectionMode.disabled;
    if (torConnectionMode == TorConnectionMode.onionOnly ||
        torConnectionMode == TorConnectionMode.enabled) {
      torEnabled = true;
    } else {
      torEnabled = false;
    }

    if (torConnectionMode == TorConnectionMode.onionOnly && onionUri == null) {
      throw Exception("Cannot connect to clearnet");
    }

    // if tor is enabled, try to connect to the onion url first:

    if (torEnabled) {
      try {
        torClient = await getProxyHttpClient(portOverride: portOverride);
      } catch (_) {}

      if (onionUri != null) {
        try {
          return makePost(
            client: torClient!,
            uri: onionUri,
            headers: headers,
          );
        } catch (_) {}
      }

      if (clearnetUri != null && torConnectionMode != TorConnectionMode.onionOnly) {
        try {
          return makePost(
            client: torClient!,
            uri: clearnetUri,
            headers: headers,
          );
        } catch (_) {}
      }
    }

    if (clearnetUri != null && !torOnly && torConnectionMode != TorConnectionMode.onionOnly) {
      try {
        return HttpOverrides.runZoned(
          () {
            return makePost(
              client: HttpClient(),
              uri: clearnetUri,
              headers: headers,
            );
          },
          createHttpClient: NullOverrides().createHttpClient,
        );
      } catch (_) {
        // we weren't able to get a response:
        rethrow;
      }
    }

    throw Exception("Unable to connect to server");
  }
}