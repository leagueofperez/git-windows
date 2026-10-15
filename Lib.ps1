<#
.SYNOPSIS
    Biblioteca comun del configurador de Git / SSH / GPG para Windows.

.DESCRIPTION
    Se carga con dot-sourcing desde los scripts de entrada:

        . "$PSScriptRoot\Lib.ps1"

    Concentra:
      - La carga del archivo .env
      - Las rutas y valores por defecto (sobrescribibles por entorno)
      - La interfaz de consola que sustituye a whiptail
      - Los helpers de backup, ACL (icacls) y escritura idempotente

    Al dot-sourcing se activan $ErrorActionPreference y Set-StrictMode, de forma
    equivalente al "set -euo pipefail" del codigo bash original. Los scripts que lo
    cargan deben usar try/catch en las operaciones que puedan fallar de forma prevista.
#>

$script:LibRoot = $PSScriptRoot

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# ---------------------------------------------------------------------------
# Rutas y valores por defecto (editable via entorno o .env)
# ---------------------------------------------------------------------------
function Initialize-Defaults {
    if ([string]::IsNullOrEmpty($env:BASE_DIR)) {
        $env:BASE_DIR = $script:LibRoot
    }

    # Las dos rutas de destino son fijas y viven siempre bajo el perfil de
    # Windows: %USERPROFILE%\.ssh y %USERPROFILE%\.gnupg (esta ultima la resuelve
    # Resolve-GpgHome). SSH_HOME y GPG_HOME siguen aceptando otra ruta, pero solo
    # si se piden de forma explicita.
    $base = $env:BASE_DIR
    $userHome = $env:USERPROFILE
    if ([string]::IsNullOrEmpty($env:SSH_HOME)) { $env:SSH_HOME = Join-Path $userHome '.ssh' }
    if ([string]::IsNullOrEmpty($env:KEY_BACKUP_ROOT)) { $env:KEY_BACKUP_ROOT = $userHome }
    $sshHome = $env:SSH_HOME

    if ([string]::IsNullOrEmpty($env:SSH_PRIVATE_KEY_SOURCE)) { $env:SSH_PRIVATE_KEY_SOURCE = Join-Path $base 'ssh\id_rsa' }
    if ([string]::IsNullOrEmpty($env:SSH_PUBLIC_KEY_SOURCE)) { $env:SSH_PUBLIC_KEY_SOURCE = Join-Path $base 'ssh\id_rsa.pub' }
    if ([string]::IsNullOrEmpty($env:SSH_KNOWN_HOSTS_SOURCE)) { $env:SSH_KNOWN_HOSTS_SOURCE = Join-Path $base 'ssh\known_hosts' }
    if ([string]::IsNullOrEmpty($env:SSH_AUTH_KEYS_SOURCE)) { $env:SSH_AUTH_KEYS_SOURCE = Join-Path $base 'ssh\authorized_keys' }

    if ([string]::IsNullOrEmpty($env:SSH_PRIVATE_KEY_DEST)) { $env:SSH_PRIVATE_KEY_DEST = Join-Path $sshHome 'id_rsa' }
    if ([string]::IsNullOrEmpty($env:SSH_PUBLIC_KEY_DEST)) { $env:SSH_PUBLIC_KEY_DEST = Join-Path $sshHome 'id_rsa.pub' }
    if ([string]::IsNullOrEmpty($env:SSH_KNOWN_HOSTS_DEST)) { $env:SSH_KNOWN_HOSTS_DEST = Join-Path $sshHome 'known_hosts' }
    if ([string]::IsNullOrEmpty($env:SSH_AUTH_KEYS_DEST)) { $env:SSH_AUTH_KEYS_DEST = Join-Path $sshHome 'authorized_keys' }

    if ([string]::IsNullOrEmpty($env:GPG_PRIVATE_KEY_SOURCE)) { $env:GPG_PRIVATE_KEY_SOURCE = Join-Path $base 'gpg\privada.gpg' }
    if ([string]::IsNullOrEmpty($env:GPG_PUBLIC_KEY_SOURCE)) { $env:GPG_PUBLIC_KEY_SOURCE = Join-Path $base 'gpg\public.gpg' }

    if ([string]::IsNullOrEmpty($env:GIT_USER_NAME)) { $env:GIT_USER_NAME = 'xxx' }
    if ([string]::IsNullOrEmpty($env:GIT_USER_EMAIL)) { $env:GIT_USER_EMAIL = 'xxx' }
    if ([string]::IsNullOrEmpty($env:GPG_KEY_ID)) { $env:GPG_KEY_ID = 'XXX' }

    # gpg-agent NO lee su home de "--homedir", sino de GNUPGHOME. Si no se exporta
    # aqui, el agente leeria un anillo de claves distinto del que usa gpg y la
    # firma fallaria con "no tenemos la clave secreta" en cuanto GPG_HOME apunte
    # a un directorio distinto del que el agente usa por defecto.
    if ([string]::IsNullOrEmpty($env:GNUPGHOME)) {
        $env:GNUPGHOME = Resolve-GpgHome
    }
}

