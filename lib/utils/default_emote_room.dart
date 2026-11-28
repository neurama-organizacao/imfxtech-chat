// SPDX-FileCopyrightText: 2026 IMFX TECH LTDA
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Ativa por padrão os pacotes de emoji da sala `#emojis:<server_name>` do
// servidor do usuário. Roda uma vez por conta; depois disso a escolha do
// usuário manda. Ver docs/SALA_DE_EMOJIS.md.

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:matrix/matrix.dart';

/// Tipo da account data que marca que a sala padrão já foi tratada.
const defaultEmoteRoomMarkerType = 'com.imfxtech.default_emote_room';

const _emoteRoomsType = 'im.ponies.emote_rooms';
const _roomEmotesType = 'im.ponies.room_emotes';
const _logPrefix = '[DefaultEmoteRoom]';

/// Monta `#<localpart>:<server_name do usuário>` a partir da setting.
///
/// Retorna `null` (recurso desligado) se a setting ficar vazia, tiver `:` ou
/// espaço, ou se o [userId] não tiver domínio.
String? buildDefaultEmoteRoomAlias(String setting, String? userId) {
  final localpart = _aliasLocalpart(setting);
  if (localpart == null) return null;
  final domain = userId?.domain;
  if (domain == null || domain.isEmpty) return null;
  return '#$localpart:$domain';
}

String? _aliasLocalpart(String setting) {
  var localpart = setting.trim();
  if (localpart.startsWith('#')) localpart = localpart.substring(1);
  if (localpart.isEmpty ||
      localpart.contains(':') ||
      localpart.contains(RegExp(r'\s'))) {
    return null;
  }
  return localpart;
}

enum DefaultEmoteRoomStatus { applied, rejected }

class DefaultEmoteRoomMarker {
  final String alias;
  final String roomId;
  final DefaultEmoteRoomStatus status;
  final Set<String> stateKeys;
  final int? appliedAt;

  const DefaultEmoteRoomMarker({
    required this.alias,
    required this.roomId,
    required this.status,
    this.stateKeys = const {},
    this.appliedAt,
  });

  /// Lê o marcador de forma tolerante. Campo obrigatório ausente, com tipo
  /// errado ou `status` desconhecido resulta em `null`.
  static DefaultEmoteRoomMarker? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final alias = json['alias'];
    final roomId = json['room_id'];
    final statusName = json['status'];
    if (alias is! String || roomId is! String || statusName is! String) {
      return null;
    }
    final status = DefaultEmoteRoomStatus.values.firstWhereOrNull(
      (s) => s.name == statusName,
    );
    if (status == null) return null;
    final rawKeys = json['state_keys'];
    final appliedAt = json['applied_at'];
    return DefaultEmoteRoomMarker(
      alias: alias,
      roomId: roomId,
      status: status,
      stateKeys: rawKeys is List ? rawKeys.whereType<String>().toSet() : {},
      appliedAt: appliedAt is int ? appliedAt : null,
    );
  }

  Map<String, Object?> toJson() => {
    'alias': alias,
    'room_id': roomId,
    'status': status.name,
    'state_keys': stateKeys.toList()..sort(),
    'applied_at': ?appliedAt,
  };
}

/// Regras contra sequestro do alias: a sala precisa ter sido criada por um
/// usuário do próprio servidor (a) e publicar o alias como endereço principal
/// ou alternativo (b).
bool isTrustedEmoteRoom({
  required String alias,
  required String userDomain,
  required String? createSenderId,
  required Map<String, Object?>? canonicalAliasContent,
}) {
  final creatorDomain = createSenderId?.domain;
  if (creatorDomain == null ||
      creatorDomain.toLowerCase() != userDomain.toLowerCase()) {
    return false;
  }
  if (canonicalAliasContent == null) return false;
  if (canonicalAliasContent['alias'] == alias) return true;
  final altAliases = canonicalAliasContent['alt_aliases'];
  return altAliases is List && altAliases.contains(alias);
}

