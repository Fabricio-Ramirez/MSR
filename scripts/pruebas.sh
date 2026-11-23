#!/bin/sh
# Pruebas P1-P6 de la propuesta, adaptadas a contenedores.
# La carga HTTP (P4 y P6) se lanza desde la VM, que cumple el papel del
# "host Windows" de la propuesta. Requiere apache2-utils instalado en la VM.
#
# CPU y RAM se miden contra el LÍMITE de web01 (cpuset y mem_limit de compose.yaml,
# con los valores de .env), no contra la VM: los triggers que tienen que dispararse
# son los del template "Contenedor web01 (cgroup v2)". El disco es /datos, el
# filesystem propio de web01 que crea scripts/disco-web01.sh.
set -eu

WEB=192.168.56.10
GW=192.168.56.254
DISCO=/datos

marca() { echo "[$(date '+%F %T')] $*"; }

uso() {
  cat <<'EOF'
Uso: scripts/pruebas.sh <prueba>
  p1            CPU: 95 % del límite de web01 durante 10 min
  p2            RAM: 92 % del límite de web01 durante 10 min
  p3 <85|92>    Disco de web01 (/datos): llena hasta ese porcentaje
  p3-limpiar    Borra los archivos de relleno
  p3b           E/S de disco sobre /datos durante 5 min
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
    # --cpu 0 lanza un worker por núcleo de la VM, pero el cpuset de web01 los encierra
    # en sus núcleos: web01 queda al tope de SU límite y la VM conserva margen.
    # --cpu-method int64: el método por defecto ("all") incluye instrucciones AVX que
    # el CPU virtual de VirtualBox no expone; stress-ng moría con SIGILL en 0,01 s y
    # la prueba "terminaba" sin haber cargado nada.
    docker exec web01 stress-ng --cpu 0 --cpu-method int64 --cpu-load 95 --timeout 10m --metrics-brief
    marca "Fin P1"
    ;;
  p2)
    marca "Inicio P2"
    # No se usa "--vm-bytes 92%": stress-ng lo calcula sobre la memoria de la VM y,
    # con el límite del contenedor, el kernel lo mataría por OOM al instante.
    bytes=$(docker exec web01 /usr/local/bin/contenedor-metricas.sh bytes-para 92)
    marca "Reservando $((bytes / 1048576)) MiB para llegar al 92 % del límite de web01"
    docker exec web01 stress-ng --vm 1 --vm-bytes "$bytes" --vm-keep --timeout 10m
    marca "Fin P2"
    ;;
  p3)
    obj=${2:?Indicá el porcentaje: 85 o 92}
    case "$obj" in 85|92) ;; *) echo "Solo se admite 85 o 92"; exit 1 ;; esac
    marca "Inicio P3 hasta $obj %"
    docker exec web01 sh -c '
      set -- $(df -B1 --output=size,used '"$DISCO"' | tail -1)
      falta=$(( $1 / 100 * '"$obj"' - $2 ))
      if [ "$falta" -le 0 ]; then echo "El disco ya supera ese porcentaje"; exit 0; fi
      fallocate -l "$falta" '"$DISCO"'/relleno/relleno-'"$obj"'.img
      df -h '"$DISCO"
    marca "Disco en $obj %. Al terminar: scripts/pruebas.sh p3-limpiar"
    ;;
  p3-limpiar)
    docker exec web01 sh -c "rm -f $DISCO/relleno/relleno-*.img; df -h $DISCO"
    marca "Relleno borrado"
    ;;
  p3b)
    marca "Inicio P3b"
    # 2 x 512 MB entran holgados en los 4 GB de /datos.
    docker exec web01 stress-ng --hdd 2 --hdd-bytes 512M --timeout 5m --temp-path "$DISCO/relleno"
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
