import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isim_sehir/main.dart';

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('The expected LAN room state did not arrive.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Set<String> playerIds(LanGameClient client) =>
    (client.state['players'] as Map).keys.cast<String>().toSet();

void main() {
  test('host and simultaneous guests retain every joined player', () async {
    final host = LanGameClient(
      identity: 'host',
      discoveryEnabled: false,
      serverPort: 0,
    );
    final clients = <LanGameClient>[host];
    addTearDown(() async {
      for (final client in clients.reversed) {
        await client.close();
      }
    });

    await host.startHost('Oda sahibi');
    expect(host.error, isNull);
    expect(host.connecting, isFalse);
    expect(host.roomPort, greaterThan(0));

    for (final id in ['a', 'b', 'c', 'd']) {
      clients.add(LanGameClient(
        identity: id,
        discoveryEnabled: false,
        serverPort: host.roomPort,
      ));
    }
    await Future.wait(clients.skip(1).map(
          (client) => client.join('127.0.0.1', client.playerId ?? 'Misafir'),
        ));

    const expected = {'host', 'a', 'b', 'c', 'd'};
    await waitUntil(() => clients.every(
          (client) => client.state['players'] is Map &&
              playerIds(client).containsAll(expected),
        ));
    // Let queued loopback snapshots run: a stale host snapshot used to remove
    // players that had already joined through another socket.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    for (final client in clients) {
      expect(client.error, isNull);
      expect(client.connecting, isFalse);
      expect(playerIds(client), expected);
      expect(
        (client.state['players'] as Map).values.every(
              (player) => (player as Map)['connected'] == true,
            ),
        isTrue,
      );
    }
  });

  test('late join is rejected with an error and releases connecting state',
      () async {
    final host = LanGameClient(
      identity: 'host',
      discoveryEnabled: false,
      serverPort: 0,
    );
    final clients = <LanGameClient>[host];
    addTearDown(() async {
      for (final client in clients.reversed) {
        await client.close();
      }
    });

    await host.startHost('Oda sahibi');
    final guest = LanGameClient(
      identity: 'guest',
      discoveryEnabled: false,
      serverPort: host.roomPort,
    );
    final lateGuest = LanGameClient(
      identity: 'late',
      discoveryEnabled: false,
      serverPort: host.roomPort,
    );
    clients.addAll([guest, lateGuest]);
    await guest.join('127.0.0.1', 'Misafir');
    await waitUntil(() => playerIds(host).length == 2);
    host.startRound();
    await waitUntil(() => host.phase == 'answer');

    await lateGuest.join('127.0.0.1', 'Geç kalan');
    expect(lateGuest.connecting, isFalse);
    expect(lateGuest.error, contains('başladı'));
    expect(playerIds(host), {'host', 'guest'});
  });

  test('join tries another room address when the first address is unreachable',
      () async {
    final host = LanGameClient(
      identity: 'host',
      discoveryEnabled: false,
      serverPort: 0,
    );
    final guest = LanGameClient(
      identity: 'guest',
      discoveryEnabled: false,
      connectionTimeout: const Duration(milliseconds: 100),
    );
    addTearDown(() async {
      await guest.close();
      await host.close();
    });
    await host.startHost('Oda sahibi');

    await guest.join(
      '203.0.113.1',
      'Misafir',
      alternatives: ['127.0.0.1'],
      remotePort: host.roomPort,
    ).timeout(const Duration(seconds: 3));

    expect(guest.connecting, isFalse);
    expect(guest.error, isNull);
    expect(playerIds(guest), {'host', 'guest'});
    expect(playerIds(host), {'host', 'guest'});
  });

  test('manual IP and port override the default room port', () async {
    final host = LanGameClient(
      identity: 'host',
      discoveryEnabled: false,
      serverPort: 0,
    );
    final guest = LanGameClient(
      identity: 'guest',
      discoveryEnabled: false,
    );
    addTearDown(() async {
      await guest.close();
      await host.close();
    });
    await host.startHost('Oda sahibi');

    await guest.join('127.0.0.1:${host.roomPort}', 'Misafir');

    expect(guest.error, isNull);
    expect(guest.connecting, isFalse);
    expect(playerIds(guest), {'host', 'guest'});
  });

  test('host duration is shared and guest cannot override it', () async {
    final host = LanGameClient(
      identity: 'host',
      discoveryEnabled: false,
      serverPort: 0,
    );
    final clients = <LanGameClient>[host];
    addTearDown(() async {
      for (final client in clients.reversed) {
        await client.close();
      }
    });
    await host.startHost('Oda sahibi');
    final guest = LanGameClient(
      identity: 'guest',
      discoveryEnabled: false,
      serverPort: host.roomPort,
    );
    clients.add(guest);
    await guest.join('127.0.0.1', 'Misafir');

    host.setRoundDuration(180);
    await waitUntil(() => guest.state['duration'] == 180);
    expect(host.state['duration'], 180);
    guest.setRoundDuration(30);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.state['duration'], 180);
    expect(guest.state['duration'], 180);

    final startedAt = DateTime.now().millisecondsSinceEpoch;
    host.startRound();
    await waitUntil(() => host.phase == 'answer' && guest.phase == 'answer');
    expect(host.state['duration'], 180);
    expect(guest.state['duration'], 180);
    expect(guest.state['endsAt'], host.state['endsAt']);
    expect(
      host.state['endsAt'] as int,
      inInclusiveRange(startedAt + 179000, startedAt + 183000),
    );
  });

  test('a copied host identity receives a guest identity without host powers',
      () async {
    final host = LanGameClient(
      identity: 'host',
      discoveryEnabled: false,
      serverPort: 0,
    );
    final clients = <LanGameClient>[host];
    addTearDown(() async {
      for (final client in clients.reversed) {
        await client.close();
      }
    });
    await host.startHost('Asıl oda sahibi');
    final guest = LanGameClient(
      identity: 'host',
      discoveryEnabled: false,
      serverPort: host.roomPort,
    );
    clients.add(guest);

    await guest.join('127.0.0.1', 'Kopyalanmış cihaz');

    expect(guest.error, isNull);
    expect(guest.playerId, isNot('host'));
    expect(guest.playerId, isNotNull);
    expect(host.playerId, 'host');
    expect(playerIds(host), {'host', guest.playerId!});
    expect((host.state['players'] as Map)['host']['name'], 'Asıl oda sahibi');
    host.setRoundDuration(180);
    await waitUntil(() => guest.state['duration'] == 180);
    guest.setRoundDuration(30);
    guest.startRound();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.phase, 'lobby');
    expect(host.state['duration'], 180);
    host.startRound();
    await waitUntil(() => guest.phase == 'answer');
    expect(guest.state['duration'], 180);
  });

  test('a socket without a join reply times out instead of hanging', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final subscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((_) {});
    });
    final client = LanGameClient(
      identity: 'guest',
      discoveryEnabled: false,
      serverPort: server.port,
      connectionTimeout: const Duration(milliseconds: 100),
    );
    addTearDown(() async {
      await client.close();
      for (final socket in sockets) {
        await socket.close();
      }
      await subscription.cancel();
      await server.close(force: true);
    });

    await client.join('127.0.0.1', 'Misafir').timeout(
          const Duration(seconds: 3),
        );
    expect(client.connecting, isFalse);
    expect(client.error, isNotNull);
    expect(client.error, isNotEmpty);
    expect(client.state, isEmpty);
  });
}
