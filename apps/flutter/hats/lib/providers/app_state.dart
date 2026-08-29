import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/agent.dart';
import '../models/chat_message.dart';
import '../models/ticket.dart';
import '../models/avatar_config.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/speech_service.dart';
import '../widgets/avatar_view.dart';

class AppState extends ChangeNotifier {
  final AuthService _auth = AuthService();

  String? serverUrl;
  String? apiKey;
  String? username;
  String? projectId;

  List<Agent> agents = [];
  List<ChatMessage> messages = [];
  List<Ticket> tickets = [];
  Map<String, AvatarConfig> _avatarConfigs = {};
  final Map<String, AvatarViewState> _avatarViews = {};

  ApiService? _api;
  SpeechService? _speech;
  StreamSubscription<Map<String, dynamic>>? _sseSub;

  void registerAvatarView(String agentName, AvatarViewState view) {
    _avatarViews[agentName] = view;
  }

  void unregisterAvatarView(String agentName) {
    _avatarViews.remove(agentName);
  }

  ApiService get api {
    assert(_api != null, 'ApiService not initialised — call initFromStorage first');
    return _api!;
  }

  bool get isAuthenticated => apiKey != null && serverUrl != null;
  bool get hasProject => projectId != null;

  Future<bool> initFromStorage() async {
    final creds = await _auth.load();
    if (creds == null) return false;
    serverUrl = creds.serverUrl;
    apiKey = creds.apiKey;
    username = creds.username;
    _api = ApiService(serverUrl: serverUrl!, apiKey: apiKey!);
    _setupSpeech();
    projectId = await _auth.loadProjectId();
    // Always kick off configs; also reload agents + SSE for saved project.
    if (projectId != null) {
      unawaited(_restoreProject(projectId!));
    } else {
      unawaited(_loadAvatarConfigs().then((_) => notifyListeners()));
    }
    return true;
  }

  Future<void> _restoreProject(String id) async {
    try {
      final agentsFuture = _api!.switchProject(id);
      await Future.wait([agentsFuture, _loadAvatarConfigs()]);
      agents = await agentsFuture;
    } catch (_) {}
    notifyListeners();
    _reconnectSse();
  }

  Future<void> setCredentials({
    required String url,
    required String key,
    required String user,
  }) async {
    serverUrl = url;
    apiKey = key;
    username = user;
    await _auth.save(serverUrl: url, apiKey: key, username: user);
    _api = ApiService(serverUrl: url, apiKey: key);
    _setupSpeech();
    unawaited(_loadAvatarConfigs());
    notifyListeners();
  }

  /// Waits for the speaking agent's avatar to finish loading before playing
  /// audio, so that lip sync visemes and audio start at the same time.
  Future<void> _speakWhenReady(
    String content, {
    required String agentName,
    Agent? agent,
  }) async {
    final avatarView = _avatarViews[agentName];
    if (avatarView != null) {
      await avatarView.vrmReady.timeout(
        const Duration(seconds: 12),
        onTimeout: () {},
      );
    }
    await _speech?.speak(
      content,
      agentName: agentName,
      voice: agent?.voice,
      speakerName: agent?.speakerName,
    );
  }

  void _setupSpeech() {
    _speech = SpeechService(_api!);
    _speech!.onLipSync = (agentName, visemes) {
      _avatarViews[agentName]?.applyLipSync(visemes);
    };
    unawaited(_speech!.init());
  }

  Future<void> setProject(String id) async {
    projectId = id;
    await _auth.saveProjectId(id);
    // Load configs and agents in parallel; both needed before first render.
    final agentsFuture = _api!.switchProject(id);
    await Future.wait([agentsFuture, _loadAvatarConfigs()]);
    agents = await agentsFuture;
    messages = [];
    notifyListeners();
    _reconnectSse();
  }

  AvatarConfig? avatarConfigFor(String? filename) =>
      filename == null ? null : _avatarConfigs[filename];

  Future<void> _loadAvatarConfigs() async {
    try {
      final list = await _api!.getAvatarConfigs();
      _avatarConfigs = {for (final c in list) c.file: c};
    } catch (_) {}
  }

  void _reconnectSse() {
    _sseSub?.cancel();
    _sseSub = _api!.connectSse().listen(_handleSseEvent, onError: (_) {
      // reconnect after a delay
      Future.delayed(const Duration(seconds: 5), _reconnectSse);
    });
  }

  void _handleSseEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    switch (type) {
      case 'init':
        final raw = event['agents'] as List<dynamic>?;
        if (raw != null) {
          agents = raw.map((j) => Agent.fromJson(j as Map<String, dynamic>)).toList();
        }
        final rawTickets = event['tickets'] as List<dynamic>?;
        if (rawTickets != null) {
          tickets = rawTickets
              .map((j) => Ticket.fromJson(j as Map<String, dynamic>))
              .toList();
        }
      case 'agent_update':
        final raw = event['agents'] as List<dynamic>?;
        if (raw != null) {
          agents = raw.map((j) => Agent.fromJson(j as Map<String, dynamic>)).toList();
        }
      case 'cli_output':
        if (event['kind'] == 'agent') {
          final from = event['from'] as String?;
          final content = event['content'] as String?;
          if (from != null && content != null && content.isNotEmpty) {
            messages = [
              ...messages,
              ChatMessage(text: content, sender: MessageSender.agent, agentName: from),
            ];
            final agent = agents.where((a) => a.name == from).firstOrNull;
            unawaited(_speakWhenReady(content, agentName: from, agent: agent));
          }
        }
      case 'board_update':
        final board = event['board'] as Map<String, dynamic>?;
        if (board != null) {
          final raw = board['tickets'];
          if (raw is Map<String, dynamic>) {
            tickets = raw.values
                .map((j) => Ticket.fromJson(j as Map<String, dynamic>))
                .toList();
          }
        }
    }
    notifyListeners();
  }

  void addHumanMessage(String text, String agentName) {
    messages = [
      ...messages,
      ChatMessage(text: text, sender: MessageSender.human, agentName: agentName),
    ];
    notifyListeners();
    _api!.sendMessage(agentName, text).catchError((_) => '');
  }

  Future<void> refreshTickets() async {
    try {
      tickets = await _api!.getTickets();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> logout() async {
    _sseSub?.cancel();
    _sseSub = null;
    await _speech?.stop();
    await _api?.logout();
    await _auth.clear();
    serverUrl = null;
    apiKey = null;
    username = null;
    projectId = null;
    _api = null;
    _speech = null;
    agents = [];
    messages = [];
    tickets = [];
    notifyListeners();
  }

  @override
  void dispose() {
    _sseSub?.cancel();
    _speech?.dispose();
    super.dispose();
  }
}
