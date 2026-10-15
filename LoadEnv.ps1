<#
.SYNOPSIS
    Carga variables de entorno desde un archivo .env en el entorno del proceso actual.

.DESCRIPTION
    Lee un archivo .env y define cada variable en el entorno del proceso (via
    [Environment]::SetEnvironmentVariable), de modo que quede disponible tanto para
    el script actual como para cualquier proceso hijo que se lance.

    Reglas:
    - Ignora líneas vacías y comentarios (#).
    - Acepta líneas con o sin el prefijo "export".
    - Tolera espacios en blanco alrededor del "=".
    - Maneja valores sin comillas, con comillas simples y con comillas dobles.
    - No evalúa ni ejecuta código dentro del .env: los valores que contengan
      sustitución de comandos ( $() o acentos graves ) se descartan.

.PARAMETER EnvPath
    Ruta del archivo .env. Por defecto ".env" (relativa al directorio actual).

.PARAMETER Overwrite
    Si se indica, sobrescribe variables que ya tengan un valor en el entorno.
    Por defecto solo se rellenan las variables que estén vacías o no existan.

.EXAMPLE
    . "$PSScriptRoot\LoadEnv.ps1" -EnvPath "$PSScriptRoot\.env"

.EXAMPLE
    . "$PSScriptRoot\LoadEnv.ps1" -EnvPath "$PSScriptRoot\.env" -Overwrite
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $EnvPath = '.env',

    [switch] $Overwrite
)

function Read-EnvFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    foreach ($raw in [System.IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#')) { continue }

        # Quita el prefijo "export " si esta presente
        if ($line -match '^\s*export\s+(.*)$') { $line = $Matches[1].Trim() }

        # Solo se aceptan pares CLAVE=VALOR
        if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            Write-Warning "Linea ignorada (no CLAVE=VALOR): $line"
            continue
        }

        $key = $Matches[1]
        $rest = $Matches[2]

        # Quita las comillas envolventes y resuelve escapes comunes
        if ($rest.Length -ge 2 -and $rest.StartsWith('"') -and $rest.EndsWith('"')) {
            $value = $rest.Substring(1, $rest.Length - 2).Replace('\"', '"').Replace('\n', "`n")
        }
        elseif ($rest.Length -ge 2 -and $rest.StartsWith("'") -and $rest.EndsWith("'")) {
            $value = $rest.Substring(1, $rest.Length - 2)
        }
        elseif ($rest -match '^([^#]*?)\s+#') {
            # Valor sin comillas: descarta el comentario final ("valor # comentario")
            $value = $Matches[1].TrimEnd()
        }
        else {
            $value = $rest
        }

        # No ejecutar codigo: descarta sustituciones de comandos
        if ($value.Contains('$(') -or $value.Contains([char]96)) {
            Write-Warning "Advertencia: el valor para $key contiene posible sustitucion de comandos, se omite"
            continue
        }

        $current = [Environment]::GetEnvironmentVariable($key, [EnvironmentVariableTarget]::Process)
        if ($Overwrite -or [string]::IsNullOrEmpty($current)) {
            [Environment]::SetEnvironmentVariable($key, $value, [EnvironmentVariableTarget]::Process)
        }
    }
}

if (-not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) {
    Write-Warning "Archivo .env no encontrado en: $EnvPath"
    return
}

Write-Verbose "Cargando variables desde $EnvPath"
Read-EnvFile -Path $EnvPath