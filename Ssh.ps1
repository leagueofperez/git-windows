<#
.SYNOPSIS
    Importa las claves SSH en el perfil de Windows y las registra en el agente.

.DESCRIPTION
    Sustituye a ssh.sh. Portabilidad a Windows:
      - chmod 700 ~/.ssh   -> icacls con herencia (OI)(CI) solo para el propietario
      - chmod 600 id_rsa   -> icacls sin herencia, solo el propietario
      - ssh-agent -s       -> servicio "ssh-agent" de Windows (Get-Service / Start-Service)
      - eval $(...)        -> no existe equivalente; el agente se registra como servicio

.PARAMETER Force
    Omite la confirmacion. Lo usa Full.ps1 cuando el usuario ya ha confirmado.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Ssh.ps1
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

. (Join-Path $PSScriptRoot 'Lib.ps1')

function Start-SshAgentService {
    <#
    .SYNOPSIS
        Arranca el servicio ssh-agent de Windows. Sustituye a "ssh-agent -s" + eval.
    .OUTPUTS
        [bool] $true si el servicio queda en ejecucion.
    #>
    $service = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Warning 'El servicio ssh-agent no esta disponible en este equipo. Las claves se han copiado igualmente.'
        return $false
    }

    if ($service.StartType -eq 'Disabled') {
        try {
            Set-Service -Name 'ssh-agent' -StartupType Automatic -ErrorAction Stop
        }
        catch {
            Write-Warning 'El servicio ssh-agent esta deshabilitado. Para activarlo, ejecuta como administrador:'
            Write-Warning '    Set-Service ssh-agent -StartupType Automatic'
            return $false
        }
        $service = Get-Service -Name 'ssh-agent'
    }

    if ($service.Status -ne 'Running') {
        try {
            Start-Service -Name 'ssh-agent' -ErrorAction Stop
        }
        catch {
            Write-Warning 'No se pudo iniciar el servicio ssh-agent (se requiere una consola de administrador).'
            Write-Warning '    Start-Service ssh-agent'
            return $false
        }
    }

    return $true
}

