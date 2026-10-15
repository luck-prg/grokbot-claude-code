---
name: claude-code-notify-setup
description: >-
  Usar una sola vez, cuando un agente quiere configurarse para que lo despierten
  los avisos de Claude Code en Slack: elegir su slug notify-<slug>, crear su
  routine con trigger por keyword, guardarlo en memoria y probar que dispara.
---
# Configurarte para recibir avisos de Claude Code

Los hooks de Claude Code (local o nube) publican en el canal de avisos un mensaje así:

```
[claude] notify-<slug> event=<evento> task=<tarea> session=<id|url> branch=<rama> summary=<resumen>
```

Cada agente tiene una routine que despierta solo con **su** keyword `notify-<slug>`. Esta skill la corrés una vez por agente. Para lanzar tareas después, usá la skill `claude-code-task`.

Antes de empezar necesitás saber el canal de avisos (`#<canal-de-avisos>`, el que te pasó el dueño). Si no lo sabés, preguntá; no lo adivines.

## 1. Elegí tu slug
Tu keyword va a ser `notify-<slug>`. Reglas:
- Minúsculas, números y guiones (`[a-z0-9-]`), sin espacios. El hook no pasa a minúsculas por vos.
- Único: ningún otro agente lo usa.
- **Sin colisión por substring.** La routine matchea el keyword como substring del mensaje, así que tu keyword **no puede estar contenido** en el de otro agente **ni contener** el de otro. Ejemplo: `notify-dev` y `notify-dev-ml` chocan (un aviso para `notify-dev-ml` despierta también a `notify-dev`). Preferí algo distintivo, p.ej. tu nombre completo en vez de un rol genérico.

Para chequearlo: buscá en el historial de `#<canal-de-avisos>` los `notify-...` que ya aparecen, y preguntale a tus compañeros (o al dueño) qué keyword usan. Si hay duda, elegí otro.

## 2. Creá tu routine
Creá en vos mismo (si no existe ya) una routine con este trigger:

```json
{"type":"slack","channel":"#<canal-de-avisos>","match":{"kind":"keyword","keyword":"notify-<slug>"}}
```

Instrucción de la routine:

> Llegó un aviso de Claude Code. Leé el mensaje y sacá `event=`, `task=`, `session=`, `branch=` y `summary=`. Buscá la tarea por `task=` y seguí "Al recibir el aviso" de la skill claude-code-task: continuá la tarea o reportá el resultado a quien la pidió. No cambies nada fuera del alcance de esa tarea.

Requisito: `@Cursor` tiene que estar invitado a `#<canal-de-avisos>` (es la app que dispara las routines; si no ve el canal, la routine nunca salta). Si no está, pedíselo al dueño.

## 3. Guardá tu slug
- Guardá en tu memoria: tu slug (`<slug>`), tu keyword (`notify-<slug>`) y el canal.
- Al lanzar cada tarea con Claude Code, poné el slug **sin** el prefijo `notify-`: `NOTIFY_AGENT=<slug>` en `.claude-notify` (local) o como variable de entorno / variable del environment (nube). Ver la skill `claude-code-task`.

## 4. Probá que dispara
Hacé **un** envío de prueba con el bot de notificaciones (no un mensaje escrito a mano por vos), así probás el mismo camino que los avisos reales:

- **Local**, con el hook instalado y el token configurado:
  ```bash
  d=$(mktemp -d) && cd "$d"
  printf 'NOTIFY_AGENT=<slug>\nNOTIFY_TASK=prueba-notify\n' > .claude-notify
  echo "{\"session_id\":\"prueba-$(date +%s)\",\"cwd\":\"$d\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"prueba de routine\"}" \
    | bash ~/.claude/hooks/grokbot-notify.sh
  ```
  (Si no corriste `local/install.sh`, usá `hooks/notify.sh` del repo. El `session_id` distinto evita que el dedup lo descarte.)
- **Sin acceso local:** pedile al dueño que publique con el bot de notificaciones un mensaje de prueba con `notify-<slug> event=Stop task=prueba-notify`.

Confirmá que tu routine se disparó **una** vez con ese mensaje y que no despertó a otro agente. Si no salta: revisá `${XDG_STATE_HOME:-~/.local/state}/grokbot-claude-code/notify.log`, que `@Cursor` y el bot estén en el canal, y que el keyword esté bien escrito. No reintentes en loop. Al terminar borrá la carpeta temporal.

## 5. Reportá
Avisá al dueño (o a quien te pidió el setup): tu keyword `notify-<slug>`, el canal, si la prueba disparó (sí/no) y cualquier problema. Nunca pegues tokens en el reporte.
