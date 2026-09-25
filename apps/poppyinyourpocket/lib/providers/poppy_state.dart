/// Everything the app knows, in one place.
///
/// Connection state is first-class rather than an afterthought: a phone is
/// disconnected often, and an assistant that silently swallows what you said
/// is worse than one that admits it cannot hear you.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/embodied_agent.dart';
import '../models/transcript_message.dart';
import '../services/embodiment_client.dart';
import '../services/pairing_service.dart';
import '../services/sse_client.dart';

enum Connection { offline, connecting, online }

class PoppyState extends ChangeNotifier {
  final PairingService _pairing;

  /// How to build the API client. A seam for tests — the queue-while-offline
  /// behaviour is the part most likely to break and the hardest to reach
  /// through a real socket.
  final EmbodimentClient Function(Pairing) _clientFor;

  PoppyState({
    PairingService? pairing,
    EmbodimentClient Function(Pairing)? clientFactory,
  })  : _pairing = pairing ?? PairingService(),
        _clientFor = clientFactory ??
            ((p) => EmbodimentClient(baseUrl: p.serverUrl, apiKey: p.apiKey));

  Pairing? pairing;
  EmbodimentClient? _client;
  SseClient? _sse;
  StreamSubscription<SseEvent>? _eventSub;
  StreamSubscription<SseState>? _stateSub;

  List<EmbodiedAgent> agents = [];
  EmbodiedAgent? agent;
  List<TranscriptMessage> transcript = [];
  Connection connection = Connection.offline;

  /// Said while disconnected, waiting to be sent. Not a queue of requests —
  /// a queue of things you told Poppy that she has not heard yet.
  final List<String> _outbox = [];
  int get unsentCount => _outbox.length;

  bool get isPaired => pairing != null;
  bool get hasAgent => agent != null;
  EmbodimentClient? get client => _client;

  String? get avatarUrl =>
      agent != null && agent!.hasAvatar ? _client?.avatarUrl(agent!.id) : null;

  // ── Startup ────────────────────────────────────────────────────────────────

  Future<void> restore() async {
    pairing = await _pairing.load();
    if (pairing == null) { notifyListeners(); return; }
    _client = _clientFor(pairing!);
    notifyListeners();
    await refreshAgents();
  }

  Future<void> completePairing(Pairing p) async {
    pairing = p;
    _client = _clientFor(p);
    notifyListeners();
    await refreshAgents();
  }

  Future<void> forget() async {
    _disconnect();
    await _pairing.forget();
    pairing = null;
    _client = null;
    agents = [];
    agent = null;
    transcript = [];
    _outbox.clear();
    connection = Connection.offline;
    notifyListeners();
  }

  // ── Choosing the agent ─────────────────────────────────────────────────────

  Future<void> refreshAgents() async {
    if (_client == null) return;
    _setConnection(Connection.connecting);
    try {
      agents = await _client!.agents();
      _setConnection(Connection.online);
    } on EmbodimentException {
      _setConnection(Connection.offline);
      notifyListeners();
      return;
    }

    // Reuse the remembered agent when it is still deployed, otherwise take the
    // only one there is. Poppy in Your Pocket is a one-agent app.
    final remembered = agents.where((a) => a.id == pairing?.agentId);
    final chosen = remembered.isNotEmpty
        ? remembered.first
        : (agents.length == 1 ? agents.first : null);
    if (chosen != null) {
      await chooseAgent(chosen);
    } else {
      notifyListeners();
    }
  }

  Future<void> chooseAgent(EmbodiedAgent a) async {
    agent = a;
    await _pairing.saveAgentId(a.id);
    notifyListeners();
    await _loadTranscript();
    _connectStream();
  }

  Future<void> _loadTranscript() async {
    if (_client == null || agent == null) return;
    try {
      transcript = await _client!.messages(agent!.id, limit: 100);
      notifyListeners();
    } on EmbodimentException {
      // Keep whatever is on screen; the stream will fill in from here.
    }
  }

