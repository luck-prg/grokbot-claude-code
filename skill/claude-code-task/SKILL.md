---
name: claude-code-task
description: >-
  Usar cuando un bot quiere delegar una tarea de código en un repo a Claude Code y
  enterarse por Slack cuando termina o necesita input, sin hacer polling. Por defecto
  corre en la nube (`claude --cloud`); local en la computadora compartida (worktree +
  notify-run) solo como fallback.
---
# Correr una tarea con Claude Code

Claude Code está instalado en la computadora compartida (`~/.local/bin/claude`) y ya tiene la sesión iniciada con la cuenta de Claude del dueño. Cualquier bot lo puede usar. **Por defecto la tarea corre en la nube** (`claude --cloud`); la ejecución local queda como fallback.

Cuando Claude termina, falla o necesita input, un hook publica en el canal privado `#<canal>`:

```
*Claude Code*
• *evento:* `<evento>`
• *sesión:* <url|session_xxx>
• *repo:* `owner/name`
• *rama:* `<rama>`
• *agente:* `notify-<slug>`
• *tarea:* `<tarea>`
```

Cómo parsearlo (humano, script o agente):
- La primera línea es el título fijo `*Claude Code*` (sin viñeta). Cada línea siguiente es un campo y empieza con `• ` (U+2022 + espacio): `• *<campo>:* <valor>` (regex `^• \*([^*]+):\* (.*)$`).
- El valor va entre backticks (`` `valor` ``) o, en `sesión` en la nube, como link `<url|session_xxx>` (la URL es lo que está entre `<` y `|`; el texto del link, entre `|` y `>`, es el id de sesión). En local, `sesión` es el id entre backticks.
- `evento` puede traer un detalle en un segundo span: `` `StopFailure` · `error=rate_limit` ``.
- Campos posibles, en este orden: `evento`, `sesión`, `repo`, `rama`, `agente`, `tarea`. Si un campo no tiene valor, su línea no está.
- `agente` es tu keyword `notify-<slug>` tal cual. Es el único `notify-` real del mensaje: en los demás valores aparece como `notify‐` (guion U+2010) y `&`, `<`, `>` como `&amp;`, `&lt;`, `&gt;`. Si el prompt no traía la línea `notify: <slug>`, sale `` `desconocido` `` sin keyword: el aviso llega al canal pero no despierta a nadie.
- `tarea` es la rama sin el prefijo `feature/`, `hotfix/` o `release/` (`feature/login` → `login`; otra rama queda igual). Sin rama (HEAD detached) no hay `tarea`.

**A quién avisar:** el prompt de la tarea lleva una línea sola `notify: <slug>` (tu slug, sin el prefijo `notify-`). El hook la lee del **primer** mensaje del usuario de la sesión; en mensajes posteriores no cuenta. No hace falta crear archivos ni variables por tarea.

Tu routine con trigger Slack por keyword `notify-<slug>` te despierta solo a vos. **No hagas polling** (no `sleep`, no revisar `run.log` en loop, no `ps`): esperá el mensaje.

## Reglas que no cambian
- Claude Code nunca mergea, nunca hace push a ramas protegidas ni a ramas de otra persona, y no toca infraestructura (deploys, variables, bases de datos, migraciones) salvo que el brief lo pida y el dueño lo haya aprobado.
- Una tarea = una carpeta de trabajo propia + una rama nueva. Nunca dos tareas en la misma carpeta (dos bots se pisan).
- Las imágenes de evidencia no se commitean; van en la descripción del PR.
- El que juzga no es el que construye: el PR lo revisa otro bot o una persona.
- `BRIEF.md`, `STATUS.md` y `run.log` no se commitean.
- La rama es `feature/<tarea>` (o `hotfix/<tarea>` / `release/<tarea>`): así el campo `tarea` del aviso es `<tarea>`.

