/// Game rules shared by the authoritative room and its tests.
String normalizeAnswer(String value) => value
    .toLowerCase()
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll('ı', 'i')
    .replaceAll('İ', 'i');

bool startsWithRoundLetter(String answer, String letter) =>
    normalizeAnswer(answer).startsWith(normalizeAnswer(letter));

/// A strict majority of all eligible voters is required; abstentions count as
/// not accepting the answer, and a tie is a rejection.
bool isAnswerAccepted({required int yesVotes, required int eligibleVoters}) =>
    eligibleVoters > 0 && yesVotes * 2 > eligibleVoters;

int answerPoints({required bool accepted, required bool duplicate}) =>
    !accepted ? 0 : duplicate ? 5 : 10;
