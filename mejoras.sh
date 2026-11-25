#!/usr/bin/env bash
# =============================================================================
# scripts/mejoras.sh
#
# Mejora 1: monitoreo por contenedor (agente Zabbix 2 en la VM + template Docker)
# Mejora 2: monitoreo del propio monitoreo (salud de Zabbix + watchdog local con aviso a Telegram)
#
# Uso (desde la carpeta del proyecto, en master01):
#   chmod +x scripts/mejoras.sh
#   sudo scripts/mejoras.sh            # hace las dos mejoras (primero la 1, después la 2)
#   sudo scripts/mejoras.sh 1          # solo la mejora 1
#   sudo scripts/mejoras.sh 2          # solo la mejora 2
#
# Variables opcionales (si no se pasan, el script las pregunta):
#   ZBX_PASS   contraseña del usuario Admin de Zabbix
#   TG_TOKEN / TG_CHAT   token y chat ID del bot (si no se pasan, se leen de Zabbix)
#
# Es idempotente: se puede ejecutar varias veces sin duplicar nada.
# Requisitos previos: stack levantado (docker compose up) y zabbix-agent2 instalado.
# =============================================================================
# Si se ejecuta con sh (dash), relanzar con bash.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi

QUE="${1:-todo}"
case "$QUE" in todo|1|2|4) ;; *) echo "Uso: sudo bash scripts/mejoras.sh [todo|1|2]"; exit 1 ;; esac
[ "$QUE" = "2" ] && QUE=4      # internamente la mejora 2 es la rama "4"

# ---------- parámetros (coinciden con el proyecto obligatorio-docker) ----------
ZBX_URL="${ZBX_URL:-http://192.168.56.21:8080/api_jsonrpc.php}"
ZBX_USER="${ZBX_USER:-Admin}"
SERVER_IP="192.168.56.20"           # zabbix-server (origen de las consultas)
AGENT_IP="192.168.56.254"           # la VM vista desde la red Docker (gateway)
HOST_NAME="master01"
PSK_ID="PSK-master01"
PSK_FILE="/etc/zabbix/master01.psk"
CONF="/etc/zabbix/zabbix_agent2.conf"
GRUPO_INFRA="Infraestructura"
ACCION="Notificar problemas tienda"
WD_ENV="/etc/watchdog-zabbix.env"
WD_SCRIPT="/usr/local/bin/watchdog-zabbix.sh"

ok()    { echo "  OK    $*"; }
aviso() { echo "  AVISO $*"; }
paso()  { echo; echo "== $* =="; }
die()   { echo "  ERROR $*" >&2; exit 1; }

# ---------- requisitos ----------
paso "Requisitos"
command -v docker >/dev/null        || die "Docker no está instalado."
command -v zabbix_agent2 >/dev/null || die "Falta zabbix-agent2 (sudo apt install -y zabbix-agent2)."
for c in curl jq openssl; do
  command -v "$c" >/dev/null || { apt-get install -y "$c" >/dev/null 2>&1 || die "No pude instalar $c"; }
done
[ "$(docker inspect -f '{{.State.Running}}' zabbix-server 2>/dev/null)" = true ] \
  || die "El contenedor zabbix-server no está en ejecución (docker compose up -d)."
ok "docker, zabbix_agent2, curl, jq y openssl disponibles; zabbix-server en ejecución"

