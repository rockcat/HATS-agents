/// Pairing this device with a runner, and remembering it.
///
/// The QR code from the dashboard carries a one-shot URL; fetching it returns
/// an API key. The key is the device's identity from then on — and, deliberately,
/// the only thing that grants authority. Face recognition tells Poppy who she is
/// looking at; it never decides what she is willing to do.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class Pairing {
  final String serverUrl;
  final String apiKey;
  final String username;
  final String? agentId;

  const Pairing({
    required this.serverUrl,
    required this.apiKey,
    required this.username,
    this.agentId,
  });

  Pairing withAgent(String id) =>
      Pairing(serverUrl: serverUrl, apiKey: apiKey, username: username, agentId: id);
}

class PairingException implements Exception {
  final String message;
  PairingException(this.message);
  @override
  String toString() => message;
}

class PairingService {
  static const _store = FlutterSecureStorage();
  static const _keyServer = 'poppy_server_url';
  static const _keyApiKey = 'poppy_api_key';
  static const _keyUsername = 'poppy_username';
  static const _keyAgent = 'poppy_agent_id';

  final http.Client _http;
  PairingService({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  /// Redeem a scanned pairing URL. Single use: the dashboard invalidates it.
  Future<Pairing> redeem(String scannedUrl) async {
    final uri = Uri.tryParse(scannedUrl.trim());
    if (uri == null || !uri.hasScheme) throw PairingException('That is not a pairing code.');

    late http.Response res;
    try {
      res = await _http.get(uri, headers: {'Accept': 'application/json'});
    } on Object catch (err) {
      throw PairingException('Could not reach $uri — is the runner on this network? ($err)');
    }

    if (res.statusCode == 410) throw PairingException('That code has expired. Generate a new one.');
    if (res.statusCode >= 400) throw PairingException('Pairing failed (HTTP ${res.statusCode}).');

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final apiKey = body['apiKey'] as String?;
    if (body['ok'] != true || apiKey == null) {
      throw PairingException(body['error'] as String? ?? 'Pairing failed.');
    }

    // The key is served by the runner itself, so its origin is the runner's.
    final pairing = Pairing(
      serverUrl: uri.replace(path: '', query: '', fragment: '').toString().replaceAll(RegExp(r'/$'), ''),
      apiKey: apiKey,
      username: body['username'] as String? ?? 'you',
    );
    await save(pairing);
    return pairing;
  }

  Future<void> save(Pairing p) async {
    await Future.wait([
      _store.write(key: _keyServer, value: p.serverUrl),
      _store.write(key: _keyApiKey, value: p.apiKey),
      _store.write(key: _keyUsername, value: p.username),
      if (p.agentId != null) _store.write(key: _keyAgent, value: p.agentId),
    ]);
  }

  Future<Pairing?> load() async {
    final serverUrl = await _store.read(key: _keyServer);
    final apiKey = await _store.read(key: _keyApiKey);
    if (serverUrl == null || apiKey == null) return null;
    return Pairing(
      serverUrl: serverUrl,
      apiKey: apiKey,
      username: await _store.read(key: _keyUsername) ?? 'you',
      agentId: await _store.read(key: _keyAgent),
    );
  }

  Future<void> saveAgentId(String id) => _store.write(key: _keyAgent, value: id);

  Future<void> forget() async {
    await Future.wait([
      _store.delete(key: _keyServer),
      _store.delete(key: _keyApiKey),
      _store.delete(key: _keyUsername),
      _store.delete(key: _keyAgent),
    ]);
  }
}
