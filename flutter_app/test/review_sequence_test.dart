import 'package:flutter_test/flutter_test.dart';
import 'package:isim_sehir/main.dart';

Future<void> waitForReview(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('The expected review state did not arrive.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('players are reviewed in sequence and accepted duplicates score five', () async {
    final host = LanGameClient(identity: 'host', discoveryEnabled: false, serverPort: 0);
    final clients = <LanGameClient>[host];
    addTearDown(() async {
      for (final client in clients.reversed) {
        await client.close();
      }
    });
    await host.startHost('Oda sahibi');
    for (final id in ['a', 'b']) {
      final client = LanGameClient(identity: id, discoveryEnabled: false, serverPort: host.roomPort);
      clients.add(client);
      await client.join('127.0.0.1', id);
    }
    await waitForReview(() => (host.state['players'] as Map).length == 3);
    host.startRound();
    await waitForReview(() => clients.every((client) => client.phase == 'answer'));
    final answer = '${host.state['letter']}li';
    for (final client in clients) {
      client.submit({0: answer});
    }
    await waitForReview(() => clients.every((client) => client.phase == 'review'));
    final order = List<String>.from(host.state['reviewOrder'] as List);
    expect(order.toSet(), {'host', 'a', 'b'});

    for (var step = 0; step < order.length; step++) {
      final target = order[step];
      await waitForReview(() => clients.every((client) =>
          client.state['reviewTarget'] == target && client.state['reviewStep'] == step));
      final voters = clients.where((client) => client.playerId != target).toList();
      if (step == 1) {
        // A delayed vote from the preceding player's review cannot count for
        // the new player even when its target otherwise matches.
        final staleVoter = voters.last;
        staleVoter.state['reviewStep'] = step - 1;
        staleVoter.vote(target, 0, true);
        staleVoter.state['reviewStep'] = step;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(host.state['reviewTarget'], target);
        expect((host.state['votes'] as Map)['$target:0'], isNull);
      }
      for (final voter in voters) {
        voter.vote(target, 0, true);
      }
      if (step < order.length - 1) {
        await waitForReview(() => host.state['reviewStep'] == step + 1);
        expect(host.phase, 'review');
      }
    }

    await waitForReview(() => clients.every((client) => client.phase == 'results'));
    final results = host.state['roundResults'] as Map;
    expect(results['scores'], {'host': 5, 'a': 5, 'b': 5});
    for (final client in clients) {
      expect((client.state['roundResults'] as Map)['scores'], results['scores']);
      expect((client.state['players'] as Map).values.every((player) => (player as Map)['score'] == 5), isTrue);
    }
  });
}
