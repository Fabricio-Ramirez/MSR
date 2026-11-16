# Obligatorio Monitoreo y Supervisión de Redes en Docker sobre una VM de VirtualBox

Implementa la arquitectura de contenedores dentro de **una VM Ubuntu nueva**. No usa la VM del curso ni Docker en Windows.

## Los tres documentos

Todo lo que hace falta está en esta carpeta, que es lo que se versiona:

| Archivo | Para qué |
|---|---|
| **`README.md`** | Qué es el proyecto, cómo está armado, cómo se accede y los problemas que aparecieron, con su causa raíz |
| **`PUESTA-EN-MARCHA.md`** | El paso a paso de cero: crear la VM, la red de VirtualBox, instalar Docker, levantar el stack y abrir las IP de la documentación |

## Inicio rápido

Con la VM y Docker ya preparados (pasos 1 a 4 de `PUESTA-EN-MARCHA.md`):

```bash
git clone <url-del-repositorio> obligatorio-docker
cd obligatorio-docker
sh scripts/iniciar.sh
```

Al terminar muestra por pantalla cómo entrar a la tienda, a Zabbix y a Grafana, con usuario
y contraseña.

| Script | Qué hace |
|---|---|
| `sh scripts/iniciar.sh` | Todo: genera claves, construye, arranca, espera y muestra los accesos |
| `sh scripts/credenciales.sh` | Vuelve a mostrar direcciones, usuarios y contraseñas, y dice si siguen vigentes |
| `sh scripts/verificar.sh` | 34 comprobaciones del laboratorio completo |
| `sh scripts/pruebas.sh <p1..p6>` | Las pruebas de carga de la propuesta |
| `sudo sh scripts/puente-lab.sh` | Opcional: abre las IP `192.168.56.x` desde Windows (apartado 4) |
| `sh scripts/init.sh` | Solo genera `.env` y la PSK; lo llama `iniciar.sh` |

**Las contraseñas no están en el repositorio.** Se generan al azar en cada instalación y
quedan en `.env` y `secrets/`, que figuran en `.gitignore`. Clonar el proyecto en otra
máquina da claves nuevas.

## Arquitectura

Igual que la propuesta reducida: una sola red plana, sin router, sin firewall,
sin base de datos de la tienda y sin PC de usuarios.

```text
              Windows (navegador)
                     |
   VirtualBox: redirects NAT (localhost:844x)
   + host-only  192.168.57.1 <--> 192.168.57.10
                     |
  VM Ubuntu 26.04 + Docker          <-- hace de "host" de la propuesta:
  |                                     abre los paneles y genera la carga HTTP
  |  red lab 192.168.56.0/24
  |  gateway .254 (puente de Docker) ---- Internet (Telegram, SMTP)
  |        |
  |     web01 .10                 zabbix-server .20  (mon01)
  |     Nginx HTTP :80            zabbix-web    .21  :8080
  |     Zabbix agent 2 (PSK)      zabbix-db     .22
  |     snmpd v3 (authPriv)       grafana       .23  :3000
  |     Alloy                     loki          .24  :3100
```

`mon01` se reparte en contenedores, uno por servicio; `zabbix-server` conserva la IP
`192.168.56.20` de la propuesta.

### Direcciones fijas

Son las de la tabla de la documentación y están declaradas una por una en `compose.yaml`,
con `ipv4_address` dentro de la red `lab`. No dependen del orden de arranque ni cambian
al recrear los contenedores.

| Contenedor | IP interna |
|---|---|
| `web01` | `192.168.56.10` |
| `zabbix-server` | `192.168.56.20` |
| `zabbix-web` | `192.168.56.21` |
| `zabbix-db` | `192.168.56.22` |
| `grafana` | `192.168.56.23` |
| `loki` | `192.168.56.24` |

`scripts/verificar.sh` comprueba las seis contra esta tabla: si alguna no coincide,
el escenario web, la interfaz SNMP y las fuentes de datos de Grafana quedan apuntando al
lugar equivocado, y es mejor enterarse ahí que tres pantallas después.