# ---------------------------------------------------------------------------
# Interfaz de consola (sustituye a whiptail)
# ---------------------------------------------------------------------------

function Wait-Enter {
    <#
    .SYNOPSIS
        Espera a que el usuario pulse Enter. No falla si la entrada no es interactiva.
    #>
    param([string] $Prompt = '  Pulsa Enter para continuar...')

    try {
        [void](Read-Host $Prompt)
    }
    catch {
        Write-Host $Prompt -ForegroundColor DarkGray
    }
}

function Get-BoxWidth {
    <#
    .SYNOPSIS
        Ancho del recuadro, adaptado a la consola en la que se ejecuta.
    #>
    $preferred = 72
    $consoleWidth = 0

    try {
        $raw = $Host.UI.RawUI
        if ($raw -and $raw.WindowSize -and $raw.WindowSize.Width -gt 0) {
            $consoleWidth = $raw.WindowSize.Width
        }
    }
    catch {
        # Hosts sin consola (ISE, remoting) no exponen WindowSize
        $consoleWidth = 0
    }

    if ($consoleWidth -lt 20) { $consoleWidth = 80 }

    # Un recuadro mas ancho que la consola se parte en dos lineas y parece roto
    return [Math]::Max(40, [Math]::Min($preferred, $consoleWidth - 1))
}

function Format-BoxLines {
    <#
    .SYNOPSIS
        Parte el texto en lineas que caben en el ancho interior del recuadro.
    .DESCRIPTION
        Sin esto, una linea larga se desborda, envuelve la consola y el borde
        derecho deja de cerrar el recuadro. Las palabras se parten por el punto de
        corte normal; una palabra mas larga que la caja se parte por la fuerza.
    .OUTPUTS
        [string[]] Lineas de como mucho $Width caracteres.
    #>
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text,
        [int] $Width
    )

    $lines = New-Object System.Collections.ArrayList

    foreach ($raw in (($Text -join "`r`n") -split "`r?`n")) {
        if ($raw.Length -le $Width) {
            [void]$lines.Add($raw)
            continue
        }

        if ([string]::IsNullOrWhiteSpace($raw)) {
            [void]$lines.Add('')
            continue
        }

        $current = ''
        foreach ($word in ($raw -split '\s+')) {
            while ($word.Length -gt $Width) {
                if ($current) {
                    [void]$lines.Add($current)
                    $current = ''
                }
                [void]$lines.Add($word.Substring(0, $Width))
                $word = $word.Substring($Width)
            }

            if (-not $current) { $current = $word }
            elseif (($current.Length + 1 + $word.Length) -le $Width) { $current += ' ' + $word }
            else {
                [void]$lines.Add($current)
                $current = $word
            }
        }

        if ($current) { [void]$lines.Add($current) }
    }

    return $lines.ToArray()
}