## Una sola vez: tu routine
Si todavía no te configuraste, seguí la skill `claude-code-notify-setup`. Tiene dos flujos: **coordinador** (un agente le pregunta al usuario el canal, su channel id y qué bots activar, y configura a todos) o **por agente** (te configurás vos). En los dos, el canal (`#<canal>`) y su id se le preguntan al usuario, los slugs se chequean con `local/check-slugs` (colisión por substring) y se hace una sola prueba por bot. En resumen, la routine tiene este trigger, con `<slug>` en minúsculas, sin espacios, y sin estar contenido en el keyword de otro agente ni contenerlo (la routine matchea por substring):

```
{type:'slack', channel:'#<canal>', match:{kind:'keyword', keyword:'notify-<slug>'}}
```

Instrucción de la routine: "Llegó un aviso de Claude Code. Confirmá que la línea `*agente:*` diga `` `notify-<slug>` `` (si no, ignorá el mensaje). Cada línea es `• *<campo>:* <valor>`, con el valor entre backticks o como `<url|session_xxx>`: sacá `evento`, `tarea`, `sesión` y `rama`, buscá la tarea por `tarea` y seguí los pasos de 'Al recibir el aviso' del skill claude-code-task."

## Pasos (nube, por defecto)
`claude --cloud "<tarea>"` desde la carpeta del repo crea una sesión que corre en la nube de Anthropic sobre la rama actual del remoto de GitHub. Requiere GitHub conectado a la cuenta de Claude (`/web-setup` dentro de `claude`) y un environment estilo GrokBot configurado con el setup script [`cloud/setup.sh`](../../cloud/setup.sh) (ver README del repo).

1. Prepará la rama en una carpeta propia y **hacé push antes de lanzar** (la nube solo ve lo que está en el remoto):
   ```
   git worktree add /workspace/cc/<repo>-<tarea> -b feature/<tarea> origin/<base>
   cd /workspace/cc/<repo>-<tarea> && git push -u origin feature/<tarea>
   ```
2. Lanzá la sesión desde la carpeta del repo, con la línea `notify: <slug>` en el prompt. `claude --cloud` necesita una TTY; desde un bot (sin terminal) corrélo con `script`:
   ```
   cd /workspace/cc/<repo>-<tarea>
   script -qec 'claude --cloud "notify: <slug>
   <objetivo, alcance y lo que NO se toca, cómo probar, criterio de listo>. Commiteá en la rama y hacé push de la rama. No mergees."' /dev/null </dev/null
   ```
   La línea `notify: <slug>` tiene que ir sola en su línea (salto de línea real, no `\n` escrito).
