---
name: claude-code-notify-setup
description: >-
  Usar una sola vez para que uno o varios agentes de Grok Bot se despierten con los
  avisos de Claude Code en Slack. Le pregunta al usuario el canal de avisos, su
  channel id y qué bots activar; asigna un slug notify-<slug> por bot sin colisiones,
  crea la routine con trigger por keyword, lo guarda en memoria y prueba que dispara.
  Dos flujos: coordinador (configura a varios bots) o por agente (se configura solo).
---
# Configurar agentes para recibir avisos de Claude Code

Los hooks de Claude Code (local o nube) publican en el canal de avisos un mensaje así:

```
🤖 *Claude Code*
*evento:* `<evento>`
*sesión:* <url|abrir>
*repo:* `owner/name`
*rama:* `<rama>`
*agente:* `notify-<slug>`
*tarea:* `<tarea>`
```

Un campo por línea (`*<campo>:* <valor>`, valor entre backticks o `<url|abrir>`); los campos vacíos no aparecen. La routine identifica al agente por la línea `*agente:*` `` `notify-<slug>` ``, que es el único `notify-` real del mensaje. Detalle del parseo en la skill `claude-code-task`.

Cada agente tiene una routine que despierta solo con **su** keyword `notify-<slug>`. Esta skill se corre una vez (por agente o una vez para varios). Para lanzar tareas después, usá la skill `claude-code-task`.

## Qué le preguntás al usuario (nunca lo adivines)

Nada de esto viene fijo en la skill: el canal y los bots son los del usuario de Grok Bot.

1. **Nombre del canal de avisos** (`#<canal>`): el canal privado donde publica el bot de notificaciones.
2. **Channel id** de ese canal (estilo `C0123456789`; en Slack: detalles del canal → abajo de todo). Es el valor de `SLACK_NOTIFY_CHANNEL` (local en `~/.config/grokbot-claude-code/env`, nube en las variables del environment).
3. **Qué bots activar** (flujo coordinador) o confirmación de que sos vos (flujo por agente), y el **slug** de cada uno.
4. **Los `notify-...` que ya se usan** en `#<canal>`, si el usuario los conoce (además, revisá el historial del canal si podés leerlo).

Si falta algún dato, preguntá y esperá la respuesta. No pegues ni pidas tokens por el chat: el token `xoxb-...` va solo en el archivo de config o como network secret.

## Reglas del slug

Tu keyword va a ser `notify-<slug>`:
- Minúsculas, números y guiones (`^[a-z0-9][a-z0-9-]*$`), sin espacios. El hook no pasa a minúsculas por vos.
- Único: ningún otro agente lo usa.
- **Sin colisión por substring.** La routine matchea el keyword como substring del mensaje, así que un keyword **no puede estar contenido** en el de otro agente **ni contener** el de otro. Ejemplo: `notify-dev` y `notify-dev-ml` chocan (un aviso para `notify-dev-ml` despierta también a `notify-dev`). Preferí algo distintivo, p.ej. el nombre del bot en vez de un rol genérico.

Chequealo siempre con el helper del repo, pasando **todos** los slugs: los nuevos y los que ya se usan en el canal (con o sin el prefijo `notify-`):

```bash
bash ~/grokbot-claude-code/local/check-slugs <slug-nuevo-1> <slug-nuevo-2> <slug-ya-usado-1> ...
```

[`local/check-slugs`](../../local/check-slugs) sale 0 si está todo bien y 1 si hay problemas (formato, duplicados o colisión por substring; los imprime). Si sale 1, proponé otros slugs al usuario y volvé a chequear. Si no tenés el repo a mano, aplicá la regla a mano par por par.

## Routine (igual para todos los flujos)

Trigger, con el nombre de canal que te dio el usuario:

```json
{"type":"slack","channel":"#<canal>","match":{"kind":"keyword","keyword":"notify-<slug>"}}
```

Instrucción de la routine:

> Llegó un aviso de Claude Code. Confirmá que la línea `*agente:*` diga `` `notify-<slug>` `` (si no, ignorá el mensaje). Cada línea es `*<campo>:* <valor>`, con el valor entre backticks o como `<url|abrir>`: sacá `evento` (con su detalle, p.ej. `error=rate_limit`), `tarea`, `sesión` y `rama`. Buscá la tarea por `tarea` y seguí "Al recibir el aviso" de la skill claude-code-task: continuá la tarea o reportá el resultado a quien la pidió. No cambies nada fuera del alcance de esa tarea.

Requisito: `@Cursor` tiene que estar invitado a `#<canal>` (es la app que dispara las routines; si no ve el canal, la routine nunca salta). Si no está, pedíselo al usuario.

## Prueba (exactamente UNA por bot)

Siempre con el bot de notificaciones (vía el hook), no con un mensaje escrito a mano, así se prueba el mismo camino que los avisos reales. Con el hook instalado y `SLACK_NOTIFY_TOKEN` / `SLACK_NOTIFY_CHANNEL` configurados:

```bash
d=$(mktemp -d) && cd "$d"
printf 'NOTIFY_AGENT=<slug>\nNOTIFY_TASK=prueba-notify\n' > .claude-notify
echo "{\"session_id\":\"prueba-$(date +%s)\",\"cwd\":\"$d\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"prueba de routine\"}" \
  | bash ~/.claude/hooks/grokbot-notify.sh
cd - >/dev/null && rm -rf "$d"
```

(Si no corriste `local/install.sh`, usá `hooks/notify.sh` del repo. El `session_id` distinto evita que el dedup lo descarte.) Sin acceso local: pedile al usuario que publique con el bot de notificaciones un mensaje con el formato de arriba, con las líneas `` *evento:* `Stop` ``, `` *agente:* `notify-<slug>` `` y `` *tarea:* `prueba-notify` ``.

Confirmá que la routine de ese bot disparó **una** vez y que no despertó a otro. Si no salta: revisá `${XDG_STATE_HOME:-~/.local/state}/grokbot-claude-code/notify.log`, que `@Cursor` y el bot de notificaciones estén en el canal y que el keyword esté bien escrito. No reintentes en loop.

---

## Flujo A: coordinador (un agente configura a varios bots)

Usalo cuando el usuario te pide configurar a varios de sus bots de una.

1. **Preguntá** al usuario: nombre del canal (`#<canal>`), channel id (`C0123456789`), la lista de bots a activar y un slug por bot (proponé uno si no lo tiene, y que lo confirme). Preguntá también qué `notify-...` ya existen en el canal.
2. **Chequeá colisiones** sobre TODOS los slugs (nuevos + ya usados en el canal) con `local/check-slugs`. Si sale 1, ajustá con el usuario y repetí hasta que salga 0.
3. **Config del hook:** confirmá que la máquina (o el environment de la nube) tiene `SLACK_NOTIFY_CHANNEL` con el channel id que te dieron (ver README del repo). El token no lo toques vos si no te lo pidieron.
4. **Mandale las instrucciones a cada bot:**
   - Si tenés `SendToAgent`, mandale a cada bot el **prompt por agente** de abajo con su canal y su slug ya completos.
   - Si no, dale al usuario un prompt listo para copiar y pegar por bot (el mismo, completo), uno por bot.
   Pedile a cada bot que cree la routine y guarde el slug en memoria, pero que **no** haga su propia prueba: la hacés vos en el paso 5 (así hay una sola por bot).
5. **Verificá:** cuando cada bot confirme su routine, hacé **exactamente una** prueba por bot (ver "Prueba") y anotá si disparó.
6. **Reportá** al usuario una tabla:

   | Bot | Keyword | Disparó |
   | :- | :- | :- |
   | `<bot>` | `notify-<slug>` | sí / no (motivo) |

   Más el canal usado y cualquier problema. Nunca pegues tokens en el reporte.

Prompt por agente (lo que mandás con `SendToAgent` o le das al usuario para pegar):

```text
Configurate para que te despierten los avisos de Claude Code (skill claude-code-notify-setup del repo grokbot-claude-code).
- Canal de avisos: #<canal>
- Tu slug: <slug> (keyword notify-<slug>). Ya está chequeado contra colisión por substring con los demás slugs.
1) Creá en vos una routine con trigger {"type":"slack","channel":"#<canal>","match":{"kind":"keyword","keyword":"notify-<slug>"}} cuya instrucción confirme la línea *agente:* `notify-<slug>`, lea los campos del aviso (una línea por campo, *<campo>:* <valor>, valor entre backticks o <url|abrir>: evento, tarea, sesión, rama) y siga "Al recibir el aviso" de la skill claude-code-task, sin cambiar nada fuera del alcance de la tarea.
2) Guardá en tu memoria el slug, el keyword y el canal; usá NOTIFY_AGENT=<slug> al lanzar tareas.
3) No hagas la prueba vos: avisame cuando la routine esté creada y yo mando una sola prueba.
No pegues tokens en el chat ni en ningún repo. No hagas polling.
```

## Flujo B: por agente (te configurás vos)

1. **Preguntá** al usuario el nombre del canal (`#<canal>`) y su channel id (`C0123456789`), y **confirmá** tu slug (proponé uno si no te lo dieron). Preguntá qué `notify-...` ya se usan en el canal.
2. **Chequeá colisiones** con `local/check-slugs` pasando tu slug y todos los ya usados. Si sale 1, proponé otro y repetí.
3. **Creá tu routine** (ver "Routine") si no existe ya.
4. **Guardá en tu memoria** tu slug (`<slug>`), tu keyword (`notify-<slug>`) y el canal. Al lanzar cada tarea con Claude Code, usá el slug **sin** el prefijo: `NOTIFY_AGENT=<slug>` en `.claude-notify` (local) o como variable del environment (nube). Ver la skill `claude-code-task`.
5. **Probá** con **una** sola prueba (ver "Prueba").
6. **Reportá** al usuario: keyword `notify-<slug>`, canal, si la prueba disparó (sí/no) y cualquier problema. Nunca pegues tokens en el reporte.