El puente de Docker se llama **`br-lab`**, con nombre fijo en vez del `br-<id>` que Docker
genera solo. Sirve para los `tcpdump` de la evidencia de SNMPv3 y para las reglas de
`scripts/acceso-lan.sh`, que así no hay que rehacer cada vez que se recrea la red.

| Contenedor | Contenido |
|---|---|
| `web01` | Nginx, Zabbix agent 2 con TLS-PSK, `snmpd` v3 authPriv, Alloy, `stress-ng` |
| `zabbix-server`, `zabbix-web`, `zabbix-db` | Zabbix 7.0 y su base PostgreSQL |
| `grafana`, `loki` | Consulta y almacenamiento de logs |

## 1. Crear la VM en VirtualBox

- **Sistema:** Ubuntu Server 26.04.1 LTS (`resolute`), con OpenSSH instalado. En este
  laboratorio el host es `srvmonitoreo` y el usuario es `monitoreo`.
- **Recursos:** esta VM tiene **2 vCPU, 4 GB de RAM y 98 GB de disco** (86 GB libres).
  Son los mínimos razonables: con 4 vCPU y 6 GB las pruebas de carga interferirían menos
  con el monitoreo. Anotalo al analizar la prueba P4.
- **Red:** **adaptador 1 en NAT** con estas reglas de reenvío de puertos:

| Servicio | Puerto en Windows | Puerto en la VM |
|---|---|---|
| SSH | 2223 | 22 |
| Tienda | 8444 | 80 |
| Zabbix | 8443 | 8080 |
| Grafana | 3000 | 3000 |

Los puertos del lado Windows se mantuvieron aunque ya no haya TLS, para no cambiar las
URLs; lo único que cambió es el esquema, que ahora es `http://`.

Elegí 2223 porque el 2222 ya lo usa la VM del curso. Ojo: esa VM (`lab-monitoreo 1`)
también reenvía el 2223, pero hacia su Zabbix, así que no conviene tener las dos
encendidas a la vez.

Y **adaptador 2 en host-only**, que da acceso directo por IP sin pasar por los redirects:

| Elemento | Valor |
|---|---|
| Adaptador host-only en Windows | `192.168.57.1/24` |
| Servidor DHCP de VirtualBox | deshabilitado |
| `enp0s8` en la VM | `192.168.57.10/24` fija, **sin gateway** |

> **La subred del host-only no puede ser `192.168.56.0/24`**, porque ésa es la de la red
> `lab` de Docker. Si coinciden, la VM queda con dos rutas de enlace para el mismo `/24`
> y su tráfico hacia los contenedores sale por `enp0s8` en vez del puente: eso rompe las
> tres primeras comprobaciones de `scripts/verificar.sh` y el `ab` de la prueba P4. Por
> eso el host-only va en `192.168.57.0/24`.

El adaptador 2 es opcional, porque todo se puede hacer por los redirects del NAT, y no
altera la ruta por defecto: ésa sigue saliendo por el NAT (`enp0s3`), ya que la dirección
fija se configura sin gateway. El esquema de dos adaptadores de la §4.1 de la propuesta
corresponde a la variante de dos VM; acá el puente de Docker cumple el papel de la red de
monitoreo y el NAT de VirtualBox da la salida a Internet.

La dirección fija está en `/etc/netplan/99-hostonly.yaml`:

```yaml
network:
  version: 2
  ethernets:
    enp0s8:
      dhcp4: false
      dhcp6: false
      addresses: [192.168.57.10/24]
```

Los comandos que dejaron esto armado, desde PowerShell en Windows:

```powershell
VBoxManage modifyvm "OBG-Monitoreo" --natpf1 "SSH,tcp,,2223,,22"
VBoxManage modifyvm "OBG-Monitoreo" --natpf1 "Tienda,tcp,,8444,,80"
VBoxManage modifyvm "OBG-Monitoreo" --natpf1 "Zabbix,tcp,,8443,,8080"
VBoxManage modifyvm "OBG-Monitoreo" --natpf1 "Grafana,tcp,,3000,,3000"
VBoxManage hostonlyif ipconfig "VirtualBox Host-Only Ethernet Adapter" --ip 192.168.57.1 --netmask 255.255.255.0
VBoxManage dhcpserver modify --network="HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter" --disable
```

