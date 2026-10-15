# Configurador de Git / SSH / GPG para Windows

Importa tus claves SSH y GPG y deja Git configurado a nivel global con firma de
commits. Es el equivalente para Windows del antiguo conjunto de scripts de bash,
reescrito con PowerShell y comandos nativos.

## Requisitos

- Windows PowerShell 5.1 o superior
- [GnuPG](https://gnupg.org/download/) (`gpg` y `gpgconf` en el PATH)
- [Git para Windows](https://git-scm.com/download/win)
- Cliente **OpenSSH de Windows** (`ssh`, `ssh-add`, `ssh-keygen` en el PATH)

Comprueba las dependencias antes de ejecutar nada:

```powershell
.\Main.ps1     # el menu comprueba git, gpg, gpgconf, ssh y ssh-add al arrancar
```

### ExecutionPolicy

Windows no permite ejecutar scripts locales por defecto. Una vez, para tu usuario:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

O para una ejecucion puntual, sin tocar la politica permanente:

```powershell
powershell -ExecutionPolicy Bypass -File .\Main.ps1
```

Si la politica lo impide, `Main.ps1` lo detecta al arrancar y te dice exactamente
que ejecutar, en vez de fallar con un error poco descriptivo.

## Uso

```powershell
.\Main.ps1
```

| Opcion | Que hace                                                       |
| ------ | -------------------------------------------------------------- |
| 1      | Importa las claves GPG y escribe `gpg.conf` / `gpg-agent.conf` |
| 2      | Importa las claves SSH y las registra en el agente             |
| 3      | Configura Git (identidad, rama por defecto, firma)             |
| 4      | Los tres anteriores, con una sola confirmacion                 |
| 0      | Salir                                                          |

Cada modulo tambien se puede ejecutar por separado:

```powershell
.\Gpg.ps1
.\Ssh.ps1
.\Full.ps1
```

## Estructura

| Fichero                           | Contenido                                                      |
| --------------------------------- | -------------------------------------------------------------- |
| `Main.ps1`                        | Menu principal                                                 |
| `Lib.ps1`                         | Rutas, valores por defecto, interfaz de consola, ACL y backups |
| `LoadEnv.ps1`                     | Lector de `.env`                                               |
| `Gpg.ps1` / `Ssh.ps1` / `Git.ps1` | Un modulo cada uno                                             |
| `Full.ps1`                        | Los tres en orden                                              |

`Lib.ps1` se carga con dot-sourcing y concentra todo lo comun. Los modulos se
cargan entre si de la misma forma, de modo que `Full.ps1` ejecuta las funciones
directamente en vez de lanzar procesos independientes: por eso pregunta una sola
vez en lugar de tres.

## Configuracion en `.env`

Las variables del `.env` tienen prioridad sobre los valores por defecto. Solo
sustituye las que quieras cambiar; el resto se deduce solo.

### Obligatorias para firmar commits

```ini
GIT_USER_NAME=Tu Nombre
GIT_USER_EMAIL=tu@correo.com
GPG_KEY_ID=ABCDEF0123456789ABCDEF0123456789ABCDEF01
```

Mientras `GIT_USER_NAME`, `GIT_USER_EMAIL` o `GPG_KEY_ID` valgan `xxx` / `XXX`, el
modulo Git aplica el resto de la configuracion pero **no activa la firma**, y te
avisa. Es preferible a dejar `user.signingkey` apuntando a un ID inexistente,
que haria fallar todos los commits.

El formato de `GPG_KEY_ID` depende de `keyid-format LONG` en `gpg.conf`, asi que
suele ser el ID completo de 40 caracteres, no los 8 cortos.

### Opcionales

| Variable                 | Por defecto                      | Para que sirve                       |
| ------------------------ | -------------------------------- | ------------------------------------ |
| `BASE_DIR`               | la carpeta del script            | Raiz de las rutas por defecto        |
| `SSH_HOME`               | `%USERPROFILE%\.ssh`             | Destino de las claves SSH            |
| `SSH_PRIVATE_KEY_SOURCE` | `<BASE_DIR>\ssh\id_rsa`          | Clave privada de origen              |
| `SSH_PUBLIC_KEY_SOURCE`  | `<BASE_DIR>\ssh\id_rsa.pub`      | Clave publica de origen              |
| `SSH_KNOWN_HOSTS_SOURCE` | `<BASE_DIR>\ssh\known_hosts`     | known_hosts de origen                |
| `SSH_AUTH_KEYS_SOURCE`   | `<BASE_DIR>\ssh\authorized_keys` | authorized_keys de origen            |
| `SSH_KEY_ALIAS`          | _(vacio)_                        | Renombra la clave en el agente       |
| `GPG_HOME`               | `%USERPROFILE%\.gnupg`           | Home de GnuPG                        |
| `GPG_PRIVATE_KEY_SOURCE` | `<BASE_DIR>\gpg\privada.gpg`     | Clave privada de origen              |
| `GPG_PUBLIC_KEY_SOURCE`  | `<BASE_DIR>\gpg\public.gpg`      | Clave publica de origen              |
| `GPG_PINENTRY_MODE`      | _(vacio)_                        | Fuerza `pinentry-mode` en `gpg.conf` |
| `KEY_BACKUP_ROOT`        | `%USERPROFILE%`                  | Donde se crean los respaldos         |

El formato de `.env` es el habitual: `CLAVE=valor`, comillas opcionales, `#` para
comentarios y prefijo `export` opcional. Los valores que contengan `$(` o acentos
graves se descartan, para que el fichero no pueda ejecutar codigo.

## Detalles de la portabilidad

Lo que cambia respecto a la version de bash:

- **`chmod` -> `icacls`.** `chmod 700` sobre un directorio se traduce a borrar
  la herencia y conceder control total solo al propietario, SYSTEM y
  administradores. Los SID de esos grupos se escriben en forma numerica
  (`*S-1-5-18`, `*S-1-5-32-544`) porque sus nombres estan localizados y no
  existiran en un Windows en espanol.
- **`ssh-agent -s` + `eval` -> el servicio `ssh-agent` de Windows.** El script
  arranca el servicio y llama a `ssh-add`. Necesita una consola de administrador
  la primera vez; si no puede, avisa y te da el comando exacto en vez de fallar.
- **`GNUPGHOME` se exporta.** `gpg --homedir` indica donde esta el anillo de
  claves, pero el agente lee su home de `GNUPGHOME`. Sin exportarlo, importar
  claves en un home distinto del del agente daria "no tenemos la clave secreta".
- **`gpg --batch` en todas las llamadas.** Sin el, gpg puede abrir pinentry y la
  ejecucion se queda bloqueada indefinidamente.
- **El agente se relanza antes de importar.** El script termina matando el agente
  para que relea `gpg-agent.conf`; en la ejecucion siguiente hay que volver a
  levantarlo antes de importar la clave privada.

## Firma de commits

La clave se protege con contrasena, asi que el primer `git commit` de cada
sesion abre una ventana de **pinentry** para teclearla. Despues, el agente la
mantiene en cache durante `default-cache-ttl` (unos 400 dias en la configuracion
que escribe este script), y los siguientes commits no preguntan nada.

El script **no** escribe `pinentry-mode loopback` en `gpg.conf`. Ese modo hace
que gpg no abra pinentry y espere la contrasena por la entrada estandar, que git
no envia, de modo que todo `git commit` falla con:

```powershell
gpg: cannot open 'no tty': No such file or directory
fatal: failed to write commit object
```

Es una opcion pensada para tareas por lotes, y solo debe usarse en la linea de
comandos de una operacion concreta. Si de verdad la necesitas de forma global,
define `GPG_PINENTRY_MODE=loopback` en el `.env` y el script la escribira; si no,
el script retira la linea si la encuentra.

## Dos homes de GnuPG

Resuelto: el script usa siempre `%USERPROFILE%\.gnupg`. Si tienes el otro home
(`%APPDATA%\gnupg`) de una instalacion anterior, borralo para que no quede una
copia suelta de tus claves.

## Donde se guarda todo

Los dos destinos son fijos y estan siempre bajo tu perfil de Windows:

```powershell
%USERPROFILE%\.gnupg     claves GPG, gpg.conf y gpg-agent.conf
%USERPROFILE%\.ssh       claves SSH, known_hosts y authorized_keys
```

Git Bash / MSYS ya resolvia GnuPG como `~/.gnupg`, asi que con esto PowerShell y
Git Bash terminan usando **el mismo** home y la misma clave.

Windows tiene otro home habitual, `%APPDATA%\gnupg`, que es el que usa `gpg.exe`
cuando no se le indica otro. Este script no lo toca. Si lo tienes creado de antes,
puedes borrarlo para no dejar una segunda copia de tus claves dando vueltas:

```powershell
Remove-Item "$env:APPDATA\gnupg" -Recurse -Force
```

Si de verdad necesitas otra ruta, `GPG_HOME` y `SSH_HOME` siguen funcionando, pero
entonces vuelve a haber dos homes y hay que decidir cual usa cada shell.

## Si algo falla

**`gpg: invalid size of lockfile '...\pubring.kbx.lock'`**

Un `.lock` de tamano 0 se ha quedado a medias, normalmente porque GnuPG o el
agente fueron cerrados a la fuerza (un corte de luz, o matar el proceso). Es
inofensivo: el script lo borra solo, pero si te aparece fuera del script:

```powershell
Remove-Item "$env:USERPROFILE\.gnupg\*.lock" -Force
```

Hazlo con GnuPG cerrado, o el bloqueo sera real y borrarlo dejaria el anillo
inconsistente. Comprueba antes con `Get-Process gpg-agent,keyboxd,scdaemon`.

**`gpg: cannot open 'no tty'` al hacer commit**

Significa que `gpg.conf` tiene `pinentry-mode loopback`. El script lo retira solo;
compruebalo con `Get-Content "$env:USERPROFILE\.gnupg\gpg.conf"`.

**`El proceso no puede acceder al archivo porque lo esta usando otro proceso`**

Algo mantiene abierto el home de GnuPG, normalmente Gpg4win o Kleopatra. Ciérralo
y vuelve a ejecutar. El script ya detiene `gpg-agent`, `keyboxd` y `scdaemon`
antes de mover nada.

## Respaldos

Antes de tocar nada se mueve el destino a
`<KEY_BACKUP_ROOT>\key_backup_<fecha>_<hora>`, nunca se sobreescribe a ciegas.
Se respalda `~/.ssh` completo, el home de GnuPG y el fichero de configuracion
global de Git (respetando `GIT_CONFIG_GLOBAL` si esta definido).

## Seguridad

Las claves privadas y el home de GnuPG quedan accesibles solo por tu usuario,
SYSTEM y administradores. Los ficheros publicos (`id_rsa.pub`, `known_hosts`)
conservan ademas lectura para el resto de usuarios.

El fichero `.env` contiene identificadores, no secretos. Aun asi, conviene
mantenerlo fuera del control de versiones si llegas a subirlo.
