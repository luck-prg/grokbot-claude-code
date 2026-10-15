---
name: claude-code-task
description: >-
  Usar cuando un bot quiere delegar una tarea de código en un repo a Claude Code
  (instalado en la computadora compartida), local o en la nube, y enterarse por
  Slack cuando termina o necesita input, sin hacer polling.
---
# Correr una tarea con Claude Code

Claude Code está instalado en la computadora compartida (`~/.local/bin/claude`) y ya tiene la sesión iniciada con la cuenta de Claude del dueño. Cualquier bot lo puede usar.

Cuando Claude termina, falla o necesita input, un hook publica en el canal privado `#<canal>`:

```
🤖 *Claude Code*
*evento:* `<evento>`
*sesión:* <url|abrir>
*repo:* `owner/name`
*rama:* `<rama>`
*agente:* `notify-<slug>`
*tarea:* `<tarea>`
```

Cómo parsearlo (humano, script o agente):
- La primera línea es el título fijo `🤖 *Claude Code*`. Cada línea siguiente es un campo: `*<campo>:* <valor>` (regex `^\*([^*]+):\* (.*)$`).
- El valor va entre backticks (`` `valor` ``) o, en `sesión` en la nube, como link `<url|abrir>` (la URL es lo que está entre `<` y `|`). En local, `sesión` es el id entre backticks.
- `evento` puede traer un detalle en un segundo span: `` `StopFailure` · `error=rate_limit` ``.
- Campos posibles, en este orden: `evento`, `sesión`, `repo`, `rama`, `agente`, `tarea`. Si un campo no tiene valor, su línea no está.
- `agente` es tu keyword `notify-<slug>` tal cual. Es el único `notify-` real del mensaje: en los demás valores aparece como `notify‐` (guion U+2010) y `&`, `<`, `>` como `&amp;`, `&lt;`, `&gt;`.

Tu routine con trigger Slack por keyword `notify-<slug>` te despierta solo a vos. **No hagas polling** (no `sleep`, no revisar `run.log` en loop, no `ps`): esperá el mensaje.

## Reglas que no cambian
- Claude Code nunca mergea, nunca hace push a ramas protegidas ni a ramas de otra persona, y no toca infraestructura (deploys, variables, bases de datos, migraciones) salvo que el brief lo pida y el dueño lo haya aprobado.
- Una tarea = una carpeta de trabajo propia + una rama nueva. Nunca dos tareas en la misma carpeta (dos bots se pisan).
- Las imágenes de evidencia no se commitean; van en la descripción del PR.
- El que juzga no es el que construye: el PR lo revisa otro bot o una persona.
- `.claude-notify`, `BRIEF.md`, `STATUS.md` y `run.log` no se commitean.

## Una sola vez: tu routine
Si todavía no te configuraste, seguí la skill `claude-code-notify-setup`. Tiene dos flujos: **coordinador** (un agente le pregunta al usuario el canal, su channel id y qué bots activar, y configura a todos) o **por agente** (te configurás vos). En los dos, el canal (`#<canal>`) y su id se le preguntan al usuario, los slugs se chequean con `local/check-slugs` (colisión por substring) y se hace una sola prueba por bot. En resumen, la routine tiene este trigger, con `<slug>` en minúsculas, sin espacios, y sin estar contenido en el keyword de otro agente ni contenerlo (la routine matchea por substring):

```
{type:'slack', channel:'#<canal>', match:{kind:'keyword', keyword:'notify-<slug>'}}
```

Instrucción de la routine: "Llegó un aviso de Claude Code. Confirmá que la línea `*agente:*` diga `` `notify-<slug>` `` (si no, ignorá el mensaje). Cada línea es `*<campo>:* <valor>`, con el valor entre backticks o como `<url|abrir>`: sacá `evento`, `tarea`, `sesión` y `rama`, buscá la tarea por `tarea` y seguí los pasos de 'Al recibir el aviso' del skill claude-code-task."