# ---------- cliente de la API de Zabbix ----------
TOKEN=""
api() { # api <método> [params-json]  -> imprime .result (JSON compacto)
  local params="${2-}" body resp
  [ -n "$params" ] || params='{}'
  body=$(jq -nc --arg m "$1" --argjson p "$params" '{jsonrpc:"2.0",method:$m,params:$p,id:1}') || return 1
  if [ -n "$TOKEN" ]; then
    resp=$(printf '%s' "$body" | curl -sS -m 30 -H 'Content-Type: application/json-rpc' \
           -H "Authorization: Bearer $TOKEN" --data-binary @- "$ZBX_URL") || { echo "API $1: sin respuesta" >&2; return 1; }
  else
    resp=$(printf '%s' "$body" | curl -sS -m 30 -H 'Content-Type: application/json-rpc' \
           --data-binary @- "$ZBX_URL") || { echo "API $1: sin respuesta" >&2; return 1; }
  fi
  if printf '%s' "$resp" | jq -e '.error' >/dev/null 2>&1; then
    echo "API $1: $(printf '%s' "$resp" | jq -r '.error.message + " " + (.error.data // "")')" >&2
    return 1
  fi
  printf '%s' "$resp" | jq -c '.result'
}

grupo_id() { # nombre -> id (lo crea si falta)
  local id
  id=$(api hostgroup.get "$(jq -nc --arg n "$1" '{filter:{name:[$n]},output:["groupid"]}')" | jq -r '.[0].groupid // empty')
  if [ -z "$id" ]; then
    id=$(api hostgroup.create "$(jq -nc --arg n "$1" '{name:$n}')" | jq -r '.groupids[0] // empty')
  fi
  echo "$id"
}

plantilla_id() { # nombre técnico -> id
  api template.get "$(jq -nc --arg n "$1" '{filter:{host:[$n]},output:["templateid"]}')" | jq -r '.[0].templateid // empty'
}

# =============================================================================
# MEJORA 1 (parte local): agente Zabbix 2 en la VM
# =============================================================================
mejora1_agente() {
  paso "Mejora 1 · Agente Zabbix 2 en la VM"

  if [ ! -f "$PSK_FILE" ]; then
    openssl rand -hex 32 > "$PSK_FILE"
    ok "clave PSK creada en $PSK_FILE"
  else
    ok "la clave PSK ya existía"
  fi
  chown zabbix:zabbix "$PSK_FILE" && chmod 640 "$PSK_FILE"

  [ -f "$CONF.orig" ] || cp "$CONF" "$CONF.orig"
  sed -i -E '/^(Server|ServerActive|Hostname|TLSConnect|TLSAccept|TLSPSKIdentity|TLSPSKFile)=/d' "$CONF"
  cat >> "$CONF" <<EOF
Server=$SERVER_IP
Hostname=$HOST_NAME
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=$PSK_ID
TLSPSKFile=$PSK_FILE
EOF
  ok "configuración del agente escrita (copia del original en $CONF.orig)"

  usermod -aG docker zabbix && ok "usuario zabbix agregado al grupo docker"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow from 192.168.56.0/24 to any port 10050 proto tcp >/dev/null && ok "ufw: puerto 10050 permitido desde la red Docker"
  else
    ok "ufw inactivo: no hace falta abrir el puerto 10050"
  fi

  systemctl enable zabbix-agent2 >/dev/null 2>&1
  systemctl restart zabbix-agent2
  sleep 4
  if systemctl is-active --quiet zabbix-agent2; then ok "zabbix-agent2 activo"
  else die "zabbix-agent2 no arrancó. Mirá: tail -n 30 /var/log/zabbix/zabbix_agent2.log"; fi

  ss -tln | grep -q ':10050 ' && ok "el agente escucha en el puerto 10050" || aviso "no veo el puerto 10050 en escucha"

  if sudo -u zabbix zabbix_agent2 -c "$CONF" -t docker.info 2>/dev/null | grep -qi 'containers'; then
    ok "el plugin de Docker responde (docker.info)"
  else
    aviso "docker.info no respondió; revisá que el usuario zabbix tenga acceso a /var/run/docker.sock"
  fi

  if docker exec zabbix-server nc -z -w 3 "$AGENT_IP" 10050 >/dev/null 2>&1; then
    ok "zabbix-server llega al agente en $AGENT_IP:10050"
  else
    aviso "zabbix-server NO llega a $AGENT_IP:10050 (firewall o agente caído)"
  fi
}