`192.168.57.0/24` entra en el rango que VirtualBox permite por defecto para las redes
host-only (`192.168.56.0/21`), así que no hay que tocar `networks.conf`.

## 2. Instalar Docker en la VM

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
sudo timedatectl set-timezone America/Montevideo
sudo apt install -y chrony apache2-utils
```

`apache2-utils` trae `ab`, que la prueba P4 ejecuta desde la VM.
Cerrá la sesión y volvé a entrar para que aplique el grupo `docker`.

El repositorio de Docker ya publica para `resolute` (26.04), así que el script de
`get.docker.com` sirve. Si alguna vez no estuviera disponible, el respaldo son los
paquetes de Ubuntu: `sudo apt install -y docker.io docker-compose-v2`.

## 3. Copiar y levantar el proyecto

Desde PowerShell, en Windows:

```powershell
ssh -p 2223 monitoreo@127.0.0.1 "rm -rf ~/obligatorio-docker"
scp -P 2223 -r "$HOME\Desktop\Monitoreo y Sup\Obligatorio\obligatorio-docker" monitoreo@127.0.0.1:~/
```

El `rm -rf` importa: `scp -r` fusiona con lo que ya exista y, si copiaste la versión
anterior, te dejaría las carpetas `router/` y `pc/` que este proyecto ya no usa.

Usá `127.0.0.1` y no `localhost`: son entradas distintas en `known_hosts`, y si la clave
del host no está aceptada todavía, un comando con pipe falla sin poder preguntarte. Por el
host-only la copia es más corta, sin `-P`:

```powershell
scp -r "$HOME\Desktop\Monitoreo y Sup\Obligatorio\obligatorio-docker" monitoreo@192.168.57.10:~/
```

En la VM:

```bash
cd ~/obligatorio-docker
sh scripts/iniciar.sh
```

`iniciar.sh` genera las claves si faltan, construye y arranca los seis contenedores, espera
a que Zabbix y Grafana respondan y **muestra por pantalla la dirección, el usuario y la
contraseña de cada servicio**. Es idempotente. Dos minutos después, la comprobación:

```bash
sh scripts/verificar.sh
```

La primera construcción descarga varias imágenes y puede demorar bastante.

> **Si ya habías levantado una versión anterior en esta VM**, borrá el estado antes de
> empezar: `docker compose down -v && rm -rf certs secrets .env`. `init.sh` no sobrescribe
> lo que ya existe, y el directorio `certs/` de la versión con TLS ya no se usa.

## 4. Acceder

| Servicio | Por el NAT | Por el host-only | Por la IP de la documentación | Usuario |
|---|---|---|---|---|
| Tienda | `http://localhost:8444` | `http://192.168.57.10` | `http://192.168.56.10` | |
| Zabbix | `http://localhost:8443` | `http://192.168.57.10:8080` | `http://192.168.56.21:8080` | `Admin` / `zabbix`: cambiá la contraseña al entrar |
| Grafana | `http://localhost:3000` | `http://192.168.57.10:3000` | `http://192.168.56.23:3000` | `admin` / la muestra `sh scripts/credenciales.sh` |

Por el host-only se usan los puertos reales del contenedor: la tienda es el 80 y Zabbix el
8080. Los `8444` y `8443` existen solo en las reglas de reenvío del NAT.

Sin TLS no hay advertencias del navegador ni certificados que importar.

### Abrir las IP de la documentación desde Windows