  // ── The live stream ────────────────────────────────────────────────────────

  void _connectStream() {
    _disconnect();
    if (_client == null || agent == null) return;

    final sse = _client!.events(agentId: agent!.id);
    _sse = sse;
    _stateSub = sse.state.listen((s) {
      _setConnection(switch (s) {
        SseState.open => Connection.online,
        SseState.connecting => Connection.connecting,
        SseState.closed => Connection.offline,
      });
      if (s == SseState.open) unawaited(_flushOutbox());
    });
    _eventSub = sse.events.listen(_onEvent);
    sse.connect();
  }

  void _onEvent(SseEvent e) {
    switch (e.event) {
      case 'agent_message':
        if (e.data['agentId'] != agent?.id) return;
        transcript.add(TranscriptMessage(
          role: e.data['role'] as String? ?? 'assistant',
          content: e.data['content'] as String? ?? '',
          timestamp: DateTime.tryParse(e.data['timestamp'] as String? ?? '') ?? DateTime.now(),
        ));
        notifyListeners();

      case 'agent_state':
        if (e.data['agentId'] != agent?.id) return;
        agent = EmbodiedAgent(
          id: agent!.id, name: agent!.name, hats: agent!.hats,
          state: e.data['state'] as String? ?? agent!.state,
          activity: e.data['activity'] as String? ?? '',
          hasVoice: agent!.hasVoice, hasAvatar: agent!.hasAvatar,
          avatarFile: agent!.avatarFile, specialisation: agent!.specialisation,
          appearance: agent!.appearance,
        );
        notifyListeners();

      case 'agent_speech':
        // Audio and visemes are handled by the speaker, wired up in phase 2.
        onSpeech?.call(e.data);
    }
  }

  /// Set by the screen that owns the avatar and the audio player.
  void Function(Map<String, dynamic>)? onSpeech;

  @visibleForTesting
  void setConnectionForTest(Connection c) {
    _setConnection(c);
    if (c == Connection.online) unawaited(_flushOutbox());
  }

  void _setConnection(Connection c) {
    if (connection == c) return;
    connection = c;
    notifyListeners();
  }

  void _disconnect() {
    _eventSub?.cancel();
    _stateSub?.cancel();
    _sse?.close();
    _eventSub = null;
    _stateSub = null;
    _sse = null;
  }

  // ── Talking ────────────────────────────────────────────────────────────────

  /// Say something. Held in the outbox while offline rather than lost.
  Future<void> say(String text) async {
    final content = text.trim();
    if (content.isEmpty || _client == null || agent == null) return;

    transcript.add(TranscriptMessage(
      role: 'user', content: content, timestamp: DateTime.now(),
      pending: connection != Connection.online,
    ));
    notifyListeners();

    if (connection != Connection.online) {
      _outbox.add(content);
      return;
    }
    try {
      await _client!.send(agent!.id, content);
      _settleLast();
    } on EmbodimentException catch (err) {
      if (err.isTransient) {
        _outbox.add(content);
        _setConnection(Connection.offline);
      } else {
        rethrow;
      }
    }
  }

  /// Send what was said while disconnected, oldest first, stopping at the
  /// first failure so nothing is sent out of order.
  Future<void> _flushOutbox() async {
    while (_outbox.isNotEmpty && _client != null && agent != null) {
      try {
        await _client!.send(agent!.id, _outbox.first);
        _outbox.removeAt(0);
      } on EmbodimentException {
        return;
      }
    }
    for (var i = 0; i < transcript.length; i++) {
      if (transcript[i].pending) transcript[i] = transcript[i].settled();
    }
    notifyListeners();
  }

  void _settleLast() {
    final i = transcript.lastIndexWhere((m) => m.pending);
    if (i >= 0) transcript[i] = transcript[i].settled();
    notifyListeners();
  }

  @override
  void dispose() {
    _disconnect();
    _client?.close();
    super.dispose();
  }
}
