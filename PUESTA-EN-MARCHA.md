# Puesta en marcha — Laboratorio MSR

## Qué vas a levantar

Una VM Ubuntu con siete contenedores Docker: el servidor web monitoreado (`web01`), la pila de monitoreo (Zabbix server, frontend, PostgreSQL, Grafana y Loki) y `mon-agent`, el agente que monitorea los contenedores y la base. Es un solo comando una vez que la VM está lista.

Calculá **una hora** la primera vez. La construcción de las imágenes sola lleva unos 10 minutos.

Antes de empezar, tené a mano:

- **VirtualBox 7.1** instalado en Windows.
- La **ISO de Ubuntu Server 26.04 LTS**.
- La carpeta **`obligatorio-docker`**, que está en `Desktop\Monitoreo y Sup\Obligatorio`. Sin binarios ni contraseñas: las claves las genera `init.sh` dentro de la VM y nunca salen de ahí.

Todos los comandos que empiezan con `VBoxManage` van en **PowerShell, en Windows**. El resto va dentro de la VM.

## Paso 1 — Crear la VM

En VirtualBox, **Nueva**, con estos valores:

| Opción | Valor |
| --- | --- |
| Nombre | `OBG-Monitoreo` |
| Tipo | Linux / Ubuntu (64-bit) |
| Memoria | 4096 MB (6144 si te sobra RAM) |
| Procesadores | 2 (4 si te sobran núcleos) |
| Disco | 40 GB o más |

Durante la instalación de Ubuntu, lo único que importa:

1. Marcá **Install OpenSSH server**. Sin eso no podés entrar desde Windows y hay que hacer todo en la ventanita de VirtualBox.
2. Anotá el usuario que creás. En el laboratorio de referencia es `monitoreo` y el host es `srvmonitoreo`.
3. No instales nada más desde el instalador.

Con 2 vCPU y 4 GB alcanza, pero son los mínimos: durante las pruebas de carga la VM comparte CPU entre `stress-ng` y el propio Zabbix, así que los números salen más ruidosos. Conviene anotarlo al analizar la prueba P4.

## Paso 2 — Red en VirtualBox

Dos adaptadores. **Apagá la VM antes de tocar esto.**

**Adaptador 1: NAT.** Da salida a Internet y acerca los paneles a Windows por reenvío de puertos. En PowerShell:

```
VBoxManage modifyvm "OBG-Monitoreo" --natpf1 "SSH,tcp,,2223,,22"
VBoxManage modifyvm "OBG-Monitoreo" --natpf1 "Tienda,tcp,,8444,,80"
VBoxManage modifyvm "OBG-Monitoreo" --natpf1 "Zabbix,tcp,,8443,,8080"
VBoxManage modifyvm "OBG-Monitoreo" --natpf1 "Grafana,tcp,,3000,,3000"
```

**Adaptador 2: host-only.** Te deja entrar por IP sin pasar por los reenvíos. En la pestaña Red de la VM, Adaptador 2, Habilitar, "Adaptador solo-anfitrión". Después:

```
VBoxManage hostonlyif ipconfig "VirtualBox Host-Only Ethernet Adapter" --ip 192.168.57.1 --netmask 255.255.255.0
VBoxManage dhcpserver modify --network="HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter" --disable
```

> **El host-only tiene que ir en `192.168.57.0/24`, nunca en `192.168.56.0/24`.** Esa segunda es la red interna de Docker. Si las dos coinciden, la VM queda con dos rutas para el mismo `/24` y su tráfico hacia los contenedores sale por la interfaz equivocada: se rompen tres comprobaciones de `verificar.sh` y la prueba P4. Nos pasó, y cuesta de diagnosticar porque todo *parece* bien.

El DHCP queda deshabilitado a propósito: la IP se fija a mano en el paso siguiente, así no cambia nunca.