> **Es un paso manual y opcional, fuera del despliegue.** No lo hace `docker compose up` ni
> `scripts/init.sh`: toca la configuración de VirtualBox y la red de la VM, así que pide
> **la VM apagada**, **PowerShell como administrador** y **contraseña de `sudo`**. Sin él el
> laboratorio funciona entero y las 34 comprobaciones de `verificar.sh` pasan igual; lo
> único que agrega es poder abrir esas IP **desde el navegador de Windows**.
>
> **Aplicado y verificado el 16/11/2026** con la opción A. Las seis direcciones responden
> desde Windows y la ruta a `192.168.56.0/24` figura con `NextHop 0.0.0.0`, es decir
> directamente conectada: no hay enrutamiento ni reglas de firewall en juego.
>
> **Lo que configures acá no viaja en el repositorio**: el adaptador de VirtualBox vive en
> la configuración de la VM y las unidades de systemd viven en `/etc` de la VM. Lo que sí
> está versionado son los scripts que lo rehacen, así que en una máquina nueva hay que
> repetir este apartado.

La tercera columna de la tabla de arriba no funciona recién instalado: `192.168.56.0/24` es
el puente `br-lab`, interno de la VM, y Windows no sabe llegar.

Hay dos formas de resolverlo y **se excluyen entre sí**. La recomendada es la primera.

#### Opción A (recomendada): meter a Windows dentro de la red del laboratorio

En vez de enrutar desde Windows hacia la red de Docker, se pone a Windows **adentro** de
esa red. Se le agrega a la VM un tercer adaptador, en host-only, y ese adaptador pasa a ser
un puerto más del puente `br-lab`, igual que los `veth` de los contenedores. Windows queda
en `192.168.56.1`, en el mismo segmento de capa 2 que los seis contenedores.

```text
  Windows  192.168.56.1  (adaptador host-only #2)
        |
        |  capa 2, sin enrutamiento
        |
  VM: enp0s9 (sin IP) --- puerto del puente ---> br-lab 192.168.56.254
                                                   |
                      web01 .10   zabbix-server .20   zabbix-web .21
                      zabbix-db .22   grafana .23   loki .24
```

Lo que lo hace limpio: **no hace falta ninguna regla de firewall**. El tráfico puenteado no
pasa por `netfilter` mientras el módulo `br_netfilter` no esté cargado, y en esta VM no lo
está ni hay nada que lo cargue (`lsmod | grep br_netfilter` no devuelve nada). Tampoco hay
ruta que agregar en Windows: la red le queda directamente conectada.

De yapa, **Windows pasa a ser el "PC de usuarios" que la propuesta ubica en
`192.168.56.1`**, así que desaparece una de las diferencias de la tabla del final.

**Paso 1, en VirtualBox, con la VM apagada.** PowerShell **como administrador**:

```powershell
VBoxManage hostonlyif create
VBoxManage list hostonlyifs          # confirmá el nombre que te creó
VBoxManage hostonlyif ipconfig "VirtualBox Host-Only Ethernet Adapter #2" --ip 192.168.56.1 --netmask 255.255.255.0
VBoxManage dhcpserver modify --network="HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter #2" --disable
VBoxManage modifyvm "OBG-Monitoreo" --nic3 hostonly --host-only-adapter3 "VirtualBox Host-Only Ethernet Adapter #2"
VBoxManage modifyvm "OBG-Monitoreo" --nicpromisc3 allow-all
```

Tres detalles que no son opcionales:

- **El DHCP de VirtualBox tiene que quedar deshabilitado** en ese adaptador. Si reparte
  direcciones en `192.168.56.0/24` puede pisar las seis IP fijas. Si el comando dice que no
  existe ese servidor DHCP, mejor: no hay nada que deshabilitar.
- **`--nicpromisc3 allow-all` es obligatorio.** Las tramas que vuelven de los contenedores
  llevan la MAC del contenedor, no la de la NIC de la VM; sin modo promiscuo VirtualBox las
  descarta y no anda nada.
- **La VM tiene que estar apagada.** Usa el chipset PIIX3, que no admite agregar NIC en
  caliente.

`192.168.56.0/24` entra en el rango que VirtualBox permite por defecto para host-only
(`192.168.56.0/21`), así que no hay que tocar `networks.conf`.

**Paso 2, dentro de la VM**, con el stack levantado:

