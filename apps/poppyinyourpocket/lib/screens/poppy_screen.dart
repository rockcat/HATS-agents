/// Poppy's face, and the conversation with her.
///
/// Phase 1 puts the face on screen and lets you type. Phase 2 adds the voice
/// on both sides — push-to-talk in, per-sentence speech and lip sync out.
library;

import 'package:flutter/material.dart';
import 'package:hats_avatar_view/hats_avatar_view.dart';
import 'package:provider/provider.dart';

import '../providers/poppy_state.dart';
import '../services/voice_input.dart';
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

  /// Hearing you, on the device. Built here rather than in PoppyState
  /// because what it produces goes into this text field, not to the runner —
  /// you read it back and fix it before Poppy ever sees it.
  late final VoiceInput _listener;

  /// What the field held before dictation started, so a correction replaces
  /// only the dictated part rather than everything already typed.
  String _beforeDictation = '';

  @override
  void initState() {
    super.initState();
    // Whoever is speaking — device or server — drives the same face.
    final state = context.read<PoppyState>();
    state.onLipSync = (visemes) => _avatarKey.currentState?.applyLipSync(visemes);
    state.setSpeechMode(state.speechMode);

    _listener = VoiceInput(
      onHeard: _onHeard,
      onState: (_) { if (mounted) setState(() {}); },
      onError: _complain,
    );
  }

  @override
  void dispose() {
    _listener.cancel();
    _input.dispose();
    super.dispose();
  }

  /// Show what was heard, as it settles.
  ///
  /// Written into the field rather than held aside: recognition is usually
  /// nearly right, and the fastest fix is the keyboard already on screen.
  void _onHeard(String text, bool isFinal) {
    final join = _beforeDictation.isEmpty || _beforeDictation.endsWith(' ') ? '' : ' ';
    final full = _beforeDictation + join + text;
    _input.value = TextEditingValue(
      text: full,
      selection: TextSelection.collapsed(offset: full.length),
    );
  }

  void _complain(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleListening() async {
    if (_listener.isListening) {
      await _listener.stop();
    } else {
      _beforeDictation = _input.text;
      await _listener.start();
    }
    if (mounted) setState(() {});
  }

  Future<void> _send(PoppyState state) async {
    // Sending while still listening counts what you just said: the
    // recogniser's last word usually lands before the stop does.
    if (_listener.isListening) await _listener.stop();

    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    _beforeDictation = '';
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
          _CameraButton(offered: state.offersCamera),
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
                      decoration: InputDecoration(
                        hintText: _listener.isListening
                            ? 'Listening…'
                            : 'Say something to Poppy…',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _MicButton(hearing: _listener.state, onPressed: _toggleListening),
                  const SizedBox(width: 4),
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

/// Talk instead of typing.
///
/// Click to start and click to stop, not hold-to-talk. A phone is held in
/// one hand, and a finger pinned to a button for the length of a sentence is
/// both awkward and easy to slip off.
class _MicButton extends StatelessWidget {
  final Hearing hearing;
  final VoidCallback onPressed;
  const _MicButton({required this.hearing, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colours = Theme.of(context).colorScheme;
    final listening = hearing != Hearing.idle;
    return IconButton(
      tooltip: listening ? 'Stop listening' : 'Speak to Poppy',
      // Disabled only while settling: the recogniser is still deciding, and
      // a second tap there would cancel what it is about to hand over.
      onPressed: hearing == Hearing.settling ? null : onPressed,
      style: IconButton.styleFrom(
        backgroundColor: listening ? colours.errorContainer : null,
      ),
      icon: Icon(
        listening ? Icons.mic : Icons.mic_none,
        color: listening ? colours.onErrorContainer : null,
      ),
    );
  }
}

/// Whether Poppy may use the camera.
///
/// Shown whether or not it is granted, so the state is visible rather than
/// something you discover by asking her to look at something and being told
/// she cannot. Tapping prompts; the agent is only offered the tool once the
/// answer is yes.
class _CameraButton extends StatelessWidget {
  final bool offered;
  const _CameraButton({required this.offered});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: offered
            ? 'Poppy can use the camera'
            : 'Let Poppy use the camera',
        icon: Icon(offered ? Icons.photo_camera : Icons.no_photography),
        onPressed: offered
            ? null
            : () async {
                final messenger = ScaffoldMessenger.of(context);
                final granted = await context.read<PoppyState>().requestCamera();
                if (!granted) {
                  messenger.showSnackBar(const SnackBar(
                    content: Text('Without the camera, Poppy cannot see anything.'),
                  ));
                }
              },
      );
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
