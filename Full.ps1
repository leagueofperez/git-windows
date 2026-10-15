<#
.SYNOPSIS
    Ejecuta la configuracion completa: SSH, GPG y Git en ese orden.

.DESCRIPTION
    Sustituye a full.sh. El bash lanzaba ssh.sh, gpg.sh y git.sh como procesos
    independientes, cada uno con su propia confirmacion y su propia carga de .env.
    Aqui los modulos se cargan con dot-sourcing y se invocan sus funciones con
    -Force, por lo que el usuario solo confirma una vez.

.PARAMETER Force
    Omite la confirmacion global. Pensado para ejecuciones desatendidas.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Full.ps1
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

. (Join-Path $PSScriptRoot 'Lib.ps1')
. (Join-Path $PSScriptRoot 'Ssh.ps1')
. (Join-Path $PSScriptRoot 'Gpg.ps1')
. (Join-Path $PSScriptRoot 'Git.ps1')

function Invoke-FullSetup {
    <#
    .OUTPUTS
        [bool] $true si los tres modulos terminaron bien (los omitidos cuentan como ok).
    #>
    [CmdletBinding()]
    param([switch] $Force)

    if (-not $Force) {
        $confirmed = Confirm-Action -Title 'Configuracion completa' -Text 'Deseas ejecutar configuracion completa: SSH, GPG, Git?'
        if (-not $confirmed) {
            Write-Host '  Configuracion completa omitida por el usuario.' -ForegroundColor DarkGray
            return $true
        }
    }

    $summary = [ordered]@{}

    # Un fallo de SSH no detiene el proceso: Git sigue siendo configurable.
    $summary['SSH'] = [string](Invoke-SshSetup -Force)

    # GPG si es critico: sin la clave secreta, commit.gpgsign dejaria los repos
    # en un estado en el que no se puede confirmar ningun commit.
    $summary['GPG'] = [string](Invoke-GpgSetup -Force)
    if ($summary['GPG'] -ne 'True') {
        Show-Error -Text @(
            'El modulo GPG fallo, se detiene la configuracion completa.',
            '',
            'La firma de commits depende de una clave GPG importada correctamente.'
        )
        return $false
    }

    $summary['Git'] = [string](Invoke-GitSetup -Force)
    if ($summary['Git'] -ne 'True') {
        Show-Error -Text 'El modulo Git fallo.'
        return $false
    }

    $lines = @()
    foreach ($module in $summary.GetEnumerator()) {
        $lines += ('  {0,-4} {1}' -f $module.Key, $module.Value)
    }

    if ($summary['SSH'] -ne 'True') {
        Show-WarningBox -Title 'Configuracion completa finalizada' -Text (@(
            'Git y GPG quedaron configurados, pero el modulo SSH fallo:',
            ''
        ) + $lines)
        return $true
    }

    Show-Info -Title 'Configuracion completa finalizada' -Text (@('Modulos ejecutados:') + $lines)
    return $true
}

if ($MyInvocation.InvocationName -ne '.') {
    if (Invoke-FullSetup) { exit 0 } else { exit 1 }
}