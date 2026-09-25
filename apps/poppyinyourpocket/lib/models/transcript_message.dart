/// One line of the conversation.
class TranscriptMessage {
  final String role; // 'user' | 'assistant' | 'tool'
  final String content;
  final DateTime timestamp;
  final String? toolName;

  /// Not yet accepted by the runner — said while offline, or still in flight.
  /// Kept on the message so the transcript can show it greyed rather than
  /// pretending it was delivered.
  final bool pending;

  const TranscriptMessage({
    required this.role,
    required this.content,
    required this.timestamp,
    this.toolName,
    this.pending = false,
  });

  bool get isUser => role == 'user';

  factory TranscriptMessage.fromJson(Map<String, dynamic> j) => TranscriptMessage(
        role: j['role'] as String? ?? 'assistant',
        content: j['content'] as String? ?? '',
        timestamp: DateTime.tryParse(j['timestamp'] as String? ?? '') ?? DateTime.now(),
        toolName: j['toolName'] as String?,
      );

  TranscriptMessage settled() => TranscriptMessage(
        role: role, content: content, timestamp: timestamp, toolName: toolName, pending: false,
      );
}
