#!/bin/sh
# Hace que las IP fijas de la documentacion (192.168.56.10/.20/.21/.22/.23/.24)
# se puedan abrir tal cual desde Windows, sin pasar por localhost:844x.
#
# Por que hace falta: la red "lab" es un puente interno de Docker dentro de la VM.
# La VM si la alcanza, pero Windows no, por dos motivos independientes:
#   1. Windows no tiene ruta hacia 192.168.56.0/24  -> se arregla desde Windows,
#      con scripts/ruta-windows.ps1 (una sola ruta persistente).
#   2. Docker deja la cadena FORWARD en DROP y solo abre los puertos publicados,
#      asi que descarta el trafico que entra por el host-only -> se arregla aqui.
#
# Se ejecuta DENTRO DE LA VM, una sola vez. Deja una unidad de systemd para que
# las reglas vuelvan solas despues de reiniciar o de un "systemctl restart docker".
#
#   sudo scripts/acceso-lan.sh            instala
#   sudo scripts/acceso-lan.sh --quitar   desinstala
set -eu

LAB=192.168.56.0/24
HOSTONLY=192.168.57.0/24
REGLAS=/usr/local/sbin/acceso-lab-reglas.sh
UNIDAD=/etc/systemd/system/acceso-lab.service
SYSCTL=/etc/sysctl.d/99-acceso-lab.conf

if [ "$(id -u)" != 0 ]; then
  echo "Hay que ejecutarlo con sudo: sudo $0 $*" >&2
  exit 1
fi

if ! iptables -S DOCKER-USER >/dev/null 2>&1; then
  echo "FALLO: no existe la cadena DOCKER-USER." >&2
  echo "Levanta Docker primero (systemctl start docker) y volve a intentar." >&2
  exit 1
fi

# ---------- desinstalar ----------

if [ "${1:-}" = "--quitar" ]; then
  systemctl disable --now acceso-lab.service >/dev/null 2>&1 || true
  rm -f "$UNIDAD" "$REGLAS" "$SYSCTL"
  systemctl daemon-reload
  while iptables -C DOCKER-USER -s "$HOSTONLY" -d "$LAB" -j ACCEPT 2>/dev/null; do
    iptables -D DOCKER-USER -s "$HOSTONLY" -d "$LAB" -j ACCEPT
  done
  while iptables -C DOCKER-USER -s "$LAB" -d "$HOSTONLY" -j ACCEPT 2>/dev/null; do
    iptables -D DOCKER-USER -s "$LAB" -d "$HOSTONLY" -j ACCEPT
  done
  echo "Reglas y unidad eliminadas."
  echo "En Windows, para sacar la ruta:  scripts\ruta-windows.ps1 -Quitar"
  exit 0
fi

# ---------- comprobar que las IP fijas son las de la documentacion ----------

esperadas="web01=192.168.56.10 zabbix-server=192.168.56.20 zabbix-web=192.168.56.21 \
zabbix-db=192.168.56.22 grafana=192.168.56.23 loki=192.168.56.24"

echo "IP fijas de los contenedores:"
desvios=0
for par in $esperadas; do
  nombre=${par%%=*}
  esperada=${par#*=}
  real=$(docker inspect -f \
    '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$nombre" 2>/dev/null || true)
  if [ -z "$real" ]; then
    echo "  ?     $nombre: no esta levantado (se comprueba cuando corras docker compose up)"
  elif [ "$real" = "$esperada" ]; then
    echo "  OK    $nombre -> $real"
  else
    echo "  FALLO $nombre -> $real (la documentacion dice $esperada)"
    desvios=$((desvios + 1))
  fi
done

if [ "$desvios" -gt 0 ]; then
  echo >&2
  echo "Hay contenedores con una IP distinta a la documentada. Recrea la red:" >&2
  echo "  docker compose down && docker compose up -d" >&2
  exit 1
fi

# ---------- reenvio de IPv4 ----------

printf '%s\n' \
  '# El trafico de Windows hacia la red lab de Docker atraviesa la VM.' \
  'net.ipv4.ip_forward = 1' > "$SYSCTL"
sysctl -q -w net.ipv4.ip_forward=1

# ---------- reglas de iptables ----------

cat > "$REGLAS" <<'EOF'
#!/bin/sh
# Generado por scripts/acceso-lan.sh del obligatorio de MSR.
# Deja pasar el trafico entre el host-only (192.168.57.0/24) y la red lab de
# Docker (192.168.56.0/24). DOCKER-USER se recorre antes que las reglas que
# escribe Docker, asi que un ACCEPT aqui gana y sobrevive a los reinicios del
# demonio, que vacian el resto de las cadenas.
set -eu
LAB=192.168.56.0/24
HOSTONLY=192.168.57.0/24
for sentido in "-s $HOSTONLY -d $LAB" "-s $LAB -d $HOSTONLY"; do
  # shellcheck disable=SC2086
  iptables -C DOCKER-USER $sentido -j ACCEPT 2>/dev/null && continue
  # shellcheck disable=SC2086
  iptables -I DOCKER-USER 1 $sentido -j ACCEPT
done
EOF
chmod 755 "$REGLAS"
"$REGLAS"

# ---------- unidad de systemd ----------

cat > "$UNIDAD" <<EOF
[Unit]
Description=Acceso desde el host-only a la red lab de Docker (192.168.56.0/24)
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$REGLAS

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now acceso-lab.service >/dev/null

# ---------- resumen ----------

ip_hostonly=$(ip -4 -o addr show | awk '$4 ~ /^192\.168\.57\./ {split($4,a,"/"); print a[1]; exit}')

echo
echo "Listo del lado de la VM:"
echo "  - net.ipv4.ip_forward = 1 (persistente en $SYSCTL)"
echo "  - dos reglas ACCEPT en DOCKER-USER, reaplicadas por acceso-lab.service"
echo
if [ -z "$ip_hostonly" ]; then
  echo "AVISO: esta VM no tiene ninguna direccion en 192.168.57.0/24."
  echo "Falta el adaptador 2 en host-only; mira el paso 2 de PUESTA-EN-MARCHA.md."
  ip_hostonly=192.168.57.10
fi
echo "Falta un paso en Windows, en PowerShell como administrador:"
echo
echo "  route -p add 192.168.56.0 mask 255.255.255.0 $ip_hostonly"
echo
echo "o, lo mismo con comprobaciones:  scripts\ruta-windows.ps1"
echo
echo "Despues, desde el navegador de Windows:"
echo "  http://192.168.56.10        tienda"
echo "  http://192.168.56.21:8080   Zabbix"
echo "  http://192.168.56.23:3000   Grafana"