function Show-Box {
    <#
    .SYNOPSIS
        Muestra un recuadro de titulo y texto en la consola.
    .PARAMETER Text
        Una cadena, o un array de cadenas que se unen con saltos de linea.
        Aceptar el array evita tener que unirlo en cada llamada.
    .PARAMETER Kind
        Info, Aviso, Ok, Error o Salir. Determina el color de la barra de titulo.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $Title,

        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text = @(),

        [ValidateSet('Info', 'Aviso', 'Ok', 'Error', 'Salir')]
        [string] $Kind = 'Info'
    )

    $palette = @{
        Info  = @{ Bg = [ConsoleColor]::Cyan;    Fg = [ConsoleColor]::Black }
        Aviso = @{ Bg = [ConsoleColor]::Yellow;  Fg = [ConsoleColor]::Black }
        Ok    = @{ Bg = [ConsoleColor]::Green;   Fg = [ConsoleColor]::Black }
        Error = @{ Bg = [ConsoleColor]::Red;     Fg = [ConsoleColor]::White }
        Salir = @{ Bg = [ConsoleColor]::DarkGray; Fg = [ConsoleColor]::White }
    }
    $color = $palette[$Kind]

    $width = Get-BoxWidth
    $inner = $width - 4          # "| " por delante y " |" por detras
    $rule = '+' + ('-' * ($width - 2)) + '+'

    # El color del recuadro solo se aplica a la barra de titulo, que lleva fondo
    # propio. Ponerlo tambien en el texto lo haria negro sobre el fondo oscuro
    # de la consola, que es justo donde no se lee nada.
    $heading = $Title
    if ($heading.Length -gt $inner) {
        $heading = $heading.Substring(0, [Math]::Max(0, $inner - 3)) + '...'
    }

    Write-Host ''
    Write-Host $rule
    # La expresion completa va entre parentesis: si no, el "+ ' |'" se
    # interpreta como un argumento mas de Write-Host y lo une con un espacio.
    Write-Host (('| ' + $heading).PadRight($width - 2) + ' |') -ForegroundColor $color.Fg -BackgroundColor $color.Bg
    Write-Host $rule

    foreach ($line in (Format-BoxLines -Text $Text -Width $inner)) {
        Write-Host ('| ' + $line.PadRight($inner) + ' |')
    }

    Write-Host $rule
    Write-Host ''
}

function Show-Info {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text,
        [string] $Title = 'Info'
    )
    Show-Box -Title $Title -Text $Text -Kind Info
    Wait-Enter
}

function Show-WarningBox {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text,
        [string] $Title = 'Aviso'
    )
    Show-Box -Title $Title -Text $Text -Kind Aviso
    Wait-Enter
}

function Show-Error {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text,
        [string] $Title = 'Error'
    )
    Show-Box -Title $Title -Text $Text -Kind Error
    Wait-Enter
}

function Confirm-Action {
    <#
    .SYNOPSIS
        Equivalente a "whiptail --yesno": S para si, N o Enter para no.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Title,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text
    )

    Show-Box -Title $Title -Text $Text -Kind Aviso

    while ($true) {
        $answer = ''
        try {
            $answer = (Read-Host '  Continuar? [S/N]').Trim()
        }
        catch {
            return $false
        }

        if ($answer -eq '') { return $false }
        if ($answer -match '^[SsYy]') { return $true }
        if ($answer -match '^[Nn]') { return $false }

        Write-Host '  Responde S (si) o N (no).' -ForegroundColor Yellow
    }
}

