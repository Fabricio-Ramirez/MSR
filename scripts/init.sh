#!/bin/sh
# Genera las contraseñas y la PSK del agente. No sobrescribe lo que ya existe.
#
# El laboratorio no usa TLS ni certificados: el cifrado que pide la letra
# ("siempre que sea posible, utilice protocolos que cifren la información, ej. SNMPv3")
# lo aportan SNMPv3 authPriv (SHA/AES) y la TLS-PSK del agente Zabbix.
set -eu
cd "$(dirname "$0")/.."
umask 077

mkdir -p secrets

if [ ! -f .env ]; then
  {
    echo "ZABBIX_DB_PASSWORD=$(openssl rand -hex 16)"
    echo "GRAFANA_PASSWORD=$(openssl rand -hex 12)"
    echo "SNMP_AUTH=$(openssl rand -hex 12)"
    echo "SNMP_PRIV=$(openssl rand -hex 12)"
  } > .env
  echo "Creado .env"
fi

# Variables que se sumaron después. Se agregan solo si faltan, así sirve tanto en una
# instalación nueva como en una que ya tenía .env (y no pisa lo que hayas cambiado).
agregar() { # NOMBRE valor
  grep -q "^$1=" .env || { echo "$1=$2" >> .env; echo "Agregado $1 a .env"; }
}

# Límites de web01. Con límites, la CPU y la RAM del servidor web se miden contra su
# propio límite (template "Contenedor web01") y una prueba de carga no puede dejar sin
# recursos a Zabbix. Se le deja un núcleo y la mitad de la RAM al resto del laboratorio.
# CPU con núcleos fijos (cpuset), no con cuota: ver el comentario en compose.yaml.
# web01 recibe del núcleo 1 en adelante; el 0 queda para el resto.
nucleos=$(nproc)
case "$nucleos" in
  1) cpuset=0 ;;
  2) cpuset=1 ;;
  *) cpuset="1-$((nucleos - 1))" ;;
esac
memoria=$(awk '$1 == "MemTotal:" { printf "%dm", $2 / 1024 / 2 }' /proc/meminfo)
agregar WEB01_CPUSET "$cpuset"
agregar WEB01_MEM "$memoria"

# GID del grupo dueño del socket de Docker: mon-agent lo recibe con group_add para
# poder leerlo sin correr como root.
if [ -S /var/run/docker.sock ]; then
  agregar DOCKER_GID "$(stat -c %g /var/run/docker.sock)"
fi

# Usuario de solo lectura con el que mon-agent monitorea PostgreSQL.
agregar PG_MONITOR_PASSWORD "$(openssl rand -hex 12)"

if [ ! -f secrets/web01.psk ]; then
  openssl rand -hex 32 > secrets/web01.psk
  echo "Creada PSK de web01"
fi

if [ ! -f secrets/mon-agent.psk ]; then
  openssl rand -hex 32 > secrets/mon-agent.psk
  echo "Creada PSK de mon-agent"
fi

# Los agentes corren con el usuario zabbix dentro de su contenedor y necesitan leer
# la PSK. Aceptable en un laboratorio; .env queda restringido.
chmod 755 secrets
chmod 644 secrets/web01.psk secrets/mon-agent.psk
chmod 600 .env

echo "Listo. Siguiente paso: docker compose up -d --build"