3. Avisá al usuario que arrancó, con **un solo mensaje corto**, como con los agentes de Cursor. Tiene que tener el link de la sesión (`https://claude.ai/code/<session id>`, lo imprime `claude --cloud`) con el nombre de la tarea como texto, el modelo, la rama, que no va a mergear y que te avisan por Slack cuando termine. Plantilla:
   > Ya arrancó la [sesión de Claude Code de <tarea>](https://claude.ai/code/<session id>), con <modelo>. Trabaja en la rama `feature/<tarea>` y no va a mergear nada. Cuando termine me llega el aviso por Slack, lo reviso y te cuento.
4. Terminá tu turno. No esperes ni revises (no polling): el aviso de Slack te despierta.

En la nube, `*sesión:*` trae el link `<url|session_xxx>`: el texto del link es el id de sesión (si la variable de la nube no está, sale solo el id entre backticks). Las mismas reglas aplican.

## Alternativa local (fallback)
Usala solo si la nube no está disponible (sin environment, sin GitHub conectado, caída), si la tarea necesita recursos locales de la computadora compartida (archivos, servicios, credenciales) o si el usuario la pide.

1. Prepará la carpeta: `git worktree add /workspace/cc/<repo>-<tarea> -b feature/<tarea> origin/<base>` desde un clon del repo (o un clon nuevo en esa ruta).
2. Escribí el brief en `/workspace/cc/<repo>-<tarea>/BRIEF.md`: objetivo, alcance y lo que NO se toca, cómo probar, criterio de listo.
3. Corré en segundo plano con `notify-run` (mismos argumentos que `claude`; avisa también si el proceso muere sin que salte ningún hook, p.ej. SIGKILL u OOM). El prompt empieza con la línea `notify: <slug>`:
   ```
   cd /workspace/cc/<repo>-<tarea> && nohup notify-run -p "notify: <slug>
   Leé BRIEF.md y hacelo. Al terminar escribí STATUS.md con: qué cambió, cómo probarlo, tests corridos con su resultado, y qué quedó pendiente o en duda. No mergees ni hagas push." < /dev/null > run.log 2>&1 &
   ```
   Agregá `--permission-mode acceptEdits` si necesita editar sin pedir confirmación.
4. Avisá al usuario que arrancó, con un solo mensaje corto (no hay link de sesión: nombrá la carpeta). Plantilla:
   > Ya arrancó Claude Code en local para <tarea> (carpeta `/workspace/cc/<repo>-<tarea>`), con <modelo>. Trabaja en la rama `feature/<tarea>`, no hace push y no va a mergear nada. Cuando termine me llega el aviso por Slack, lo reviso y te cuento.
5. Terminá tu turno. No esperes ni revises: el aviso te despierta.

**Regla: nunca esperes con bucles de `pgrep` ni `pgrep -f`.** `pgrep -f` matchea contra la línea de comando completa, incluida la del propio `bash` que corre el bucle (que contiene el patrón buscado): se encuentra a sí mismo y el bucle nunca termina.
Si de verdad tenés que esperar a que termine, hacelo de una de estas formas:
- con `notify-run`: ya vigila el proceso y avisa cuando termina (incluso si muere sin hooks);
- con el aviso de Slack (lo normal: terminá tu turno);
- esperando el PID exacto que devolvió el lanzamiento: guardalo con `pid=$!` justo después del `&` y esperá con `wait "$pid"` (misma shell) o `tail --pid="$pid" -f /dev/null` (otra shell). Nunca lo busques por nombre o patrón.

## Al recibir el aviso
Leé los campos `*evento:*`, `*tarea:*`, `*sesión:*` y `*rama:*`; el mensaje no trae resumen de lo que hizo Claude. Según `*evento:*` (y su detalle):
- `Stop`: Claude terminó el turno. Revisá vos la rama (diff, tests); no confiés solo en lo que dice Claude.
  - Nube (por defecto): hacé `git fetch` y revisá la rama pusheada (`git diff origin/<base>...origin/<rama>`, corré los tests), o traé la sesión con `claude --teleport <id>` (el id es el texto del link de `*sesión:*`). Si está bien, abrí el PR siguiendo las reglas del repo, **sin mergear**. Borrá el worktree con `git worktree remove` al cerrar.
  - Local (fallback): leé `STATUS.md` y verificá (tests, diff). Si está bien, hacé push de la rama y abrí el PR sin mergear. Borrá la carpeta con `git worktree remove` al cerrar.
- `PermissionRequest` (`tool=<tool>`) / `Notification` (`type=permission_prompt|elicitation_*`): Claude necesita permiso o input. En la nube, respondé en la sesión (link de `*sesión:*` o `claude --teleport <id>`). En local con `-p` el permiso se deniega solo; revisá `run.log` y, si hace falta, relanzá con el permiso adecuado.
- `Notification` · `type=idle_prompt`: sesión interactiva esperando input.
- `StopFailure`: error de API (`error=rate_limit`, `authentication_failed`, `billing_error`, ...). Ver "Si falla".
- `SessionEnd` (sin Stop previo) o `ProcessExit` · `exit=<código>`: el proceso terminó sin cerrar el turno (p.ej. `--max-turns`, señal, SIGKILL=137, OOM). En la nube, abrí la sesión y revisá la rama; en local, revisá `run.log` y el estado de la carpeta antes de decidir.

## Continuar o leer una sesión (nube)
Probado con Claude Code 2.1.300. `<id>` es el id de la sesión (`cse_...` o `session_...`, el texto del link de `*sesión:*`); también acepta la URL `claude.ai/code/...`. Siempre con `timeout` y `</dev/null` para no colgarse.

- **Mandar un mensaje** (follow-up) a una sesión existente: encola el mensaje y sale al instante, **sin esperar la respuesta**. Desde cualquier carpeta, con la cuenta logueada:
  ```
  timeout 90 claude -p $'notify: <slug>\n<mensaje>' --cloud <id> --output-format json </dev/null
  ```
  Salida: `{"ok":true,"session_id":"<id>","url":"https://claude.ai/code/<id>?..."}` (con `ok:false` y `error` si la sesión no existe o está archivada). Poné `notify: <slug>` como primera línea: cuando Claude termina ese turno salta tu routine y llega un aviso `Stop` a Slack, como en el lanzamiento. Sin `-p`, `--cloud <id>` falla ("Attaching to an existing cloud session is not enabled").
- **Leer la conversación** (qué dijo Claude último): desde un clon **limpio** del mismo repo (sin cambios sin commitear), con `--teleport` y `-p`. Trae el historial y la rama de la sesión y responde la pregunta en local:
  ```
  cd /workspace/cc/<repo> && timeout 180 claude -p --teleport <id> "Sin usar herramientas ni cambiar archivos: citá textualmente el último mensaje del usuario y tu última respuesta." </dev/null
  ```
  La respuesta corre en una **copia local** de la sesión: no llega a la sesión de la nube ni dispara avisos. Hace checkout de la rama de la sesión en ese clon.
- Esperá el aviso `Stop` de Slack antes de leer: justo después de que Claude responde, el historial que trae `--teleport` puede no tener todavía el último turno (pasó una vez; al repetir minutos después sí estaba).

Dudas (sin probar):
- `--resume` no sirve para sesiones de la nube (según la documentación solo lee el historial local de esta computadora).
- No hay comando de CLI documentado para listar sesiones de la nube de forma no interactiva: `claude --teleport` sin id abre un selector interactivo (no usarlo desde un bot). El id sale del aviso de Slack o de claude.ai/code.
- No probado: `claude -p --teleport` con `--output-format json`, ni sobre sesiones archivadas o con el environment vencido.

## Control de respaldo
La routine que dispara el aviso puede terminar en `failed` sin que te llegue nada. Por eso, al retomar la tarea (en tu próximo turno, si el usuario pregunta por ella o en un chequeo posterior):
1. Leé `#<canal>` con el conector de Slack y buscá tu keyword `notify-<slug>` junto con la sesión o la rama de tu tarea.
2. Si el aviso está ahí, procesalo a mano siguiendo "Al recibir el aviso".
3. Si no hay aviso, leé el estado de la sesión con `claude -p --teleport <id>` (ver "Continuar o leer una sesión").

No respondas en el canal de Slack; solo lo leés. Nunca esperes con loops de `pgrep` ni `sleep`.

## Si falla
- Error de sesión o de cuenta: avisá al dueño; no intentes iniciar sesión vos.
- Límite de uso: avisá y no reintentes en loop.
- No llega ningún aviso: en la nube, revisá que el environment tenga `SLACK_NOTIFY_CHANNEL` y el network secret; en local, `${XDG_STATE_HOME:-~/.local/state}/grokbot-claude-code/notify.log`. Si en el canal aparece el aviso con `*agente:*` `` `desconocido` ``, el primer mensaje del prompt no tenía la línea `notify: <slug>` sola en su línea. Avisá al dueño en vez de hacer polling.
- La nube no está disponible: pasá a la alternativa local.
- La primera vez en una carpeta nueva el lanzamiento se queda colgado: en una sesión interactiva (como `claude --cloud` corrido con `script`), Claude Code muestra el diálogo "trust this folder" y espera una respuesta que nadie da. Las sesiones `-p` no lo muestran. La confianza se guarda por carpeta en `~/.claude.json`, en `projects["<ruta>"].hasTrustDialogAccepted`. Para evitarlo, antes de lanzar aceptá el diálogo una vez a mano en esa carpeta o marcá el worktree como confiable (con ningún otro `claude` abierto, porque las sesiones reescriben el archivo entero y pisan el cambio):
  ```
  f=~/.claude.json; d=/workspace/cc/<repo>-<tarea>
  jq --arg d "$d" '.projects[$d].hasTrustDialogAccepted = true' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  ```
  No lo hagas en tu carpeta home (ahí la confianza no se guarda). Si ya quedó colgado, matá ese proceso `script` y relanzá.