function Show-Menu {
    <#
    .SYNOPSIS
        Menu numerado en consola. Equivale a "whiptail --menu".
    .PARAMETER Options
        Array de hashtables @{ Key = '1'; Text = 'descripcion' }
    .OUTPUTS
        [string] La clave elegida.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Title,
        [Parameter(Mandatory = $true)][string] $Question,
        [Parameter(Mandatory = $true)][object[]] $Options
    )

    Show-Box -Title $Title -Text $Question -Kind Info

    foreach ($option in $Options) {
        Write-Host ("   {0}) {1}" -f $option.Key, $option.Text)
    }
    Write-Host ''

    while ($true) {
        $answer = ''
        try {
            $answer = (Read-Host '  Elige una opcion').Trim()
        }
        catch {
            return $Options[-1].Key
        }

        # Equivale al "Debes elegir una opcion." del bash: la entrada vacia no es valida
        if ($answer -eq '') {
            Write-Host '  Debes elegir una opcion.' -ForegroundColor Yellow
            continue
        }

        $match = $Options | Where-Object { $_.Key -eq $answer } | Select-Object -First 1
        if ($match) { return $match.Key }

        Write-Host '  Opcion no valida.' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Procesos nativos
# ---------------------------------------------------------------------------

function Invoke-Native {
    <#
    .SYNOPSIS
        Ejecuta un comando nativo y devuelve su codigo de salida junto a la salida
        capturada, sin que un error en stderr interrumpa el script.
    .OUTPUTS
        PSCustomObject con ExitCode (int) y Output (string[]).
    #>
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $Arguments = @()
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    $lines = @()
    foreach ($item in @($output)) {
        if ($null -ne $item) { $lines += [string]$item }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $lines
    }
}

function Get-NativePath {
    <#
    .SYNOPSIS
        Localiza un ejecutable en el PATH y, si no esta, en rutas de Windows conocidas.
    .OUTPUTS
        [string] Ruta completa, o $null si no se encuentra.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [string[]] $FallbackFolder
    )

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { return $command.Source }

    if ($FallbackFolder) {
        foreach ($folder in $FallbackFolder) {
            $candidate = Join-Path $folder "$Name.exe"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }

    return $null
}

function Test-CommandAvailable {
    <#
    .SYNOPSIS
        Devuelve $true si el comando existe en el PATH. Equivale a "command -v".
    #>
    param([Parameter(Mandatory = $true)][string] $Name)
    return $null -ne (Get-NativePath -Name $Name)
}

function Assert-Commands {
    <#
    .SYNOPSIS
        Comprueba que existan los comandos indicados. Equivale a require_commands.
        El original bash se llamaba sin argumentos, por lo que la comprobacion nunca
        llego a ejecutarse; aqui la lista es obligatoria.
    .OUTPUTS
        [bool]
    #>
    param([Parameter(Mandatory = $true)][string[]] $Name)

    $missing = @($Name | Where-Object { -not (Test-CommandAvailable $_) })
    if ($missing.Count -gt 0) {
        Show-Error -Text ("Faltan dependencias necesarias: " + ($missing -join ', '))
        return $false
    }

    return $true
}

# ---------------------------------------------------------------------------
# Archivos, permisos y backups
# ---------------------------------------------------------------------------

function Protect-File {
    <#
    .SYNOPSIS
        Aplica ACLs de Windows equivalentes a chmod, usando icacls de forma nativa.
    .DESCRIPTION
        Los SID de los grupos del sistema se escriben en forma numerica (*S-1-5-18,
        *S-1-5-32-544, *S-1-5-32-545) porque sus nombres estan localizados y fallarian
        en un Windows en espanol.

        Private  -> solo el usuario, SYSTEM y administradores. Equivale a chmod 600.
        Public   -> los anteriores mas lectura para el resto de usuarios. Equivale a chmod 644.
        Directory -> los anteriores con herencia (OI)(CI). Equivale a chmod 700.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [ValidateSet('Private', 'Public', 'Directory')][string] $Mode = 'Private',
        [switch] $IncludeSubItems
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $system = '*S-1-5-18'
    $administrators = '*S-1-5-32-544'
    $users = '*S-1-5-32-545'

    $targets = New-Object System.Collections.ArrayList
    $root = Get-Item -LiteralPath $Path -Force
    [void]$targets.Add($root)

    if ($IncludeSubItems) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
            [void]$targets.Add($child)
        }
    }

    # Se aplica item a item y no con icacls /T. Al combinar /T con marcadores de
    # herencia, icacls deja los ficheros ya existentes con una DACL vacia y GnuPG
    # o ssh dejan de poder leer sus propias claves. El riesgo no se ve con /C /Q.
    foreach ($target in $targets) {
        $itemMode = if ($target.PSIsContainer) { 'Directory' } else { $Mode }

        if ($target.PSIsContainer) {
            # Los marcadores (OI)(CI) solo son validos en directorios, y son los que
            # hacen que los ficheros que cree despues la aplicacion hereden el permiso.
            $flags = '(OI)(CI)F'
            $arguments = @(
                $target.FullName, '/inheritance:r', '/grant:r',
                "${user}:$flags", "${system}:$flags", "${administrators}:$flags"
            )
        }
        else {
            $arguments = @(
                $target.FullName, '/inheritance:r', '/grant:r',
                "${user}:F", "${system}:F", "${administrators}:F"
            )
            if ($itemMode -eq 'Public') {
                $arguments += "${users}:R"
            }
        }

        $arguments += @('/C', '/Q')

        $result = Invoke-Native -FilePath 'icacls.exe' -Arguments $arguments
        if ($result.ExitCode -ne 0) {
            Write-Warning ("icacls no pudo aplicarse sobre {0} (codigo {1}): {2}" -f $target.FullName, $result.ExitCode, ($result.Output -join ' '))
        }
    }
}

