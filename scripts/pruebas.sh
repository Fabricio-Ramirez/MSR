#!/bin/sh
# Pruebas P1-P6 de la propuesta, adaptadas a contenedores.
# La carga HTTP (P4 y P6) se lanza desde la VM, que cumple el papel del
# "host Windows" de la propuesta. Requiere apache2-utils instalado en la VM.
set -eu

WEB=192.168.56.10
GW=192.168.56.254

marca() { echo "[$(date '+%F %T')] $*"; }

uso() {
  cat <<'EOF'
Uso: scripts/pruebas.sh <prueba>
  p1            CPU: 95 % durante 10 min
  p2            RAM: 92 % durante 10 min
  p3 <85|92>    Disco: llena hasta ese porcentaje
  p3-limpiar    Borra los archivos de relleno
  p3b           E/S de disco durante 5 min
  p4            Carga HTTP desde la VM (necesita apache2-utils)
  p5a           Detiene Nginx
  p5a-subir     Arranca Nginx
  p5b           Corta la red de web01
  p5b-subir     Restablece la red de web01
  p6            Genera 50 errores HTTP 500
EOF
}

case "${1:-}" in
  p1)
    marca "Inicio P1"
    docker exec web01 stress-ng --cpu 0 --cpu-load 95 --timeout 10m --metrics-brief
    marca "Fin P1"
    ;;
  p2)
    marca "Inicio P2"
    docker exec web01 stress-ng --vm 1 --vm-bytes 92% --vm-keep --timeout 10m
    marca "Fin P2"
    ;;
  p3)
    obj=${2:?Indicá el porcentaje: 85 o 92}
    case "$obj" in 85|92) ;; *) echo "Solo se admite 85 o 92"; exit 1 ;; esac
    marca "Inicio P3 hasta $obj %"
    docker exec web01 sh -c '
      set -- $(df -B1 --output=size,used / | tail -1)
      falta=$(( $1 / 100 * '"$obj"' - $2 ))
      if [ "$falta" -le 0 ]; then echo "El disco ya supera ese porcentaje"; exit 0; fi
      fallocate -l "$falta" /var/tmp/relleno-'"$obj"'.img
      df -h /'
    marca "Disco en $obj %. Al terminar: scripts/pruebas.sh p3-limpiar"
    ;;
  p3-limpiar)
    docker exec web01 sh -c 'rm -f /var/tmp/relleno-*.img; df -h /'
    marca "Relleno borrado"
    ;;
  p3b)
    marca "Inicio P3b"
    docker exec web01 stress-ng --hdd 2 --hdd-bytes 1G --timeout 5m --temp-path /var/tmp
    marca "Fin P3b"
    ;;
  p4)
    command -v ab >/dev/null 2>&1 || {
      echo "Falta ab en la VM: sudo apt install -y apache2-utils"; exit 1; }
    marca "Inicio P4"
    ab -k -n 200000 -c 300 "http://$WEB/"
    marca "Fin P4"
    ;;
  p5a)
    docker exec web01 supervisorctl stop nginx
    marca "Nginx detenido"
    ;;
  p5a-subir)
    docker exec web01 supervisorctl start nginx
    marca "Nginx iniciado"
    ;;
  p5b)
    docker exec web01 ip link set eth0 down
    marca "Red de web01 cortada"
    ;;
  p5b-subir)
    # Bajar la interfaz borra la ruta por defecto; hay que reponerla.
    docker exec web01 sh -c "ip link set eth0 up && ip route replace default via $GW"
    marca "Red de web01 restablecida"
    ;;
  p6)
    marca "Inicio P6"
    i=1
    while [ "$i" -le 50 ]; do
      curl -s -m 10 -o /dev/null "http://$WEB/error500"
      i=$((i + 1))
    done
    marca "Fin P6"
    ;;
  *)
    uso
    exit 1
    ;;
esac
