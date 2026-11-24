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

# Los volúmenes de Docker sobreviven a borrar la carpeta del proyecto. La base de Zabbix
# y Grafana guardan la contraseña con la que se crearon la primera vez: si acá se genera
# un .env nuevo sobre esos volúmenes, zabbix-server y zabbix-web no entran a la base
# ("password authentication failed") y Grafana rechaza la contraseña de admin.
# Si no se puede consultar a Docker (por ejemplo, falta sudo), se sigue sin comprobar.
if [ ! -f .env ]; then
  viejos=""
  for v in zabbix_db grafana_data; do
    if docker volume inspect "obligatorio-msr_$v" >/dev/null 2>&1; then
      viejos="$viejos obligatorio-msr_$v"
    fi
  done
  if [ -n "$viejos" ]; then
    cat >&2 <<AVISO
ERROR: no hay .env, pero quedan datos de una instalación anterior:$viejos
Un .env nuevo traería contraseñas que esa base y Grafana no conocen. Elegí una:
  - Conservar los datos: copiá acá el .env y la carpeta secrets/ de la instalación
    anterior y volvé a correr este script.
  - Empezar de cero (borra la configuración de Zabbix y Grafana):
      docker compose down -v
    y volvé a correr este script.
AVISO
    exit 1
  fi
fi

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

# Si se levantaron los contenedores antes que este script, Docker crea una carpeta
# vacía en el lugar de cada archivo montado que falta (secrets/web01.psk/ en vez del
# archivo) y escribir la PSK falla con "Is a directory". Se borra si está vacía; si
# tiene algo, se frena para no perder nada.
crear_psk() { # archivo nombre
  if [ -d "$1" ]; then
    rmdir "$1" 2>/dev/null || {
      echo "ERROR: $1 es una carpeta y no se pudo borrar (¿no está vacía o es de root?)." >&2
      echo "       Revisala y borrala a mano: sudo rm -rf $1" >&2
      exit 1; }
    echo "Borrada la carpeta $1 que había creado Docker"
  fi
  if [ ! -f "$1" ]; then
    openssl rand -hex 32 > "$1"
    echo "Creada PSK de $2"
  fi
}

crear_psk secrets/web01.psk web01
crear_psk secrets/mon-agent.psk mon-agent

# Los agentes corren con el usuario zabbix dentro de su contenedor y necesitan leer
# la PSK. Aceptable en un laboratorio; .env queda restringido.
chmod 755 secrets
chmod 644 secrets/web01.psk secrets/mon-agent.psk
chmod 600 .env

echo "Listo. Siguiente paso: docker compose up -d --build"
