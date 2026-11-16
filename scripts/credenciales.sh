#!/bin/sh
# Muestra por pantalla cómo entrar a cada servicio: dirección, usuario y contraseña.
# Lo llama scripts/iniciar.sh al terminar, y se puede correr suelto cuando haga falta.
#
# Las contraseñas no están en el repositorio: las genera scripts/init.sh dentro de
# la VM y quedan en .env y secrets/, que están en .gitignore. Este script las lee de
# ahí y además prueba contra cada servicio si siguen vigentes, porque Zabbix y
# Grafana dejan cambiarlas desde la interfaz y en ese caso lo de .env ya no vale.
#
# Ojo: la salida tiene secretos. No la pegues en una captura de la entrega.
set -eu
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "Falta .env. Corré primero: sh scripts/iniciar.sh" >&2
  exit 1
fi
set -a
. ./.env
set +a

ZBX=192.168.56.21:8080
GRAF=192.168.56.23:3000

# Una sola prueba de login por servicio. Zabbix bloquea la cuenta 30 segundos después
# de cinco intentos fallidos seguidos, así que no conviene correr esto en un bucle
# si ya cambiaste la contraseña de Admin.
estado_zabbix() {
  r=$(curl -s -m 5 -H 'Content-Type: application/json-rpc' \
        -d '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"zabbix"},"id":1}' \
        "http://$ZBX/api_jsonrpc.php" 2>/dev/null || true)
  case "$r" in
    *'"result"'*) echo "vigente: es la de fábrica, cambiala al entrar" ;;
    *'"error"'*)  echo "YA NO VALE: la cambiaste desde la interfaz" ;;
    *)            echo "sin verificar: el frontend todavía no responde" ;;
  esac
}

estado_grafana() {
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u "admin:$GRAFANA_PASSWORD" \
        "http://$GRAF/api/user" 2>/dev/null || true)
  case "$c" in
    200) echo "vigente" ;;
    401) echo "YA NO VALE: la cambiaste desde la interfaz" ;;
    *)   echo "sin verificar: Grafana todavía no responde" ;;
  esac
}

hostonly=$(ip -4 -o addr show 2>/dev/null | awk '$4 ~ /^192\.168\.57\./ {split($4,a,"/"); print a[1]; exit}')
psk=$(cat secrets/web01.psk 2>/dev/null || echo "(falta secrets/web01.psk)")

cat <<EOF

================================================================
  Laboratorio MSR - accesos
================================================================

  TIENDA      http://192.168.56.10
              sin usuario. Panel técnico: diez clics en el logo

  ZABBIX      http://192.168.56.21:8080
              usuario:     Admin
              contraseña:  zabbix
              estado:      $(estado_zabbix)

  GRAFANA     http://192.168.56.23:3000
              usuario:     admin
              contraseña:  $GRAFANA_PASSWORD
              estado:      $(estado_grafana)

  Las direcciones 192.168.56.x se abren desde Windows solo si hiciste
  el paso 7 de PUESTA-EN-MARCHA.md. Si no, las mismas tres por:
    NAT          localhost:8444 (tienda)  :8443 (Zabbix)  :3000 (Grafana)
    host-only    ${hostonly:-192.168.57.10}  :80  :8080  :3000

----------------------------------------------------------------
  Para configurar el host web01 en Zabbix
----------------------------------------------------------------

  AGENTE      192.168.56.10:10050, cifrado PSK
              identidad:   PSK-web01
              valor:       $psk

  SNMPv3      192.168.56.10:161, usuario zbxv3, authPriv
              auth SHA1:   $SNMP_AUTH
              priv AES128: $SNMP_PRIV

  POSTGRESQL  192.168.56.22:5432, base zabbix
              usuario:     zabbix
              contraseña:  $ZABBIX_DB_PASSWORD

  Todo esto sale de .env y secrets/, que no se suben al repositorio.
  Para verlo de nuevo: sh scripts/credenciales.sh
================================================================

EOF
