import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:isim_sehir/game_rules.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const ink = Color(0xFF101522);
const panel = Color(0xFF1B2233);
const mint = Color(0xFF72E5C0);
const gold = Color(0xFFFFC66E);
const lilac = Color(0xFFB9A7FF);
const questions = ['İsim', 'Şehir', 'Hayvan', 'Bitki', 'Eşya', 'Ünlü'];
const letters = 'ABCÇDEFGĞHIİJKLMNOÖPRSŞTUÜVYZ';
const serviceType = '_isimsehir._tcp';
const port = 4040;

void main() => runApp(const IsimSehirApp());

class IsimSehirApp extends StatelessWidget {
  const IsimSehirApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'İsim Şehir',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: ink,
          colorScheme: const ColorScheme.dark(primary: mint, secondary: gold, surface: panel),
          fontFamily: 'sans-serif',
          useMaterial3: true,
          inputDecorationTheme: InputDecorationTheme(
            filled: true, fillColor: const Color(0xFF242C3E),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: const BorderSide(color: mint, width: 1.5)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          ),
        ),
        home: const GameHome(),
      );
}

class LanGameClient extends ChangeNotifier {
  LanGameClient({String? identity, this.discoveryEnabled = true, this.connectionTimeout = const Duration(seconds: 8), this.serverPort = port}) : _identityOverride = identity;
  final String? _identityOverride;
  final bool discoveryEnabled;
  final Duration connectionTimeout;
  final int serverPort;
  int get roomPort => _server?.port ?? serverPort;
  HttpServer? _server;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription? _discoveryEvents;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketEvents;
  int _connectionAttempt = 0;
  Timer? _clock;
  Timer? _deadline;
  final Map<String, String> discovered = {};
  final Map<String, List<String>> _roomAddresses = {};
  final Map<String, int> _roomPorts = {};
  List<String> localAddresses = [];
  Map<String, dynamic> state = {};
  String? playerId;
  String playerName = '';
  String? error;
  bool hosting = false;
  bool connecting = false;
  String? localIp;
  int _serverOffsetMs = 0;

  String get phase => state['phase'] as String? ?? 'lobby';
  int get secondsLeft {
    final end = state['endsAt'] as int?;
    if (end == null) return 0;
    return max(0, ((end - DateTime.now().millisecondsSinceEpoch - _serverOffsetMs) / 1000).ceil());
  }

  Future<String> _identity() async {
    if (_identityOverride != null) return _identityOverride;
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString('player_id');
    if (existing != null) return existing;
    final id = const Uuid().v4();
      await prefs.setString('player_id', id);
      return id;
  }

  Future<void> startHost(String name) async {
    if (connecting || hosting) return;
    connecting = true;
    error = null;
    playerName = name.trim();
    try {
      playerId = await _identity();
      _server = await HttpServer.bind(InternetAddress.anyIPv4, serverPort);
      _server!.listen(_accept, onError: (_) {});
      hosting = true;
      _startRoom();
      _hostId = playerId;
      state['players'] = {playerId!: {'id': playerId, 'name': _cleanName(name), 'connected': true, 'answers': <String, String>{}, 'score': 0}};
      localAddresses = await _findLanAddresses();
      localIp = localAddresses.isEmpty ? null : localAddresses.first;
      state['hostAddresses'] = localAddresses;
      state['hostPort'] = roomPort;
      connecting = false;
      if (discoveryEnabled) unawaited(_publishRoom());
    } catch (e) {
      error = 'Oda açılamadı: $e';
      await close();
    }
    notifyListeners();
  }

  Future<void> _publishRoom() async {
    final server = _server;
    if (server == null) return;
    final broadcast = BonsoirBroadcast(service: BonsoirService(
      name: 'İsim Şehir ${state['room']}', type: serviceType, port: server.port,
      attributes: {'ips': localAddresses.join(','), 'protocol': '2'},
    ));
    _broadcast = broadcast;
    try {
      await broadcast.initialize().timeout(const Duration(seconds: 4));
      if (!identical(_server, server)) return;
      await broadcast.start().timeout(const Duration(seconds: 4));
    } catch (_) {
      // Manual IP joining remains available when multicast is unavailable.
    }
  }

  void _startRoom() {
    state = {
      'room': _roomCode(), 'phase': 'lobby', 'round': 0, 'letter': '', 'duration': 60,
      'endsAt': null, 'players': <String, dynamic>{}, 'votes': <String, dynamic>{},
      'roundResults': <String, dynamic>{}, 'totalRounds': 5,
    };
  }