Object? _deepCopy(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _deepCopy(entry.value),
    };
  }
  if (value is List) return value.map(_deepCopy).toList();
  return value;
}

/// Devolve uma cópia profunda de [emoteRoomsContent] com `stateKey: {}` para
/// cada chave de [stateKeys] que ainda falta em `rooms[roomId]`. Nunca remove
/// nada.
Map<String, Object?> mergeEmoteRoomPacks(
  Map<String, Object?>? emoteRoomsContent,
  String roomId,
  Iterable<String> stateKeys,
) {
  final content =
      _deepCopy(emoteRoomsContent ?? const {}) as Map<String, Object?>;
  final rooms = content['rooms'] is Map
      ? content['rooms'] as Map<String, Object?>
      : <String, Object?>{};
  content['rooms'] = rooms;
  final room = rooms[roomId] is Map
      ? rooms[roomId] as Map<String, Object?>
      : <String, Object?>{};
  rooms[roomId] = room;
  for (final key in stateKeys) {
    room.putIfAbsent(key, () => <String, Object?>{});
  }
  return content;
}

/// Diz se o usuário já tem uma entrada para [roomId] (também quando vazia,
/// que é o caso "desligou todos os pacotes").
bool hasEmoteRoomEntry(Map<String, Object?>? emoteRoomsContent, String roomId) {
  final rooms = emoteRoomsContent?['rooms'];
  return rooms is Map && rooms[roomId] is Map;
}

Set<String> newPackKeys(Iterable<String> current, Set<String> known) =>
    current.toSet().difference(known);

Set<String> _roomPackKeys(Room room) =>
    room.states[_roomEmotesType]?.keys.toSet() ?? <String>{};

Future<void> _writeMarker(Client client, DefaultEmoteRoomMarker marker) =>
    client.setAccountData(
      client.userID!,
      defaultEmoteRoomMarkerType,
      marker.toJson(),
    );

