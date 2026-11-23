#!/bin/sh
# Métricas del PROPIO contenedor web01, leídas de su cgroup v2.
#
# Por qué existe: el agente corre dentro del contenedor, pero /proc/stat y
# /proc/meminfo no están aislados por contenedor y muestran la VM entera. Por eso los
# templates de Linux miden la VM y no el servidor web. El cgroup sí es propio: con
# cgroup v2, Docker le muestra a cada contenedor solo el suyo en /sys/fs/cgroup.
# Es la misma fuente que usa "docker stats", y no necesita el socket de Docker.
#
# Lo usa el agente con la clave contenedor[<métrica>] (UserParameter que agrega
# entrypoint.sh) y lo usan las pruebas de RAM (pruebas.sh p2 y el panel de la tienda)
# para calcular cuánta memoria reservar sin pasarse del límite.
#
#   contenedor-metricas.sh cpu.uso        µs de CPU acumulados / núcleos del límite
#                                         (en Zabbix: Change per second y x0.0001 = % del límite)
#   contenedor-metricas.sh cpu.limite     núcleos asignados (cpus: de compose.yaml)
#   contenedor-metricas.sh cpu.throttled  veces que el kernel frenó al contenedor por llegar al límite
#   contenedor-metricas.sh mem.uso        bytes en uso, sin la caché inactiva (igual que docker stats)
#   contenedor-metricas.sh mem.limite     bytes del límite (mem_limit: de compose.yaml)
#   contenedor-metricas.sh mem.pct        % de memoria usada respecto del límite
#   contenedor-metricas.sh mem.oom        procesos matados por falta de memoria (acumulado)
#   contenedor-metricas.sh io.lectura     bytes leídos de disco (acumulado)
#   contenedor-metricas.sh io.escritura   bytes escritos a disco (acumulado)
#   contenedor-metricas.sh procesos       cantidad de procesos del contenedor
#   contenedor-metricas.sh bytes-para N   bytes a reservar para llevar la memoria al N % del límite
set -u
CG=/sys/fs/cgroup

[ -r "$CG/cpu.stat" ] || { echo "Sin cgroup v2 en $CG" >&2; exit 1; }

nucleos_limite() {
  read -r cuota periodo < "$CG/cpu.max"
  if [ "$cuota" = max ]; then
    nproc
  else
    awk -v c="$cuota" -v p="$periodo" 'BEGIN { printf "%.2f\n", c / p }'
  fi
}

memoria_limite() {
  m=$(cat "$CG/memory.max")
  if [ "$m" = max ]; then
    # Sin límite: el tope real es la memoria de la VM.
    awk '$1 == "MemTotal:" { printf "%.0f\n", $2 * 1024 }' /proc/meminfo
  else
    echo "$m"
  fi
}

memoria_uso() {
  awk -v cur="$(cat "$CG/memory.current")" '
    $1 == "inactive_file" { i = $2 }
    END { u = cur - i; if (u < 0) u = cur; printf "%.0f\n", u }' "$CG/memory.stat"
}

io_suma() { # campo de io.stat: rbytes o wbytes, sumado sobre todos los dispositivos
  [ -r "$CG/io.stat" ] || { echo 0; return; }
  awk -v campo="$1" '{
      for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] == campo) s += kv[2] }
    } END { printf "%.0f\n", s + 0 }' "$CG/io.stat"
}

case "${1:-}" in
  cpu.uso)
    awk -v n="$(nucleos_limite)" '$1 == "usage_usec" { printf "%.0f\n", $2 / n }' "$CG/cpu.stat"
    ;;
  cpu.limite)    nucleos_limite ;;
  cpu.throttled) awk '$1 == "nr_throttled" { print $2 }' "$CG/cpu.stat" ;;
  mem.uso)       memoria_uso ;;
  mem.limite)    memoria_limite ;;
  mem.pct)
    awk -v u="$(memoria_uso)" -v l="$(memoria_limite)" 'BEGIN { printf "%.2f\n", u * 100 / l }'
    ;;
  mem.oom)       awk '$1 == "oom_kill" { print $2 }' "$CG/memory.events" ;;
  io.lectura)    io_suma rbytes ;;
  io.escritura)  io_suma wbytes ;;
  procesos)      cat "$CG/pids.current" ;;
  bytes-para)
    obj=${2:?Indicá el porcentaje objetivo}
    awk -v u="$(memoria_uso)" -v l="$(memoria_limite)" -v o="$obj" \
      'BEGIN { b = l * o / 100 - u; if (b < 0) b = 0; printf "%.0f\n", b }'
    ;;
  *)
    echo "Uso: $0 cpu.uso|cpu.limite|cpu.throttled|mem.uso|mem.limite|mem.pct|mem.oom|io.lectura|io.escritura|procesos|bytes-para N" >&2
    exit 1
    ;;
esac
