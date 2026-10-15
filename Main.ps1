<#
.SYNOPSIS
    Menu principal del configurador de Git / SSH / GPG para Windows.

.DESCRIPTION
    Sustituye a main.sh. El menu se dibuja en consola con Show-Menu, de forma que
    funciona igual en una terminal normal, en Windows Terminal y sobre remoting.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Main.ps1
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Assert-RunnableHost {
    <#
    .SYNOPSIS
        Detecta las dos razones mas habituales por las que un .ps1 no arranca:
        una ExecutionPolicy restrictiva y el modo ConstrainedLanguage.
        No es una autoelevacion: informa de lo que hay que hacer.
    .OUTPUTS
        [bool] $true si se puede continuar.
    #>
    $problems = @()

    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        $problems += 'La sesion esta en modo ' + $ExecutionContext.SessionState.LanguageMode + ' en lugar de FullLanguage.'
    }

    foreach ($scope in @('Machine', 'User')) {
        try {
            $policy = Get-ExecutionPolicy -Scope $scope -ErrorAction Stop
            if ($policy -in @('Restricted', 'AllSigned')) {
                $problems += "La ExecutionPolicy de $scope es '$policy'."
            }
        }
        catch {
            # Get-ExecutionPolicy no esta disponible en algunos hosts; se ignora
        }
    }

    if ($problems.Count -eq 0) { return $true }

    Show-Error -Title 'No se puede ejecutar' -Text (@(
        $problems
        ''
        'Para permitir los scripts locales de tu usuario, ejecuta en PowerShell:'
        '    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
        ''
        'O bien, para una ejecucion puntual:'
        '    powershell -ExecutionPolicy Bypass -File .\Main.ps1'
    ))
    return $false
}

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $OutputEncoding = [Console]::OutputEncoding
}
catch {
    # En hosts sin consola (remoting, ISE) la codificacion no es aplicable
}

if (-not (Assert-RunnableHost)) {
    exit 1
}

. (Join-Path $PSScriptRoot 'Lib.ps1')
. (Join-Path $PSScriptRoot 'Gpg.ps1')
. (Join-Path $PSScriptRoot 'Ssh.ps1')
. (Join-Path $PSScriptRoot 'Git.ps1')
. (Join-Path $PSScriptRoot 'Full.ps1')

$options = @(
    @{ Key = '1'; Text = 'Configurar GPG' }
    @{ Key = '2'; Text = 'Configurar SSH' }
    @{ Key = '3'; Text = 'Configuracion Git' }
    @{ Key = '4'; Text = 'Configuracion completa' }
    @{ Key = '0'; Text = 'Salir' }
)

while ($true) {
    $choice = Show-Menu -Title 'Menu de configuracion' -Question 'Elige una opcion' -Options $options

    switch ($choice) {
        '1' { $null = Invoke-GpgSetup }
        '2' { $null = Invoke-SshSetup }
        '3' { $null = Invoke-GitSetup }
        '4' { $null = Invoke-FullSetup }
        '0' {
            Show-Box -Title 'Salir' -Text 'Saliendo...' -Kind Salir
            Wait-Enter
            exit 0
        }
        default {
            Show-Error -Text 'Opcion no valida.'
        }
    }
}