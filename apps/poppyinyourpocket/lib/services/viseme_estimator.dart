/// Guessing mouth shapes from spelling, for speech the server did not make.
///
/// Piper hands back real phoneme timings from Rhubarb. The platform voices do
/// not: Android and iOS will tell you *which word* they are on and when, and
/// nothing more. So when speech is synthesised on the device, the mouth is
/// driven from the letters of each word spread across the time it takes to say
/// it.
///
/// This is an approximation and looks like one under scrutiny — English
/// spelling is a poor guide to English sound. It is markedly better than the
/// alternative, which is a mouth flapping at a fixed rate, and it costs a
/// connection and a round trip less than the real thing.
library;

/// One mouth shape, in the shape the avatar renderer already consumes.
class Viseme {
  final String viseme;
  final double start;
  final double end;
  const Viseme(this.viseme, this.start, this.end);

  Map<String, dynamic> toJson() => {'viseme': viseme, 'start': start, 'end': end};
}

/// Vowels hold the shape; consonants pass through. Weighting them differently
/// is most of what stops the result looking like a chattering puppet.
const _vowelWeight = 2.2;
const _consonantWeight = 1.0;

/// Above this many shapes a word strobes rather than speaks, so longer words
/// get their segments merged instead.
const _maxSegments = 8;

/// Digraphs first — `th` is not `t` then `h`, and `oo` is not two `o`s.
const _digraphs = <String, String>{
  'th': 'viseme_TH',
  'sh': 'viseme_SS',
  'ch': 'viseme_SS',
  'ph': 'viseme_FF',
  'oo': 'viseme_OO',
  'ou': 'viseme_OO',
  'ow': 'viseme_OO',
  'ee': 'viseme_E',
  'ea': 'viseme_E',
  'oa': 'viseme_O',
  'ai': 'viseme_E',
  'ay': 'viseme_E',
  'wh': 'viseme_U',
  'qu': 'viseme_U',
};

/// Chosen by how the mouth looks, not by phonetic accuracy: an `i` is spread,
/// an `o` is round, and that is what an onlooker reads.
const _letters = <String, String>{
  'a': 'viseme_aa',
  'e': 'viseme_E',
  'i': 'viseme_E',
  'y': 'viseme_E',
  'o': 'viseme_O',
  'u': 'viseme_U',
  'w': 'viseme_U',
  'm': 'viseme_PP',
  'b': 'viseme_PP',
  'p': 'viseme_PP',
  'f': 'viseme_FF',
  'v': 'viseme_FF',
  's': 'viseme_SS',
  'z': 'viseme_SS',
  'j': 'viseme_SS',
  'x': 'viseme_SS',
  'c': 'viseme_SS',
};

const _vowels = {'viseme_aa', 'viseme_E', 'viseme_O', 'viseme_U', 'viseme_OO'};

/// Everything else that is spoken but shapeless — n, l, d, t, r, g, k, h.
const _neutral = 'viseme_nn';

/// Split a word into mouth shapes, longest match first.
List<String> _shapesOf(String word) {
  final letters = word.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  final shapes = <String>[];

  for (var i = 0; i < letters.length;) {
    if (i + 1 < letters.length) {
      final pair = letters.substring(i, i + 2);
      final digraph = _digraphs[pair];
      if (digraph != null) {
        shapes.add(digraph);
        i += 2;
        continue;
      }
    }
    shapes.add(_letters[letters[i]] ?? _neutral);
    i += 1;
  }

  // A doubled shape is one held sound, not two — "little" should not chatter.
  final collapsed = <String>[];
  for (final shape in shapes) {
    if (collapsed.isEmpty || collapsed.last != shape) collapsed.add(shape);
  }
  return collapsed;
}

/// Keep the vowels and drop neutral consonants until the word fits.
List<String> _fit(List<String> shapes) {
  if (shapes.length <= _maxSegments) return shapes;
  final kept = shapes.where((s) => s != _neutral).toList();
  if (kept.length <= _maxSegments) return kept.isEmpty ? shapes.take(_maxSegments).toList() : kept;
  final vowelsOnly = kept.where(_vowels.contains).toList();
  final result = vowelsOnly.isEmpty ? kept : vowelsOnly;
  return result.take(_maxSegments).toList();
}

/// Mouth shapes for one word, spread across the time it is spoken.
///
/// [start] and [end] are seconds from the beginning of the utterance, matching
/// what the server sends.
List<Viseme> visemesForWord(String word, {required double start, required double end}) {
  final span = end - start;
  if (span <= 0) return const [];

  final shapes = _fit(_shapesOf(word));
  if (shapes.isEmpty) return [Viseme('viseme_sil', start, end)];

  final weights = [for (final s in shapes) _vowels.contains(s) ? _vowelWeight : _consonantWeight];
  final total = weights.reduce((a, b) => a + b);

  final out = <Viseme>[];
  var t = start;
  for (var i = 0; i < shapes.length; i++) {
    // The last segment takes whatever is left, so rounding cannot leave a gap.
    final next = i == shapes.length - 1 ? end : t + span * (weights[i] / total);
    out.add(Viseme(shapes[i], t, next));
    t = next;
  }
  return out;
}

/// Mouth shapes for a whole sentence, given only its duration.
///
/// The fallback for a platform that reports no word boundaries at all: assume
/// even pacing, which is wrong but rhythmic in roughly the right way.
List<Viseme> visemesForSentence(String sentence, {required double duration}) {
  final words = sentence.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).toList();
  if (words.isEmpty || duration <= 0) return const [];

  // Longer words take longer to say; character count is a crude but fair proxy.
  final lengths = [for (final w in words) w.length.toDouble()];
  final total = lengths.reduce((a, b) => a + b);

  final out = <Viseme>[];
  var t = 0.0;
  for (var i = 0; i < words.length; i++) {
    final end = i == words.length - 1 ? duration : t + duration * (lengths[i] / total);
    out.addAll(visemesForWord(words[i], start: t, end: end));
    t = end;
  }
  return out;
}
