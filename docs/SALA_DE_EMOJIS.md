<!--
SPDX-FileCopyrightText: 2026 IMFX TECH LTDA

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Sala de emojis do servidor

## O que faz

Ao abrir o app, cada conta procura a sala `#emojis:<server_name da conta>` (por exemplo `#emojis:example.com`). Se ela existir e passar na validação abaixo, o app:

1. entra na sala sem aviso;
2. silencia a sala e a põe em baixa prioridade (fim da lista de conversas);
3. ativa todos os pacotes de emoji e figurinha da sala no seletor e no autocompletar `:shortcode:`.

Isso acontece uma vez por conta (o app grava um marcador na account data `com.imfxtech.default_emote_room`, que vale para todos os dispositivos). Depois disso, a escolha do usuário manda:

- pacote que o admin criar depois entra sozinho na próxima abertura do app, desde que o usuário continue na sala;
- pacote que o usuário desligar em Configurações > Emojis continua desligado;
- quem sair da sala não volta a entrar.

Se o usuário já estava na sala (por exemplo, via `auto_join_rooms`), o app só ativa os pacotes e não mexe na notificação nem na prioridade.

## Validação da sala

O app só aceita a sala se:

- ela foi criada por um usuário do próprio servidor (o `sender` do `m.room.create` tem o mesmo domínio da conta); e
- o `m.room.canonical_alias` da sala publica `#emojis:example.com` como endereço principal ou alternativo.

Sala reprovada: o app sai dela, a esquece e não tenta de novo enquanto o alias apontar para a mesma sala.

## Criar a sala

Com uma conta de admin do próprio servidor, **antes** de liberar o app para os usuários:

- Endereço local `#emojis:example.com`, publicado como **endereço principal** (canonical alias). Sem isso, o app recusa a sala.
- Entrada pública (`join_rule: public`), para o usuário entrar sem convite.
- Recomendado: bloquear quem não é do servidor (`m.federate: false`). Só dá para definir na criação da sala. O app não exige.
- Power levels: `events_default` alto (por exemplo 100, sala só de leitura) e `im.ponies.room_emotes` só para admin.
- Pacotes: nas configurações de emoji da sala, um pacote por state key.

## Proteger o alias

No Synapse, por padrão qualquer usuário local pode criar alias. Num servidor que ainda não tem a sala, alguém poderia registrar `#emojis` primeiro e fazer todo mundo entrar na sala dele. Restrinja no `homeserver.yaml`:

```yaml
alias_creation_rules:
  - user_id: "@admin:example.com"
    alias: "*"
    action: allow
  - user_id: "*"
    alias: "#emojis:*"
    action: deny
  - user_id: "*"
    alias: "*"
    action: allow
```

Vale a primeira regra que casar. Confira a sintaxe na documentação da versão do Synapse em uso.

## Opcional: entrada automática pelo servidor

`auto_join_rooms: ["#emojis:example.com"]` no Synapse é compatível: o app vê que o usuário já está na sala e só ativa os pacotes.

## Desligar ou trocar

Chave `defaultEmoteRoomAlias`, com **só o localpart** (padrão `emojis`; um `#` na frente é aceito). Valor vazio desliga, e valor com `:` é inválido e também desliga.

- Android: managed configuration (MDM).
- iOS: AppConfig do MDM, mesma chave.
- Web: `config.json`.
- Desktop (Linux, macOS, Windows): não há como desligar, igual às outras settings.

## Limitações

- Só pacotes `im.ponies.room_emotes`. Pacotes publicados apenas como `m.room.image_pack` não são lidos.
- Se o alias passar a apontar para outra sala depois da primeira aplicação, o app não acompanha.
- Pacotes criados durante a sessão entram na próxima abertura do app.
