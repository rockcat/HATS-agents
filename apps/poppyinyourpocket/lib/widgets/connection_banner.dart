import 'package:flutter/material.dart';

import '../providers/poppy_state.dart';

/// Says plainly when Poppy cannot hear you.
///
/// Silence is the wrong failure mode for an assistant: if what you said is
/// sitting in an outbox rather than on its way, you need to know now.
class ConnectionBanner extends StatelessWidget {
  final Connection connection;
  final int unsent;

  const ConnectionBanner({super.key, required this.connection, this.unsent = 0});

  @override
  Widget build(BuildContext context) {
    if (connection == Connection.online && unsent == 0) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final (String text, Color background, IconData icon) = switch (connection) {
      Connection.online => (
          '$unsent message${unsent == 1 ? '' : 's'} still to send',
          scheme.tertiaryContainer,
          Icons.upload,
        ),
      Connection.connecting => ('Reconnecting…', scheme.surfaceContainerHighest, Icons.sync),
      Connection.offline => (
          unsent == 0
              ? 'Offline — Poppy cannot hear you'
              : 'Offline — $unsent message${unsent == 1 ? '' : 's'} saved for when she can',
          scheme.errorContainer,
          Icons.cloud_off,
        ),
    };

    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(
        children: [
          Icon(icon, size: 15),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}