  Future<void> startDiscovery() async {
    await stopDiscovery();
    discovered.clear();
    _roomAddresses.clear();
    _roomPorts.clear();
    _discovery = BonsoirDiscovery(type: serviceType);
    await _discovery!.initialize();
    _discoveryEvents = _discovery!.eventStream!.listen((event) {
      if (event is BonsoirDiscoveryServiceFoundEvent) {
        event.service.resolve(_discovery!.serviceResolver);
      } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
        _recordRoom(event.service);
      } else if (event is BonsoirDiscoveryServiceUpdatedEvent) {
        _recordRoom(event.service);
      } else if (event is BonsoirDiscoveryServiceLostEvent) {
        discovered.remove(event.service.name);
        _roomAddresses.remove(event.service.name);
        _roomPorts.remove(event.service.name);
        notifyListeners();
      }
    });
    await _discovery!.start();
    notifyListeners();
  }

  void _recordRoom(BonsoirService service) {
    final addresses = [...(service.attributes['ips'] ?? '').split(','), ...service.hostAddresses]
        .where((value) {
          final address = InternetAddress.tryParse(value);
          return address != null && address.type == InternetAddressType.IPv4 && !address.isLoopback && address.address != '0.0.0.0';
        }).toSet().toList();
    if (addresses.isEmpty) return;
    _roomAddresses[service.name] = addresses;
    _roomPorts[service.name] = service.port;
    discovered[service.name] = addresses.first;
    notifyListeners();
  }

  Future<void> stopDiscovery() async {
    await _discoveryEvents?.cancel();
    if (_discovery != null) await _discovery!.stop();
    _discovery = null;
    _discoveryEvents = null;
  }

  Future<void> joinRoom(String room, String name) => join(discovered[room] ?? '', name,
    alternatives: _roomAddresses[room] ?? [], remotePort: _roomPorts[room]);

  Future<void> join(String host, String name, {List<String> alternatives = const [], int? remotePort}) async {
    if (connecting) return;
    connecting = true;
    error = null;
    notifyListeners();
    playerName = name.trim();
    try {
      playerId = await _identity();
      final value = host.trim();
      final uri = Uri.parse(value.contains('://') ? value : 'ws://$value');
      if (uri.host.isEmpty) throw const FormatException('Missing host');
      await _connect(uri.host, name, alternatives: alternatives,
        remotePort: remotePort ?? (uri.hasPort ? uri.port : serverPort));
    } catch (_) {
      connecting = false;
      error = 'Geçerli bir oda IP adresi yazın (örnek: 192.168.43.1 veya 192.168.43.1:4040).';
      notifyListeners();
    }
  }

  Future<void> _connect(String host, String name, {List<String> alternatives = const [], int? remotePort}) async {
    final attempt = ++_connectionAttempt;
    connecting = true;
    error = null;
    notifyListeners();
    final previous = _socket;
    _socket = null;
    await _socketEvents?.cancel();
    _socketEvents = null;
    unawaited(previous?.close());
    final candidates = {host, ...alternatives}.where((value) => value.isNotEmpty).toList();
    final addressTimeout = connectionTimeout < const Duration(seconds: 3) ? connectionTimeout : const Duration(seconds: 3);
    for (final address in candidates) {
      final acknowledged = Completer<void>();
      try {
        final client = HttpClient()..findProxy = (_) => 'DIRECT';
        final pending = WebSocket.connect(Uri(scheme: 'ws', host: address, port: remotePort ?? serverPort).toString(),
          customClient: client, compression: CompressionOptions.compressionOff).whenComplete(() => client.close());
        final socket = await pending.timeout(addressTimeout, onTimeout: () {
          client.close(force: true);
          unawaited(pending.then<void>((late) { unawaited(late.close()); }, onError: (Object error) {}));
          throw TimeoutException('Connection timed out');
        });
        if (attempt != _connectionAttempt) { unawaited(socket.close()); return; }
        _socket = socket;
        socket.pingInterval = const Duration(seconds: 10);
        void disconnected() {
          if (!identical(_socket, socket)) return;
          if (!acknowledged.isCompleted) {
            acknowledged.completeError(const SocketException('Room closed before joining'));
          } else {
            _disconnected();
          }
        }
        _socketEvents = socket.listen((raw) {
          if (!identical(_socket, socket)) return;
          _onMessage(raw);
          if (!connecting && !acknowledged.isCompleted) acknowledged.complete();
        }, onDone: disconnected, onError: (_) => disconnected());
        socket.add(jsonEncode({'type': 'join', 'id': playerId, 'name': name.trim()}));
        await acknowledged.future.timeout(connectionTimeout);
        return;
      } catch (_) {
        if (attempt != _connectionAttempt) return;
        final failed = _socket;
        _socket = null;
        await _socketEvents?.cancel();
        _socketEvents = null;
        unawaited(failed?.close());
      }
    }
    connecting = false;
    error = 'Odaya ulaşılamadı. Oda sahibinin ekranındaki Wi-Fi/hotspot IP adresini elle deneyin. Telefonlar aynı ağda olmalı; VPN ve hotspot cihaz yalıtımı bağlantıyı engelleyebilir.';
    notifyListeners();
  }

  void _accept(HttpRequest request) {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      WebSocketTransformer.upgrade(request).then(_serveClient, onError: (_) {});
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
    }
  }

  final Map<String, WebSocket> _clients = {};
  final Map<String, Timer> _disconnectTimers = {};
  final Map<String, Map<String, bool>> _ballots = {};
  String? _hostId;

  void _serveClient(WebSocket socket) {
    String? id;
    socket.listen((raw) {
      try {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        if (message['type'] == 'join') {
          if (id != null) return;
          var playerId = (message['id'] as String?) ?? const Uuid().v4();
          if (playerId == _hostId || _clients[playerId]?.readyState == WebSocket.open) {
            playerId = const Uuid().v4();
          }
          id = playerId;
          final players = Map<String, dynamic>.from(state['players'] as Map);
          if (!players.containsKey(playerId)) {
            if (phase != 'lobby') {
              socket.add(jsonEncode({'type': 'error', 'message': 'Tur başladıktan sonra yeni oyuncu alınmaz. Yeniden katılma yalnızca aynı cihazla mümkündür.'}));
              socket.close();
              return;
            }
            if (players.length >= 8) {
              socket.add(jsonEncode({'type': 'error', 'message': 'Oda en fazla 8 oyuncu alabilir.'}));
              socket.close();
              return;
            }
          }
          final previous = Map<String, dynamic>.from(players[playerId] as Map? ?? {});
          players[playerId] = {...previous, 'id': playerId, 'name': _cleanName(message['name'] as String? ?? 'Oyuncu'), 'connected': true, 'answers': previous['answers'] ?? <String, String>{}, 'score': previous['score'] ?? 0};
          state['players'] = players;
          _disconnectTimers.remove(playerId)?.cancel();
          _clients[playerId] = socket;
          _hostId ??= playerId;
          socket.pingInterval = const Duration(seconds: 10);
          socket.add(jsonEncode({'type': 'welcome', 'id': playerId}));
          _sendState(socket, playerId);
          if (phase == 'answer' && (players.values).where((p) => (p as Map)['connected'] == true).every((p) => (p as Map)['submitted'] == true)) _beginReview();
          _broadcastState();
          return;
        }
        if (id == null || !identical(_clients[id], socket)) return;
        _handleAction(id!, message);
      } catch (_) {
        socket.add(jsonEncode({'type': 'error', 'message': 'Geçersiz oyun verisi.'}));
      }
    }, onDone: () => _removeClient(id, socket), onError: (_) => _removeClient(id, socket));
  }

  void _removeClient(String? id, WebSocket socket) {
    if (id == null || !identical(_clients[id], socket)) return;
    _clients.remove(id);
    final players = Map<String, dynamic>.from(state['players'] as Map);
    if (players[id] is Map) players[id] = {...Map<String, dynamic>.from(players[id] as Map), 'connected': false};
    state['players'] = players;
    _tryFinishReview();
    _disconnectTimers.remove(id)?.cancel();
    _disconnectTimers[id] = Timer(const Duration(seconds: 45), () {
      _disconnectTimers.remove(id);
      if (_clients.containsKey(id)) return;
      final current = Map<String, dynamic>.from(state['players'] as Map);
      if (current[id] is Map && current[id]['connected'] != true) {
        current.remove(id);
        state['players'] = current;
        _tryFinishReview();
        _broadcastState();
      }
    });
    _broadcastState();
  }

  void _handleAction(String id, Map<String, dynamic> m) {
    switch (m['type']) {
      case 'settings':
        if (id != _hostId || phase != 'lobby') return;
        state['duration'] = (m['duration'] as num?)?.toInt().clamp(30, 300).toInt() ?? 60;
        _broadcastState();
        return;
      case 'start':
        if (id != _hostId || phase != 'lobby' || _playerCount < 2) return;
        final duration = ((m['duration'] ?? state['duration']) as num?)?.toInt().clamp(30, 300).toInt() ?? 60;
        state['round'] = 1;
        state['totalRounds'] = 5;
        state['duration'] = duration;
        _beginRound();
        return;
      case 'answers':
        if (phase != 'answer' || state['endsAt'] == null) return;
        final players = Map<String, dynamic>.from(state['players'] as Map);
        if (players[id] == null) return;
        final raw = Map<String, dynamic>.from(m['answers'] as Map? ?? {});
        final clean = <String, String>{};
        for (var i = 0; i < questions.length; i++) {
          final value = _cleanAnswer(raw['$i'] as String? ?? '');
          if (value.isNotEmpty) clean['$i'] = value;
        }
        players[id] = {...Map<String, dynamic>.from(players[id] as Map), 'answers': clean, 'submitted': true};
        state['players'] = players;
        if ((players.values).where((p) => (p as Map)['connected'] == true).every((p) => (p as Map)['submitted'] == true)) _beginReview();
        else _broadcastState();
        return;
      case 'vote':
        if (phase != 'review') return;
        final target = m['target'] as String?;
        if (target == null || target == id || target != state['reviewTarget'] ||
            m['step'] != state['reviewStep']) return;
        final reviewPlayers = state['players'] as Map;
        if (reviewPlayers[target] == null || (reviewPlayers[id] as Map?)?['connected'] != true) return;
        final index = (m['index'] as num?)?.toInt();
        if (index == null || index < 0 || index >= questions.length) return;
        final answer = ((reviewPlayers[target] as Map)['answers'] as Map?)?['$index'];
        if (answer is! String || answer.isEmpty) return;
        final key = '$target:$index';
        (_ballots[key] ??= {})[id] = m['valid'] == true;
        _tryFinishReview();
        _broadcastState();
        return;
      case 'next':
        if (id != _hostId || phase != 'results' || _playerCount < 2) return;
        if ((state['round'] as int) >= (state['totalRounds'] as int)) {
          state['phase'] = 'finished';
          _broadcastState();
        } else {
          state['round'] = (state['round'] as int) + 1;
          _beginRound();
        }
        return;
    }
  }

  int get _playerCount => (state['players'] as Map? ?? {}).values.where((p) => (p as Map)['connected'] == true).length;

  void _beginRound() {
    final players = Map<String, dynamic>.from(state['players'] as Map);
    for (final entry in players.entries.toList()) {
      players[entry.key] = {...Map<String, dynamic>.from(entry.value as Map), 'answers': <String, String>{}, 'submitted': false};
    }
    state['players'] = players;
    state['letter'] = letters[Random.secure().nextInt(letters.length)];
    state['phase'] = 'answer';
    state['endsAt'] = DateTime.now().add(Duration(seconds: state['duration'] as int)).millisecondsSinceEpoch;
    _ballots.clear();
    _setDeadline((state['duration'] as int), _beginReview);
    _broadcastState();
  }

  void _beginReview() {
    if (phase != 'answer') return;
    state['phase'] = 'review';
    state['reviewOrder'] = (state['players'] as Map).keys.cast<String>().toList();
    state['reviewStep'] = -1;
    state['reviewTarget'] = null;
    _advanceReview();
  }

  void _advanceReview() {
    if (phase != 'review') return;
    _deadline?.cancel();
    final order = List<String>.from(state['reviewOrder'] as List? ?? []);
    final players = state['players'] as Map;
    var step = (state['reviewStep'] as int? ?? -1) + 1;
    while (step < order.length) {
      final target = order[step];
      final answers = (players[target] as Map?)?['answers'] as Map? ?? {};
      if (answers.values.any((answer) => answer is String && answer.isNotEmpty)) {
        state['reviewStep'] = step;
        state['reviewTarget'] = target;
        state['endsAt'] = DateTime.now().add(const Duration(seconds: 35)).millisecondsSinceEpoch;
        _setDeadline(35, _advanceReview);
        _tryFinishReview();
        _broadcastState();
        return;
      }
      step++;
    }
    state['reviewStep'] = order.length;
    state['reviewTarget'] = null;
    _finishReview();
  }

  void _tryFinishReview() {
    if (phase != 'review') return;
    final players = state['players'] as Map;
    final targetId = state['reviewTarget'] as String?;
    if (targetId == null) return;
    final answers = (players[targetId] as Map?)?['answers'] as Map? ?? {};
    final eligible = players.entries
        .where((e) => e.key != targetId && (e.value as Map)['connected'] == true)
        .map((e) => e.key as String)
        .toList();
    for (var i = 0; i < questions.length; i++) {
      final answer = answers['$i'];
      if (answer is! String || answer.isEmpty) continue;
      final ballot = _ballots['$targetId:$i'] ?? {};
      if (eligible.any((voter) => !ballot.containsKey(voter))) return;
    }
    _advanceReview();
  }

  void _finishReview() {
    if (phase != 'review') return;
    final players = Map<String, dynamic>.from(state['players'] as Map);
    final accepted = <String, dynamic>{};
    for (final entry in players.entries) {
      final target = entry.key;
      final answers = Map<String, dynamic>.from((entry.value as Map)['answers'] as Map? ?? {});
      for (var i = 0; i < questions.length; i++) {
        final answer = answers['$i'];
        if (answer == null || (answer as String).isEmpty) continue;
        final ballot = _ballots['$target:$i'] ?? {};
        final eligible = players.entries.where((e) => e.key != target && (e.value as Map)['connected'] == true).map((e) => e.key).toList();
        final yes = eligible.where((voter) => ballot[voter] == true).length;
        accepted['$target:$i'] = startsWithRoundLetter(answer, state['letter'] as String) && isAnswerAccepted(yesVotes: yes, eligibleVoters: eligible.length);
      }
    }
    final answerCounts = <String, int>{};
    for (final entry in players.entries) {
      for (var i = 0; i < questions.length; i++) {
        final k = '${entry.key}:$i';
        final answer = ((entry.value as Map)['answers'] as Map?)?['$i'] as String?;
        if (accepted[k] == true && answer != null) {
          final norm = normalizeAnswer(answer);
          final duplicateKey = '$i:$norm';
          answerCounts[duplicateKey] = (answerCounts[duplicateKey] ?? 0) + 1;
        }
      }
    }
    final roundScores = <String, int>{};
    for (final entry in players.entries) {
      var score = 0;
      for (var i = 0; i < questions.length; i++) {
        final key = '${entry.key}:$i';
        final answer = ((entry.value as Map)['answers'] as Map?)?['$i'] as String?;
        if (answer == null || accepted[key] != true) continue;
        score += answerPoints(accepted: true, duplicate: (answerCounts['$i:${normalizeAnswer(answer)}'] ?? 0) > 1);
      }
      final old = Map<String, dynamic>.from(entry.value as Map);
      old['score'] = ((old['score'] as num?)?.toInt() ?? 0) + score;
      players[entry.key] = old;
      roundScores[entry.key] = score;
    }
    state['players'] = players;
    state['roundResults'] = {'scores': roundScores, 'accepted': accepted};
    state['phase'] = 'results';
    state['endsAt'] = null;
    _deadline?.cancel();
    _clock?.cancel();
    _broadcastState();
  }

  void _setDeadline(int seconds, void Function() action) {
    _deadline?.cancel();
    _deadline = Timer(Duration(seconds: seconds), action);
  }

  void _sendState(WebSocket socket, [String? recipient]) => socket.add(jsonEncode({'type': 'state', 'state': state, 'votes': _voteSummary(recipient), 'serverNow': DateTime.now().millisecondsSinceEpoch}));
  void _broadcastState() {
    for (final socket in _clients.values.toList()) {
      if (socket.readyState == WebSocket.open) {
        try { _sendState(socket, _clients.entries.firstWhere((e) => identical(e.value, socket)).key); } catch (_) {}
      }
    }
    if (hosting) {
      state['votes'] = _voteSummary(playerId);
      _clock?.cancel();
      if (state['endsAt'] != null) _clock = Timer.periodic(const Duration(milliseconds: 400), (_) => notifyListeners());
      notifyListeners();
    }
  }

  Map<String, dynamic> _voteSummary([String? recipient]) => {for (final e in _ballots.entries) e.key: {'yes': e.value.values.where((v) => v).length, 'no': e.value.values.where((v) => !v).length, 'mine': e.value[recipient]}};

  void _onMessage(dynamic raw) {
    try {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      if (message['type'] == 'welcome') {
        playerId = message['id'] as String;
        if (_identityOverride == null) {
          final assignedId = playerId!;
          unawaited(SharedPreferences.getInstance().then<void>((prefs) { unawaited(prefs.setString('player_id', assignedId)); }));
        }
      } else if (message['type'] == 'state') {
        _serverOffsetMs = hosting ? 0 : ((message['serverNow'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch) - DateTime.now().millisecondsSinceEpoch;
        // The host's loopback socket can receive snapshots queued before another
        // player joined. Keep the authoritative room instead of restoring them.
        if (!hosting) state = Map<String, dynamic>.from(message['state'] as Map);
        state['votes'] = hosting ? _voteSummary(playerId) : message['votes'] ?? {};
        connecting = false;
        error = null;
        _clock?.cancel();
        if (state['endsAt'] != null) {
          _clock = Timer.periodic(const Duration(milliseconds: 400), (_) => notifyListeners());
        }
      } else if (message['type'] == 'error') {
        error = message['message'] as String?;
        connecting = false;
      }
      notifyListeners();
    } catch (_) {}
  }

  void _disconnected() {
    if (_socket != null) {
      _socket = null;
      connecting = false;
      if (!hosting) error ??= 'Bağlantı kesildi. Odaya yeniden katılmayı deneyin.';
      notifyListeners();
    }
  }

  void setRoundDuration(int duration) => _send({'type': 'settings', 'duration': duration});
  void startRound([int? duration]) => _send({'type': 'start', 'duration': duration ?? state['duration'] ?? 60});
  void submit(Map<int, String> answers) => _send({'type': 'answers', 'answers': {for (final e in answers.entries) '${e.key}': e.value}});
  void vote(String target, int index, bool valid) => _send({'type': 'vote', 'target': target, 'index': index, 'valid': valid, 'step': state['reviewStep']});
  void next() => _send({'type': 'next'});
  void _send(Map<String, dynamic> message) {
    if (hosting && playerId != null) { _handleAction(playerId!, message); return; }
    if (_socket?.readyState == WebSocket.open) _socket!.add(jsonEncode(message));
  }

  Future<void> close() async {
    _connectionAttempt++;
    connecting = false;
    _clock?.cancel();
    _deadline?.cancel();
    await stopDiscovery();
    try { await _broadcast?.stop(); } catch (_) {}
    _broadcast = null;
    await _socketEvents?.cancel();
    _socketEvents = null;
    await _socket?.close();
    _socket = null;
    await _server?.close(force: true);
    _server = null;
    final clients = _clients.values.toList();
    _clients.clear();
    for (final timer in _disconnectTimers.values) { timer.cancel(); }
    _disconnectTimers.clear();
    for (final socket in clients) { try { await socket.close(); } catch (_) {} }
    _hostId = null;
    _ballots.clear();
    hosting = false;
    state = {};
    notifyListeners();
  }

  Future<List<String>> _findLanAddresses() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    int priority(NetworkInterface interface) {
      final name = interface.name.toLowerCase();
      if (RegExp(r'^(tun|tap|ppp|wg|rmnet|ccmni|pdp|utun)').hasMatch(name)) return 3;
      if (RegExp(r'^(wlan|wifi|ap|swlan|softap|eth|en|bridge|br)').hasMatch(name)) return 0;
      return 1;
    }
    interfaces.sort((a, b) => priority(a).compareTo(priority(b)));
    final addresses = <String>[];
    for (final interface in interfaces) {
      final values = interface.addresses.where((address) => !address.isLoopback && address.address != '0.0.0.0').toList();
      values.sort((a, b) => (_isPrivateIpv4(b) ? 1 : 0).compareTo(_isPrivateIpv4(a) ? 1 : 0));
      addresses.addAll(values.map((address) => address.address));
    }
    return addresses.toSet().toList();
  }
}

