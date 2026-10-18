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
