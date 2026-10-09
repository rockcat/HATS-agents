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
import '../services/device_tools.dart';
import '../services/embodiment_client.dart';
import '../services/pairing_service.dart';
import '../services/speaker.dart';
import '../services/sse_client.dart';

enum Connection { offline, connecting, online }

class PoppyState extends ChangeNotifier {
  final PairingService _pairing;

  /// How to build the API client. A seam for tests — the queue-while-offline
  /// behaviour is the part most likely to break and the hardest to reach
  /// through a real socket.
  final EmbodimentClient Function(Pairing) _clientFor;

  /// How to build a voice. A seam for tests, and the reason the platform TTS
  /// plugin is not constructed until something actually intends to speak —
  /// it reaches for a binding the moment it exists.
  final Speaker Function(SpeechMode, PoppyState)? _speakerFor;

  PoppyState({
    PairingService? pairing,
    EmbodimentClient Function(Pairing)? clientFactory,
    Speaker Function(SpeechMode, PoppyState)? speakerFactory,
  })  : _pairing = pairing ?? PairingService(),
        _speakerFor = speakerFactory,
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

  /// What this phone can do for Poppy that the runner cannot.
  DeviceToolHost? deviceTools;
  String? _deviceId;

  /// Said while disconnected, waiting to be sent. Not a queue of requests —
  /// a queue of things you told Poppy that she has not heard yet.
  final List<String> _outbox = [];
  int get unsentCount => _outbox.length;

  bool get isPaired => pairing != null;
  bool get hasAgent => agent != null;
  EmbodimentClient? get client => _client;

  String? get avatarUrl =>
      agent != null && agent!.hasAvatar ? _client?.avatarUrl(agent!.id) : null;

  /// What the avatar WebView needs to fetch the model: the Embodiment API
  /// authenticates `/api/*`, and a WebView carries no cookie.
  Map<String, String> get avatarHeaders =>
      pairing == null ? const {} : {'X-API-Key': pairing!.apiKey};

  // ── Startup ────────────────────────────────────────────────────────────────

  Future<void> restore() async {
    pairing = await _pairing.load();
    if (pairing == null) { notifyListeners(); return; }
    _client = _clientFor(pairing!);
    await _buildDeviceHost();
    notifyListeners();
    await refreshAgents();
  }

  Future<void> completePairing(Pairing p) async {
    pairing = p;
    _client = _clientFor(p);
    await _buildDeviceHost();
    notifyListeners();
    await refreshAgents();
  }

  /// Tell the runner what this phone can do. Failure is not fatal: the
  /// conversation works with no device tools at all.
  Future<void> _announceDevice() async { await deviceTools?.declare(); }

  /// Offer this phone to the runner as somewhere tools can run.
  Future<void> _buildDeviceHost() async {
    if (_client == null) return;
    _deviceId ??= await _pairing.deviceId();
    deviceTools = DeviceToolHost(
      client: _client!,
      deviceId: _deviceId!,
      label: pairing?.username ?? 'phone',
      tools: defaultDeviceTools(),
    );
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
    // The server speaker is bound to one agent, so it is rebuilt — but only
    // if one was already in use. Choosing an agent is not asking to talk.
    if (_speaker is! SilentSpeaker) {
      await _speaker.dispose();
      _speaker = _buildSpeaker();
    }
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

    final sse = _client!.events(agentId: agent!.id, deviceId: _deviceId);
    _sse = sse;
    _stateSub = sse.state.listen((s) {
      _setConnection(switch (s) {
        SseState.open => Connection.online,
        SseState.connecting => Connection.connecting,
        SseState.closed => Connection.offline,
      });
      if (s == SseState.open) {
        unawaited(_flushOutbox());
        // Declared after the stream is up, not before: the runner drops a
        // device when its stream closes, so declaring first would announce
        // tools and immediately withdraw them on a reconnect.
        unawaited(_announceDevice());
      }
    });
    _eventSub = sse.events.listen(_onEvent);
    sse.connect();
  }

  @visibleForTesting
  void handleEventForTest(String event, Map<String, dynamic> data) =>
      _onEvent(SseEvent(event, data));

  void _onEvent(SseEvent e) {
    switch (e.event) {
      case 'agent_message':
        if (e.data['agentId'] != agent?.id) return;
        final role = e.data['role'] as String? ?? 'assistant';
        final content = e.data['content'] as String? ?? '';
        transcript.add(TranscriptMessage(
          role: role,
          content: content,
          timestamp: DateTime.tryParse(e.data['timestamp'] as String? ?? '') ?? DateTime.now(),
        ));
        notifyListeners();
        if (role == 'assistant') unawaited(_speakReply(content));

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
        // Another client asked the runner to speak. Nothing to do here —
        // this app drives its own voice through the Speaker.
        break;

      case 'device_request':
        // Poppy wants something only this phone can do.
        unawaited(deviceTools?.handle(e.data) ?? Future.value());
    }
  }

  // ── Speaking ───────────────────────────────────────────────────────────────

  /// Where Poppy's voice comes from. The device by default: it needs no
  /// connection, costs the server nothing, and starts talking immediately.
  /// The trade is lip sync — see `speaker.dart`.
  SpeechMode speechMode = SpeechMode.device;
  Speaker _speaker = const SilentSpeaker();

  /// Mouth shapes, handed to whatever is rendering the face.
  void Function(List<Map<String, dynamic>>)? onLipSync;

  /// Rebuild the speaker for the current mode. Safe to call repeatedly.
  Future<void> setSpeechMode(SpeechMode mode) async {
    speechMode = mode;
    await _speaker.dispose();
    _speaker = _buildSpeaker();
    notifyListeners();
  }

  Speaker _buildSpeaker() {
    final custom = _speakerFor;
    if (custom != null) return custom(speechMode, this);

    void lip(List<Map<String, dynamic>> v) => onLipSync?.call(v);
    return switch (speechMode) {
      SpeechMode.device => DeviceSpeaker(onLipSync: lip),
      SpeechMode.server when _client != null && agent != null =>
        ServerSpeaker(client: _client!, agentId: agent!.id, onLipSync: lip),
      _ => const SilentSpeaker(),
    };
  }

  /// Say a reply out loud, if Poppy is meant to have a voice at all.
  ///
  /// Failure here is never allowed to break the conversation: a silent reply
  /// you can still read beats an error over a voice.
  Future<void> _speakReply(String text) async {
    if (speechMode == SpeechMode.off) return;
    try {
      await _speaker.speak(text);
    } catch (_) {
      // Voices are an enhancement. The text is already on screen.
    }
  }

  /// Cut Poppy off — talking over you is worse than silence.
  Future<void> hush() => _speaker.stop();

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
    _speaker.dispose();
    _client?.close();
    super.dispose();
  }
}
