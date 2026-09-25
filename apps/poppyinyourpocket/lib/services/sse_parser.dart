/// The server-sent events wire format, as a pure line-at-a-time parser.
///
/// Separated from the socket because the framing is the fiddly part — a frame
/// is only complete at a blank line, `data:` can repeat across lines, and
/// keep-alive comments look like content if you squint. None of that needs I/O
/// to test.
library;

import 'dart:convert';

class SseEvent {
  final String event;
  final Map<String, dynamic> data;
  const SseEvent(this.event, this.data);
}

class SseFrameParser {
  String _event = 'message';
  final StringBuffer _data = StringBuffer();

  /// Feed one line. Returns an event when the line completed a frame.
  SseEvent? addLine(String line) {
    if (line.isEmpty) {
      final frame = _data.isEmpty ? null : _decode(_event, _data.toString());
      _event = 'message';
      _data.clear();
      return frame;
    }
    // A line starting with a colon is a comment — the runner's keep-alive.
    if (line.startsWith(':')) return null;

    if (line.startsWith('event:')) {
      _event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      if (_data.isNotEmpty) _data.write('\n');
      _data.write(line.substring(5).trimLeft());
    }
    return null;
  }

  /// Drop a partial frame — after a disconnect, its rest is never coming.
  void reset() {
    _event = 'message';
    _data.clear();
  }

  static SseEvent? _decode(String event, String raw) {
    try {
      final parsed = jsonDecode(raw);
      // A malformed frame is skipped; the stream carries on.
      return parsed is Map<String, dynamic> ? SseEvent(event, parsed) : null;
    } catch (_) {
      return null;
    }
  }
}