Un detalle si tenés la VM del curso: `lab-monitoreo` también reenvía los puertos 2222 y 2223, así que **no las enciendas a la vez** o una de las dos reglas no va a poder tomar el puerto.

## Paso 3 — IP fija en Ubuntu

Encendé la VM y entrá por SSH desde PowerShell:

```
ssh -p 2223 monitoreo@127.0.0.1
```

Usá `127.0.0.1` y no `localhost`: son entradas distintas en `known_hosts` y, si después corrés un comando con pipe antes de aceptar la huella, falla sin poder preguntarte.

El adaptador 2 lo agregaste después de instalar Ubuntu, así que netplan **no lo conoce** y nunca va a configurarlo solo. Hay que declararlo. Primero confirmá cómo se llama:

```
ip -br link
```

Debería ser `enp0s8`. Si tiene otro nombre, cambiáselo abajo antes de aplicar:

```
sudo tee /etc/netplan/99-hostonly.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    enp0s8:
      dhcp4: false
      dhcp6: false
      addresses: [192.168.57.10/24]
EOF
sudo chmod 600 /etc/netplan/99-hostonly.yaml
sudo netplan apply
```

**Sin `gateway`, a propósito.** La ruta por defecto tiene que seguir saliendo por el NAT (`enp0s3`), que es la que da Internet. Comprobalo:

```
ip -br a                  # enp0s8 con 192.168.57.10/24
ip route | grep default   # tiene que decir dev enp0s3
```

Desde acá ya podés entrar directo con `ssh monitoreo@192.168.57.10`.

## Paso 4 — Instalar Docker

Dentro de la VM:

```
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
sudo timedatectl set-timezone America/Montevideo
sudo apt install -y chrony apache2-utils
```

**Cerrá la sesión SSH y volvé a entrar**, o el grupo `docker` no aplica y cada comando te va a pedir `sudo`.

Qué aporta cada cosa: `chrony` sincroniza el reloj, que importa para que las horas de los eventos en Zabbix coincidan con las de los logs en Grafana; `apache2-utils` trae `ab`, la herramienta de la prueba de carga HTTP.

El repositorio de Docker ya publica para Ubuntu 26.04 (`resolute`), así que el script anda. Si alguna vez no estuviera, el respaldo son los paquetes de Ubuntu: `sudo apt install -y docker.io docker-compose-v2`.

Verificá antes de seguir:

```
docker version
docker compose version
```

## Paso 5 — Copiar el proyecto y levantarlo

Desde PowerShell, en Windows:

```
scp -r "$HOME\Desktop\Monitoreo y Sup\Obligatorio\obligatorio-docker" monitoreo@192.168.57.10:~/
```

Si ya había una copia vieja, borrala primero con `ssh monitoreo@192.168.57.10 "rm -rf ~/obligatorio-docker"`. El `scp -r` **fusiona** con lo que exista en vez de reemplazarlo, y te puede dejar archivos de versiones anteriores.

> **Si el laboratorio ya estaba funcionando y configurado en Zabbix, no borres la carpeta: seguí "Actualizar una instalación existente", más abajo.** El `rm -rf` se lleva `.env` y `secrets/`. La base de Zabbix, en cambio, sobrevive en su volumen con la contraseña vieja. `init.sh` generaría claves nuevas y quedarían tres cosas rotas: zabbix-server no entra a la base, el host web01 pierde la PSK y SNMPv3 deja de autenticar.

### Actualizar una instalación existente

Para pasar a la versión con monitoreo por contenedor (`mon-agent`, límites de `web01`, disco `/datos`) sin perder claves ni configuración:

1. Desde PowerShell, copiá la versión nueva a una carpeta aparte:

   ```
   scp -r "$HOME\Desktop\Monitoreo y Sup\Obligatorio\MSR" monitoreo@192.168.57.10:~/obligatorio-nuevo
   ```

