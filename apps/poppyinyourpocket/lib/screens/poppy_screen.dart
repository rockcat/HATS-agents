/// Poppy's face, and the conversation with her.
///
/// Phase 1 puts the face on screen and lets you type. Phase 2 adds the voice
/// on both sides — push-to-talk in, per-sentence speech and lip sync out.
library;

import 'package:flutter/material.dart';
import 'package:hats_avatar_view/hats_avatar_view.dart';
import 'package:provider/provider.dart';

import '../providers/poppy_state.dart';
import '../widgets/connection_banner.dart';
import '../widgets/transcript_list.dart';

class PoppyScreen extends StatefulWidget {
  const PoppyScreen({super.key});

  @override
  State<PoppyScreen> createState() => _PoppyScreenState();
}

class _PoppyScreenState extends State<PoppyScreen> {
  final _input = TextEditingController();
  final _avatarKey = GlobalKey<AvatarViewState>();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send(PoppyState state) async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    await state.say(text);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PoppyState>();

    if (!state.hasAgent) {
      return Scaffold(
        appBar: AppBar(title: const Text('Poppy')),
        body: _NoAgent(state: state),
      );
    }

    final url = state.avatarUrl;

    return Scaffold(
      appBar: AppBar(
        title: Text(state.agent!.name),
        actions: [
          IconButton(
            tooltip: 'Forget this pairing',
            icon: const Icon(Icons.link_off),
            onPressed: () => context.read<PoppyState>().forget(),
          ),
        ],
      ),
      body: Column(
        children: [
          ConnectionBanner(connection: state.connection, unsent: state.unsentCount),
          // The face. A fixed share of the screen so the transcript always has
          // room — this is a phone, not a kiosk.
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.38,
            child: url == null
                ? const Center(child: Text('No avatar configured'))
                : AvatarView(
                    key: _avatarKey,
                    src: url,
                    config: state.agent!.appearance,
                  ),
          ),
          const Divider(height: 1),
          Expanded(child: TranscriptList(messages: state.transcript, agentName: state.agent!.name)),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(state),
                      decoration: const InputDecoration(
                        hintText: 'Say something to Poppy…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: () => _send(state),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoAgent extends StatelessWidget {
  final PoppyState state;
  const _NoAgent({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.agents.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                state.connection == Connection.online
                    ? 'The runner has no agents deployed. Add one in the Project Designer.'
                    : 'Cannot reach the runner. Poppy runs on your own machine — is it on?',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.read<PoppyState>().refreshAgents(),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    // More than one deployed: let the user say which of them is Poppy.
    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Which agent is yours?'),
        ),
        for (final a in state.agents)
          ListTile(
            title: Text(a.name),
            subtitle: Text(a.specialisation ?? a.hats.join(', ')),
            trailing: a.hasVoice ? const Icon(Icons.volume_up, size: 18) : null,
            onTap: () => context.read<PoppyState>().chooseAgent(a),
          ),
      ],
    );
  }
}