```bash
scripts/puente-lab.sh --estado   # diagnóstico, no necesita root
sudo scripts/puente-lab.sh
```

El script detecta la interfaz nueva —la única NIC física **sin dirección IPv4**—, la mete en
`br-lab` y deja `puente-lab.service` y `puente-lab.timer`. El timer importa: `docker compose
down` borra el puente y `up` lo crea de nuevo, y en ese momento la interfaz queda suelta; el
timer la vuelve a enganchar en menos de un minuto. Se revierte con `--quitar`.

Se planta y no hace nada si la interfaz que le pasás tiene una IP, para no dejarte sin
acceso a la VM metiendo `enp0s8` en un puente por error.

**Si alguna vez se carga `br_netfilter`** —no lo hace nadie hoy, pero una actualización
podría—, el tráfico puenteado empezaría a pasar por `iptables`. Está cubierto: las reglas
`ACCEPT` que dejó `scripts/acceso-lan.sh` en `DOCKER-USER` siguen instaladas y lo permiten.

### La página de la tienda

`web01/www/index.html` sirve un catálogo con carrito, para que las capturas de la entrega
muestren un sitio real y no un `<h1>` suelto. El carrito usa `localStorage`, así que el
número sobrevive al refresco.

Tiene un **panel técnico oculto**. Se abre con el código Konami (↑ ↑ ↓ ↓ ← → ← → B A) o con
diez clics en el logo, y se cierra con `Esc`. Adentro hay enlaces a Zabbix y Grafana, y
botones que **disparan las pruebas de carga en vivo**, pensados para la defensa: hacés clic
y el pico se ve en Zabbix mientras hablás.

| Botón | Equivale a |
|---|---|
| CPU 95% · 10 min | `pruebas.sh p1` |
| RAM 92% · 10 min | `pruebas.sh p2` |
| Disco 85% | `pruebas.sh p3 85` |
| Limpiar disco | `pruebas.sh p3-limpiar` |
| Detener | mata el `stress-ng` en curso |
| 50 errores 500 | `pruebas.sh p6` |

Debajo hay una línea de estado que se refresca cada 5 segundos con la prueba en curso, los
segundos transcurridos y el uso de disco.

**Cómo funciona.** Nginx no puede ejecutar procesos, así que el contenedor suma `fcgiwrap`
(un proceso más en `supervisord`) y nginx expone `location = /api/carga`, atendido por
`web01/cgi-bin/carga.sh`. Ese script **no recibe ningún parámetro del navegador**: elige
entre acciones fijas con un `case`, por lo que no hay forma de inyectar comandos. Corre
como `www-data`, igual que los workers de nginx, nunca como root.

> Que la carga salga del propio servidor monitoreado es cómodo para demostrar, pero
> **para las mediciones de la entrega usá `scripts/pruebas.sh`**, que es lo que documenta
> la propuesta. Los botones son para la defensa, no para la tabla de resultados.

`verificar.sh` cubre todo esto con cinco comprobaciones: que la página servida sea el
catálogo y no un index por defecto, que el panel oculto siga embebido, que `/error500`
devuelva 500 y no 404, que `/api/carga` responda, y —la más valiosa— que **un error 500
recién generado aparezca consultando Loki**, que recorre la cadena completa
nginx → Alloy → Loki.

## 5. Configurar Zabbix

Seguí desde la sección 4.4 de la propuesta (parte del frontend) hasta la 4.9, con estos datos:

| Dato | Valor |
|---|---|
| Interfaz de agente | `192.168.56.10:10050` |
| PSK | Identidad `PSK-web01`; valor con `cat secrets/web01.psk` |
| Interfaz SNMPv3 | `192.168.56.10:161`, usuario `zbxv3`, authPriv, SHA1 y AES128; claves `SNMP_AUTH` y `SNMP_PRIV` de `.env` |
| Escenario web | Un paso a `http://192.168.56.10/`, código esperado `200`. Sin TLS no hay que tocar "SSL verify peer" |
| Notificaciones | **Pendiente, y la letra lo exige.** Hay que crear la acción de trigger (Telegram por webhook o correo SMTP). Ver abajo |

