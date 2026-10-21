/// Tools the agent calls that run here, on the phone.
///
/// Everything else an agent can do happens on the runner. A camera cannot: it
/// is attached to this device, and a server-side process has no route to it.
/// So the runner asks, over the event stream this app is already listening on,
/// and the answer is posted back against the request's id.
///
/// Two rules worth keeping:
///
///  * **Declare only what works.** The runner offers the agent exactly what is
///    declared here. A tool listed without the permission to back it becomes a
///    tool the agent calls repeatedly and never gets anything from.
///  * **Always answer.** A request that goes unanswered costs the agent a
///    thirty-second wait before it learns nothing. Failing fast and saying why
///    is better than silence.
library;

import 'dart:async';

import 'embodiment_client.dart';

/// What a tool produced.
///
/// The text always stands on its own. A picture may not survive the trip —
/// the runner drops one too large for the model, and a provider that cannot
/// see ignores it — so an agent reading only the text must still be told
/// what happened.
class DeviceToolResult {
  final String text;

  /// A picture, base64, with no data: prefix.
  final String? imageBase64;
  final String imageMediaType;

  /// Something the runner asked for that the agent must never read.
  ///
  /// A face vector is 192 numbers. Routed through the agent it would cost two
  /// kilobytes of its context, arrive as prose and be retyped wrong — and it
  /// is not information a language model can use. The runner reads this
  /// directly; none of it reaches the conversation.
  final Object? data;

  const DeviceToolResult(this.text, {
    this.imageBase64,
    this.imageMediaType = 'image/jpeg',
    this.data,
  });
}

/// Runs one tool. Returns what the agent should read, and optionally see.
typedef DeviceToolRun = Future<DeviceToolResult> Function(Map<String, dynamic> arguments);

class DeviceTool {
  final String name;
  final String description;

  /// JSON Schema for the arguments, or null when the tool takes none.
  final Map<String, dynamic>? parameters;
  final DeviceToolRun run;

  const DeviceTool({
    required this.name,
    required this.description,
    required this.run,
    this.parameters,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        if (parameters != null) 'parameters': parameters,
      };
}

/// Holds this device's tools and answers the runner's requests for them.
class DeviceToolHost {
  final EmbodimentClient client;
  final String deviceId;
  final String label;

  final Map<String, DeviceTool> _tools = {};

  /// Requests already being handled, so a retransmitted one is not run twice —
  /// taking two photos because a frame arrived twice would be a poor surprise.
  final Set<String> _inFlight = {};

  DeviceToolHost({
    required this.client,
    required this.deviceId,
    this.label = 'phone',
    List<DeviceTool> tools = const [],
  }) {
    for (final tool in tools) {
      _tools[tool.name] = tool;
    }
  }

  List<DeviceTool> get tools => _tools.values.toList();

  /// Is this tool being offered?
  bool has(String name) => _tools.containsKey(name);

  /// Add or replace a tool. Takes effect at the next [declare].
  void add(DeviceTool tool) => _tools[tool.name] = tool;

  /// Withdraw a tool — permission revoked, hardware missing.
  void remove(String name) => _tools.remove(name);

  /// Tell the runner what this device can do. Safe to call again at any time;
  /// the runner replaces the previous list rather than merging.
  /// What this device can do for itself, beyond the tools it offers.
  ///
  /// Not the same thing as a tool: the runner never calls these, it reads
  /// them to decide how to do its own job. Whether a face is embedded here
  /// or on the runner is settled from this.
  Map<String, dynamic> capabilities = const {};

  /// What the runner and this device settled on, after [declare].
  Map<String, dynamic> agreed = const {};

  Future<bool> declare() async {
    try {
      agreed = await client.declareDevice(
        deviceId,
        _tools.values.map((t) => t.toJson()).toList(),
        label: label,
        capabilities: capabilities.isEmpty ? null : capabilities,
      );
      return true;
    } on EmbodimentException {
      // Not fatal. The conversation works without any of this.
      return false;
    }
  }

  /// Stop offering anything — the app is closing or going to the background.
  Future<void> withdraw() async {
    try {
      await client.withdrawDevice(deviceId);
    } on EmbodimentException {
      // The runner drops a device when its stream closes anyway.
    }
  }

  /// Handle one `device_request` frame. Always posts an answer.
  Future<void> handle(Map<String, dynamic> event) async {
    final id = event['id'] as String?;
    final name = event['tool'] as String?;
    if (id == null || name == null || !_inFlight.add(id)) return;

    try {
      final tool = _tools[name];
      if (tool == null) {
        await _answer(id, ok: false, error: 'This device does not offer "$name".');
        return;
      }
      final args = (event['arguments'] as Map?)?.cast<String, dynamic>() ?? const {};
      final produced = await tool.run(args);
      await _answer(id, ok: true, produced: produced);
    } catch (err) {
      // Whatever went wrong, the agent is told. Silence would cost it the full
      // timeout and teach it nothing.
      await _answer(id, ok: false, error: '$err');
    } finally {
      _inFlight.remove(id);
    }
  }

  Future<void> _answer(String id,
      {required bool ok, DeviceToolResult? produced, String? error}) async {
    try {
      await client.sendDeviceResult(id,
          ok: ok,
          result: produced?.text,
          error: error,
          imageBase64: produced?.imageBase64,
          imageMediaType: produced?.imageMediaType ?? 'image/jpeg',
          data: produced?.data);
    } on EmbodimentException {
      // The runner will time the request out; nothing better is available.
    }
  }
}

/// The tools every build offers, whatever else it adds.
///
/// `get_device_time` is deliberately trivial: it needs no permission and no
/// hardware, so it proves the round trip works without anything else being
/// right.
List<DeviceTool> defaultDeviceTools() => [
      DeviceTool(
        name: 'get_device_time',
        description: "The current local time on the user's device, with its time zone. "
            'Useful when the user says "this morning" or "tonight" and you need to know theirs.',
        run: (_) async {
          final now = DateTime.now();
          return DeviceToolResult(
              '${now.toIso8601String()} (${now.timeZoneName}, UTC${_offset(now)})');
        },
      ),
    ];

String _offset(DateTime now) {
  final offset = now.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final hours = offset.inHours.abs().toString().padLeft(2, '0');
  final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
  return '$sign$hours:$minutes';
}
