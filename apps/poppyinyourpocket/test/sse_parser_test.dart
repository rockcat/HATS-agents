import 'package:flutter_test/flutter_test.dart';
import 'package:poppy/services/sse_parser.dart';

void main() {
  late SseFrameParser parser;
  setUp(() => parser = SseFrameParser());

  /// Feed lines, collect whatever frames complete.
  List<SseEvent> feed(List<String> lines) =>
      [for (final l in lines) parser.addLine(l)].whereType<SseEvent>().toList();

  group('SseFrameParser', () {
    test('completes a frame at the blank line, not before', () {
      expect(parser.addLine('event: agent_message'), isNull);
      expect(parser.addLine('data: {"content":"hello"}'), isNull);
      final event = parser.addLine('');
      expect(event, isNotNull);
      expect(event!.event, 'agent_message');
      expect(event.data['content'], 'hello');
    });

    test('ignores the keep-alive comment the runner sends every 25 seconds', () {
      expect(feed([': connected', '', ': heartbeat', '']), isEmpty);
    });

    test('joins a data field split across lines', () {
      final events = feed(['event: agent_speech', 'data: {"sentence":', 'data: "one two"}', '']);
      expect(events.single.data['sentence'], 'one two');
    });

    test('skips a malformed frame and keeps going', () {
      final events = feed([
        'event: junk', 'data: {not json', '',
        'event: agent_message', 'data: {"content":"still here"}', '',
      ]);
      expect(events, hasLength(1));
      expect(events.single.data['content'], 'still here');
    });

    test('defaults the event name when only data arrives', () {
      expect(feed(['data: {"a":1}', '']).single.event, 'message');
    });

    test('does not leak the event name into the next frame', () {
      final events = feed([
        'event: agent_speech', 'data: {"a":1}', '',
        'data: {"b":2}', '',
      ]);
      expect(events.map((e) => e.event), ['agent_speech', 'message']);
    });

    test('tolerates a value with no space after the colon', () {
      expect(feed(['event:agent_message', 'data:{"content":"tight"}', '']).single.data['content'],
          'tight');
    });

    test('ignores a blank line when nothing is buffered', () {
      expect(feed(['', '', 'data: {"a":1}', '']), hasLength(1));
    });

    test('drops a partial frame on reset, because its rest is never coming', () {
      parser.addLine('event: agent_message');
      parser.addLine('data: {"content":"half"}');
      parser.reset();
      expect(parser.addLine(''), isNull);
    });
  });
}
