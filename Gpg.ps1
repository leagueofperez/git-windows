<#
.SYNOPSIS
    Importa las claves GPG y escribe la configuracion de firma en el home de GnuPG.

.DESCRIPTION
    Sustituye a gpg.sh. Portabilidad a Windows:
      - $HOME/.gnupg -> el home real que declara GnuPG (gpgconf --list-dirs homedir),
        con %APPDATA%\gnupg como alternativa.
      - chmod 700 / 600 -> icacls. El glob sin comillas del bash sobre .gnupg/* fallaba
        cuando el directorio estaba vacio; aqui se resuelve con icacls /T.
      - keychain -q --eval -> llamada exclusiva de macOS, se elimina.
      - gpgconf --kill gpg-agent se mantiene.

.PARAMETER Force
    Omite la confirmacion. Lo usa Full.ps1 cuando el usuario ya ha confirmado.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Gpg.ps1
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

. (Join-Path $PSScriptRoot 'Lib.ps1')

function Get-GpgSettingMap {
    <#
    .SYNOPSIS
        Ajustes de gpg.conf y gpg-agent.conf.
    .PARAMETER GpgHome
        Home de GnuPG.
    .PARAMETER PinentryMode
        Modo de pinentry a forzar. Vacio significa "no escribir ninguno", que es
        lo correcto para firmar commits de forma interactiva.
    .OUTPUTS
        Tabla hash ordenada: ruta de archivo -> hashtable con Lines y Obsolete.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $GpgHome,
        [string] $PinentryMode
    )

    # pinentry-mode loopback NO debe ir en un gpg.conf global: en ese modo gpg no
    # lanza pinentry y espera la contrasena por la entrada estandar, que git no
    # envia. El resultado es que cualquier "git commit -S" falla con
    # "gpg: cannot open 'no tty'". Solo tiene sentido aplicarlo en la linea de
    # comandos de una operacion por lotes.
    $gpgLines = @('keyid-format LONG', 'use-agent')
    if (-not [string]::IsNullOrWhiteSpace($PinentryMode)) {
        $gpgLines += "pinentry-mode $PinentryMode"
    }

    return [ordered]@{
        (Join-Path $GpgHome 'gpg-agent.conf') = @{
            Lines = @(
                'default-cache-ttl 34560000'
                'max-cache-ttl 34560000'
                'default-cache-ttl-ssh 34560000'
                'max-cache-ttl-ssh 34560000'
                'allow-preset-passphrase'
                'allow-loopback-pinentry'
            )
            Obsolete = @()
        }
        (Join-Path $GpgHome 'gpg.conf') = @{
            Lines    = $gpgLines
            Obsolete = @('pinentry-mode loopback')
        }
    }
}

function Stop-GpgAgent {
    <#
    .SYNOPSIS
        Detiene gpg-agent y los procesos auxiliares que lo acompanan.
    .DESCRIPTION
        "gpgconf --kill gpg-agent" solo baja el agente. keyboxd y scdaemon
        sobreviven a esa llamada y siguen con los ficheros del home abiertos, de
        modo que el directorio no se puede mover mientras sigan activos.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $GpgHome,
        [Parameter(Mandatory = $true)][string] $Gpgconf
    )

    [void](Invoke-Native -FilePath $Gpgconf -Arguments @('--homedir', $GpgHome, '--kill', 'gpg-agent'))

    foreach ($name in @('gpg-agent', 'keyboxd', 'scdaemon')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
            }
            catch {
                Write-Warning ("No se pudo detener {0} (PID {1})" -f $process.ProcessName, $process.Id)
            }
        }
    }

    # Los handles tardan un instante en liberarse tras matar el proceso
    Start-Sleep -Milliseconds 400
}

function Start-GpgAgent {
    <#
    .SYNOPSIS
        Deja un gpg-agent vivo para el home indicado y devuelve si su socket responde.
    .DESCRIPTION
        El script termina matando el agente para que relea gpg-agent.conf. En la
        ejecucion siguiente gpg da por hecho que el agente se levanta solo al
        importar la clave privada, pero si el socket se quedo de una ejecucion
        anterior "gpgconf --launch" no hace nada y la importacion falla con
        "error enviando al agente: No such file or directory".

        Por eso se mata primero (para retirar sockets obsoletos) y luego se lanza.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory = $true)][string] $GpgHome,
        [Parameter(Mandatory = $true)][string] $Gpgconf
    )

    # El kill ignora su resultado: si no habia agente, no hay nada que limpiar.
    [void](Invoke-Native -FilePath $Gpgconf -Arguments @('--homedir', $GpgHome, '--kill', 'gpg-agent'))
    $launch = Invoke-Native -FilePath $Gpgconf -Arguments @('--homedir', $GpgHome, '--launch', 'gpg-agent')
    if ($launch.ExitCode -ne 0) {
        Write-Warning ("No se pudo arrancar gpg-agent: " + ($launch.Output -join ' '))
        return $false
    }

    $socket = @((Invoke-Native -FilePath $Gpgconf -Arguments @('--list-dirs', 'agent-socket')).Output |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    return [bool]($socket | Where-Object { Test-Path -LiteralPath $_ })
}

function Invoke-GpgImport {
    <#
    .SYNOPSIS
        Importa un fichero de claves, reintentando una vez si el agente no responde.
    .OUTPUTS
        [pscustomobject] con ExitCode y Output de gpg.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Gpg,
        [Parameter(Mandatory = $true)][string] $Gpgconf,
        [Parameter(Mandatory = $true)][string] $GpgHome,
        [Parameter(Mandatory = $true)][string] $File
    )

    $arguments = @('--homedir', $GpgHome, '--batch', '--import', $File)
    $result = Invoke-Native -FilePath $Gpg -Arguments $arguments

    if ($result.ExitCode -eq 0) {
        return $result
    }

    # Un unico reintento levantando el agente de nuevo: el fallo observed es de
    # conexion con el agente, no del contenido del fichero de claves.
    Write-Warning ("gpg --import fallo en la primera pasada, reintentando tras relanzar el agente: " + $File)
    $null = Start-GpgAgent -GpgHome $GpgHome -Gpgconf $Gpgconf

    return (Invoke-Native -FilePath $Gpg -Arguments $arguments)
}

function Invoke-GpgSetup {
    <#
    .OUTPUTS
        [bool] $true si las claves se importaron correctamente o el usuario decidio omitirlo.
    #>
    [CmdletBinding()]
    param([switch] $Force)

    Write-Host ''
    Write-Host '  == Configuracion GPG ==' -ForegroundColor Cyan

    if (-not (Assert-Commands -Name @('gpg', 'gpgconf'))) {
        return $false
    }

    if (-not $Force) {
        $confirmed = Confirm-Action -Title 'Importar GPG' -Text 'Deseas importar tus claves GPG?'
        if (-not $confirmed) {
            Write-Host '  Omitido: GPG' -ForegroundColor DarkGray
            return $true
        }
    }

    if (-not (Test-GpgKeyId)) {
        return $false
    }

    $gpgHome = Resolve-GpgHome

    # El agente lee GNUPGHOME, no --homedir. Sin esto el agente usaria su home por
    # defecto y no encontraria las claves que se importan a continuacion.
    $env:GNUPGHOME = $gpgHome

    Write-Host "  Home de GnuPG: $gpgHome" -ForegroundColor DarkGray

    $gpg = Get-NativePath -Name 'gpg'
    $gpgconf = Get-NativePath -Name 'gpgconf'

    # Nada de esto puede seguir abierto mientras se mueve el home: sin parar el
    # agente antes del backup, el move falla y deja el directorio partido.
    Stop-GpgAgent -GpgHome $gpgHome -Gpgconf $gpgconf

    # Stop-GpgAgent mata a la fuerza, y GnuPG no siempre alcanza a borrar sus
    # ficheros de bloqueo. Un .lock de tamano 0 rompe la siguiente ejecucion.
    $stale = Clear-StaleLockFiles -GpgHome $gpgHome
    foreach ($name in $stale) {
        Write-Host "  - $name (bloqueo residual eliminado)" -ForegroundColor DarkYellow
    }

    [void](Backup-Target -Path $gpgHome)

    New-Item -ItemType Directory -Path $gpgHome -Force | Out-Null

    # El agente debe estar vivo antes de importar la clave privada.
    $null = Start-GpgAgent -GpgHome $gpgHome -Gpgconf $gpgconf

    # --- Importacion de claves ---
    $sources = [ordered]@{
        'privada' = $env:GPG_PRIVATE_KEY_SOURCE
        'publica' = $env:GPG_PUBLIC_KEY_SOURCE
    }

    foreach ($entry in $sources.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
            Show-Error -Text "Clave $($entry.Key) GPG no encontrada en $($entry.Value)"
            return $false
        }

        # --batch es obligatorio: sin el, gpg intenta abrir pinentry y la
        # invocacion se queda bloqueada indefinidamente.
        $result = Invoke-GpgImport -Gpg $gpg -Gpgconf $gpgconf -GpgHome $gpgHome -File $entry.Value
        if ($result.ExitCode -ne 0) {
            Show-Error -Text ("gpg --import $($entry.Value) fallo:`r`n" + ($result.Output -join "`r`n"))
            return $false
        }
    }

    # --- Verificacion de la clave secreta ---
    $check = Invoke-Native -FilePath $gpg -Arguments @('--homedir', $gpgHome, '--batch', '--list-secret-keys', $env:GPG_KEY_ID)
    if ($check.ExitCode -ne 0) {
        Show-Error -Text "No se encontro la clave secreta GPG con ID $($env:GPG_KEY_ID)"
        return $false
    }

    # --- Permisos: chmod 700 en el home y 600 en todo su contenido ---
    Protect-File -Path $gpgHome -IncludeSubItems

    # --- Archivos de configuracion ---
    # GPG_PINENTRY_MODE fuerza un modo (por ejemplo loopback) solo si se pide de
    # forma explicita; en caso contrario se retira el loopback que hubiera.
    $settings = Get-GpgSettingMap -GpgHome $gpgHome -PinentryMode $env:GPG_PINENTRY_MODE
    foreach ($file in $settings.Keys) {
        $entry = $settings[$file]

        if ($entry.Obsolete -and (Remove-LineFromFile -Lines $entry.Obsolete -File $file)) {
            foreach ($gone in $entry.Obsolete) {
                Write-Host "  - $(Split-Path -Leaf $file): $gone (retirada)" -ForegroundColor DarkYellow
            }
        }

        foreach ($line in $entry.Lines) {
            if (Add-LineIfMissing -Line $line -File $file) {
                Write-Host "  + $(Split-Path -Leaf $file): $line" -ForegroundColor DarkGray
            }
        }
    }

    # Reinicia el agente para que recoja gpg-agent.conf en la proxima ejecucion.
    # Stop-GpgAgent baja tambien keyboxd y scdaemon, y despues se limpian los
    # bloqueos que la importacion haya dejado a medias: si no, el siguiente
    # "gpg -k" falla con "invalid size of lockfile".
    Stop-GpgAgent -GpgHome $gpgHome -Gpgconf $gpgconf

    $leftovers = Clear-StaleLockFiles -GpgHome $gpgHome
    foreach ($name in $leftovers) {
        Write-Host "  - $name (bloqueo residual eliminado)" -ForegroundColor DarkYellow
    }

    Show-Info -Title 'Importar GPG' -Text 'Claves GPG importadas y configuracion aplicada.'
    return $true
}

# Solo se ejecuta el flujo principal cuando el archivo se invoca directamente.
if ($MyInvocation.InvocationName -ne '.') {
    if (Invoke-GpgSetup) { exit 0 } else { exit 1 }
}