# Recibe la URL del repositorio y el directorio como argumentos
param (
    [string]$repoUrl,
    [string]$dirPath
)

# Crear el directorio si no existe
if (!(Test-Path -Path $dirPath)) {
    New-Item -ItemType Directory -Path $dirPath | Out-Null
}

# Cambiar al directorio
Set-Location -Path $dirPath

# Clonar el repositorio
git clone $repoUrl

# Obtener el nombre del repositorio sin la extensión .git
$repoName = [System.IO.Path]::GetFileNameWithoutExtension($repoUrl)

# Mover todos los archivos y carpetas (excepto ocultos) al directorio actual
Get-ChildItem -Path "$repoName" -Force -Exclude '.git' | ForEach-Object {
    Move-Item -Path $_.FullName -Destination .
}

# Mover archivos ocultos (punto-prefijados en Unix, incluidos .gitignore, etc.)
# Nota: PowerShell en Windows no trata los archivos con "." como ocultos, así que usamos una expresión regular
Get-ChildItem -Path "$repoName" -Force | Where-Object { $_.Name -match '^(\..+)' } | ForEach-Object {
    Move-Item -Path $_.FullName -Destination .
}

# Eliminar el directorio del repositorio clonado
Remove-Item -Recurse -Force -Path $repoName