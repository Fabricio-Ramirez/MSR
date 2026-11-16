#!/bin/sh
set -eu

# La imagen base no trae tini ni su-exec: los instala el Dockerfile. Si tini llegara a
# faltar, arrancamos sin él en lugar de pasarle un argumento vacío a su-exec, que es lo
# que provocaba "su-exec: : No such file or directory" y el bucle de reinicios.
TINI="$(command -v tini || true)"

if [ -n "$TINI" ]; then
  exec su-exec zabbix "$TINI" -- /usr/bin/docker-entrypoint.sh "$@"
fi

exec su-exec zabbix /usr/bin/docker-entrypoint.sh "$@"