function Invoke-SshSetup {
    <#
    .OUTPUTS
        [bool] $true si las claves se importaron correctamente o el usuario decidio omitirlo.
    #>
    [CmdletBinding()]
    param([switch] $Force)

    Write-Host ''
    Write-Host '  == Configuracion SSH ==' -ForegroundColor Cyan

    if (-not (Assert-Commands -Name @('ssh', 'ssh-add'))) {
        return $false
    }

    if (-not $Force) {
        $confirmed = Confirm-Action -Title 'Importar SSH' -Text 'Deseas importar tus claves SSH?'
        if (-not $confirmed) {
            Write-Host '  Omitido: SSH' -ForegroundColor DarkGray
            return $true
        }
    }

    [void](Backup-Target -Path $env:SSH_HOME)

    $sshHome = $env:SSH_HOME
    New-Item -ItemType Directory -Path $sshHome -Force | Out-Null
    Protect-File -Path $sshHome -IncludeSubItems

    # --- Clave privada ---
    if (-not (Test-Path -LiteralPath $env:SSH_PRIVATE_KEY_SOURCE -PathType Leaf)) {
        Show-Error -Text "Clave privada SSH no encontrada en $($env:SSH_PRIVATE_KEY_SOURCE)"
        return $false
    }
    Copy-Item -LiteralPath $env:SSH_PRIVATE_KEY_SOURCE -Destination $env:SSH_PRIVATE_KEY_DEST -Force
    Protect-File -Path $env:SSH_PRIVATE_KEY_DEST -Mode Private
    Write-Host "  Copiada clave privada -> $($env:SSH_PRIVATE_KEY_DEST)" -ForegroundColor DarkGray

    # --- Clave publica ---
    if (-not (Test-Path -LiteralPath $env:SSH_PUBLIC_KEY_SOURCE -PathType Leaf)) {
        Show-Error -Text "Clave publica SSH no encontrada en $($env:SSH_PUBLIC_KEY_SOURCE)"
        return $false
    }
    Copy-Item -LiteralPath $env:SSH_PUBLIC_KEY_SOURCE -Destination $env:SSH_PUBLIC_KEY_DEST -Force

    # Opcional: renombra el comentario de la clave publica, que es el nombre que
    # usa el agente. SSH_KEY_ALIAS vacio (por defecto) deja el comentario intacto.
    if (-not [string]::IsNullOrWhiteSpace($env:SSH_KEY_ALIAS)) {
        $fields = @((Get-Content -LiteralPath $env:SSH_PUBLIC_KEY_DEST -TotalCount 1) -split '\s+')
        if ($fields.Count -ge 2) {
            Write-TextFile -File $env:SSH_PUBLIC_KEY_DEST -Content "$($fields[0]) $($fields[1]) $env:SSH_KEY_ALIAS`r`n"
            Write-Host "  Alias de la clave: $env:SSH_KEY_ALIAS" -ForegroundColor DarkGray
        }
    }
    Protect-File -Path $env:SSH_PUBLIC_KEY_DEST -Mode Public

    # --- known_hosts y authorized_keys (opcionales) ---
    if (Test-Path -LiteralPath $env:SSH_KNOWN_HOSTS_SOURCE -PathType Leaf) {
        Copy-Item -LiteralPath $env:SSH_KNOWN_HOSTS_SOURCE -Destination $env:SSH_KNOWN_HOSTS_DEST -Force
        Protect-File -Path $env:SSH_KNOWN_HOSTS_DEST -Mode Public
        Write-Host '  Restaurado known_hosts' -ForegroundColor DarkGray
    }
    else {
        Show-WarningBox -Text "Archivo known_hosts no encontrado en $($env:SSH_KNOWN_HOSTS_SOURCE)"
    }

    if (Test-Path -LiteralPath $env:SSH_AUTH_KEYS_SOURCE -PathType Leaf) {
        Copy-Item -LiteralPath $env:SSH_AUTH_KEYS_SOURCE -Destination $env:SSH_AUTH_KEYS_DEST -Force
        Protect-File -Path $env:SSH_AUTH_KEYS_DEST -Mode Private
        Write-Host '  Restaurado authorized_keys' -ForegroundColor DarkGray
    }
    else {
        Show-WarningBox -Text "Archivo authorized_keys no encontrado en $($env:SSH_AUTH_KEYS_SOURCE)"
    }

    # --- Agente SSH ---
    if (-not (Start-SshAgentService)) {
        Show-WarningBox -Text @(
            'Las claves se han copiado y protegido correctamente, pero el agente no esta disponible.',
            '',
            'Para cargarlas manualmente, ejecuta en una consola de administrador:',
            '    Start-Service ssh-agent',
            "    ssh-add `"$($env:SSH_PRIVATE_KEY_DEST)`""
        )
        return $true
    }

    $sshAdd = Get-NativePath -Name 'ssh-add' -FallbackFolder (Join-Path $env:WINDIR 'System32\OpenSSH')
    $result = Invoke-Native -FilePath $sshAdd -Arguments @($env:SSH_PRIVATE_KEY_DEST)

    if ($result.ExitCode -eq 0) {
        Show-Info -Title 'Importar SSH' -Text "Clave SSH importada y anadida exitosamente.`r`n$($env:SSH_PRIVATE_KEY_DEST)"
        return $true
    }

    Show-WarningBox -Text @(
        'Las claves se copiaron, pero ssh-add no pudo registrarlas:',
        ($result.Output -join "`r`n"),
        '',
        'Comprueba el formato de la clave y el estado del agente con:',
        '    ssh-add -l'
    )
    return $false
}

# Solo se ejecuta el flujo principal cuando el archivo se invoca directamente.
# Cuando se carga con dot-sourcing desde Main.ps1 o Full.ps1, $MyInvocation.InvocationName
# es "." y un exit aqui cerraria el script que lo contiene.
if ($MyInvocation.InvocationName -ne '.') {
    if (Invoke-SshSetup) { exit 0 } else { exit 1 }
}