2. En la VM, pasale las claves de la instalación actual y cambiá una carpeta por la otra:

   ```
   cp -a ~/obligatorio-docker/.env ~/obligatorio-docker/secrets ~/obligatorio-nuevo/
   mv ~/obligatorio-docker ~/obligatorio-viejo
   mv ~/obligatorio-nuevo ~/obligatorio-docker
   cd ~/obligatorio-docker
   ```

3. Creá el disco de web01 y levantá:

   ```
   sudo sh scripts/disco-web01.sh
   sh scripts/iniciar.sh
   ```

   `init.sh` conserva lo que hay en `.env` y solo agrega las variables nuevas: límites de web01, `DOCKER_GID`, `PG_MONITOR_PASSWORD` y la PSK de `mon-agent`. `up -d --build` reconstruye web01 y crea mon-agent. Los demás contenedores y sus datos quedan como estaban.

4. `sh scripts/verificar.sh` y, cuando dé todo OK, borrá `~/obligatorio-viejo`.

**No corras `docker compose down -v`**: borra la base de Zabbix con toda la configuración del frontend.

Después del primer reinicio de la VM, confirmá que el disco de web01 se montó antes que Docker: `sh scripts/disco-web01.sh --estado` tiene que decir que `/datos` es un montaje propio.

Dentro de la VM, primero, **una sola vez por VM**, el disco propio de `web01`:

```
cd ~/obligatorio-docker
sudo sh scripts/disco-web01.sh
```

Crea un archivo imagen de 4 GB con un ext4 adentro, lo monta en `/srv/msr/web01-datos` y lo deja en `/etc/fstab`. `web01` lo ve como `/datos`, y ahí escriben las pruebas de disco: así llenan el disco del servidor web y no el de la VM, donde están PostgreSQL y Zabbix. Pide `sudo` porque toca `/etc/fstab`, y por eso no lo hace `iniciar.sh`. Si lo salteás el laboratorio anda igual, pero `/datos` queda en el disco de la VM y `verificar.sh` lo marca. Diagnóstico sin root: `sh scripts/disco-web01.sh --estado`.

Después, un solo comando levanta todo:

```
sh scripts/iniciar.sh
```

Hace tres cosas seguidas. Primero llama a `init.sh`, que genera `.env` con las contraseñas aleatorias, los límites de CPU y RAM de `web01` (un núcleo y la mitad de la RAM quedan para el resto del laboratorio) y las claves PSK de los dos agentes Zabbix; **no sobrescribe nada si ya existe**, solo agrega lo que falte. Después corre `docker compose up -d --build`, que es lo que tarda: descarga tres imágenes y construye otras tres, unos 10 minutos y cerca de 5 GB la primera vez. Y al final espera a que Zabbix y Grafana respondan y **muestra por pantalla la dirección, el usuario y la contraseña de cada servicio**.

Podés correrlo las veces que quieras: si todo ya está arriba no recrea nada. Y para volver a ver solo los accesos, sin tocar los contenedores:

```
sh scripts/credenciales.sh
```

Ese listado además te dice si cada contraseña **sigue vigente**: Zabbix y Grafana dejan cambiarla desde la interfaz, y en ese caso lo que quedó en `.env` ya no sirve. Tiene secretos, así que no lo pegues en una captura.

Se invocan con `sh` adelante a propósito: Git en Windows no conserva el bit de ejecución, y así funcionan igual recién clonados.

Antes de comprobar nada esperá **dos minutos**: Loki y `zabbix-server` tardan un poco más que el frontend en quedar listos.

## Paso 6 — Comprobar y entrar

Un solo comando te dice si quedó todo bien:

```
sh scripts/verificar.sh
```

Son **46 comprobaciones** y tienen que dar todas OK: los siete contenedores, sus siete IP fijas contra la tabla de la documentación, los cinco procesos dentro de `web01`, la conectividad entre ellos, SNMPv3 en sus dos caras (que v3 responda y que v2c sea rechazado), la cadena de logs de punta a punta, los límites y el disco propio de `web01`, las métricas del contenedor, el acceso de `mon-agent` al socket de Docker y a PostgreSQL, y la salida a Healthchecks.io. Tarda un par de minutos porque algunas esperan.

