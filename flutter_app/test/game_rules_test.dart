import 'package:flutter_test/flutter_test.dart';
import 'package:isim_sehir/game_rules.dart';

void main() {
  group('strict-majority voting', () {
    test('accepts more than half of eligible players', () {
      expect(isAnswerAccepted(yesVotes: 2, eligibleVoters: 3), isTrue);
      expect(isAnswerAccepted(yesVotes: 2, eligibleVoters: 4), isFalse);
    });

    test('a tie, no voters, or zero eligible voters rejects', () {
      expect(isAnswerAccepted(yesVotes: 1, eligibleVoters: 2), isFalse);
      expect(isAnswerAccepted(yesVotes: 0, eligibleVoters: 0), isFalse);
    });
  });

  test('Turkish round letter matching ignores case and whitespace', () {
    expect(startsWithRoundLetter('  İZMİR  ', 'İ'), isTrue);
    expect(startsWithRoundLetter('ısparta', 'I'), isTrue);
    expect(startsWithRoundLetter('Ankara', 'A'), isTrue);
    expect(startsWithRoundLetter('Armut', 'A'), isTrue);
    expect(startsWithRoundLetter('Ali', 'A'), isTrue);
    expect(startsWithRoundLetter('Armut', 'İ'), isFalse);
  });

  test('accepted unique, duplicate, and rejected answers score correctly', () {
    expect(answerPoints(accepted: true, duplicate: false), 10);
    expect(answerPoints(accepted: true, duplicate: true), 5);
    expect(answerPoints(accepted: false, duplicate: false), 0);
  });
}
