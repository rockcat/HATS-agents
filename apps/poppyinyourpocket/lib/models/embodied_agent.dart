import 'package:hats_avatar_view/hats_avatar_view.dart';

/// An agent as the Embodiment API presents it.
///
/// Only the parts this app uses. `appearance` matters more than it looks: the
/// avatar endpoint returns a model with no camera in it, so without the
/// framing the runner sends, a client can download 18 MB and render a nostril.
class EmbodiedAgent {
  final String id;
  final String name;
  final List<String> hats;
  final String state;
  final String activity;
  final bool hasVoice;
  final bool hasAvatar;
  final String? avatarFile;
  final String? specialisation;
  final AvatarConfig? appearance;

  const EmbodiedAgent({
    required this.id,
    required this.name,
    this.hats = const [],
    this.state = 'idle',
    this.activity = '',
    this.hasVoice = false,
    this.hasAvatar = false,
    this.avatarFile,
    this.specialisation,
    this.appearance,
  });

  factory EmbodiedAgent.fromJson(Map<String, dynamic> j) {
    final identity = (j['identity'] as Map<String, dynamic>?) ?? const {};
    final appearance = j['appearance'] as Map<String, dynamic>?;
    return EmbodiedAgent(
      id: j['id'] as String? ?? '',
      name: j['name'] as String? ?? '',
      hats: (j['hats'] as List<dynamic>? ?? []).map((h) => h.toString()).toList(),
      state: j['state'] as String? ?? 'idle',
      activity: j['activity'] as String? ?? '',
      hasVoice: j['hasVoice'] as bool? ?? false,
      hasAvatar: j['hasAvatar'] as bool? ?? false,
      avatarFile: identity['avatar'] as String?,
      specialisation: identity['specialisation'] as String?,
      appearance: appearance == null ? null : AvatarConfig.fromJson(appearance),
    );
  }
}
