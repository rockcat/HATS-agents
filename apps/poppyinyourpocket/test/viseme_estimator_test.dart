import 'package:flutter_test/flutter_test.dart';
import 'package:poppy/services/viseme_estimator.dart';

void main() {
  List<String> shapes(String word) =>
      visemesForWord(word, start: 0, end: 1).map((v) => v.viseme).toList();

  group('visemesForWord', () {
    test('opens the mouth on an open vowel', () {
      expect(shapes('ah'), contains('viseme_aa'));
    });

    test('rounds it on an o', () {
      expect(shapes('go'), contains('viseme_O'));
    });

    test('closes it on a p, b or m', () {
      for (final word in ['pop', 'bob', 'mum']) {
        expect(shapes(word), contains('viseme_PP'), reason: word);
      }
    });

    test('reads a digraph as one sound, not two letters', () {
      // "th" is not t-then-h, and "oo" is not two o's.
      expect(shapes('the'), contains('viseme_TH'));
      expect(shapes('the'), isNot(contains('viseme_nn')));
      expect(shapes('moon'), contains('viseme_OO'));
    });

    test('holds a doubled letter as one shape rather than chattering', () {
      expect(shapes('little').where((s) => s == 'viseme_nn').length, lessThan(3));
    });

    test('covers the whole span with no gaps', () {
      final out = visemesForWord('hello', start: 2.0, end: 2.5);
      expect(out.first.start, 2.0);
      expect(out.last.end, 2.5);
      for (var i = 1; i < out.length; i++) {
        expect(out[i].start, out[i - 1].end, reason: 'segment $i should start where the last ended');
      }
    });

    test('gives a vowel more time than a consonant', () {
      // Vowels hold the shape; consonants pass through. Without this the
      // result reads as a chattering puppet.
      final out = visemesForWord('ma', start: 0, end: 1);
      final consonant = out.firstWhere((v) => v.viseme == 'viseme_PP');
      final vowel = out.firstWhere((v) => v.viseme == 'viseme_aa');
      expect(vowel.end - vowel.start, greaterThan(consonant.end - consonant.start));
    });

    test('does not strobe on a long word', () {
      expect(shapes('antidisestablishmentarianism').length, lessThanOrEqualTo(8));
    });

    test('keeps the vowels when it has to drop something', () {
      final kept = shapes('antidisestablishmentarianism');
      expect(kept.any((s) => ['viseme_aa', 'viseme_E', 'viseme_O', 'viseme_U'].contains(s)), isTrue);
    });

    test('ignores punctuation', () {
      expect(shapes('"hello,"'), shapes('hello'));
    });

    test('falls silent on a word with no letters', () {
      expect(shapes('—'), ['viseme_sil']);
    });

    test('returns nothing for a span with no time in it', () {
      expect(visemesForWord('hello', start: 1, end: 1), isEmpty);
      expect(visemesForWord('hello', start: 2, end: 1), isEmpty);
    });
  });

  group('visemesForSentence', () {
    test('spreads across the whole utterance', () {
      final out = visemesForSentence('hello there poppy', duration: 3.0);
      expect(out.first.start, 0.0);
      expect(out.last.end, 3.0);
    });

    test('gives a longer word more of the time', () {
      final out = visemesForSentence('a magnificent', duration: 2.0);
      // The boundary should fall early: "a" is one character of fourteen.
      final firstWordEnd = out.firstWhere((v) => v.end > 0).end;
      expect(firstWordEnd, lessThan(0.5));
    });

    test('handles an empty or untimed sentence without throwing', () {
      expect(visemesForSentence('', duration: 1), isEmpty);
      expect(visemesForSentence('hello', duration: 0), isEmpty);
    });

    test('produces the shape the avatar renderer already consumes', () {
      final json = visemesForSentence('hello', duration: 1).first.toJson();
      expect(json.keys, containsAll(['viseme', 'start', 'end']));
    });
  });
}
