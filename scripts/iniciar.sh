#!/bin/sh
# Levanta el laboratorio completo con un solo comando y, al terminar, muestra por
# pantalla los usuarios y contraseñas de cada servicio.
#
#   sh scripts/iniciar.sh
#
# Hace, en orden: genera las claves si faltan (init.sh no pisa las que existan),
# construye y arranca los siete contenedores, espera a que Zabbix y Grafana
# respondan de verdad, crea el usuario de solo lectura de PostgreSQL que usa
# mon-agent, y llama a credenciales.sh. Se puede correr las veces que
# haga falta: si todo ya está arriba, no recrea nada y solo muestra los accesos.
#
# Se invoca con "sh" a propósito, igual que los scripts que llama: así no depende
# del bit de ejecución, que Git en Windows no conserva.
set -eu
cd "$(dirname "$0")/.."

command -v docker >/dev/null 2>&1 || {
  echo "Falta Docker. Ver el paso 4 de PUESTA-EN-MARCHA.md" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || {
  echo "Falta el plugin de Compose (docker compose)." >&2; exit 1; }

sh scripts/init.sh
docker compose up -d --build

# El frontend de Zabbix contesta HTTP antes de estar listo: en el primer arranque
# PostgreSQL todavía está importando el esquema. La API sí espera a la base, así
# que se le pregunta a ella. Con Grafana alcanza con /api/health.
api_zabbix() {
  curl -s -m 5 -H 'Content-Type: application/json-rpc' \
    -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' \
    http://192.168.56.21:8080/api_jsonrpc.php 2>/dev/null | grep -q '"result"'
}
salud_grafana() {
  curl -sf -m 5 -o /dev/null http://192.168.56.23:3000/api/health 2>/dev/null
}

printf 'Esperando a que Zabbix y Grafana respondan'
listo=no
i=0
while [ $i -lt 60 ]; do
  if api_zabbix && salud_grafana; then listo=si; break; fi
  printf '.'
  sleep 5
  i=$((i + 1))
done
echo

# Usuario de solo lectura para el template "PostgreSQL by Zabbix agent 2" (mon-agent).
# Se crea acá y no en un script de initdb porque esos solo corren con la base vacía, y
# esta instalación puede venir de una base que ya existía. Idempotente.
usuario_pg_monitor() {
  set -a; . ./.env; set +a
  if docker exec zabbix-db psql -U zabbix -d zabbix -tAc        "SELECT 1 FROM pg_roles WHERE rolname = 'zbx_monitor'" 2>/dev/null | grep -q 1; then
    return 0
  fi
  docker exec zabbix-db psql -U zabbix -d zabbix -q -c     "CREATE USER zbx_monitor WITH PASSWORD '$PG_MONITOR_PASSWORD'; GRANT pg_monitor TO zbx_monitor;"     && echo "Creado el usuario zbx_monitor en PostgreSQL"
}
usuario_pg_monitor || echo "AVISO: no se pudo crear zbx_monitor en PostgreSQL; reintentá con sh scripts/iniciar.sh"

if [ "$listo" = no ]; then
  echo "AVISO: pasaron 5 minutos y algún servicio no respondió."
  echo "Mirá qué pasa con: docker compose ps  y  docker compose logs --tail=50 <servicio>"
fi

sh scripts/credenciales.sh

echo "Para comprobar el laboratorio entero: sh scripts/verificar.sh"
echo "Si recién arrancó, esperá un par de minutos antes: Loki y zabbix-server tardan."
if ! mountpoint -q /srv/msr/web01-datos 2>/dev/null; then
  echo
  echo "AVISO: web01 todavía no tiene disco propio; /datos está en el disco de la VM."
  echo "       Crealo una vez con: sudo sh scripts/disco-web01.sh"
fi