bool _isPrivateIpv4(InternetAddress address) {
  final parts = address.address.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((part) => part == null)) return false;
  final a = parts[0]!;
  final b = parts[1]!;
  return a == 10 || a == 192 && b == 168 || a == 172 && b >= 16 && b <= 31;
}

String _roomCode() => List.generate(4, (_) => Random.secure().nextInt(10)).join();
String _cleanName(String value) => _limit(value.trim().replaceAll(RegExp(r'\s+'), ' '), 18).ifEmpty('Oyuncu');
String _cleanAnswer(String value) => _limit(value.trim().replaceAll(RegExp(r'\s+'), ' '), 35);
String _limit(String value, int length) => String.fromCharCodes(value.runes.take(length));
extension on String { String ifEmpty(String fallback) => isEmpty ? fallback : this; }

class GameHome extends StatefulWidget {
  const GameHome({super.key});
  @override
  State<GameHome> createState() => _GameHomeState();
}

class _GameHomeState extends State<GameHome> {
  final game = LanGameClient();
  final name = TextEditingController();
  final ip = TextEditingController();
  bool scanning = false;
  bool _entered = false;

  @override
  void initState() { super.initState(); game.addListener(_update); }
  void _update() { if (!mounted) return; if (!_entered && !game.connecting && (game.state['players'] as Map?)?.containsKey(game.playerId) == true && game.error == null) { _entered = true; game.stopDiscovery(); Navigator.of(context).push(MaterialPageRoute(builder: (_) => GameRoomScreen(game: game, onExit: () { _entered = false; if (mounted) setState(() {}); }))); } setState(() {}); }
  String get _name => name.text.trim().isEmpty ? 'Oyuncu' : name.text.trim();
  @override
  void dispose() { game.removeListener(_update); name.dispose(); ip.dispose(); game.close(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned(top: -100, right: -80, child: _glow(mint.withValues(alpha: .17), 260)),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListenableBuilder(
                  listenable: game,
                  builder: (context, _) => SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 34),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [const Icon(Icons.wifi_tethering_rounded, color: mint, size: 19), const SizedBox(width: 9), Text('İNTERNETSİZ • YEREL AĞ', style: TextStyle(color: mint.withValues(alpha: .9), fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4))]),
                        const SizedBox(height: 28),
                        const Text('İsim\nŞehir', style: TextStyle(fontSize: 54, height: .98, fontWeight: FontWeight.w900, letterSpacing: -2.5)),
                        const SizedBox(height: 16),
                        Text('Aynı ağa bağlanın, harf gelsin,\ncevapları birlikte karara bağlayın.', style: TextStyle(color: Colors.white.withValues(alpha: .66), fontSize: 16, height: 1.5)),
                        const SizedBox(height: 30),
                        _panel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('OYUNCU ADIN', style: _eyebrow),
                              const SizedBox(height: 10),
                              TextField(controller: name, maxLength: 18, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'Bir isim seç', prefixIcon: Icon(Icons.person_outline_rounded), counterText: '')),
                              const SizedBox(height: 22),
                              _button('Oda kur', Icons.add_circle_outline_rounded, mint, game.connecting ? null : () => game.startHost(_name), secondary: 'Bu telefon oda sahibi olur'),
                              const SizedBox(height: 12),
                              _button(scanning ? 'Odalar aranıyor…' : 'Yakındaki odaya katıl', Icons.radar_rounded, lilac, game.connecting ? null : () async {
                                setState(() => scanning = true);
                                await game.startDiscovery();
                                Future.delayed(const Duration(seconds: 7), () { if (mounted) setState(() => scanning = false); });
                              }, secondary: 'Aynı Wi-Fi veya telefon hotspotu'),
                              if (game.discovered.isNotEmpty) ...game.discovered.entries.map((e) => Padding(padding: const EdgeInsets.only(top: 9), child: _button(e.key, Icons.wifi_rounded, gold, game.connecting ? null : () => game.joinRoom(e.key, _name), secondary: e.value))),
                              const SizedBox(height: 16),
                              Row(children: [Expanded(child: TextField(controller: ip, keyboardType: TextInputType.url, decoration: const InputDecoration(hintText: 'Oda IP adresi', prefixIcon: Icon(Icons.lan_outlined)))), const SizedBox(width: 8), IconButton.filled(onPressed: game.connecting ? null : () => game.join(ip.text, _name), icon: const Icon(Icons.arrow_forward_rounded), style: IconButton.styleFrom(backgroundColor: gold, foregroundColor: ink, minimumSize: const Size(54, 54)))]),
                              const SizedBox(height: 7),
                              Text('IP adresiyle elle bağlan', style: TextStyle(color: Colors.white.withValues(alpha: .48), fontSize: 12)),
                            ],
                          ),
                        ),
                        if (game.error != null) Padding(padding: const EdgeInsets.only(top: 16), child: _message(game.error!, Icons.info_outline_rounded, gold)),
                        const SizedBox(height: 22),
                        Row(children: [const Icon(Icons.phonelink_rounded, color: Colors.white54, size: 17), const SizedBox(width: 8), Text('Android ve iPhone • Sunucu telefonlardan biri', style: TextStyle(color: Colors.white.withValues(alpha: .48), fontSize: 12))]),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GameRoomScreen extends StatefulWidget {
  const GameRoomScreen({super.key, required this.game, required this.onExit});
  final LanGameClient game;
  final VoidCallback onExit;
  @override
  State<GameRoomScreen> createState() => _GameRoomScreenState();
}