**Ajuste necesario para el disco:** dentro del contenedor, `/` es de tipo `overlay`, que
el descubrimiento del template puede excluir. En las macros de `web01`, agregá `overlay`
a `{$VFS.FS.FSTYPE.MATCHES}` y usá `{$VFS.FS.FSNAME.MATCHES}` = `^/$`. Verificá los
nombres en la pestaña de macros heredadas.

En Grafana, la fuente de datos Loki y el plugin de Zabbix ya quedan cargados. Falta crear
la fuente Zabbix con URL `http://192.168.56.21:8080/api_jsonrpc.php` y un token de API.

> Esa URL la resuelve el **backend** de Grafana, que está en esa misma red: desde Grafana 9
> no existe el modo "Browser / Direct access", todas las consultas salen del servidor. Es
> decir que funciona aunque tu navegador no llegue a `192.168.56.0/24`. Si corriste
> `scripts/acceso-lan.sh` y la ruta de Windows, además la podés abrir vos para comprobarla.

**Falta implementar las notificaciones.** La letra pide: *"El sistema debe enviar
notificaciones por algún medio frente a eventos anormales (vía mail, chat, una aplicación,
etc.)"*. Hoy el proyecto no configura ni Telegram ni SMTP; `verificar.sh` solo comprueba
que `zabbix-server` llegue a `api.telegram.org`. Es un paso de frontend (Alerts › Media
types › Actions) y entra en los 20 puntos de implementación, así que no lo dejes para el
final.

## 6. Pruebas de carga

```bash
scripts/pruebas.sh        # lista las pruebas
scripts/pruebas.sh p1     # CPU
scripts/pruebas.sh p2     # RAM
scripts/pruebas.sh p3 85  # disco; después: p3 92 y p3-limpiar
scripts/pruebas.sh p4     # carga HTTP, desde la VM
```

Cada prueba imprime la hora de inicio y de fin para completar la tabla 7.

## Diferencias con la propuesta

| Propuesta | Esta implementación | Consecuencia |
|---|---|---|
| `web01` y `mon01` son VM separadas | Contenedores en una sola VM | Si la VM cae, cae todo; esto debilita el argumento de separación de funciones |
| CPU, RAM y disco de `web01` | El agente lee los valores **de toda la VM** | `stress-ng` también afecta a Zabbix y las métricas incluyen a todos los contenedores |
| La carga HTTP sale del host Windows | Sale de la VM, con `ab` | La VM comparte CPU con todo el laboratorio; anotalo al analizar P4 |
| `systemctl stop nginx` | `supervisorctl stop nginx` (`pruebas.sh p5a`) | Sin efecto en lo que se mide |
| `chrony` en cada equipo | `chrony` solo en la VM | Los contenedores usan el reloj de la VM |
| Frontend de Zabbix en `mon01:443` | `zabbix-web` en `192.168.56.21:8080`, sin TLS | El 443 lo usaba la tienda; además se quitaron los certificados |
| Loki en `mon01:3100` | `loki` en `192.168.56.24:3100` | Solo cambia la IP |
| HTTPS en la tienda, el frontend, Grafana y Loki, con una CA propia | **Todo en HTTP.** El cifrado queda en SNMPv3 authPriv y la TLS-PSK del agente | Decisión consciente: la letra pide cifrar "siempre que sea posible" y nombra SNMPv3 como ejemplo, pero no exige TLS. Se quitó la CA propia, los dos certificados y el `dhparam`, que agregaban trabajo (importar la CA, "SSL verify peer", `openssl dhparam`) sin sumar puntos. **Mencionalo en la defensa como una decisión, no como un olvido** |
| Host de usuarios en `192.168.56.1` | Con la opción A del apartado 4, **Windows es ese host**: queda en `192.168.56.1`, sobre el mismo segmento que los contenedores. Sin ella, se entra por `localhost:844x` o por `192.168.57.10` | La diferencia desaparece si se aplica la opción A |
| Dos adaptadores por VM, NAT + host-only en `192.168.56.0/24` | NAT + host-only en `192.168.57.0/24`; la red de monitoreo es el puente de Docker, en `192.168.56.0/24` | El host-only tuvo que cambiar de subred para no chocar con la de Docker; para los contenedores no cambia nada |
| Desconectar la interfaz de la VM (P5b) | `ip link set eth0 down` en `web01` | Equivalente para este escenario |

