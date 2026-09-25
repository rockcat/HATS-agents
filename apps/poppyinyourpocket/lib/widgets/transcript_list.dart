import 'package:flutter/material.dart';

import '../models/transcript_message.dart';

/// The conversation, newest at the bottom.
class TranscriptList extends StatefulWidget {
  final List<TranscriptMessage> messages;
  final String agentName;

  const TranscriptList({super.key, required this.messages, required this.agentName});

  @override
  State<TranscriptList> createState() => _TranscriptListState();
}

class _TranscriptListState extends State<TranscriptList> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(TranscriptList old) {
    super.didUpdateWidget(old);
    if (widget.messages.length != old.messages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return Center(
        child: Text('Say hello to ${widget.agentName}.',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: widget.messages.length,
      itemBuilder: (context, i) => _Bubble(message: widget.messages[i], agentName: widget.agentName),
    );
  }
}

class _Bubble extends StatelessWidget {
  final TranscriptMessage message;
  final String agentName;

  const _Bubble({required this.message, required this.agentName});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.isUser;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        // Dimmed until the runner has actually accepted it, so an unsent
        // message never looks delivered.
        child: Opacity(
          opacity: message.pending ? 0.55 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mine ? 'You' : (message.toolName ?? agentName),
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 2),
              Text(message.content),
            ],
          ),
        ),
      ),
    );
  }
}
