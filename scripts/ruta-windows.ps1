<#
.SYNOPSIS
  Agrega en Windows la ruta hacia la red lab de Docker, para poder abrir las IP
  fijas de la documentacion (192.168.56.10, .20, .21, .22, .23, .24) tal cual.

.DESCRIPTION
  Windows no sabe llegar a 192.168.56.0/24: esa red vive dentro de la VM, detras
  del puente de Docker. Esta ruta persistente la manda por el adaptador host-only,
  a la IP de la VM (192.168.57.10, que hace de router).

  Es la mitad del trabajo. La otra mitad va dentro de la VM, porque Docker descarta
  el trafico que entra desde fuera hacia puertos no publicados:

      sudo scripts/acceso-lan.sh

.PARAMETER VM
  IP de la VM en el host-only. Por defecto 192.168.57.10.

.PARAMETER Quitar
  Borra la ruta en vez de crearla.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\ruta-windows.ps1
#>
[CmdletBinding()]
param(
  [string]$VM = '192.168.57.10',
  [switch]$Quitar
)

$ErrorActionPreference = 'Stop'
$red     = '192.168.56.0'
$mascara = '255.255.255.0'
$prefijo = '192.168.56.0/24'

$esAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $esAdmin) {
  Write-Host "Hay que ejecutarlo en una PowerShell como administrador." -ForegroundColor Red
  Write-Host "Abri PowerShell con boton derecho > Ejecutar como administrador y repeti el comando."
  exit 1
}

if ($Quitar) {
  # Sin redireccion de stderr: en PowerShell 5.1 un 2>$null sobre un .exe con
  # ErrorActionPreference = 'Stop' aborta el script aunque el comando haya ido bien.
  & route.exe delete $red | Out-Null
  Write-Host "Ruta hacia $prefijo eliminada."
  exit 0
}

# La ruta no sirve de nada si el adaptador host-only no esta levantado.
$hostonly = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -like '192.168.57.*' }

if (-not $hostonly) {
  Write-Host "No hay ningun adaptador de Windows en 192.168.57.0/24." -ForegroundColor Red
  Write-Host "Falta el adaptador host-only de VirtualBox. Mira el paso 2 de PUESTA-EN-MARCHA.md:"
  Write-Host '  VBoxManage hostonlyif ipconfig "VirtualBox Host-Only Ethernet Adapter" --ip 192.168.57.1 --netmask 255.255.255.0'
  exit 1
}
Write-Host ("Adaptador host-only: {0} en {1}" -f $hostonly[0].IPAddress, $hostonly[0].InterfaceAlias)

# Un adaptador propio de Windows en 192.168.56.0/24 ganaria sobre esta ruta.
$choque = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -like '192.168.56.*' }
if ($choque) {
  Write-Host ("AVISO: {0} ya tiene {1}. Esa interfaz se queda con la red 192.168.56.0/24 y la ruta no se va a usar." `
    -f $choque[0].InterfaceAlias, $choque[0].IPAddress) -ForegroundColor Yellow
  Write-Host "Casi siempre es otro adaptador host-only de VirtualBox; cambiale la subred o deshabilitalo."
}

if (-not (Test-Connection -ComputerName $VM -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
  Write-Host "AVISO: la VM $VM no responde al ping. Encendela antes de probar." -ForegroundColor Yellow
}

& route.exe delete $red | Out-Null      # por si ya existia, apuntando a otro lado
& route.exe -p add $red mask $mascara $VM | Out-Null
if ($LASTEXITCODE -ne 0) { throw "No se pudo agregar la ruta." }

$r = Get-NetRoute -DestinationPrefix $prefijo -ErrorAction SilentlyContinue
if ($r) {
  Write-Host ("Ruta persistente creada: {0} via {1}" -f $prefijo, $r[0].NextHop) -ForegroundColor Green
} else {
  Write-Host "La ruta se agrego pero no aparece en la tabla; revisa 'route print'." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Comprobacion (necesita el stack levantado y scripts/acceso-lan.sh corrido en la VM):"
foreach ($p in @(
    @{ n = 'tienda  '; d = '192.168.56.10'; t = 80 },
    @{ n = 'Zabbix  '; d = '192.168.56.21'; t = 8080 },
    @{ n = 'Grafana '; d = '192.168.56.23'; t = 3000 })) {
  $ok = Test-NetConnection -ComputerName $p.d -Port $p.t -InformationLevel Quiet -WarningAction SilentlyContinue
  $estado = if ($ok) { 'OK   ' } else { 'FALLO' }
  $color  = if ($ok) { 'Green' } else { 'Red' }
  Write-Host ("  {0} {1} http://{2}:{3}" -f $estado, $p.n, $p.d, $p.t) -ForegroundColor $color
}
