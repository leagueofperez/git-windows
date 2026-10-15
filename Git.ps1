<#
.SYNOPSIS
    Aplica la configuracion global de Git (identidad, rama por defecto y firma GPG).

.DESCRIPTION
    Sustituye a git.sh. Backups, validacion y entradas se mantienen igual; la unica
    diferencia funcional es que commit.gpgsign y user.signingkey solo se escriben
    cuando GPG_KEY_ID tiene un valor real, para no dejar la repo con la firma rota.

.PARAMETER Force
    Omite la confirmacion. Lo usa Full.ps1 cuando el usuario ya ha confirmado.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Git.ps1
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

. (Join-Path $PSScriptRoot 'Lib.ps1')

function Format-GitConfigValue {
    <#
    .SYNOPSIS
        Prepara un valor para pasarlo a "git config" en la linea de comandos.
    .DESCRIPTION
        git config interpreta barras invertidas y comillas dobles del valor: sin
        escaparlas, un nombre como 'Perez, Jose "Pepe"' se guardaria como
        'Perez, Jose Pepe', perdiendo las comillas sin avisar.
    #>
    param([string] $Value)

    if ($Value.Contains('"') -or $Value.Contains('\')) {
        return $Value.Replace('\', '\\').Replace('"', '\"')
    }

    return $Value
}

function Invoke-GitSetup {
    <#
    .OUTPUTS
        [bool] $true si Git quedo configurado o el usuario decidio omitirlo.
    #>
    [CmdletBinding()]
    param([switch] $Force)

    Write-Host ''
    Write-Host '  == Configuracion Git ==' -ForegroundColor Cyan

    if (-not (Assert-Commands -Name @('git'))) {
        return $false
    }

    if (-not $Force) {
        $confirmed = Confirm-Action -Title 'Configurar Git' -Text 'Deseas configurar Git globalmente (name, email, gpg sign)?'
        if (-not $confirmed) {
            Write-Host '  Omitido: Git' -ForegroundColor DarkGray
            return $true
        }
    }

    if (-not (Test-GitConfig)) {
        return $false
    }

    # Respeta GIT_CONFIG_GLOBAL: es la misma variable que usa git para decidir
    # donde vive la configuracion global. Si esta definida, respaldar el
    # ~/.gitconfig por defecto seria respaldar el fichero equivocado.
    $gitConfigPath = $env:GIT_CONFIG_GLOBAL
    if ([string]::IsNullOrEmpty($gitConfigPath)) {
        $gitConfigPath = Join-Path $env:USERPROFILE '.gitconfig'
    }

    [void](Backup-Target -Path $gitConfigPath)

    $git = Get-NativePath -Name 'git'

    $values = [ordered]@{
        'init.defaultBranch' = 'main'
        'user.name'          = $env:GIT_USER_NAME
        'user.email'         = $env:GIT_USER_EMAIL
    }

    if ((Test-GpgKeyId -Quiet)) {
        $values['commit.gpgsign'] = 'true'
        $values['user.signingkey'] = $env:GPG_KEY_ID
    }
    else {
        Show-WarningBox -Text @(
            'GPG_KEY_ID no esta definido, se omite la firma de commits.',
            '',
            'Define GPG_KEY_ID en el entorno o en .env y vuelve a ejecutar este modulo',
            'para activar commit.gpgsign y user.signingkey.'
        )
    }

    foreach ($key in $values.Keys) {
        $result = Invoke-Native -FilePath $git -Arguments @(
            'config', '--global', $key, (Format-GitConfigValue $values[$key])
        )
        if ($result.ExitCode -ne 0) {
            Show-Error -Text ("git config --global $key $($values[$key]) fallo:" + "`r`n" + ($result.Output -join "`r`n"))
            return $false
        }
        Write-Host "  git config --global $key $($values[$key])" -ForegroundColor DarkGray
    }

    $current = Invoke-Native -FilePath $git -Arguments @('config', '--global', '--list')
    if ($current.ExitCode -ne 0) {
        Show-Error -Text ('git config --global --list fallo:' + "`r`n" + ($current.Output -join "`r`n"))
        return $false
    }

    Show-Info -Title 'Configuracion Git' -Text ('Configuracion actual:' + "`r`n" + ($current.Output -join "`r`n"))
    return $true
}

# Solo se ejecuta el flujo principal cuando el archivo se invoca directamente.
if ($MyInvocation.InvocationName -ne '.') {
    if (Invoke-GitSetup) { exit 0 } else { exit 1 }
}