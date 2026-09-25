/// Server-sent events, with the reconnection a phone needs.
///
/// `package:http` has no EventSource and the browser one is not available
/// here, so this drives [SseFrameParser] straight off the response stream. An
/// `agent_speech` frame reaches the app the moment the runner flushes it —
/// buffering would undo the per-sentence pipeline the server went to trouble
/// to build.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sse_parser.dart';

export 'sse_parser.dart' show SseEvent;

/// Whether the stream is currently carrying events.
enum SseState { connecting, open, closed }

class SseClient {
  final Uri uri;
  final Map<String, String> headers;

  /// How long to wait before reconnecting, doubling to [_maxBackoff]. A phone
  /// loses its connection constantly; hammering the runner helps nobody.
  static const _minBackoff = Duration(seconds: 1);
  static const _maxBackoff = Duration(seconds: 30);

  final _events = StreamController<SseEvent>.broadcast();
  final _state = StreamController<SseState>.broadcast();
  final _parser = SseFrameParser();

  final http.Client Function() _clientFactory;
  http.Client? _http;
  StreamSubscription<String>? _sub;
  Timer? _retry;
  Duration _backoff = _minBackoff;
  bool _closed = false;

  SseClient({
    required this.uri,
    this.headers = const {},
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  Stream<SseEvent> get events => _events.stream;
  Stream<SseState> get state => _state.stream;

  void connect() {
    if (_closed) return;
    _state.add(SseState.connecting);
    _parser.reset();
    final client = _clientFactory();
    _http = client;

    final request = http.Request('GET', uri)
      ..headers.addAll({...headers, 'Accept': 'text/event-stream', 'Cache-Control': 'no-cache'});

    client.send(request).then((response) {
      if (_closed) return;
      if (response.statusCode != 200) {
        _scheduleRetry();
        return;
      }
      _state.add(SseState.open);
      _backoff = _minBackoff; // a good connection earns a fast retry next time

      _sub = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          final event = _parser.addLine(line);
          if (event != null && !_events.isClosed) _events.add(event);
        },
        onDone: _scheduleRetry,
        onError: (_) => _scheduleRetry(),
        cancelOnError: true,
      );
    }).catchError((_) => _scheduleRetry());
  }

  void _scheduleRetry() {
    if (_closed) return;
    _teardown();
    _state.add(SseState.closed);
    _retry = Timer(_backoff, connect);
    _backoff = _backoff * 2 > _maxBackoff ? _maxBackoff : _backoff * 2;
  }

  void _teardown() {
    _sub?.cancel();
    _sub = null;
    _http?.close();
    _http = null;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _retry?.cancel();
    _teardown();
    _state.add(SseState.closed);
    _events.close();
    _state.close();
  }
}
