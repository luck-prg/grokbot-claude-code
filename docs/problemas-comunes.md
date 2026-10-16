# Problemas comunes

[← README](../README.md) · [Instalación](instalacion.md) · [Detalles técnicos](detalles-tecnicos.md)

El primer lugar para mirar es `${XDG_STATE_HOME:-~/.local/state}/grokbot-claude-code/notify.log` (en la nube, dentro de la VM de la sesión).

- **El aviso llega con `` • *agente:* `desconocido` `` y no despierta a nadie.**
  *Causa:* el primer mensaje del prompt no tenía una línea sola `notify: <agent-slug>` (p.ej. venía pegada a otro texto, con mayúsculas o espacios en el slug, como `\n` escrito en vez de un salto de línea real, o recién en un mensaje posterior), y no hay `NOTIFY_AGENT` en el entorno.
  *Solución:* relanzá la tarea con la línea `notify: <agent-slug>` sola en el primer mensaje (minúsculas, números y guiones).
- **`notify.log` dice `sin SLACK_NOTIFY_TOKEN` o `sin SLACK_NOTIFY_CHANNEL`.**
  *Causa:* `~/.config/grokbot-claude-code/env` sigue con el placeholder `xoxb-REPLACE_ME` (el hook lo trata como vacío) o falta el channel id. En la nube es normal que no haya token en la VM (lo inyecta el proxy), pero el hook solo envía sin token propio si `CLAUDE_CODE_REMOTE=true`.
  *Solución:* en local, completá `SLACK_NOTIFY_TOKEN` y `SLACK_NOTIFY_CHANNEL` en ese archivo (modo 600). En la nube, definí `SLACK_NOTIFY_CHANNEL` en las variables del environment y el network secret Bearer para `slack.com` ([paso 2](instalacion.md#2-nube-claudeaicode-environments-por-defecto)).
- **`notify.log` dice `fallo al enviar (...)` con `not_in_channel`, `channel_not_found` o `invalid_auth`.**
  *Causa:* el bot de notificaciones no es miembro del canal privado, `SLACK_NOTIFY_CHANNEL` tiene el nombre (`#<canal>`) en vez del id (`C0123456789`), o el token es inválido.
  *Solución:* `/invite @<tu-app>` en `#<canal>`, usá el channel id y revisá el token. Como la marca de dedup se escribe solo si el envío salió bien, el próximo evento vuelve a intentar.
- **El aviso aparece en el canal pero la routine del agente no dispara.**
  *Causa:* `@Cursor` (la app que dispara las routines de Grok Bot) no está invitada al canal privado y no ve los mensajes, o el keyword de la routine no coincide con la línea `*agente:*` `` `notify-<slug>` `` (el slug de la línea `notify:` tiene que ser `[a-z0-9-]+`; en los fallbacks, el hook convierte a `-` todo carácter fuera de `A-Za-z0-9_.-` del `NOTIFY_AGENT`).
  *Solución:* `/invite @Cursor` en `#<canal>` y compará el keyword de la routine con el que muestra el aviso. Para probar, seguí la skill [`claude-code-notify-setup`](../skill/claude-code-notify-setup/SKILL.md): una sola prueba, sin reintentar en loop.
- **Se despierta otro agente además del correcto.**
  *Causa:* colisión por substring: la routine matchea el keyword como substring, así que `notify-dev` también salta con un aviso para `notify-dev-ml`.
  *Solución:* `bash local/check-slugs <todos-los-slugs-del-canal>` y cambiá el slug que choque (sale 1 y lista las colisiones).

