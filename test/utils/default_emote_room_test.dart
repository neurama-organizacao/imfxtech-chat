// SPDX-FileCopyrightText: 2026 IMFX TECH LTDA
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Sala de emojis padrão do servidor (issue #8): pacotes de #emojis:<servidor>
// ativados uma vez por conta, sem sobrescrever a escolha do usuário.

// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/default_emote_room.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'test_client.dart';

const _domain = 'fakeServer.notExisting';
const _alias = '#emojis:$_domain';
const _roomId = '!emojis:$_domain';
const _emoteRoomsType = 'im.ponies.emote_rooms';

final _userPath = Uri.encodeComponent('@test:$_domain');
final _roomPath = Uri.encodeComponent(_roomId);
final _directoryAction =
    '/client/v3/directory/room/${Uri.encodeComponent(_alias)}';
final _joinAction = '/client/v3/join/$_roomPath?via=$_domain';
final _pushRuleAction = '/client/v3/pushrules/global/override/$_roomPath';
final _tagAction =
    '/client/v3/user/$_userPath/rooms/$_roomPath/tags/m.lowpriority';
final _leaveAction = '/client/v3/rooms/$_roomPath/leave';
final _emoteRoomsPut =
    '/client/v3/user/$_userPath/account_data/$_emoteRoomsType';
final _markerPut =
    '/client/v3/user/$_userPath/account_data/$defaultEmoteRoomMarkerType';

var _eventCounter = 0;

MatrixEvent _state(
  String type,
  Map<String, Object?> content, {
  String stateKey = '',
  String sender = '@admin:$_domain',
}) => MatrixEvent(
  type: type,
  content: content,
  senderId: sender,
  stateKey: stateKey,
  eventId: '\$emote${_eventCounter++}',
  originServerTs: DateTime.now(),
);

List<MatrixEvent> _roomState({
  String creator = '@admin:$_domain',
  Iterable<String> packs = const ['', 'fixas'],
}) => [
  _state(EventTypes.RoomCreate, {'room_version': '11'}, sender: creator),
  _state(EventTypes.RoomCanonicalAlias, {'alias': _alias}, sender: creator),
  for (final key in packs)
    _state('im.ponies.room_emotes', {
      'images': {
        'img$key': {'url': 'mxc://example.com/$key'},
      },
    }, stateKey: key),
];

Map<String, Object?>? _accountData(Client client, String type) =>
    client.accountData[type]?.content;

Future<void> _setAccountData(
  Client client,
  String type,
  Map<String, Object?> content,
) => client.handleSync(
  SyncUpdate(
    nextBatch: '',
    accountData: [BasicEvent(type: type, content: content)],
  ),
);

Future<void> _joinLocally(Client client, List<MatrixEvent> state) =>
    client.handleSync(
      SyncUpdate(
        nextBatch: '',
        rooms: RoomsUpdate(join: {_roomId: JoinedRoomUpdate(state: state)}),
      ),
    );

bool _called(String action) =>
    FakeMatrixApi.calledEndpoints[action]?.isNotEmpty ?? false;

void main() {
  group('buildDefaultEmoteRoomAlias', () {
    test('monta o alias com o server_name do usuário', () {
      for (final setting in ['emojis', '#emojis', '  emojis ']) {
        expect(
          buildDefaultEmoteRoomAlias(setting, '@a:example.com'),
          '#emojis:example.com',
        );
      }
      expect(
        buildDefaultEmoteRoomAlias('emojis', '@a:example.com:8448'),
        '#emojis:example.com:8448',
      );
    });

    test('setting vazia ou inválida desliga', () {
      for (final setting in ['', '   ', '#', 'emojis:outro.com', 'a b']) {
        expect(
          buildDefaultEmoteRoomAlias(setting, '@a:example.com'),
          isNull,
          reason: setting,
        );
      }
      expect(buildDefaultEmoteRoomAlias('emojis', null), isNull);
      expect(buildDefaultEmoteRoomAlias('emojis', 'invalido'), isNull);
    });

    test('padrão é "emojis"', () {
      expect(AppSettings.defaultEmoteRoomAlias.defaultValue, 'emojis');
    });
  });

  group('DefaultEmoteRoomMarker', () {
    test('ida e volta pelo JSON', () {
      const marker = DefaultEmoteRoomMarker(
        alias: '#emojis:example.com',
        roomId: '!abc:example.com',
        status: DefaultEmoteRoomStatus.applied,
        stateKeys: {'', 'fixas'},
        appliedAt: 1764300000000,
      );
      final parsed = DefaultEmoteRoomMarker.fromJson(marker.toJson())!;
      expect(parsed.alias, marker.alias);
      expect(parsed.roomId, marker.roomId);
      expect(parsed.status, marker.status);
      expect(parsed.stateKeys, marker.stateKeys);
      expect(parsed.appliedAt, marker.appliedAt);
    });

    test('tolera conteúdo ausente ou com tipo errado', () {
      expect(DefaultEmoteRoomMarker.fromJson(null), isNull);
      expect(DefaultEmoteRoomMarker.fromJson({}), isNull);
      expect(
        DefaultEmoteRoomMarker.fromJson({
          'alias': '#emojis:example.com',
          'room_id': '!abc:example.com',
          'status': 'desconhecido',
        }),
        isNull,
      );
      final marker = DefaultEmoteRoomMarker.fromJson({
        'alias': '#emojis:example.com',
        'room_id': '!abc:example.com',
        'status': 'rejected',
        'state_keys': 'errado',
        'applied_at': 'errado',
      })!;
      expect(marker.status, DefaultEmoteRoomStatus.rejected);
      expect(marker.stateKeys, isEmpty);
      expect(marker.appliedAt, isNull);
    });
  });

  group('isTrustedEmoteRoom', () {
    bool trusted(String? sender, Map<String, Object?>? canonical) =>
        isTrustedEmoteRoom(
          alias: '#emojis:example.com',
          userDomain: 'example.com',
          createSenderId: sender,
          canonicalAliasContent: canonical,
        );

    test('aprova criador local com o alias publicado', () {
      expect(
        trusted('@admin:example.com', {'alias': '#emojis:example.com'}),
        isTrue,
      );
      expect(
        trusted('@admin:example.com', {
          'alias': '#geral:example.com',
          'alt_aliases': ['#emojis:example.com'],
        }),
        isTrue,
      );
    });

    test('reprova criador de fora, canonical ausente ou de outro alias', () {
      expect(
        trusted('@x:outro.example', {'alias': '#emojis:example.com'}),
        isFalse,
      );
      expect(trusted(null, {'alias': '#emojis:example.com'}), isFalse);
      expect(trusted('@admin:example.com', null), isFalse);
      expect(
        trusted('@admin:example.com', {'alias': '#geral:example.com'}),
        isFalse,
      );
    });
  });

  group('mergeEmoteRoomPacks', () {
    test('cria a estrutura a partir de nada', () {
      expect(mergeEmoteRoomPacks(null, '!r:x', ['', 'a']), {
        'rooms': {
          '!r:x': {'': {}, 'a': {}},
        },
      });
    });

    test('preserva o resto, não duplica e não altera a entrada', () {
      final input = <String, Object?>{
        'outro': 1,
        'rooms': {
          '!outra:x': {'p': <String, Object?>{}},
          '!r:x': {'a': <String, Object?>{}},
        },
      };
      final merged = mergeEmoteRoomPacks(input, '!r:x', ['a', 'b']);
      expect(merged, {
        'outro': 1,
        'rooms': {
          '!outra:x': {'p': {}},
          '!r:x': {'a': {}, 'b': {}},
        },
      });
      expect((input['rooms'] as Map)['!r:x'], {'a': {}});
    });

    test('substitui rooms com tipo errado', () {
      expect(mergeEmoteRoomPacks({'rooms': 'errado'}, '!r:x', ['']), {
        'rooms': {
          '!r:x': {'': {}},
        },
      });
    });
  });

  test('hasEmoteRoomEntry considera sala com todos os pacotes desligados', () {
    expect(
      hasEmoteRoomEntry({
        'rooms': {'!r:x': {}},
      }, '!r:x'),
      isTrue,
    );
    expect(hasEmoteRoomEntry({'rooms': {}}, '!r:x'), isFalse);
    expect(hasEmoteRoomEntry(null, '!r:x'), isFalse);
  });

  test('newPackKeys devolve só a diferença', () {
    expect(newPackKeys(['', 'a', 'b'], {'', 'a'}), {'b'});
    expect(newPackKeys(['a'], {'a', 'b'}), isEmpty);
  });

  group('applyDefaultEmoteRoom', () {
    late Client client;
    late FakeMatrixApi api;
    late List<MatrixEvent> joinState;

    void route(String method, String action, Object? Function(Object?) res) =>
        api.api[method]![action] = res;

    setUp(() async {
      client = await prepareTestClient(loggedIn: true);
      api = FakeMatrixApi.currentApi!;
      FakeMatrixApi.client = client;
      joinState = _roomState();
      route(
        'GET',
        _directoryAction,
        (_) => {
          'room_id': _roomId,
          'servers': [_domain],
        },
      );
      route('POST', _joinAction, (_) {
        unawaited(
          Future.delayed(
            const Duration(milliseconds: 5),
            () => _joinLocally(client, joinState),
          ),
        );
        return {'room_id': _roomId};
      });
      route('PUT', _pushRuleAction, (_) => {});
      route('PUT', _tagAction, (_) => {});
      route('POST', _leaveAction, (_) => {});
      route('POST', '/client/v3/rooms/$_roomPath/forget', (_) => {});
      FakeMatrixApi.calledEndpoints.clear();
    });

    tearDown(() async {
      FakeMatrixApi.client = null;
      await client.dispose(closeDatabase: true);
    });

    Future<void> apply({String setting = 'emojis'}) => applyDefaultEmoteRoom(
      client,
      aliasSetting: setting,
      joinTimeout: const Duration(seconds: 5),
    );

    DefaultEmoteRoomMarker? marker() => DefaultEmoteRoomMarker.fromJson(
      _accountData(client, defaultEmoteRoomMarkerType),
    );

    Map<String, Object?>? packsOfRoom() =>
        (_accountData(client, _emoteRoomsType)?['rooms'] as Map?)?[_roomId]
            as Map<String, Object?>?;

    test('conta nova: entra, silencia e ativa todos os pacotes', () async {
      await apply();

      expect(client.getRoomById(_roomId)?.membership, Membership.join);
      expect(packsOfRoom()?.keys.toSet(), {'', 'fixas'});
      final m = marker()!;
      expect(m.status, DefaultEmoteRoomStatus.applied);
      expect(m.alias, _alias);
      expect(m.roomId, _roomId);
      expect(m.stateKeys, {'', 'fixas'});
      expect(_called(_pushRuleAction), isTrue);
      expect(_called(_tagAction), isTrue);
    });

    test('alias inexistente não grava nada', () async {
      route('GET', _directoryAction, (_) => {'errcode': 'M_NOT_FOUND'});
      await apply();

      expect(_called(_directoryAction), isTrue);
      expect(_called(_emoteRoomsPut), isFalse);
      expect(_called(_markerPut), isFalse);
      expect(marker(), isNull);
    });

    test('join recusado não grava marcador e não lança', () async {
      route('POST', _joinAction, (_) => {'errcode': 'M_FORBIDDEN'});
      await apply();

      expect(_called(_joinAction), isTrue);
      expect(_called(_markerPut), isFalse);
      expect(marker(), isNull);
    });

    test(
      'não sobrescreve pacote desligado e acrescenta só pacote novo',
      () async {
        await _joinLocally(client, _roomState());
        await _setAccountData(client, _emoteRoomsType, {
          'rooms': {
            _roomId: {'': {}},
          },
        });
        await _setAccountData(
          client,
          defaultEmoteRoomMarkerType,
          const DefaultEmoteRoomMarker(
            alias: _alias,
            roomId: _roomId,
            status: DefaultEmoteRoomStatus.applied,
            stateKeys: {'', 'fixas'},
          ).toJson(),
        );
        FakeMatrixApi.calledEndpoints.clear();

        await apply();
        expect(_called(_emoteRoomsPut), isFalse);
        expect(_called(_markerPut), isFalse);
        expect(_called(_directoryAction), isFalse);
        expect(packsOfRoom()?.keys.toSet(), {''});

        await _joinLocally(client, [
          _state('im.ponies.room_emotes', {
            'images': <String, Object?>{},
          }, stateKey: 'extra'),
        ]);
        await apply();
        expect(_called(_emoteRoomsPut), isTrue);
        expect(packsOfRoom()?.keys.toSet(), {'', 'extra'});
        expect(marker()!.stateKeys, {'', 'fixas', 'extra'});
        expect(_called(_directoryAction), isFalse);
        expect(_called(_joinAction), isFalse);
      },
    );

    test('quem saiu da sala não volta', () async {
      await _setAccountData(
        client,
        defaultEmoteRoomMarkerType,
        const DefaultEmoteRoomMarker(
          alias: _alias,
          roomId: _roomId,
          status: DefaultEmoteRoomStatus.applied,
          stateKeys: {'', 'fixas'},
        ).toJson(),
      );
      await client.handleSync(
        SyncUpdate(
          nextBatch: '',
          rooms: RoomsUpdate(leave: {_roomId: LeftRoomUpdate()}),
        ),
      );
      FakeMatrixApi.calledEndpoints.clear();

      await apply();
      expect(_called(_directoryAction), isFalse);
      expect(_called(_joinAction), isFalse);
      expect(_called(_emoteRoomsPut), isFalse);
    });

    test('escolha anterior do usuário vale mesmo sem marcador', () async {
      await _joinLocally(client, _roomState());
      await _setAccountData(client, _emoteRoomsType, {
        'rooms': {_roomId: <String, Object?>{}},
      });
      FakeMatrixApi.calledEndpoints.clear();

      await apply();
      expect(_called(_joinAction), isFalse);
      expect(_called(_pushRuleAction), isFalse);
      expect(_called(_emoteRoomsPut), isFalse);
      expect(packsOfRoom(), isEmpty);
      expect(marker()?.status, DefaultEmoteRoomStatus.applied);
      expect(marker()?.stateKeys, {'', 'fixas'});
    });

    test('sala reprovada: sai, marca rejected e não tenta de novo', () async {
      joinState = _roomState(creator: '@x:outro.example');
      await apply();

      expect(_called(_joinAction), isTrue);
      expect(_called(_leaveAction), isTrue);
      expect(_called(_emoteRoomsPut), isFalse);
      expect(marker()?.status, DefaultEmoteRoomStatus.rejected);
      expect(marker()?.roomId, _roomId);

      FakeMatrixApi.calledEndpoints.clear();
      await apply();
      expect(_called(_directoryAction), isTrue);
      expect(_called(_joinAction), isFalse);
    });

    test('setting vazia não faz nenhuma chamada', () async {
      await apply(setting: '');
      expect(_called(_directoryAction), isFalse);
      expect(_called(_joinAction), isFalse);
      expect(_called(_markerPut), isFalse);
    });
  });
}