class _GameRoomScreenState extends State<GameRoomScreen> {
  final fields = List.generate(questions.length, (_) => TextEditingController());
  bool submitted = false;
  String? _lastPhase;
  LanGameClient get game => widget.game;
  @override
  void initState() { super.initState(); game.addListener(_refresh); }
  void _refresh() {
    if (!mounted) return;
    if (game.phase != _lastPhase) {
      if (game.phase == 'answer' && !submitted) {
        for (var i = 0; i < fields.length; i++) {
          fields[i].text = ((game.state['players'] as Map?)?[game.playerId]?['answers'] as Map?)?['$i'] as String? ?? '';
        }
      }
      if (game.phase != 'answer') submitted = false;
      _lastPhase = game.phase;
    }
    setState(() {});
  }
  @override
  void dispose() { game.removeListener(_refresh); for (final field in fields) { field.dispose(); } super.dispose(); }
  Map<String, dynamic> get players => Map<String, dynamic>.from(game.state['players'] as Map? ?? {});
  bool get isHost => game.hosting && players[game.playerId] != null;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          widget.onExit();
          game.close();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
                    child: Row(
                      children: [
                        IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back_rounded)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(game.state['phase'] == 'lobby' ? 'OYUN ODASI' : 'TUR ${game.state['round'] ?? 1} / ${game.state['totalRounds'] ?? 5}', style: _eyebrow),
                              Text('Oda ${game.state['room'] ?? '····'}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                            ],
                          ),
                        ),
                        _statusChip(),
                      ],
                    ),
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 320),
                      child: switch (game.phase) {
                        'lobby' => _lobby(),
                        'answer' => _answer(),
                        'review' => _review(),
                        'results' => _results(),
                        'finished' => _finished(),
                        _ => _lobby(),
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _lobby() {
    final roster = players.values.toList()..sort((a,b) => (a['id'] == game.playerId ? -1 : 0));
    final duration = (game.state['duration'] as num?)?.toInt() ?? 60;
    return SingleChildScrollView(key: const ValueKey('lobby'), padding: const EdgeInsets.all(22), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 8), _roomCodeCard(), const SizedBox(height: 24), const Text('Takım hazır mı?', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -.8)), const SizedBox(height: 6), Text('Oyuna başlamak için en az 2 oyuncu gerekli.', style: TextStyle(color: Colors.white.withValues(alpha: .57))), const SizedBox(height: 18),
      ...roster.map((p) => _playerTile(p)), const SizedBox(height: 12),
      _durationPicker(duration), const SizedBox(height: 18),
      if (isHost) _button('Oyunu başlat', Icons.play_arrow_rounded, mint, roster.where((p)=>p['connected']==true).length >= 2 ? game.startRound : null, secondary: '5 tur • $duration saniye • adil çoğunluk'),
      if (!isHost) _message('Oda sahibi oyunu başlattığında burada buluşacağız.', Icons.hourglass_top_rounded, lilac),
      const SizedBox(height: 20), _rulesCard(),
    ]));
  }

  Widget _durationPicker(int duration) => _panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('TUR SÜRESİ', style: _eyebrow),
        const SizedBox(height: 8),
        Text(isHost ? 'Cevap yazmak için süreyi seç.' : 'Oda sahibinin seçtiği süre: $duration saniye', style: const TextStyle(fontSize: 13, color: Colors.white70)),
        if (isHost) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [30, 60, 90, 120, 180, 300].map((seconds) => Semantics(
              label: 'Tur süresi $seconds saniye',
              child: ChoiceChip(
                label: Text('$seconds sn'),
                selected: duration == seconds,
                onSelected: (_) => game.setRoundDuration(seconds),
                selectedColor: mint,
                checkmarkColor: ink,
                labelStyle: TextStyle(color: duration == seconds ? ink : Colors.white, fontWeight: FontWeight.w700),
                materialTapTargetSize: MaterialTapTargetSize.padded,
              ),
            )).toList(),
          ),
        ],
      ],
    ),
  );

  Widget _answer() {
    final letter = game.state['letter'] as String? ?? 'A';
    final done = (players.values.where((p)=>p['submitted']==true).length);
    return SingleChildScrollView(
      key: const ValueKey('answer'),
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('HARFİNİZ', style: _eyebrow),
                    const SizedBox(height: 4),
                    Text(letter, style: const TextStyle(fontSize: 74, height: 1, fontWeight: FontWeight.w900, color: mint)),
                  ],
                ),
              ),
              _timerBadge(),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: 1 - (game.secondsLeft / (game.state['duration'] as int? ?? 60)).clamp(0.0, 1.0),
            backgroundColor: Colors.white12,
            color: game.secondsLeft < 10 ? gold : mint,
            borderRadius: BorderRadius.circular(6),
            minHeight: 5,
          ),
          const SizedBox(height: 14),
          Text('$done / ${players.length} kişi cevapladı', style: TextStyle(color: Colors.white.withValues(alpha: .6), fontSize: 12)),
          const SizedBox(height: 18),
          ...List.generate(
            questions.length,
            (i) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SizedBox(width: 94, child: Text(questions[i], style: const TextStyle(fontWeight: FontWeight.w700))),
                  Expanded(
                    child: TextField(
                      controller: fields[i],
                      enabled: !submitted,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 35,
                      inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\n'))],
                      decoration: InputDecoration(hintText: '$letter ile başlayan…', counterText: '', contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14)),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _button(
            submitted ? 'Cevapların gönderildi' : 'Cevapları gönder',
            submitted ? Icons.check_circle_outline_rounded : Icons.send_rounded,
            submitted ? lilac : mint,
            submitted ? null : (_answersAreEntered ? _submit : null),
            secondary: 'Erken gönder, süre dolmadan düzenleyemezsin',
          ),
          const SizedBox(height: 8),
          _message('Boş bırakılan ya da harfle başlamayan cevaplar puan almaz.', Icons.lightbulb_outline_rounded, gold),
        ],
      ),
    );
  }
  bool get _answersAreEntered => fields.any((f) => f.text.trim().isNotEmpty);
  void _submit() { final a = <int, String>{for (var i=0;i<fields.length;i++) i: fields[i].text.trim()}; game.submit(a); submitted = true; setState(() {}); }

  Widget _review() {
    final myId = game.playerId;
    final current = game.state['votes'] as Map? ?? {};
    final target = game.state['reviewTarget'] as String?;
    final targetPlayer = players[target] as Map?;
    final answers = targetPlayer?['answers'] as Map? ?? {};
    final step = (game.state['reviewStep'] as num?)?.toInt() ?? 0;
    final total = (game.state['reviewOrder'] as List?)?.length ?? players.length;
    final isMyTurn = target == myId;
    return ListView(
      key: ValueKey('review-$step'),
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 26),
      children: [
        Row(children: [
          const Expanded(child: Text('Birlikte karar verin', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, letterSpacing: -.7))),
          _timerBadge(),
        ]),
        const SizedBox(height: 12),
        Text('OYUNCU ${step + 1} / $total', style: _eyebrow),
        const SizedBox(height: 6),
        Text('${targetPlayer?['name'] ?? 'Oyuncu'} cevapları', style: const TextStyle(color: lilac, fontWeight: FontWeight.w800, fontSize: 19)),
        const SizedBox(height: 12),
        if (isMyTurn) _message('Cevapların değerlendiriliyor. Diğer oyuncuların oylarını bekle.', Icons.hourglass_top_rounded, lilac)
        else Text('Her cevaba oy ver. Herkes tamamlayınca sıradaki oyuncuya geçilir.', style: TextStyle(color: Colors.white.withValues(alpha: .6), height: 1.4)),
        const SizedBox(height: 18),
        for (var i = 0; i < questions.length; i++)
          if ((answers['$i'] as String?)?.isNotEmpty == true && target != null)
            Padding(padding: const EdgeInsets.only(bottom: 9), child: _voteCard(target, i, answers['$i'] as String, current, canVote: !isMyTurn)),
        const SizedBox(height: 10),
        _message('Eşitlikte cevap reddedilir. Bu oyuncu için 35 saniye sonunda sıradakine geçilir; verilmeyen oylar kabul sayılmaz.', Icons.how_to_vote_rounded, gold),
      ],
    );
  }

  Widget _voteCard(String target, int index, String answer, Map votes, {bool canVote = true}) {
    final key = '$target:$index';
    final ballot = votes[key] as Map? ?? {};
    final mine = ballot['mine'];
    return Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white.withValues(alpha: .06))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Text(questions[index].toUpperCase(), style: _eyebrow), const Spacer(), Text('👍 ${ballot['yes'] ?? 0}   👎 ${ballot['no'] ?? 0}', style: const TextStyle(fontSize: 12))]), const SizedBox(height: 8), Text(answer, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)), const SizedBox(height: 12),
      if (canVote) Row(children: [Expanded(child: _voteButton('Kabul', Icons.check_rounded, mint, mine == true, () => game.vote(target, index, true))), const SizedBox(width: 8), Expanded(child: _voteButton('Ret', Icons.close_rounded, const Color(0xFFFF8793), mine == false, () => game.vote(target, index, false)))])
    ]));
  }

  Widget _results() {
    final playersSorted = players.values.toList()..sort((a,b) => (b['score'] as int).compareTo(a['score'] as int));
    final roundScores = (game.state['roundResults'] as Map?)?['scores'] as Map? ?? {};
    final approved = (game.state['roundResults'] as Map?)?['accepted'] as Map? ?? {};
    return ListView(key: const ValueKey('results'), padding: const EdgeInsets.all(22), children: [
      const SizedBox(height: 8), const Text('Tur tamamlandı', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)), const SizedBox(height: 6), Text('${game.state['letter']} harfiyle oynanan tur puanları', style: TextStyle(color: Colors.white.withValues(alpha: .6))), const SizedBox(height: 18),
      for (final p in playersSorted) _scoreTile(p, roundScores[p['id']] ?? 0),
      const SizedBox(height: 16), const Text('Cevaplara topluca bakış', style: TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 8),
      for (final p in playersSorted) for (var i=0; i<questions.length; i++) if (((p['answers'] as Map?)?['$i'] as String?)?.isNotEmpty == true)
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [Icon(approved['${p['id']}:$i'] == true ? Icons.check_circle_rounded : Icons.cancel_rounded, color: approved['${p['id']}:$i'] == true ? mint : const Color(0xFFFF8793), size: 18), const SizedBox(width: 8), Expanded(child: Text('${questions[i]} · ${(p['answers'] as Map)['$i']}')), Text(approved['${p['id']}:$i'] == true ? 'KABUL' : 'RET', style: const TextStyle(fontSize: 10, color: Colors.white54, fontWeight: FontWeight.w800))])),
      const SizedBox(height: 18), if (isHost) _button((game.state['round'] as int) >= (game.state['totalRounds'] as int) ? 'Final puan tablosu' : 'Sonraki tur', Icons.arrow_forward_rounded, mint, game.next),
      if (!isHost) _message('Sonraki turu oda sahibi başlatacak.', Icons.hourglass_top_rounded, lilac),
    ]);
  }

  Widget _finished() {
    final sorted = players.values.toList()..sort((a,b) => (b['score'] as int).compareTo(a['score'] as int));
    return ListView(key: const ValueKey('finished'), padding: const EdgeInsets.all(24), children: [const SizedBox(height: 34), const Icon(Icons.emoji_events_rounded, color: gold, size: 72), const SizedBox(height: 14), const Text('Oyun bitti!', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 32)), const SizedBox(height: 22), for (var i=0; i<sorted.length; i++) _scoreTile(sorted[i], sorted[i]['score']), const SizedBox(height: 14), _message('Güzel oyundu. Yeni bir oda kurup tekrar oynayın.', Icons.favorite_rounded, mint)]);
  }

  Widget _roomCodeCard() {
    final addresses = List<String>.from(game.state['hostAddresses'] as List? ?? game.localAddresses);
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF244238), Color(0xFF253149)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(24), border: Border.all(color: mint.withValues(alpha: .22))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('ODA ${game.state['room'] ?? '····'}', style: _eyebrow.copyWith(color: mint)),
        const SizedBox(height: 12),
        const Text('IP ile katıl', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        for (final address in addresses) Row(children: [
          Expanded(child: SelectableText(address, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700))),
          IconButton(tooltip: 'IP adresini kopyala', onPressed: () {
            Clipboard.setData(ClipboardData(text: address));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('IP adresi panoya kopyalandı')));
          }, icon: const Icon(Icons.copy_rounded)),
        ]),
        if (addresses.isEmpty) const Text('Wi-Fi veya hotspot bağlantısını kontrol edin.'),
        const SizedBox(height: 8),
        Text('Diğer telefonlarda bu IP adresini yazın. Birden fazla adres varsa sırayla deneyin. Herkes aynı Wi-Fi veya hotspot üzerinde olmalı.', style: TextStyle(color: Colors.white.withValues(alpha: .7), fontSize: 12, height: 1.4)),
      ]),
    );
  }

  Widget _playerTile(Map p) => Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13), decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(16)), child: Row(children: [CircleAvatar(radius: 18, backgroundColor: p['connected'] == true ? mint.withValues(alpha: .18) : Colors.white12, child: Icon(p['connected'] == true ? Icons.person_rounded : Icons.person_off_rounded, color: p['connected'] == true ? mint : Colors.white38, size: 19)), const SizedBox(width: 11), Expanded(child: Text('${p['name']}${p['id'] == game.playerId ? '  (sen)' : ''}', style: const TextStyle(fontWeight: FontWeight.w700))), Text(p['connected'] == true ? 'HAZIR' : 'YENİDEN BAĞLANIYOR', style: TextStyle(fontSize: 9, color: p['connected'] == true ? mint : gold, fontWeight: FontWeight.w900, letterSpacing: .5))]));

  Widget _scoreTile(Map p, int roundScore) => Container(margin: const EdgeInsets.only(bottom: 9), padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white.withValues(alpha: .05))), child: Row(children: [Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w800)), const Spacer(), Text('+$roundScore', style: const TextStyle(color: mint, fontWeight: FontWeight.w700)), const SizedBox(width: 15), Text('${p['score']} puan', style: const TextStyle(color: gold, fontSize: 13, fontWeight: FontWeight.w800))]));

  Widget _rulesCard() => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white.withValues(alpha: .035), borderRadius: BorderRadius.circular(18)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('NASIL OYNANIR', style: _eyebrow), const SizedBox(height: 9), _rule('01', '${game.state['duration'] ?? 60} saniyede 6 kategoriye cevap yaz.'), _rule('02', 'Oyuncular birbirlerinin cevaplarını gizli oylar.'), _rule('03', 'Katı çoğunluk kabul eder; eşitlikte cevap reddedilir.'), _rule('04', 'Kabul edilen özgün cevap 10, tekrar cevap 5 puan.'), _rule('05', 'Bağlantı koparsa oyuncu 45 saniye odada tutulur.') ]));
  Widget _rule(String n, String text) => Padding(padding: const EdgeInsets.only(top: 7), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(n, style: const TextStyle(color: mint, fontWeight: FontWeight.w800, fontSize: 11)), const SizedBox(width: 9), Expanded(child: Text(text, style: TextStyle(color: Colors.white.withValues(alpha: .7), fontSize: 12, height: 1.4)))]));
  Widget _timerBadge() => Container(padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9), decoration: BoxDecoration(color: game.secondsLeft <= 10 ? const Color(0xFF593D29) : Colors.white.withValues(alpha: .07), borderRadius: BorderRadius.circular(14)), child: Row(children: [Icon(Icons.timer_outlined, size: 17, color: game.secondsLeft <= 10 ? gold : mint), const SizedBox(width: 6), Text('${game.secondsLeft ~/ 60}:${(game.secondsLeft % 60).toString().padLeft(2, '0')}', style: TextStyle(color: game.secondsLeft <= 10 ? gold : Colors.white, fontWeight: FontWeight.w900, fontFeatures: const [FontFeature.tabularFigures()]))]));
  Widget _statusChip() => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7), decoration: BoxDecoration(color: (game.hosting || game._socket?.readyState == WebSocket.open) ? mint.withValues(alpha: .12) : gold.withValues(alpha: .12), borderRadius: BorderRadius.circular(20)), child: Row(children: [Icon(Icons.circle, size: 7, color: (game.hosting || game._socket?.readyState == WebSocket.open) ? mint : gold), const SizedBox(width: 6), Text((game.hosting || game._socket?.readyState == WebSocket.open) ? 'BAĞLI' : 'BEKLENİYOR', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900))]));
  Widget _voteButton(String label, IconData icon, Color color, bool selected, VoidCallback onTap) => OutlinedButton.icon(onPressed: onTap, icon: Icon(icon, size: 17), label: Text(label), style: OutlinedButton.styleFrom(foregroundColor: selected ? ink : color, backgroundColor: selected ? color : Colors.transparent, side: BorderSide(color: color.withValues(alpha: .4)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)), padding: const EdgeInsets.symmetric(vertical: 12)));
}