function Write-TextFile {
    <#
    .SYNOPSIS
        Escribe texto en un fichero controlando los atributos que se lo impiden.
    .DESCRIPTION
        File.WriteAllText falla con "Acceso denegado" si el fichero tiene el
        atributo Hidden, y File.AppendAllText falla ademas con ReadOnly. Los
        ficheros de configuracion de GnuPG pueden llevar Hidden, asi que hay que
        retirarlos antes de escribir y devolver Hidden despues (ReadOnly no se
        restaura: escribirlo otra vez debe seguir siendo posible).
    #>
    param(
        [Parameter(Mandatory = $true)][string] $File,
        [AllowEmptyString()][string] $Content = '',
        [switch] $Append
    )

    $hidden = [int][System.IO.FileAttributes]::Hidden
    $readOnly = [int][System.IO.FileAttributes]::ReadOnly

    $item = Get-Item -LiteralPath $File -Force
    $current = [int]$item.Attributes
    $wasHidden = ($current -band $hidden) -ne 0

    if (($current -band ($hidden -bor $readOnly)) -ne 0) {
        $null = $item.Attributes = [System.IO.FileAttributes]($current -band (-bnot ($hidden -bor $readOnly)))
    }

    try {
        if ($Append) {
            [System.IO.File]::AppendAllText($File, $Content)
        }
        else {
            [System.IO.File]::WriteAllText($File, $Content)
        }
    }
    finally {
        if ($wasHidden) {
            $restored = Get-Item -LiteralPath $File -Force
            $null = $restored.Attributes = [System.IO.FileAttributes]([int]$restored.Attributes -bor $hidden)
        }
    }
}

function Clear-StaleLockFiles {
    <#
    .SYNOPSIS
        Borra los ficheros de bloqueo que GnuPG dejo a medias.
    .DESCRIPTION
        El script detiene gpg-agent con Stop-Process -Force para poder mover el
        home. Si el proceso no llega a limpiar, deja pubring.kbx.lock,
        trustdb.gpg.lock o gnupg_spawn_agent_sentinel.lock con tamano 0, y la
        siguiente ejecucion falla con:

            gpg: invalid size of lockfile '...'
            gpg: cannot read lockfile
            gpg: can't lock '...'

        Un lock de GnuPG valido ocupa 1 byte, asi que cualquier otro es residuo.
        Por seguridad solo se limpian si no hay ningun proceso de GnuPG en
        marcha: con uno vivo, el bloqueo seria real y borrarloROMperia el acceso.
    .OUTPUTS
        [string[]] Rutas eliminadas.
    #>
    param([Parameter(Mandatory = $true)][string] $GpgHome)

    if (-not (Test-Path -LiteralPath $GpgHome)) { return @() }

    $running = @(Get-Process -Name 'gpg-agent', 'keyboxd', 'scdaemon', 'gpg' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Warning 'Hay procesos de GnuPG en marcha; no se tocan los ficheros de bloqueo.'
        return @()
    }

    $removed = @()
    $locks = @(Get-ChildItem -LiteralPath $GpgHome -Filter '*.lock' -Force -Recurse -ErrorAction SilentlyContinue) +
              @(Get-ChildItem -LiteralPath $GpgHome -Filter '*.lck' -Force -Recurse -ErrorAction SilentlyContinue)

    foreach ($lock in $locks) {
        try {
            Remove-Item -LiteralPath $lock.FullName -Force -ErrorAction Stop
            $removed += $lock.Name
        }
        catch {
            Write-Warning ("No se pudo borrar el bloqueo {0}: {1}" -f $lock.Name, $_.Exception.Message)
        }
    }

    return $removed
}