## Pasos (local)
1. Prepará la carpeta: `git worktree add /workspace/cc/<repo>-<tarea> -b <tipo>/<tarea> origin/<base>` desde un clon del repo (o un clon nuevo en esa ruta).
2. Escribí el brief en `/workspace/cc/<repo>-<tarea>/BRIEF.md`: objetivo, alcance y lo que NO se toca, cómo probar, criterio de listo.
3. Decí a quién avisar, en la raíz de la carpeta, y excluilo de git:
   ```
   cd /workspace/cc/<repo>-<tarea>
   printf 'NOTIFY_AGENT=<slug>\nNOTIFY_TASK=<repo>-<tarea>\n' > .claude-notify
   echo .claude-notify >> "$(git rev-parse --git-common-dir)/info/exclude"
   ```
4. Corré en segundo plano con `notify-run` (mismos argumentos que `claude`; avisa también si el proceso muere sin que salte ningún hook, p.ej. SIGKILL u OOM):
   `cd /workspace/cc/<repo>-<tarea> && nohup notify-run -p "Leé BRIEF.md y hacelo. Al terminar escribí STATUS.md con: qué cambió, cómo probarlo, tests corridos con su resultado, y qué quedó pendiente o en duda. No mergees ni hagas push." < /dev/null > run.log 2>&1 &`
   Agregá `--permission-mode acceptEdits` si necesita editar sin pedir confirmación.
5. Terminá tu turno. No esperes ni revises: el aviso te despierta.

## Variante en la nube
`claude --cloud "<tarea>"` desde la carpeta del repo crea una sesión que corre en la nube de Anthropic sobre la rama actual del remoto de GitHub (hacé push antes). Requiere GitHub conectado a la cuenta de Claude (`/web-setup` dentro de `claude`) y un environment configurado con el setup script de grokbot-claude-code (ver README del repo).

- `.claude-notify` no viaja a la nube (no está commiteado). Usá un environment con `NOTIFY_AGENT=<slug>` en sus variables, o empezá la tarea con: "Primero creá `.claude-notify` en la raíz con `NOTIFY_AGENT=<slug>` y `NOTIFY_TASK=<tarea>` (no lo commitees)."
- `*sesión:*` trae el link `<url|abrir>` (o el id si la variable de la nube no está). Para traerla de vuelta: `claude --teleport <id>`.
- Las mismas reglas aplican.

## Al recibir el aviso
Leé los campos `*evento:*`, `*tarea:*`, `*sesión:*` y `*rama:*`; el mensaje no trae resumen de lo que hizo Claude. Según `*evento:*` (y su detalle):
- `Stop`: Claude terminó el turno. Leé `STATUS.md` y verificá vos (tests, diff). No confiés solo en la nota. Si está bien, hacé push de la rama y abrí el PR siguiendo las reglas del repo. Borrá la carpeta con `git worktree remove` al cerrar.
- `PermissionRequest` (`tool=<tool>`) / `Notification` (`type=permission_prompt|elicitation_*`): Claude necesita permiso o input. En `-p` el permiso se deniega solo; revisá `run.log` y, si hace falta, relanzá con el permiso adecuado. En la nube, respondé en la sesión.
- `Notification` · `type=idle_prompt`: sesión interactiva esperando input.
- `StopFailure`: error de API (`error=rate_limit`, `authentication_failed`, `billing_error`, ...). Ver "Si falla".
- `SessionEnd` (sin Stop previo) o `ProcessExit` · `exit=<código>`: el proceso terminó sin cerrar el turno (p.ej. `--max-turns`, señal, SIGKILL=137, OOM). Revisá `run.log` y el estado de la carpeta antes de decidir.

## Si falla
- Error de sesión o de cuenta: avisá al dueño; no intentes iniciar sesión vos.
- Límite de uso: avisá y no reintentes en loop.
- No llega ningún aviso: revisá `${XDG_STATE_HOME:-~/.local/state}/grokbot-claude-code/notify.log` y `.claude-notify`; avisá al dueño en vez de hacer polling.