# =============================================================================
# MEJORA 1 (parte Zabbix): host master01 con el template Docker
# =============================================================================
mejora1_host() {
  paso "Mejora 1 · Host $HOST_NAME en Zabbix"

  local gid tid existe psk
  gid=$(grupo_id "$GRUPO_INFRA");           [ -n "$gid" ] || die "No pude crear/leer el grupo $GRUPO_INFRA"
  tid=$(plantilla_id "Docker by Zabbix agent 2"); [ -n "$tid" ] || die "No encontré el template 'Docker by Zabbix agent 2'"

  existe=$(api host.get "$(jq -nc --arg h "$HOST_NAME" '{filter:{host:[$h]},output:["hostid"]}')" | jq -r '.[0].hostid // empty')
  if [ -n "$existe" ]; then
    ok "el host $HOST_NAME ya existe (id $existe)"
  else
    psk=$(cat "$PSK_FILE")
    api host.create "$(jq -nc --arg h "$HOST_NAME" --arg g "$gid" --arg t "$tid" --arg ip "$AGENT_IP" \
        --arg pid "$PSK_ID" --arg psk "$psk" \
        '{host:$h, groups:[{groupid:$g}], templates:[{templateid:$t}],
          interfaces:[{type:1,main:1,useip:1,ip:$ip,dns:"",port:"10050"}],
          tls_connect:2, tls_accept:2, tls_psk_identity:$pid, tls_psk:$psk}')" >/dev/null \
      && ok "host $HOST_NAME creado con el template Docker y PSK" \
      || die "No pude crear el host $HOST_NAME"
  fi

  echo "  Esperando que el agente quede disponible (hasta 2 min)..."
  local disp=""
  for _ in $(seq 1 12); do
    disp=$(api host.get "$(jq -nc --arg h "$HOST_NAME" '{filter:{host:[$h]},output:["hostid"],selectInterfaces:["available","error"]}')" \
           | jq -r '.[0].interfaces[0].available // empty')
    [ "$disp" = "1" ] && break
    sleep 10
  done
  if [ "$disp" = "1" ]; then ok "el ícono ZBX de $HOST_NAME está en verde"
  else aviso "el agente aún no figura disponible; revisá el error en Data collection › Hosts"; fi
}

# =============================================================================
# MEJORA 4: monitoreo del monitoreo
# =============================================================================
crear_item() { # nombre clave
  local ex
  ex=$(api item.get "$(jq -nc --arg h "$SRV_ID" --arg k "$2" '{hostids:[$h],filter:{key_:[$k]},output:["itemid"]}')" | jq -r '.[0].itemid // empty')
  if [ -n "$ex" ]; then ok "ítem ya existe: $1"; return; fi
  api item.create "$(jq -nc --arg n "$1" --arg k "$2" --arg h "$SRV_ID" --arg i "$SRV_IF" \
      '{name:$n,key_:$k,hostid:$h,type:3,value_type:3,delay:"1m",interfaceid:$i}')" >/dev/null \
    && ok "ítem creado: $1" || aviso "no pude crear el ítem: $1"
}

crear_trigger() { # nombre prioridad expresión
  local ex
  ex=$(api trigger.get "$(jq -nc --arg d "$1" --arg h "$SRV_ID" '{hostids:[$h],filter:{description:[$d]},output:["triggerid"]}')" | jq -r '.[0].triggerid // empty')
  if [ -n "$ex" ]; then ok "trigger ya existe: $1"; return; fi
  api trigger.create "$(jq -nc --arg d "$1" --arg e "$3" --arg p "$2" '{description:$d,expression:$e,priority:($p|tonumber)}')" >/dev/null \
    && ok "trigger creado: $1" || aviso "no pude crear el trigger: $1"
}