Si alguna falla, el nombre te dice cuál es y el apartado siguiente tiene los comandos para mirar.

Los tres paneles, desde el navegador de Windows:

| Panel | URL | Por su IP fija | Usuario |
| --- | --- | --- | --- |
| Tienda | `http://localhost:8444` | `http://192.168.56.10` | — |
| Zabbix | `http://localhost:8443` | `http://192.168.56.21:8080` | `Admin` / `zabbix`, cambiá la contraseña al entrar |
| Grafana | `http://localhost:3000` | `http://192.168.56.23:3000` | `admin`, la contraseña la muestra `sh scripts/credenciales.sh` |

La tercera columna son las direcciones de la documentación, y funcionan después del paso 7.

Es `http://`, sin `s`: el laboratorio no usa TLS. El cifrado que pide la letra lo aportan SNMPv3 authPriv y la TLS-PSK del agente, que no necesitan certificados.

> Las direcciones `192.168.56.x` son la red interna de Docker y viven dentro de la VM, así que **recién instalado no se abren desde Windows**. El paso 7 las habilita. Aunque no lo hagas, las pantallas que piden una URL de esa red funcionan igual: la fuente de datos de Grafana hacia Zabbix la resuelve el backend de Grafana, que sí está adentro.

Entrá a la tienda y probá el código Konami: ↑ ↑ ↓ ↓ ← → ← → B A, o diez clics en el logo. Se abre un panel con enlaces a los paneles y botones que disparan las pruebas de carga en vivo.

## Paso 7 — Abrir las IP de la documentación desde Windows

**Es un paso manual y opcional, fuera del despliegue.** No lo hace `docker compose up`:
pide la VM apagada, una PowerShell como administrador y contraseña de `sudo`. Sin él el
laboratorio funciona igual —las comprobaciones de `verificar.sh` pasan—, pero conviene:
deja las seis direcciones de la tabla —`192.168.56.10` web01, `.20` server, `.21` frontend,
`.22` base, `.23` Grafana, `.24` Loki— accesibles tal cual desde el navegador de Windows, y
las capturas quedan coincidiendo con lo que dice la propuesta.

La idea es **meter a Windows dentro de la red del laboratorio** en vez de enrutar hacia
ella: se le agrega a la VM un tercer adaptador en host-only y ese adaptador pasa a ser un
puerto más del puente `br-lab`. Windows queda en `192.168.56.1`, en el mismo segmento de
capa 2 que los contenedores. No hay rutas ni reglas de firewall que mantener. Y Windows
pasa a ser el "PC de usuarios" que la propuesta ubica justamente en `192.168.56.1`.

**En VirtualBox, con la VM apagada**, en PowerShell como administrador:

```powershell
VBoxManage hostonlyif create
VBoxManage list hostonlyifs          # confirmá el nombre que te creó
VBoxManage hostonlyif ipconfig "VirtualBox Host-Only Ethernet Adapter #2" --ip 192.168.56.1 --netmask 255.255.255.0
VBoxManage dhcpserver modify --network="HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter #2" --disable
VBoxManage modifyvm "OBG-Monitoreo" --nic3 hostonly --host-only-adapter3 "VirtualBox Host-Only Ethernet Adapter #2"
VBoxManage modifyvm "OBG-Monitoreo" --nicpromisc3 allow-all
```

Tres cosas que no son opcionales: el **DHCP deshabilitado** en ese adaptador, porque si
reparte direcciones puede pisar las IP fijas; **`--nicpromisc3 allow-all`**, porque las
tramas que vuelven de los contenedores llevan la MAC del contenedor y sin modo promiscuo
VirtualBox las descarta; y la **VM apagada**, porque el chipset PIIX3 no admite agregar
NIC en caliente.

