/// Poppy's face, and the conversation with her.
///
/// Phase 1 puts the face on screen and lets you type. Phase 2 adds the voice
/// on both sides — push-to-talk in, per-sentence speech and lip sync out.
library;

import 'package:flutter/material.dart';
import 'package:hats_avatar_view/hats_avatar_view.dart';
import 'package:provider/provider.dart';

import '../providers/poppy_state.dart';
import '../services/speaker.dart';
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
  void initState() {
    super.initState();
    // Whoever is speaking — device or server — drives the same face.
    final state = context.read<PoppyState>();
    state.onLipSync = (visemes) => _avatarKey.currentState?.applyLipSync(visemes);
    state.setSpeechMode(state.speechMode);
  }

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
        appBar: AppBar(
          title: const Text('Poppy'),
          // Reachable here on purpose: if the stored address is wrong, this
          // is the only screen you ever see, and re-pairing is the fix.
          actions: [_ForgetButton(serverUrl: state.pairing?.serverUrl)],
        ),
        body: _NoAgent(state: state),
      );
    }

    final url = state.avatarUrl;

    return Scaffold(
      appBar: AppBar(
        title: Text(state.agent!.name),
        actions: [
          _VoiceMenu(mode: state.speechMode),
          _ForgetButton(serverUrl: state.pairing?.serverUrl),
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
                    headers: state.avatarHeaders,
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

/// Unpair, and say which runner is being unpaired from.
///
/// The address is in the tooltip because a wrong one is invisible otherwise —
/// the difference between a working pairing and a dead one is a few
/// characters you never see.
class _ForgetButton extends StatelessWidget {
  final String? serverUrl;
  const _ForgetButton({this.serverUrl});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: serverUrl == null ? 'Forget this pairing' : 'Paired with $serverUrl — tap to forget',
        icon: const Icon(Icons.link_off),
        onPressed: () => context.read<PoppyState>().forget(),
      );
}

/// Where Poppy's voice comes from.
///
/// Stated in the menu rather than buried in settings, because the trade is
/// real and the user is the one who can judge it: the device voice starts
/// instantly and works offline, the server voice is the one the operator
/// chose and moves the mouth accurately.
class _VoiceMenu extends StatelessWidget {
  final SpeechMode mode;
  const _VoiceMenu({required this.mode});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<SpeechMode>(
    tooltip: 'Voice',
      icon: Icon(switch (mode) {
        SpeechMode.device => Icons.phone_android,
        SpeechMode.server => Icons.cloud_queue,
        SpeechMode.off => Icons.volume_off,
      }),
      onSelected: (m) => context.read<PoppyState>().setSpeechMode(m),
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: SpeechMode.device,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.phone_android),
            title: Text('This phone'),
            subtitle: Text('Instant, works offline'),
          ),
        ),
        PopupMenuItem(
          value: SpeechMode.server,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.cloud_queue),
            title: Text('Her own voice'),
            subtitle: Text('Accurate lip sync, needs a connection'),
          ),
        ),
        PopupMenuItem(
          value: SpeechMode.off,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.volume_off),
            title: Text('Silent'),
            subtitle: Text('Read her replies'),
          ),
        ),
      ],
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
                    : 'Cannot reach the runner at\n${state.pairing?.serverUrl ?? 'nowhere'}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              if (state.connection != Connection.online)
                Text(
                  'Poppy runs on your own machine. Check it is running and that the address above is right — unpair to scan a new code.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
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
