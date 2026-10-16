# Instalación

[← README](../README.md) · [Problemas comunes](problemas-comunes.md) · [Detalles técnicos](detalles-tecnicos.md)

## 0. Claude Code en la computadora de los bots

La computadora es **compartida por todos los bots**: se instala y se loguea una sola vez y la usan todos.

1. Instalá la CLI con el instalador oficial nativo (Linux/macOS/WSL; se actualiza solo):
   ```
   curl -fsSL https://claude.ai/install.sh | bash
   ```
   Deja el lanzador en `~/.local/bin/claude` (tiene que estar en el `PATH`).
2. Verificá: `claude --version` imprime algo como `2.1.xxx (Claude Code)`. Para un diagnóstico más completo: `claude doctor`.
3. Login con la cuenta de Claude del dueño (Pro, Max, Team o Enterprise), **una sola vez**, en la pantalla del bot: corré `claude` y seguí el login en el navegador (o `claude auth login`). Los bots no inician sesión por su cuenta.
4. Conectá GitHub para la nube: dentro de `claude`, corré `/web-setup` (manda tu token de `gh` a la cuenta de Claude; si no tenés environment, crea el *Default*). Alternativa: instalar la Claude GitHub App desde claude.ai/code.

## 1. Slack

1. Creá un canal **privado** `#<canal>` y anotá su channel id (`C0123456789`; en Slack: detalles del canal → abajo de todo).
2. Creá una Slack app dedicada (https://api.slack.com/apps → *From scratch*). En *OAuth & Permissions* agregá **solo** los bot scopes `chat:write` y `chat:write.customize` (este último para que el mensaje salga como "Claude Code" con el ícono de Claude; sin él Slack ignora `username`/`icon_url` sin dar error). Instalala en el workspace y copiá el *Bot User OAuth Token* (`xoxb-...`).
3. En `#<canal>`: `/invite @<tu-app>` y `/invite @Cursor` (la app que dispara las routines de Grok Bot tiene que ver los mensajes del canal). No invites el bot de notificaciones a ningún otro canal.

El token solo puede escribir en canales donde el bot es miembro, así que si se filtra el daño queda acotado a ese canal. Igual, tratalo como secreto: nunca en el repo.

## 2. Nube (claude.ai/code environments, por defecto)

Es el modo por defecto: el agente hace push de la rama y lanza `claude --cloud "<tarea>"` desde la carpeta del repo (desde un bot, que no tiene TTY: `script -qec 'claude --cloud "<tarea>"' /dev/null </dev/null`). Requiere GitHub conectado a la cuenta de Claude (`/web-setup` dentro de `claude`).

El environment se crea en claude.ai/code, en la pantalla de nueva sesión: el selector de environment es el primer control de la fila debajo de la caja de mensaje → *New environment* (para editar uno existente: su fila bajo *Cloud* → ícono de configuración). Sugerencia de nombre: `<nombre-entorno>` (p.ej. `grokbot-notify`).

Duda: según la documentación, la CLI elige el environment con `/remote-env` (lo guarda en `remote.defaultEnvironmentId` de tus settings) y, si no elegiste, cae al environment alojado por Anthropic o al primero de la lista. No probamos `/remote-env` en esta computadora; si el aviso no llega, revisalo ahí.

En la configuración del environment:

1. **Network access:** *Custom*, permitir `slack.com` (y dejar los package managers por defecto).
2. **Network secret:** tipo Bearer para el host `slack.com`, con el token `xoxb-...`. El proxy de Anthropic inyecta el header `Authorization` en las requests de la sesión. Los secretos matchean **solo por host**, no por path, y el proxy **no** los agrega a requests del setup script (no intentes probar el envío ahí). Cuando no hay `SLACK_NOTIFY_TOKEN` en el env y `CLAUDE_CODE_REMOTE=true`, el hook no manda su propio header.
3. **Variables de entorno:** `SLACK_NOTIFY_CHANNEL=C0123456789`. Opcional: `NOTIFY_AGENT=<agent-slug>` como fallback si el environment es de un solo agente (la línea `notify:` del prompt gana).
4. **Setup script:** pegá entero el contenido de [`cloud/setup.sh`](../cloud/setup.sh). Escribe el hook y mergea `~/.claude/settings.json` dentro de la VM.
5. **Marcalo como environment por defecto** de tu cuenta en claude.ai/code. `claude --cloud` siempre usa el environment por defecto y no se puede elegir otro desde la terminal (`--environment` solo acepta environments self-hosted `ccpool_...`, no los `env_...` de claude.ai). Si el por defecto es otro, Claude trabaja igual pero el aviso de Slack nunca llega.

A quién avisar va en el propio prompt (línea `notify: <agent-slug>`), así que no hay nada que crear dentro de la VM.

**Verificado en una sesión real de la nube (2026-10-14), de punta a punta:**

- El network secret (Bearer para `slack.com`) **sí** se inyecta en la request que hace el hook durante la sesión: el aviso llegó al canal sin `SLACK_NOTIFY_TOKEN` en el env de la VM.
- La variable de entorno `SLACK_NOTIFY_CHANNEL` del environment llega al setup script, que la escribe en `~/.config/grokbot-claude-code/env`; con eso alcanza para el canal.
- El aviso real llevó un session id en `*sesión:*`. El hook igual mantiene el fallback: `https://claude.ai/code/$CLAUDE_CODE_REMOTE_SESSION_ID` si esa variable existe, si no el `session_id` del JSON del hook.

**Elegir el modelo** (verificado con Claude Code 2.1.300):
- Listar los disponibles, sin interacción: `timeout 60 claude -p '/model' </dev/null` (imprime el modelo actual y los alias: `sonnet`, `opus`, `haiku`, ..., `default` o un id completo).
- El agente le muestra esa lista al usuario para que elija antes de arrancar.
- Pasarlo al lanzar en la nube (verificado: el transcript de la sesión de la nube registra el modelo del alias):
  ```
  script -qec 'claude --model <alias> --cloud "notify: <agent-slug>
  <tarea>"' /dev/null </dev/null
  ```
- Duda: si se puede cambiar el modelo de una sesión que ya existe.

## 3. Local (computadora compartida, fallback)

La computadora compartida es la alternativa cuando la nube no está disponible, la tarea necesita recursos locales (archivos, servicios, credenciales de esa máquina) o el usuario lo pide. Igual conviene instalarla: el agente lanza `claude --cloud` desde ahí y las pruebas de la routine usan el hook local.

Requisitos: `git`, `bash`, `curl` y **`jq`** (en la práctica obligatorio: `local/install.sh` lo usa para mergear los hooks y el hook para parsear el JSON; el fallback sin `jq` cubre los casos de los tests, pero no es un parser JSON completo). `python3` solo para los tests.

```bash
git clone https://github.com/luck-prg/grokbot-claude-code ~/grokbot-claude-code
bash ~/grokbot-claude-code/local/install.sh          # deja el env en modo 600
$EDITOR ~/.config/grokbot-claude-code/env   # SLACK_NOTIFY_TOKEN=xoxb-... y SLACK_NOTIFY_CHANNEL=C...
```

`notify-run` queda en `~/.local/bin` (o en `BIN_DIR`). Si `command -v notify-run` no lo encuentra, agregá `export PATH="$HOME/.local/bin:$PATH"` a tu shell o usá la ruta completa. Correr el instalador de nuevo es seguro (no duplica hooks ni pisa el env). Para desinstalar: `bash ~/grokbot-claude-code/local/install.sh --uninstall`.

Opcionales en el mismo archivo o en el entorno: `SLACK_NOTIFY_USERNAME` y `SLACK_NOTIFY_ICON_URL` (ver el payload arriba). Las variables `SLACK_NOTIFY_TOKEN` / `SLACK_NOTIFY_CHANNEL` / `SLACK_NOTIFY_USERNAME` / `SLACK_NOTIFY_ICON_URL` del entorno ganan sobre el archivo. El hook envía el token por un descriptor de archivo, no por la línea de comandos (no aparece en `ps`).

Probar sin red, con un transcript mínimo cuyo primer mensaje trae `notify: prueba`:

```bash
d=$(mktemp -d)
printf '{"type":"user","message":{"role":"user","content":"hola\\nnotify: prueba"}}\n' > "$d/t.jsonl"
echo "{\"session_id\":\"s1\",\"transcript_path\":\"$d/t.jsonl\",\"cwd\":\"$d\",\"hook_event_name\":\"Stop\"}" \
  | DRY_RUN=1 bash ~/.claude/hooks/grokbot-notify.sh
```

Para probar el envío HTTP completo (headers incluidos) sin tocar Slack, apuntá el hook a un servidor falso local con `SLACK_API_URL=http://127.0.0.1:<puerto>/api/chat.postMessage` (perilla solo para tests; ver `tests/test-scripts.sh`).

Sin `DRY_RUN` publica de verdad. Log: `${XDG_STATE_HOME:-~/.local/state}/grokbot-claude-code/notify.log` (directorio privado del usuario, creado con `umask 077`; se cambia con `NOTIFY_STATE_DIR`).

Desinstalar (borra el hook, `notify-run` y las entradas de `grokbot-notify.sh` en `settings.json`, conservando el resto y dejando backup; **no** toca `~/.config/grokbot-claude-code/env`):

```bash
bash ~/grokbot-claude-code/local/install.sh --uninstall
```

## 4. Onboarding de cada agente (routine)

Cada agente Grok Bot se configura una vez con la skill [`skill/claude-code-notify-setup/SKILL.md`](../skill/claude-code-notify-setup/SKILL.md): se le asigna un slug, crea una routine con trigger Slack por keyword `notify-<slug>`, lo guarda en su memoria y se prueba que dispara. Así solo despierta ese agente (filtro determinístico, sin LLM en el medio).

Nada viene fijo: el agente le **pregunta al usuario** el nombre del canal de avisos (`#<canal>`), su channel id (`C0123456789`, el valor de `SLACK_NOTIFY_CHANNEL`) y qué bots activar. Hay dos flujos:

- **Coordinador:** un agente le pide al usuario el canal, la lista de bots y un slug por bot; chequea colisiones de todos los slugs (nuevos + ya usados en el canal) con `local/check-slugs`; a cada bot le manda las instrucciones con `SendToAgent` (si está disponible) o le da al usuario el prompt para pegarle; y al final hace **una** prueba por bot con el bot de notificaciones y reporta una tabla bot → keyword → disparó sí/no.
- **Por agente:** el agente se configura solo: pregunta canal e id, confirma su slug, chequea colisiones, crea la routine, guarda la memoria, hace una prueba y reporta.

**Regla de colisión por substring:** la routine matchea el keyword como substring del mensaje, así que el keyword de un agente no puede estar contenido en el de otro ni contenerlo. `notify-dev` y `notify-dev-ml` chocan: un aviso para `notify-dev-ml` despierta también a `notify-dev`. Chequealo con todos los slugs (los nuevos y los que ya se usan en el canal):

```bash
bash local/check-slugs <slug-1> <slug-2> <slug-ya-usado> ...   # o uno por línea por stdin
```

Sale 0 si está todo bien, 1 si hay problemas (formato `^[a-z0-9][a-z0-9-]*$`, duplicados o colisión por substring; los imprime) y 2 si no le pasaste slugs. Acepta los slugs con o sin el prefijo `notify-`.

Requisito: `@Cursor` invitado al canal de avisos (paso 1).

Los prompts para arrancar cada flujo están en [PROMPT para que un agente Grok Bot replique el setup](#prompt-para-que-un-agente-grok-bot-replique-el-setup).

## 5. Skill

Reemplazá la skill `claude-code-task` de Grok Bot por [`skill/claude-code-task/SKILL.md`](../skill/claude-code-task/SKILL.md).

## SessionStart (opcional)

Desactivado por defecto. Para avisar también al arrancar una sesión, agregá a `settings.json`:

```json
"SessionStart": [
  { "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/hooks/grokbot-notify.sh\"", "timeout": 15 } ] }
]
```

y exportá `NOTIFY_SESSION_START=1`. Para quitarlo, borrá ese bloque.


## PROMPT para que un agente Grok Bot replique el setup

Copiá y pegá el que corresponda. Los `<...>` los completa el agente preguntándote (o completalos vos antes de pegar). El token pasalo por un canal seguro, nunca en el chat.

**Coordinador** (un agente configura a varios de tus bots):

```text
Configurá las notificaciones de Claude Code para varios de mis bots, con el flujo coordinador de la skill claude-code-notify-setup del repo grokbot-claude-code. Las tareas corren por defecto en la nube (claude --cloud, skill claude-code-task); local en la computadora compartida es solo el fallback.
1. Cloná el repo en ~/grokbot-claude-code (si ya existe, hacé git pull). Si la máquina compartida todavía no tiene el hook, corré: bash ~/grokbot-claude-code/local/install.sh
2. Preguntame: el nombre del canal de avisos (#<canal>), su channel id (estilo C0123456789, para SLACK_NOTIFY_CHANNEL), qué bots activar, un slug por bot y qué notify-... ya se usan en el canal. No adivines nada de esto.
3. Chequeá todos los slugs (nuevos + ya usados) con: bash ~/grokbot-claude-code/local/check-slugs <slug-1> <slug-2> ... Si sale 1 (colisión por substring, p.ej. notify-dev vs notify-dev-ml), proponeme otros y repetí.
4. Verificá que ~/.config/grokbot-claude-code/env tenga modo 600 y SLACK_NOTIFY_CHANNEL con el id que te di. Si SLACK_NOTIFY_TOKEN sigue en xoxb-REPLACE_ME, pedímelo por un canal seguro; no lo escribas en ningún repo ni mensaje.
5. A cada bot mandale con SendToAgent (si lo tenés) el prompt por agente de la skill con su canal y slug completos; si no, dame ese prompt listo para que yo se lo pegue. Que creen la routine, guarden el slug en memoria y reemplacen su skill claude-code-task (nube por defecto, local como fallback), sin probar.
6. Cuando cada bot confirme, hacé exactamente UNA prueba por bot con el bot de notificaciones (vía el hook, como dice la skill) y reportame una tabla bot → keyword → disparó sí/no.
No hagas polling, no mergees, no hagas push de nada en este repo.
```

**Por agente** (el agente se configura solo):

```text
Configurá las notificaciones de Claude Code para vos, con el flujo por agente de la skill claude-code-notify-setup del repo grokbot-claude-code. Tus tareas corren por defecto en la nube (claude --cloud, skill claude-code-task); local en la computadora compartida es solo el fallback.
1. Cloná el repo en ~/grokbot-claude-code (si ya existe, hacé git pull). Si la máquina compartida todavía no tiene el hook, corré: bash ~/grokbot-claude-code/local/install.sh
2. Preguntame el nombre del canal de avisos (#<canal>) y su channel id (estilo C0123456789), y confirmá conmigo tu slug (proponé uno: <slug>). Preguntame qué notify-... ya se usan en el canal.
3. Chequeá tu slug contra los ya usados con: bash ~/grokbot-claude-code/local/check-slugs <slug> <slug-ya-usado> ... Si sale 1 (colisión por substring, p.ej. notify-dev vs notify-dev-ml), proponé otro.
4. Verificá que ~/.config/grokbot-claude-code/env tenga modo 600 y SLACK_NOTIFY_CHANNEL con el id que te di. Si SLACK_NOTIFY_TOKEN sigue en xoxb-REPLACE_ME, pedímelo por un canal seguro; no lo escribas en ningún repo ni mensaje.
5. Creá tu routine con trigger {type:'slack', channel:'#<canal>', match:{kind:'keyword', keyword:'notify-<slug>'}} con la instrucción de la skill (confirma la línea *agente:* y lee los campos • *<campo>:* del aviso) y guardá en tu memoria slug, keyword y canal (al lanzar tareas, el prompt lleva una línea sola "notify: <slug>").
6. Reemplazá tu skill claude-code-task por ~/grokbot-claude-code/skill/claude-code-task/SKILL.md (nube por defecto: push de la rama + claude --cloud; local con notify-run solo como fallback).
7. Hacé UNA sola prueba con el bot de notificaciones (vía el hook, como dice la skill) y reportame keyword, canal y si tu routine disparó. Si no, revisá ${XDG_STATE_HOME:-~/.local/state}/grokbot-claude-code/notify.log.
No hagas polling, no mergees, no hagas push de nada en este repo.
```