En P2, si el sistema queda sin memoria, se prioriza terminar `web01` y no Zabbix
(`oom_score_adj`). Revisá `dmesg` después de la prueba.

## Problemas encontrados al levantarlo

**1. `zabbix-server` en bucle de reinicios.** `RestartCount=10`, `ExitCode=1`, y el log
repetía `su-exec: : No such file or directory` con el nombre del programa vacío.
`arranque.sh` hacía `exec su-exec zabbix "$(command -v tini)" -- ...`, pero la imagen
`zabbix/zabbix-server-pgsql:alpine-7.0-latest` **no trae `tini`**, así que la sustitución
quedaba vacía y `su-exec` intentaba ejecutar una cadena vacía. Se agregó `tini` al
`apk add` del Dockerfile, y `arranque.sh` ahora arranca sin él si faltara en vez de pasar
un argumento vacío. Con eso el contenedor queda `Up` con `RestartCount=0`.

**2. `verificar.sh` se colgaba en la comprobación de Internet.** `api.telegram.org`
resuelve **solo a IPv6** y los contenedores no tienen ruta IPv6, así que el `curl` sin
`-m` esperaba muchísimo antes de caer a IPv4. **Resuelto**: todos los `curl` del script
llevan ahora un límite de tiempo (`-m 10`, y `-m 15` en el de Telegram).

**2b. La CA propia era rechazada por clientes estrictos.** `init.sh` generaba la CA con
`openssl req -x509` sin `-addext keyUsage`, y el OpenSSL de Python 3.14 la rechazaba con
`CA cert does not include key usage extension`. `curl`, Zabbix y Grafana sí la aceptaban.
Quedó sin efecto al pasar todo a HTTP, pero **sirve igual para la sección 7**: muestra que
una CA que "funciona" puede fallar contra un cliente más estricto.

**3. El `/ready` de Loki devuelve 503 al principio.** Si corrés `verificar.sh` demasiado
pronto, la comprobación `web01 -> Loki` falla aunque todo esté bien. Respetá el margen de
dos minutos del paso 3.

**4. `cannot find requested PSK identity "PSK-web01"` en el log de `zabbix-server`.** No es
un error: el agente de `web01` ya intenta conectarse con PSK, pero el server no conoce esa
identidad hasta que creás el host en el frontend (paso 5). Desaparece al configurarlo.

**5. La propuesta nombra un ítem que no existe en Zabbix 7.0.** La Tabla 1 de
`Obligatorio_MSR_2026_Propuesta_Solucion_Reducida.docx` dice que la RAM se mide con
`vm.memory.utilization`. En el template "Linux by Zabbix agent" de 7.0 la clave real es
**`vm.memory.util`**; `vm.memory.utilization` no existe y el ítem nunca aparece.
**Corregilo en el documento de la entrega** antes de presentarlo.

**6. El descubrimiento de filesystems no ve `/` dentro del contenedor.** El template
excluye el tipo `overlay`, que es justamente el de `/` en Docker, así que no se descubre
ningún filesystem y la métrica de almacenamiento queda vacía. Se resuelve con las dos
macros del paso 5. Verificado: con el ajuste aparecen `vfs.fs.dependent.size[/,*]`.