**Después, encendé la VM y dentro de ella:**

```bash
cd ~/obligatorio-docker
scripts/puente-lab.sh --estado   # diagnóstico, no necesita root
sudo scripts/puente-lab.sh
```

Detecta la interfaz nueva, la mete en el puente y deja un `.service` y un `.timer`. El
timer hace falta porque `docker compose down` borra el puente: cuando `up` lo vuelve a
crear, el timer reengancha la interfaz en menos de un minuto. Se revierte con `--quitar`.

Si preferís no tocar el hardware de la VM, hay una alternativa que enruta desde Windows
—`sudo scripts/acceso-lan.sh` más `scripts\ruta-windows.ps1`— documentada en el apartado 4
del `README.md`. **No se usan las dos a la vez.**

## Si algo falla

Empezá siempre por ver quién no está arriba:

```
docker compose ps
docker compose logs --tail=50 <servicio>
docker exec web01 supervisorctl status
```

Un contenedor en `Restarting` está en bucle: mirá sus logs, que ahí suele estar la causa literal.

Tres cosas que ya nos pasaron:

| Síntoma | Causa |
| --- | --- |
| `verificar.sh` falla en `web01 -> Loki` | Corriste muy pronto. Loki devuelve 503 los primeros segundos; esperá los dos minutos |
| El frontend de Zabbix no carga | PostgreSQL todavía está importando el esquema. Es normal en el primer arranque |
| `cannot find requested PSK identity` en los logs | No es un error. El agente ya intenta conectarse, pero el host no existe en Zabbix hasta que lo creás a mano |

Para empezar de cero, **borrando los datos de Zabbix, Grafana y Loki**:

```
docker compose down -v
docker compose up -d --build
```

Si el problema parece de red, confirmá que no haya vuelto el choque de subredes:

```
ip route get 192.168.56.21
```

Tiene que salir por el puente de Docker, que en este proyecto se llama **`br-lab`**. Si dice `dev enp0s8`, el host-only quedó en la subred equivocada: volvé al paso 2.

## Qué falta después

Levantar el stack es la mitad fácil. Lo que viene es todo configuración por pantalla en Zabbix, y está detallado en **`EVIDENCIAS-Y-PENDIENTES.md`**, en esta misma carpeta, con qué captura pide cada recuadro de la propuesta.

El orden que conviene:

1. **Notificaciones** (Telegram o correo). Primero que nada: hoy **no están implementadas**, la letra las exige, y la tabla de resultados pide la hora de la notificación de cada prueba. Si las dejás para el final hay que repetir las siete pruebas.
2. **Crear el host `web01`** con la interfaz de agente y PSK, la interfaz SNMPv3, los templates y las macros.
3. **Escenario web y triggers**, con las dependencias entre ellos.
4. **Fuente de datos Zabbix en Grafana** y el dashboard de alarmas.
4b. **Monitoreo por contenedor y del propio monitoreo**, siguiendo `zabbix/README.md`: template del contenedor en `web01`, host `mon-agent`, salud de Zabbix server, heartbeat y el ajuste de la acción de notificación.
5. **Quince minutos de línea base** antes de cargar nada.
6. **Las pruebas P1 a P6** con sus capturas.

Una trampa que cuesta cara: al crear el host hay que agregar `overlay` a la macro `{$VFS.FS.FSTYPE.MATCHES}` y poner `{$VFS.FS.FSNAME.MATCHES}` en `^/$`. Dentro de un contenedor el sistema de archivos raíz es de tipo `overlay`, que el template excluye por defecto, y **sin ese ajuste la métrica de almacenamiento queda vacía sin que nada avise**. Es uno de los parámetros que pide la letra.

El documento también lista cinco correcciones al `.docx` de la propuesta, que quedó desactualizado: sigue hablando de HTTPS y nombra un ítem de RAM que no existe en Zabbix 7.0.
