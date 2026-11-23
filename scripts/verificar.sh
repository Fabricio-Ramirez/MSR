#!/bin/sh
# Comprueba la infraestructura sin modificar la configuración.
cd "$(dirname "$0")/.." || exit 1
set -a
. ./.env
set +a

ok=0
mal=0

chequear() { # descripción comando...
  d=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "OK    $d"; ok=$((ok + 1))
  else
    echo "FALLO $d"; mal=$((mal + 1))
  fi
}

no_debe() { # descripción comando...
  d=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "FALLO $d"; mal=$((mal + 1))
  else
    echo "OK    $d"; ok=$((ok + 1))
  fi
}

# ---- comprobaciones de la página de la tienda ----

catalogo() { # la página servida es el catálogo, no un index por defecto
  curl -sf -m 10 http://192.168.56.10/ | grep -q "Agregar al carrito"
}

panel_oculto() { # el easter egg sigue embebido en la página
  curl -sf -m 10 http://192.168.56.10/ | grep -q 'id="panel"'
}

error500() { # la ruta de la prueba P6 responde 500 y no 404
  [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://192.168.56.10/error500)" = "500" ]
}

api_carga() { # el endpoint de las pruebas de carga responde
  curl -sf -m 10 "http://192.168.56.10/api/carga?a=estado" | grep -q '"ok":true'
}

consulta_loki() { # expresión LogQL -> respuesta de Loki, últimos 5 minutos
  curl -sfG -m 10 http://192.168.56.24:3100/loki/api/v1/query_range \
    --data-urlencode "query=$1" \
    --data-urlencode "start=$(date -d '-5 minutes' +%s)000000000" \
    --data-urlencode 'limit=5'
}

error500_en_loki() { # cadena completa: nginx -> Alloy -> Loki
  # Se marca la petición con una cadena única, así la comprobación sólo pasa si
  # una línea NUEVA recorrió toda la cadena. Con el texto fijo "error500" podía
  # pasar encontrando una línea vieja de una corrida anterior.
  marca=verif$(date +%s)
  curl -s -m 10 -o /dev/null "http://192.168.56.10/error500?$marca"

  # No alcanza con esperar un rato fijo: Alloy agrupa antes de enviar y redescubre
  # los archivos cada 10 s, así que una espera corta deja la comprobación librada
  # al azar. Se consulta en ciclo hasta 40 s y se corta apenas aparece.
  consulta='{job="nginx"} |= "'$marca'"'
  i=0
  while [ $i -lt 20 ]; do
    i=$((i + 1))
    sleep 2
    if consulta_loki "$consulta" | grep -q "$marca"; then
      return 0
    fi
  done
  return 1
}

for s in web01 zabbix-server zabbix-web zabbix-db grafana loki mon-agent; do
  chequear "contenedor $s en ejecución" sh -c "[ \"\$(docker inspect -f '{{.State.Running}}' $s)\" = true ]"
done

# Las siete IP fijas de la tabla de la documentación. Si una no coincide, todo lo que
# viene después (escenario web, interfaz SNMP, fuentes de Grafana) apunta al lugar
# equivocado, así que conviene detectarlo acá y no tres pantallas más adelante.
ip_fija() { # contenedor dirección-esperada
  [ "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1")" = "$2" ]
}
ips_fijas='web01=192.168.56.10 zabbix-server=192.168.56.20 zabbix-web=192.168.56.21
zabbix-db=192.168.56.22 grafana=192.168.56.23 loki=192.168.56.24 mon-agent=192.168.56.25'
for par in $ips_fijas; do
  chequear "IP fija de ${par%%=*} = ${par#*=}" ip_fija "${par%%=*}" "${par#*=}"
done

for p in nginx snmpd zabbix-agent2 alloy fcgiwrap; do
  chequear "web01: proceso $p" docker exec web01 sh -c "supervisorctl status $p | grep -q RUNNING"
done

# La VM hace de "host" de la propuesta: desde ahí se abren los paneles y se genera la carga.
chequear "VM -> tienda HTTP" curl -sf -m 10 http://192.168.56.10/
chequear "VM -> frontend de Zabbix" curl -s -m 10 -o /dev/null http://192.168.56.21:8080/
chequear "VM -> Grafana" curl -s -m 10 -o /dev/null http://192.168.56.23:3000/login
chequear "zabbix-server -> ping a web01" docker exec zabbix-server ping -c 2 -W 2 192.168.56.10
chequear "zabbix-server -> escenario web" docker exec zabbix-server curl -sf -m 10 http://192.168.56.10/
chequear "zabbix-server -> agente TCP 10050" docker exec zabbix-server nc -z -w 3 192.168.56.10 10050
# -m 15: api.telegram.org resuelve solo a IPv6 y los contenedores no tienen ruta IPv6,
# así que sin límite de tiempo curl tarda muchísimo en caer a IPv4.
chequear "zabbix-server -> Internet (Telegram)" docker exec zabbix-server curl -sf -m 15 -o /dev/null https://api.telegram.org/
chequear "web01 -> zabbix-server TCP 10051" docker exec web01 timeout 3 bash -c '</dev/tcp/192.168.56.20/10051'
chequear "web01 -> Loki" docker exec web01 curl -sf -m 10 http://192.168.56.24:3100/ready
chequear "SNMPv3 authPriv responde" docker exec zabbix-server snmpget -v3 -l authPriv -u zbxv3 -a SHA -A "$SNMP_AUTH" -x AES -X "$SNMP_PRIV" -t 3 -r 1 192.168.56.10 1.3.6.1.2.1.1.3.0
no_debe "SNMP v2c public rechazado" docker exec zabbix-server snmpget -v2c -c public -t 2 -r 0 192.168.56.10 1.3.6.1.2.1.1.3.0
chequear "Alloy envía logs a Loki" docker exec web01 sh -c "curl -s -m 10 http://127.0.0.1/ >/dev/null; sleep 5; curl -sfG -m 10 http://192.168.56.24:3100/loki/api/v1/labels | grep -q job"

# ---- web01 medido como contenedor y no como VM ----
# El agente lee las métricas propias de web01 de su cgroup. Si estas fallan, el template
# "Contenedor web01 (cgroup v2)" queda vacío y los triggers de carga no disparan.
item_web01() { # clave -> el agente de web01 la resuelve con un número
  docker exec web01 zabbix_agent2 -t "$1" 2>/dev/null | grep -Eq '\[[sdtu]\|[0-9.]+\]'
}
chequear "web01: límite de CPU aplicado" sh -c "docker exec web01 cat /sys/fs/cgroup/cpu.max | grep -vq '^max '"
chequear "web01: límite de memoria aplicado" sh -c "docker exec web01 cat /sys/fs/cgroup/memory.max | grep -vqx max"
chequear "web01: agente lee CPU del contenedor" item_web01 'contenedor[cpu.uso]'
chequear "web01: agente lee memoria del contenedor" item_web01 'contenedor[mem.pct]'
# /datos tiene que ser un filesystem propio. Si scripts/disco-web01.sh no se corrió,
# Docker crea una carpeta común en el disco de la VM y la prueba P3 vuelve a medir la VM.
chequear "web01: /datos es un disco propio" docker exec web01 mountpoint -q /datos
chequear "web01: /datos/relleno escribible por www-data" docker exec -u www-data web01 test -w /datos/relleno

# ---- monitoreo del monitoreo ----
chequear "mon-agent: lee el socket de Docker" sh -c "docker exec mon-agent zabbix_agent2 -t docker.ping | grep -q '|1]'"
chequear "mon-agent: PostgreSQL responde a zbx_monitor" sh -c "docker exec mon-agent zabbix_agent2 -t 'pgsql.ping[\"tcp://192.168.56.22:5432\",\"zbx_monitor\",\"$PG_MONITOR_PASSWORD\",\"zabbix\"]' | grep -q '|1]'"
chequear "zabbix-server -> agente de mon-agent TCP 10050" docker exec zabbix-server nc -z -w 3 192.168.56.25 10050
# Solo conectividad: no se pinguea la URL real del check para no falsear el heartbeat.
chequear "zabbix-server -> Internet (Healthchecks.io)" docker exec zabbix-server curl -s -m 15 -o /dev/null https://hc-ping.com/

# La página de la tienda y la cadena de logs de punta a punta.
chequear "tienda: sirve el catálogo" catalogo
chequear "tienda: panel técnico presente" panel_oculto
chequear "tienda: /error500 devuelve 500" error500
chequear "tienda: /api/carga responde" api_carga
chequear "un error 500 queda registrado en Loki" error500_en_loki

echo
echo "Correctas: $ok   Fallidas: $mal"
[ "$mal" -eq 0 ]