/// Entra na sala padrão de emojis do servidor do usuário e ativa os pacotes
/// dela. Nunca lança: todo erro vai para o log.
Future<void> applyDefaultEmoteRoom(
  Client client, {
  required String aliasSetting,
  Duration joinTimeout = const Duration(seconds: 60),
}) async {
  try {
    if (_aliasLocalpart(aliasSetting) == null) {
      if (aliasSetting.trim().isNotEmpty) {
        Logs().w('$_logPrefix Setting inválida: "$aliasSetting"');
      }
      return;
    }

    // Espera um sync desta sessão para ler a account data do servidor, e não
    // uma cópia local desatualizada. Offline, simplesmente não roda.
    await client.onSync.stream.first;

    final userId = client.userID;
    final alias = buildDefaultEmoteRoomAlias(aliasSetting, userId);
    final userDomain = userId?.domain;
    if (userId == null || alias == null || userDomain == null) return;

    var marker = DefaultEmoteRoomMarker.fromJson(
      client.accountData[defaultEmoteRoomMarkerType]?.content,
    );
    if (marker != null && marker.alias != alias) marker = null;

    if (marker != null && marker.status == DefaultEmoteRoomStatus.applied) {
      await _applyNewPacks(client, marker);
      return;
    }

    final GetRoomIdByAliasResponse resolved;
    try {
      resolved = await client.getRoomIdByAlias(alias);
    } catch (e) {
      Logs().v('$_logPrefix Alias $alias não resolvido', e);
      return;
    }
    final roomId = resolved.roomId;
    if (roomId == null) return;
    if (marker != null &&
        marker.status == DefaultEmoteRoomStatus.rejected &&
        marker.roomId == roomId) {
      return;
    }

    var joinedNow = false;
    if (client.getRoomById(roomId)?.membership != Membership.join) {
      final synced = client.onSync.stream
          .firstWhere((s) => s.rooms?.join?.containsKey(roomId) ?? false)
          .timeout(joinTimeout);
      try {
        await client.joinRoom(roomId, via: resolved.servers);
      } catch (e) {
        synced.ignore();
        Logs().w('$_logPrefix Não foi possível entrar em $alias', e);
        return;
      }
      await _muteAndLowPriority(client, roomId);
      try {
        await synced;
      } on TimeoutException {
        Logs().w('$_logPrefix Sync do join em $alias não chegou a tempo');
        return;
      }
      joinedNow = true;
    }

    final room = client.getRoomById(roomId);
    if (room == null) return;

    final trusted = isTrustedEmoteRoom(
      alias: alias,
      userDomain: userDomain,
      createSenderId: room.getState(EventTypes.RoomCreate)?.senderId,
      canonicalAliasContent: room
          .getState(EventTypes.RoomCanonicalAlias)
          ?.content,
    );
    if (!trusted) {
      Logs().w('$_logPrefix Sala $roomId de $alias reprovada na validação');
      if (joinedNow) {
        try {
          await room.leave();
          await room.forget();
        } catch (e) {
          Logs().w('$_logPrefix Falha ao sair de $roomId', e);
        }
      }
      await _writeMarker(
        client,
        DefaultEmoteRoomMarker(
          alias: alias,
          roomId: roomId,
          status: DefaultEmoteRoomStatus.rejected,
          appliedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }

    final keys = _roomPackKeys(room);
    final emoteRooms = client.accountData[_emoteRoomsType]?.content;
    // Se o usuário já mexeu nesta sala (em qualquer client), vale a escolha
    // dele.
    if (!hasEmoteRoomEntry(emoteRooms, roomId)) {
      await client.setAccountData(
        userId,
        _emoteRoomsType,
        mergeEmoteRoomPacks(emoteRooms, roomId, keys),
      );
    }
    await _writeMarker(
      client,
      DefaultEmoteRoomMarker(
        alias: alias,
        roomId: roomId,
        status: DefaultEmoteRoomStatus.applied,
        stateKeys: keys,
        appliedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  } catch (e, s) {
    Logs().w('$_logPrefix Falha ao aplicar a sala padrão de emojis', e, s);
  }
}

/// Pacotes criados na sala depois da primeira aplicação entram sozinhos,
/// desde que o usuário continue na sala. Pacote que o usuário desligou está
/// em [DefaultEmoteRoomMarker.stateKeys] e não volta.
Future<void> _applyNewPacks(
  Client client,
  DefaultEmoteRoomMarker marker,
) async {
  final room = client.getRoomById(marker.roomId);
  if (room == null || room.membership != Membership.join) return;
  final added = newPackKeys(_roomPackKeys(room), marker.stateKeys);
  if (added.isEmpty) return;
  await client.setAccountData(
    client.userID!,
    _emoteRoomsType,
    mergeEmoteRoomPacks(
      client.accountData[_emoteRoomsType]?.content,
      marker.roomId,
      added,
    ),
  );
  await _writeMarker(
    client,
    DefaultEmoteRoomMarker(
      alias: marker.alias,
      roomId: marker.roomId,
      status: DefaultEmoteRoomStatus.applied,
      stateKeys: {...marker.stateKeys, ...added},
      appliedAt: marker.appliedAt,
    ),
  );
}

/// Silencia a sala e põe em baixa prioridade. Melhor esforço.
Future<void> _muteAndLowPriority(Client client, String roomId) async {
  try {
    await client.setPushRule(
      PushRuleKind.override,
      roomId,
      [],
      conditions: [
        PushCondition(kind: 'event_match', key: 'room_id', pattern: roomId),
      ],
    );
  } catch (e) {
    Logs().w('$_logPrefix Falha ao silenciar $roomId', e);
  }
  try {
    await client.setRoomTag(client.userID!, roomId, TagType.lowPriority, Tag());
  } catch (e) {
    Logs().w('$_logPrefix Falha ao pôr $roomId em baixa prioridade', e);
  }
}
