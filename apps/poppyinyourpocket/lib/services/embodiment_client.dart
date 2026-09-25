/// Dart client for the HATS Embodiment API.
///
/// The Dart counterpart of `packages/ui-kit/embodiment-client.js`, and the only
/// thing in this app that knows the runner exists. Everything Poppy is — her
/// roster entry, her face, her voice, what she says — comes through here.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/embodied_agent.dart';
import '../models/transcript_message.dart';
import 'sse_client.dart';

class EmbodimentException implements Exception {
  final String message;
  final int? status;
  EmbodimentException(this.message, [this.status]);

  /// True when retrying later might work — the runner being off, rather than
  /// the request being wrong.
  bool get isTransient => status == null || status == 502 || status == 503 || status == 504;

  @override
  String toString() => message;
}

class EmbodimentClient {
  /// Runner origin, e.g. `http://poppy.local:3001`.
  final String baseUrl;
  final String apiKey;
  final http.Client _http;

  EmbodimentClient({required this.baseUrl, required this.apiKey, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  static const _base = '/api/embodiment/v1';

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$_base$path').replace(queryParameters: query);

  Map<String, String> get _headers => {
        'X-API-Key': apiKey,
        'Accept': 'application/json',
      };

  Future<dynamic> _get(String path, [Map<String, String>? query]) async {
    late http.Response res;
    try {
      res = await _http.get(_uri(path, query), headers: _headers);
    } on Object catch (err) {
      throw EmbodimentException('Cannot reach Poppy: $err');
    }
    if (res.statusCode == 401) throw EmbodimentException('This device is not paired.', 401);
    if (res.statusCode >= 400) {
      throw EmbodimentException(_errorFrom(res.body) ?? 'HTTP ${res.statusCode}', res.statusCode);
    }
    return jsonDecode(res.body);
  }

  static String? _errorFrom(String body) {
    try {
      final parsed = jsonDecode(body);
      return parsed is Map && parsed['error'] is String ? parsed['error'] as String : null;
    } catch (_) {
      return null;
    }
  }

  /// True when the runner answers. Used to drive the connection indicator
  /// rather than waiting for a real request to fail.
  Future<bool> isReachable() async {
    try {
      await _get('/health');
      return true;
    } on EmbodimentException {
      return false;
    }
  }

  Future<List<EmbodiedAgent>> agents() async {
    final body = await _get('/agents') as Map<String, dynamic>;
    return (body['agents'] as List<dynamic>? ?? [])
        .map((a) => EmbodiedAgent.fromJson(a as Map<String, dynamic>))
        .toList();
  }

  Future<EmbodiedAgent> agent(String id) async =>
      EmbodiedAgent.fromJson(await _get('/agents/${Uri.encodeComponent(id)}') as Map<String, dynamic>);

  Future<List<TranscriptMessage>> messages(String id, {String thread = 'general', int limit = 100}) async {
    final body = await _get('/agents/${Uri.encodeComponent(id)}/messages',
        {'thread': thread, 'limit': '$limit'}) as Map<String, dynamic>;
    return (body['messages'] as List<dynamic>? ?? [])
        .map((m) => TranscriptMessage.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  /// Say something. Accepted asynchronously — the reply arrives on the stream.
  Future<void> send(String id, String content, {String thread = 'general'}) async {
    late http.Response res;
    try {
      res = await _http.post(
        _uri('/agents/${Uri.encodeComponent(id)}/messages'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'content': content, 'thread': thread, 'mode': 'chat'}),
      );
    } on Object catch (err) {
      throw EmbodimentException('Cannot reach Poppy: $err');
    }
    // 202 is the success case: accepted, reply to follow.
    if (res.statusCode != 202 && res.statusCode >= 400) {
      throw EmbodimentException(_errorFrom(res.body) ?? 'HTTP ${res.statusCode}', res.statusCode);
    }
  }

  /// Where the avatar model lives. Handed straight to the renderer, which
  /// fetches it itself.
  String avatarUrl(String id) => '$baseUrl$_base/agents/${Uri.encodeComponent(id)}/avatar';

  String backgroundUrl(String id) => '$baseUrl$_base/agents/${Uri.encodeComponent(id)}/background';

  /// The live event stream. Speech, state and replies all arrive here.
  SseClient events({String? agentId}) => SseClient(
        uri: _uri('/events', agentId == null ? null : {'agentId': agentId}),
        headers: _headers,
      );

  void close() => _http.close();
}
