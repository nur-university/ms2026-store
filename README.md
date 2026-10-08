# Store

Ejemplo academico de microservicios (NUR Diplomado 2026). Esta carpeta contiene la solucion `Store.sln`, los scripts de instalacion, la infraestructura en Docker y el orquestador `Store.AppHost` (.NET Aspire). Con ella se pueden ejecutar todos los proyectos juntos.

Cada microservicio y cada libreria compartida vive en su **propio repositorio** de la organizacion [nur-university](https://github.com/nur-university). El script `setup-project` los descarga en el directorio padre (`../`), por lo que es importante respetar la ubicacion de esta carpeta.

## Estructura

```
<raiz>/
├── Store/                  <- esta carpeta (solucion, scripts, docker)
├── Services/
│   ├── ApiGateway/         ms2026-store-api-gateway
│   ├── Catalog/            ms2026-store-catalog
│   ├── Identity/           ms2026-store-identity
│   ├── Inventory/          ms2026-store-inventory
│   ├── Orders/             ms2026-store-orders
│   └── Payments/           ms2026-store-payments
└── SharedKernel/
    ├── Nur.Store2026.Access/          sk2026-store-access
    ├── Nur.Store2026.Integration/     sk2026-store-integration
    ├── Nur.Store2026.Observability/   sk2026-store-observability
    └── Nur.Store2026.Security/        sk2026-store-security
```

## Requisitos

| Herramienta | Para que |
|---|---|
| Git | Clonar los repositorios |
| Docker Desktop (con Docker Compose) | Infraestructura (Postgres, RabbitMQ, Vault, Consul, Jaeger, Seq) |
| SDK de .NET 9 | Compilar `Store.AppHost` (apunta a `net9.0`). Tambien compila los servicios |
| Runtime de .NET 8 | Ejecutar los servicios (apuntan a `net8.0`). Se incluye en el SDK 8; con solo el SDK 9 hay que instalarlo aparte |
| Visual Studio 2022 (17.8+) o superior | Opcional, para abrir `Store.sln` |

Descargas: [.NET 8](https://dotnet.microsoft.com/download/dotnet/8.0) y [.NET 9](https://dotnet.microsoft.com/download/dotnet/9.0).

## 1. Descargar los proyectos

```powershell
./setup-project.ps1
```
```bash
./setup-project.sh
```

Clona los 10 repositorios en `../Services` y `../SharedKernel`. Los paquetes `Nur.Store2026.*` se compilan automaticamente desde su codigo fuente local (via `ProjectReference` condicional) en cuanto la carpeta existe en `../SharedKernel`; si no existe, se usa el paquete NuGet con version.

## 2. Levantar la infraestructura

```powershell
./start-infrastructure.ps1
```
```bash
./start-infrastructure.sh
```

Ejecuta `docker-compose-only-infrastructure.yml` (proyecto `store-infrastructure`) y luego carga los secretos iniciales en Vault.

| Servicio | URL / Puerto | Credenciales de desarrollo |
|---|---|---|
| PostgreSQL | `localhost:5432` | `postgres` / `postgresspassword` |
| RabbitMQ | `localhost:5672` (UI: http://localhost:15672) | `admin` / `admin` |
| Vault | http://localhost:8200 | token `vaultroot` |
| Consul | http://localhost:8500 | - |
| Jaeger (trazas) | http://localhost:16686 | - |
| Seq (logs) | http://localhost:5341 | - |

> [!NOTE]
> Vault corre en modo desarrollo: los secretos **no se persisten**. Si reinicias el contenedor `vault-server`, vuelve a crearlos con:
>
> ```bash
> docker exec vault-server sh /vault-init.sh
> ```

> [!WARNING]
> Todas las credenciales de este repositorio son valores de ejemplo para desarrollo local. No las uses en ningun otro entorno.

## 3. Ejecutar los microservicios

Hay tres formas. Elige una.

### Opcion A: .NET Aspire (recomendada)

Con la infraestructura ya levantada:

```bash
dotnet run --project Store.AppHost
```

Abre el dashboard de Aspire (por defecto `https://localhost:17068`) con logs, trazas y controles de inicio/parada de los 11 ejecutables (`WebApi` + `WorkerService` de Identity, Catalog, Inventory, Orders y Payments, mas `ApiGateway.WebApp`). Aspire **no** administra Postgres, RabbitMQ, Vault, Consul, Jaeger ni Seq: esos los levanta el paso 2.

En Visual Studio basta con poner `Store.AppHost` como proyecto de inicio.

### Opcion B: Visual Studio sin Aspire

Abre `Store.sln`, configura como proyectos de inicio multiples los `WebApi`, `WorkerService` y `ApiGateway.WebApp`, y ejecuta. Para trabajar un solo servicio, abre su propia solucion (por ejemplo `../Services/Catalog/Catalog.sln`).

### Opcion C: todo en contenedores

Levanta infraestructura **y** servicios con un solo comando:

```bash
docker compose up -d --build
```

> [!IMPORTANT]
> No lo combines con `start-infrastructure.*`: ambos publican los mismos puertos (5432, 5672, 8200, 8500, ...). Usa uno u otro. El `vault-init` se ejecuta solo, como contenedor de un solo uso.

## Puertos de los servicios

| Servicio | Puerto |
|---|---|
| Identity | 7081 |
| Catalog | 7291 |
| Inventory | 7050 |
| Orders | 7022 |
| Payments | 7210 |
| API Gateway | 7273 (https) / 5262 (http) |

Los servicios se **registran solos en Consul** al arrancar (con health check). El API Gateway lee Consul cada 30 segundos y publica las rutas como `/api/{servicio}/**`, asi que un servicio es accesible por el gateway solo cuando esta registrado y sano. Puedes verlo en http://localhost:8500.

## Configuracion

Por defecto cada proyecto usa los valores de su `appsettings.Development.json`. Para leer la configuracion desde Vault, cambia en ese archivo:

```json
{
  "UseSecretManager": true
}
```

El usuario administrador por defecto se define en `DefaultUser` (en `appsettings.Development.json` de Identity y en `docker-infrastructure/vault/vault-init.sh`).

## Compilar y probar por linea de comandos

```bash
dotnet build ../Services/Catalog/src/Catalog.WebApi/Catalog.WebApi.csproj
dotnet run --project ../Services/Catalog/src/Catalog.WebApi/Catalog.WebApi.csproj
```

> [!NOTE]
> `dotnet build Store.sln` completo puede fallar con `NU1107` (conflicto de version de `Serilog.AspNetCore`) por el proyecto `Inventory.Test`. Compila los proyectos individualmente o usa `Store.AppHost`, que no lo referencia.

## Solucion de problemas

- **Un servicio da 404 en el gateway:** revisa en http://localhost:8500 que este registrado y con el check en verde.
- **Errores de base de datos al iniciar:** confirma que el contenedor `postgres-server` esta saludable (`docker ps`). Las migraciones se aplican solas en Development.
- **Falla `UseSecretManager: true`:** los secretos de Vault se pierden al reiniciar el contenedor; vuelve a ejecutar `vault-init.sh` (ver arriba).
- **Error de certificado HTTPS:** ejecuta `dotnet dev-certs https --trust`.
- **Puertos ocupados al usar Docker:** detiene la infraestructura previa (`docker compose -p store-infrastructure down`) antes de usar la opcion C.