mejora4() {
  paso "Mejora 2 · A. Salud interna de Zabbix"

  local SRV health_id keep clear params
  SRV=$(api host.get "$(jq -nc '{filter:{host:["Zabbix server"]},output:["hostid","status"],selectParentTemplates:["templateid","host"],selectInterfaces:["interfaceid","type"],selectHostGroups:["groupid"]}')")
  health_id=$(plantilla_id "Zabbix server health")
  [ -n "$health_id" ] || aviso "no encontré el template 'Zabbix server health'"

  if [ "$(echo "$SRV" | jq 'length')" = "0" ]; then
    local gsrv
    gsrv=$(grupo_id "Zabbix servers")
    api host.create "$(jq -nc --arg g "$gsrv" --arg t "$health_id" \
        '{host:"Zabbix server",groups:[{groupid:$g}],templates:[{templateid:$t}],
          interfaces:[{type:1,main:1,useip:1,ip:"127.0.0.1",dns:"",port:"10050"}]}')" >/dev/null \
      && ok "host 'Zabbix server' creado" || die "No pude crear el host 'Zabbix server'"
    SRV=$(api host.get "$(jq -nc '{filter:{host:["Zabbix server"]},output:["hostid","status"],selectParentTemplates:["templateid","host"],selectInterfaces:["interfaceid","type"],selectHostGroups:["groupid"]}')")
  fi

  SRV_ID=$(echo "$SRV" | jq -r '.[0].hostid')
  SRV_IF=$(echo "$SRV" | jq -r '.[0].interfaces[0].interfaceid // empty')
  [ -n "$SRV_IF" ] || die "El host 'Zabbix server' no tiene interfaz; no puedo crear checks simples."

  # Dentro del contenedor no hay agente en 127.0.0.1: se desvincula el template Linux
  # (evitaría un problema permanente) y se asegura el template de salud y que esté activo.
  keep=$(echo "$SRV"  | jq -c --arg h "$health_id" '[.[0].parentTemplates[] | select(.host!="Linux by Zabbix agent") | .templateid] + (if $h=="" then [] else [$h] end) | unique')
  clear=$(echo "$SRV" | jq -c '[.[0].parentTemplates[] | select(.host=="Linux by Zabbix agent") | .templateid]')
  params=$(jq -nc --arg id "$SRV_ID" --argjson k "$keep" --argjson c "$clear" \
    '{hostid:$id,status:0,templates:($k|map({templateid:.}))} + (if ($c|length)>0 then {templates_clear:($c|map({templateid:.}))} else {} end)')
  api host.update "$params" >/dev/null \
    && ok "'Zabbix server': activo, con 'Zabbix server health' y sin el template Linux" \
    || aviso "no pude actualizar el host 'Zabbix server'"

  paso "Mejora 2 · B. Ítems y triggers de los servicios"
  crear_item "Base de datos PostgreSQL accesible" "net.tcp.service[tcp,192.168.56.22,5432]"
  crear_item "Loki accesible"                     "net.tcp.service[tcp,192.168.56.24,3100]"
  crear_item "Grafana accesible"                  "net.tcp.service[tcp,192.168.56.23,3000]"
  crear_trigger "Base de datos de Zabbix inaccesible" 5 'last(/Zabbix server/net.tcp.service[tcp,192.168.56.22,5432])=0'
  crear_trigger "Loki inaccesible"                    4 'last(/Zabbix server/net.tcp.service[tcp,192.168.56.24,3100])=0'
  crear_trigger "Grafana inaccesible"                 3 'last(/Zabbix server/net.tcp.service[tcp,192.168.56.23,3000])=0'

  paso "Mejora 2 · Acción de Telegram para los nuevos grupos"
  local ACT AID GIDS NUEVA infra
  infra=$(grupo_id "$GRUPO_INFRA")
  GIDS=$(echo "$SRV" | jq -c --arg i "$infra" '[.[0].hostgroups // .[0].groups // [] | .[].groupid] + [$i] | map(select(. != "")) | unique')
  ACT=$(api action.get "$(jq -nc --arg n "$ACCION" '{search:{name:$n},output:["actionid","name"],selectFilter:"extend"}')")
  AID=$(echo "$ACT" | jq -r '.[0].actionid // empty')
  if [ -z "$AID" ]; then
    aviso "no encontré la acción '$ACCION'; agregá a mano los grupos 'Infraestructura' y 'Zabbix servers' a sus condiciones."
  else
    NUEVA=$(echo "$ACT" | jq -c --argjson gids "$GIDS" '
      (.[0].filter.conditions // []) as $c
      | ($c | map({conditiontype:(.conditiontype|tonumber), operator:(.operator|tonumber), value:.value})) as $base
      | $base + ($gids | map(select(. as $g | ($base | map(select(.conditiontype==0 and .value==$g)) | length)==0))
                       | map({conditiontype:0, operator:0, value:.}))')
    api action.update "$(jq -nc --arg id "$AID" --argjson c "$NUEVA" '{actionid:$id,filter:{evaltype:0,conditions:$c}}')" >/dev/null \
      && ok "la acción '$ACCION' ahora también cubre 'Infraestructura' y el grupo de 'Zabbix server'" \
      || aviso "no pude actualizar la acción; hacelo a mano (Alerts › Actions)"
  fi

  paso "Mejora 2 · C. Watchdog local con aviso directo a Telegram"
  local in_tok="${TG_TOKEN:-}" in_chat="${TG_CHAT:-}" uid tkid mt tid_old
  TG_TOKEN=""; TG_CHAT=""; ZBX_TOKEN=""
  [ -f "$WD_ENV" ] && . "$WD_ENV"           # reutiliza lo guardado en corridas anteriores
  [ -n "$in_tok" ]  && TG_TOKEN="$in_tok"
  [ -n "$in_chat" ] && TG_CHAT="$in_chat"

  # Token y chat ID: se leen de la configuración de Telegram que ya hay en Zabbix.
  if [ -z "$TG_TOKEN" ]; then
    TG_TOKEN=$(api mediatype.get '{"output":"extend","filter":{"name":["Telegram"]}}' 2>/dev/null \
      | jq -r '[.[0].parameters[]? | select(.name=="api_token" or .name=="Token") | .value] | .[0] // empty')
  fi
  if [ -z "$TG_CHAT" ]; then
    mt=$(api mediatype.get '{"output":["mediatypeid"],"filter":{"name":["Telegram"]}}' 2>/dev/null | jq -r '.[0].mediatypeid // empty')
    TG_CHAT=$(api user.get "$(jq -nc --arg u "$ZBX_USER" '{filter:{username:[$u]},output:["userid"],selectMedias:["mediatypeid","sendto"]}')" 2>/dev/null \
      | jq -r --arg m "$mt" '[.[0].medias[]? | select(.mediatypeid==$m) | .sendto | if type=="array" then .[0] else . end] | .[0] // empty')
  fi
  if [ -z "$TG_TOKEN" ]; then read -rsp "  No pude leer el token del bot. Pegalo (queda oculto): " TG_TOKEN </dev/tty || true; echo; fi
  if [ -z "$TG_CHAT" ];  then read -rp  "  Chat ID del grupo de Telegram (número negativo): " TG_CHAT </dev/tty || true; fi

  # Quita espacios y caracteres de control (p. ej. un \r al pegar desde Windows).
  TG_TOKEN=$(printf '%s' "$TG_TOKEN" | tr -d '[:space:][:cntrl:]')
  TG_CHAT=$(printf '%s' "$TG_CHAT" | tr -d '[:space:][:cntrl:]')

  if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then
    aviso "sin token o chat ID: watchdog omitido (volvé a correr 'sudo bash scripts/mejoras.sh 2')"
    return
  fi
  ok "token y chat ID de Telegram obtenidos"

  # Token de API de Zabbix para comprobar que siguen llegando datos (opcional).
  if [ -z "${ZBX_TOKEN:-}" ]; then
    uid=$(api user.get "$(jq -nc --arg u "$ZBX_USER" '{filter:{username:[$u]},output:["userid"]}')" | jq -r '.[0].userid // empty')
    for tid_old in $(api token.get '{"filter":{"name":["watchdog"]},"output":["tokenid"]}' | jq -r '.[].tokenid'); do
      api token.delete "[\"$tid_old\"]" >/dev/null
    done
    tkid=$(api token.create "$(jq -nc --arg u "$uid" '{name:"watchdog",userid:$u}')" | jq -r '.tokenids[0] // empty')
    [ -n "$tkid" ] && ZBX_TOKEN=$(api token.generate "[\"$tkid\"]" | jq -r '.[0].token // empty')
    [ -n "$ZBX_TOKEN" ] && ok "token de API 'watchdog' creado" \
      || aviso "no pude crear el token de API; el watchdog no comprobará la frescura de los datos"
  fi

  umask 077
  { echo "TG_TOKEN=\"$TG_TOKEN\""; echo "TG_CHAT=\"$TG_CHAT\""; echo "ZBX_TOKEN=\"${ZBX_TOKEN:-}\""; } > "$WD_ENV"
  chmod 600 "$WD_ENV"
  ok "credenciales guardadas en $WD_ENV (solo root)"

  cat > "$WD_SCRIPT" <<'EOF'
#!/bin/sh
# Watchdog local: vigila que el monitoreo (Zabbix) funcione y, si no, avisa directo a Telegram.
# Corre FUERA de Zabbix (cron de la VM), así que puede avisar aunque Zabbix esté caído.
# No genera tráfico hacia Internet mientras todo está bien: solo escribe a Telegram al fallar y al recuperarse.
. /etc/watchdog-zabbix.env
API=http://192.168.56.21:8080/api_jsonrpc.php
ESTADO=/var/lib/watchdog-zabbix.estado     # "<fallas_seguidas> <ultimo_aviso> <alertado 0|1>"
UMBRAL=3                                    # corridas fallidas seguidas antes de avisar (3 min)
RECORDATORIO=1800                           # repetir el aviso cada 30 min si sigue caído

enviar() {
  curl -4 -sS -m 15 -o /dev/null \
    --data-urlencode "chat_id=$TG_CHAT" --data-urlencode "text=$1" \
    "https://api.telegram.org/bot$TG_TOKEN/sendMessage"
}

motivo=""
[ "$(docker inspect -f '{{.State.Running}}' zabbix-server 2>/dev/null)" = true ] \
  || motivo="el contenedor zabbix-server no está en ejecución"

if [ -z "$motivo" ]; then
  [ "$(docker inspect -f '{{.State.Running}}' zabbix-db 2>/dev/null)" = true ] \
    || motivo="el contenedor zabbix-db (base de datos) no está en ejecución"
fi

if [ -z "$motivo" ]; then
  curl -sf -m 10 -H 'Content-Type: application/json-rpc' \
    -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":[],"id":1}' "$API" | grep -q result \
    || motivo="la interfaz/API de Zabbix no responde"
fi

if [ -z "$motivo" ] && [ -n "${ZBX_TOKEN:-}" ]; then
  ULTIMO=$(curl -sf -m 10 -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $ZBX_TOKEN" \
    -d '{"jsonrpc":"2.0","method":"item.get","params":{"output":["lastclock"],"host":"web01","filter":{"key_":"icmpping"}},"id":1}' "$API" \
    | jq -r '.result[0].lastclock // empty')
  { [ -n "$ULTIMO" ] && [ $(( $(date +%s) - ULTIMO )) -lt 300 ]; } \
    || motivo="Zabbix no recibe datos nuevos de web01 desde hace más de 5 minutos"
fi

fallas=0; ultimo=0; alertado=0
[ -f "$ESTADO" ] && read -r fallas ultimo alertado < "$ESTADO"
ahora=$(date +%s)

if [ -z "$motivo" ]; then
  [ "$alertado" = 1 ] && enviar "RECUPERADO: el monitoreo de la tienda (Zabbix) volvió a funcionar. ($(date '+%F %T'))"
  echo "0 0 0" > "$ESTADO"
else
  fallas=$((fallas + 1))
  if [ "$fallas" -ge "$UMBRAL" ]; then
    if [ "$alertado" != 1 ] || [ $((ahora - ultimo)) -ge "$RECORDATORIO" ]; then
      enviar "ALERTA: el monitoreo de la tienda (Zabbix) dejó de funcionar. Motivo: $motivo. Aviso del watchdog local de master01. ($(date '+%F %T'))"
      ultimo=$ahora; alertado=1
    fi
  fi
  echo "$fallas $ultimo $alertado" > "$ESTADO"
fi
EOF
  chmod +x "$WD_SCRIPT"
  ok "script $WD_SCRIPT creado"

  ( crontab -l 2>/dev/null | grep -v -e 'watchdog-zabbix.sh' -e 'heartbeat.sh'; \
    echo "* * * * * $WD_SCRIPT >> /var/log/watchdog-zabbix.log 2>&1" ) | crontab -
  ok "programado en cron: se ejecuta cada minuto"

  if curl -4 -sS -m 15 -o /dev/null -w '%{http_code}' --data-urlencode "chat_id=$TG_CHAT" \
       --data-urlencode "text=Watchdog instalado en master01: avisará aquí si el monitoreo deja de funcionar." \
       "https://api.telegram.org/bot$TG_TOKEN/sendMessage" | grep -q 200; then
    ok "mensaje de prueba enviado al grupo de Telegram"
  else
    aviso "no pude enviar el mensaje de prueba a Telegram; revisá el token y el chat ID en $WD_ENV"
  fi
  "$WD_SCRIPT" && ok "primera ejecución del watchdog sin errores"
}

# =============================================================================
# Ejecución
# =============================================================================
if [ "$QUE" = "todo" ] || [ "$QUE" = "1" ]; then mejora1_agente; fi

paso "Conexión con la API de Zabbix"
for _ in $(seq 1 30); do api apiinfo.version '[]' >/dev/null 2>&1 && break; sleep 2; done
VER=$(api apiinfo.version '[]' | jq -r '.' 2>/dev/null) || die "La API no responde en $ZBX_URL"
ok "API de Zabbix $VER en $ZBX_URL"
if [ -z "${ZBX_PASS:-}" ]; then
  read -rsp "  Contraseña de $ZBX_USER en Zabbix: " ZBX_PASS </dev/tty; echo
fi
TOKEN=$(api user.login "$(U="$ZBX_USER" P="$ZBX_PASS" jq -nc '{username:env.U,password:env.P}')" | jq -r '.')
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || die "No pude iniciar sesión en Zabbix (¿contraseña de $ZBX_USER?)."
ok "sesión iniciada como $ZBX_USER"

if [ "$QUE" = "todo" ] || [ "$QUE" = "1" ]; then mejora1_host; fi
if [ "$QUE" = "todo" ] || [ "$QUE" = "4" ]; then mejora4; fi

paso "Listo. Qué probar y capturar"
cat <<'EOF'
  Mejora 1
    - Zabbix › Data collection › Hosts: master01 con ZBX en verde (PSK oculta en la captura).
    - Monitoring › Latest data › master01: ítems por contenedor (CPU, memoria, estado).
    - Correr scripts/pruebas.sh p1 y capturar la gráfica del contenedor web01 frente a los demás.
  Mejora 2
    - Zabbix › Hosts › Zabbix server: ítems y triggers nuevos.
    - docker stop loki   -> en 1-2 min llega el aviso a Telegram; docker start loki -> la recuperación.
    - docker stop zabbix-server -> en ~3 min el watchdog avisa a Telegram; docker start zabbix-server -> aviso de recuperación.
EOF