**7. `fcgiwrap` quedaba FATAL en el segundo arranque y `/api/carga` dejaba de
responder.** Detectado el 16/11/2026 al reiniciar la VM. `supervisorctl status` mostraba
`fcgiwrap FATAL Exited too quickly`; los otros cuatro procesos estaban `RUNNING`. La causa:
**en Docker `/run` no es `tmpfs`**, a diferencia de un sistema con systemd, así que el
socket `/run/fcgiwrap/fcgiwrap.sock` del arranque anterior seguía en la capa de escritura
del contenedor. `fcgiwrap` no puede ponerse a escuchar sobre un archivo que ya existe,
se caía al instante y supervisord lo daba por perdido. **Resuelto**: `entrypoint.sh` borra
el socket con `rm -f` antes de que arranque supervisord.

Importa más de lo que parece: `/api/carga` es lo que alimenta los botones del panel técnico
de la tienda, los de la defensa en vivo. El laboratorio arrancaba bien la primera vez y se
rompía en silencio después de cualquier reinicio.

**8. SNMPv3 devolvía `authorizationError` después de reiniciar el contenedor.** Mismo día,
misma causa de fondo: código que sólo es correcto en el primer arranque. `snmpget -v3`
contestaba `Reason: authorizationError (access denied to that object)`, que **no es un
fallo de autenticación** —las passphrases estaban bien y el usuario seguía en la base USM
persistente—, sino de control de acceso: faltaba la línea `rouser`.

El porqué: `entrypoint.sh` reescribía `/etc/snmp/snmpd.conf` entero en cada arranque, y
quien agregaba el `rouser` era `net-snmp-create-v3-user`, que corre **una sola vez**,
protegido por el testigo `/var/lib/snmp/.usuario-creado`. Primer arranque: se escribe el
archivo, se crea el usuario, se agrega el `rouser`, todo anda. Segundo arranque: se
reescribe el archivo —y se borra el `rouser`—, el usuario ya existe así que el bloque no
corre, y nadie lo vuelve a poner.

**Resuelto**: la línea `rouser zbxv3 priv` está ahora explícita en el archivo que escribe
`entrypoint.sh`, y el bloque que crea el usuario se movió **antes**, para que la versión
nuestra sea la última en escribirse. De paso quedó más estricto: `net-snmp-create-v3-user`
dejaba `rouser zbxv3` sin nivel, con lo que alcanzaba `authNoPriv`; con `priv` se exige
cifrado. Verificado: `authPriv` responde el `sysUpTime` y `authNoPriv` es rechazado.

> **Los problemas 7 y 8 son los mejores candidatos para la §7 de la entrega.** Tienen causa
> raíz demostrable, síntoma reproducible y arreglo verificado, y los dos ilustran la misma
> lección: *algo que funciona en el primer despliegue no está probado hasta que sobrevive a
> un reinicio*. Se reproducen con `docker stop web01 && docker start web01`.

**9. La comprobación de Loki era inestable, y el sistema estaba bien.** `verificar.sh`
alternaba entre 30, 31, 33 y 34 correctas sobre un laboratorio que no cambiaba. La
comprobación generaba un error 500, esperaba **8 segundos fijos** y consultaba Loki. Pero
Alloy agrupa los envíos y redescubre los archivos cada 10 s, así que a veces llegaba a
tiempo y a veces no.

Lo que lo aclaró fue el log del propio Loki, que informa las métricas de cada consulta:

```
query="{job=\"nginx\"} |= \"error500\"" ... post_filter_lines=13 total_entries=13
```

Trece líneas almacenadas y encontradas: los datos estaban y la consulta era correcta. Los
relojes de la VM, `loki` y `web01` también coincidían, así que tampoco era desfasaje
horario. **Resuelto**: la comprobación consulta en ciclo hasta 40 s y corta apenas aparece
la línea. Y quedó más exigente: marca cada petición con una cadena única, así sólo pasa si
una línea **nueva** recorrió toda la cadena; antes podía pasar encontrando una vieja.


## Si algo falla

```bash
docker compose ps
docker compose logs --tail=50 <servicio>
docker exec web01 supervisorctl status
docker network inspect obligatorio-msr_lab
```

Reiniciar todo desde cero, **borrando los datos de Zabbix, Grafana y Loki**:

```bash
docker compose down -v
docker compose up -d --build
```