const _eyebrow = TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.1);
Widget _panel({required Widget child}) => Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(26), border: Border.all(color: Colors.white.withValues(alpha: .06))), child: child);
Widget _button(String title, IconData icon, Color color, VoidCallback? action, {String? secondary}) => SizedBox(width: double.infinity, child: FilledButton(onPressed: action, style: FilledButton.styleFrom(backgroundColor: color, foregroundColor: ink, disabledBackgroundColor: Colors.white10, disabledForegroundColor: Colors.white38, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)), padding: const EdgeInsets.fromLTRB(16, 12, 16, 12)), child: Row(children: [Icon(icon, size: 21), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)), if (secondary != null) Text(secondary, style: TextStyle(fontWeight: FontWeight.w500, fontSize: 10, color: ink.withValues(alpha: .66)))])), const Icon(Icons.chevron_right_rounded)])));
Widget _message(String text, IconData icon, Color color) => Container(width: double.infinity, padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: color.withValues(alpha: .08), borderRadius: BorderRadius.circular(16), border: Border.all(color: color.withValues(alpha: .18))), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, color: color, size: 18), const SizedBox(width: 9), Expanded(child: Text(text, style: TextStyle(color: Colors.white.withValues(alpha: .78), height: 1.4, fontSize: 12)))]));
Widget _glow(Color color, double size) => IgnorePointer(child: Container(width: size, height: size, decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: color, blurRadius: 90, spreadRadius: 20)])));