function Backup-Target {
    <#
    .SYNOPSIS
        Mueve el destino a <KEY_BACKUP_ROOT>/key_backup_<marca de tiempo>.
    .DESCRIPTION
        Se usa Directory.Move y no Move-Item a proposito: Directory.Move es
        atomico, asi que si un fichero esta en uso falla entero y el origen
        queda intacto. Move-Item, en cambio, puede haber movido ya parte del
        contenido cuando falla, lo que deja el home de GnuGI partido entre dos
        carpetas.
    .OUTPUTS
        [string] La carpeta del backup, o $null si no habia nada que respaldar.
    #>
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  No existe $Path, no es necesario hacer backup." -ForegroundColor DarkGray
        return $null
    }

    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $backupDir = Join-Path $env:KEY_BACKUP_ROOT "key_backup_$stamp"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $destination = Join-Path $backupDir (Split-Path -Leaf $Path.TrimEnd('\'))

    try {
        [System.IO.Directory]::Move($Path, $destination)
    }
    catch {
        # No se ha movido nada, pero la carpeta vacia ya creada queda colgando
        if (Test-Path -LiteralPath $backupDir) {
            Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        throw ("No se pudo mover {0} a {1}. Algún proceso lo está usando. Ciérralo (por ejemplo Gpg4win, Kleopatra o una consola de gpg) y vuelve a intentarlo.`r`nDetalle: {2}" -f $Path, $destination, $_.Exception.Message)
    }

    Write-Host "  Backup de $Path creado en $backupDir" -ForegroundColor DarkGray
    return $backupDir
}

function Add-LineIfMissing {
    <#
    .SYNOPSIS
        Anade una linea al final del archivo solo si no esta ya presente de forma
        exacta. Equivale a append_if_missing + chmod 600.
    .DESCRIPTION
        Se escribe con File.AppendAllText, que usa UTF-8 sin BOM. Un BOM inicial
        haria que GnuPG rechazase gpg.conf y gpg-agent.conf.
    .OUTPUTS
        [bool] $true si se anadio la linea.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Line,
        [Parameter(Mandatory = $true)][string] $File
    )

    $folder = Split-Path -Parent $File
    if ($folder -and -not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        [System.IO.File]::WriteAllText($File, '')
    }

    # -ccontains es la comparacion exacta y sensible a mayusculas que hace grep -Fxq
    if (@(Get-Content -LiteralPath $File) -ccontains $Line) {
        return $false
    }

    Write-TextFile -File $File -Content ($Line + "`r`n") -Append
    return $true
}

function Remove-LineFromFile {
    <#
    .SYNOPSIS
        Borra del archivo las lineas que coincidan exactamente con las indicadas.
    .DESCRIPTION
        Add-LineIfMissing solo anade, asi que cambiar una opcion que el script
        escribio antes requiere poder quitarla. Se conservan los saltos de linea
        originales y se reescribe con UTF-8 sin BOM (un BOM haria que GnuPG
        rechazase el fichero).
    .OUTPUTS
        [bool] $true si se ha modificado el archivo.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]] $Lines,
        [Parameter(Mandatory = $true)][string] $File
    )

    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }

    $content = [System.IO.File]::ReadAllText($File)
    if ([string]::IsNullOrEmpty($content)) { return $false }

    $normalized = $content -replace "`r`n", "`n"
    $updated = $normalized
    foreach ($line in $Lines) {
        # Escape para poder buscar una linea como Regex sin metacaracteres
        $updated = $updated -replace "(?m)^$([regex]::Escape($line))\s?`n?", ''
    }

    if ($updated -eq $normalized) { return $false }

    Write-TextFile -File $File -Content ($updated -replace "`n", "`r`n")
    return $true
}

# ---------------------------------------------------------------------------
# Validacion
# ---------------------------------------------------------------------------

function Test-GitConfig {
    <#
    .PARAMETER Quiet
        Devuelve el resultado sin mostrar el recuadro de error.
    .OUTPUTS
        [bool] $true si GIT_USER_NAME y GIT_USER_EMAIL estan definidos.
    #>
    param([switch] $Quiet)

    $invalid = ($env:GIT_USER_NAME -eq 'xxx') -or ($env:GIT_USER_EMAIL -eq 'xxx') -or
        [string]::IsNullOrWhiteSpace($env:GIT_USER_NAME) -or
        [string]::IsNullOrWhiteSpace($env:GIT_USER_EMAIL)

    if ($invalid) {
        if (-not $Quiet) {
            Show-Error -Text 'Debes establecer tu nombre y correo de Git (GIT_USER_NAME y GIT_USER_EMAIL).'
        }
        return $false
    }

    return $true
}

function Test-GpgKeyId {
    <#
    .PARAMETER Quiet
        Devuelve el resultado sin mostrar el recuadro de error, para que el
        llamante pueda decidir que mensaje emitir.
    .OUTPUTS
        [bool] $true si GPG_KEY_ID esta definido.
    #>
    param([switch] $Quiet)

    if (($env:GPG_KEY_ID -eq 'XXX') -or [string]::IsNullOrWhiteSpace($env:GPG_KEY_ID)) {
        if (-not $Quiet) {
            Show-Error -Text 'Debes establecer GPG_KEY_ID en el entorno o en .env.'
        }
        return $false
    }

    return $true
}

# ---------------------------------------------------------------------------
# GnuPG
# ---------------------------------------------------------------------------

function Resolve-GpgHome {
    <#
    .SYNOPSIS
        Devuelve el directorio home de GnuPG: %USERPROFILE%\.gnupg
    .DESCRIPTION
        Windows tiene dos homes habituales para GnuPG y cada shell elige uno
        distinto:

            %APPDATA%\gnupg       gpg.exe de Windows bajo PowerShell
            %USERPROFILE%\.gnupg  Git Bash / MSYS (UCRT64)

        Con los dos poblados, cada shell firma con una clave diferente y el
        resultado depende de donde se lance git. Se fija ~/.gnupg porque es el
        que usan las dos, y porque es la ruta que ya respectaba el bash original.

        Antes se preguntaba a "gpgconf --list-dirs homedir", que en Windows
        devuelve %APPDATA%\gnupg; se deja de hacer a proposito.

        GPG_HOME del entorno sigue teniendo prioridad para quien necesite otra
        ruta a proposito.
    .OUTPUTS
        [string]
    #>
    if (-not [string]::IsNullOrEmpty($env:GPG_HOME)) {
        return $env:GPG_HOME
    }

    return (Join-Path $env:USERPROFILE '.gnupg')
}

# ---------------------------------------------------------------------------
# Arranque de la biblioteca
# ---------------------------------------------------------------------------

$envFile = Join-Path $script:LibRoot '.env'
if (Test-Path -LiteralPath $envFile -PathType Leaf) {
    . (Join-Path $script:LibRoot 'LoadEnv.ps1') -EnvPath $envFile
}

Initialize-Defaults