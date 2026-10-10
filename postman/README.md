# Colección de Postman: saga de órdenes

`Store-Saga.postman_collection.json` prueba la saga de la nota de venta de punta a punta
(Orders → Inventory → Payments → Inventory) y sus compensaciones. Tiene 72 peticiones en 8 carpetas; cada una comprueba
el estado tras cada paso y espera (hasta 20 s) a que la saga avance.

> **Escribe en las bases de desarrollo.** La carpeta 1 emite una factura y descuenta 1 unidad de stock de forma
> permanente; la 5 emite otra factura. Las demás no dejan efecto neto en el stock. Al terminar:
> `bash Store/scripts/dev-restore-demo-data.sh` (con los servicios detenidos).

## 1. Infraestructura

```powershell
./Store/start-infrastructure.ps1
```

## 2. Servicios

Se necesitan Identity, Orders, Inventory y Payments, cada uno con su **WebApi y su WorkerService** (los workers mueven la
saga). Dos opciones:

```bash
dotnet run --project Store/Store.AppHost
```

```bash
bash Store/scripts/dev-services.sh build
bash Store/scripts/dev-services.sh start
bash Store/scripts/dev-services.sh status
```

Al arrancar, el worker de Orders vence las órdenes demo antiguas (quedan `Failed`); se revierte con el script de
restauración.

## 3. Postman

1. **Import** → `Store/postman/Store-Saga.postman_collection.json`.
2. **Settings → General → SSL certificate verification: OFF** (certificado de desarrollo de ASP.NET Core).
3. Revisa las variables de la colección:

| Variable | Valor por defecto |
|---|---|
| `identityUrl` | `https://localhost:7081` |
| `ordersUrl` | `https://localhost:7022` |
| `paymentsUrl` | `https://localhost:7210` |
| `inventoryUrl` | `https://localhost:7050` |
| `username` / `password` | administrador sembrado por `vault-init.sh` (solo desarrollo) |

Para HTTP usa los puertos `5126`, `5023`, `5242` y `5048`.

## 4. Ejecución

1. Carpeta **0 · Preparación** (*Run folder*): login y elección del producto con más stock.
2. Carpeta **1 · Venta completa**: camino feliz.
3. Carpetas **2 a 7**, en cualquier orden (son independientes).

| Carpeta | Qué demuestra |
|---|---|
| 0 · Preparación | Token y producto |
| 1 · Venta completa | Reservar, cobrar (efectivo), cobrar de nuevo (idempotente), entregar y completar; stock en cada paso |
| 2 · Cancelación | Compensación: se libera la reserva y se cancela la orden de cobro |
| 3 · Reserva fallida | Stock insuficiente → nota `Failed`, sin orden de cobro |
| 4 · Borrador | Escribir, completar y descartar un borrador |
| 5 · Pagada y no retirada | Transferencia → no cancelable (409) → anulación del supervisor con reembolso pendiente |
| 6 · Negativos | 401, validaciones, entregar sin pagar (409), método/referencia/monto inválidos |
| 7 · Consultas | Listados, cola de caja, pendientes de almacén y kardex |

Resultado esperado: todas las pruebas en verde.

## 5. Observar mientras corre

| Herramienta | URL | Qué mirar |
|---|---|---|
| Grafana | http://localhost:3000 | Dashboard *Saga de órdenes* |
| Jaeger | http://localhost:16686 | Servicio `orders.api`: una traza por venta, a través de RabbitMQ |
| Seq | http://localhost:5341 | Logs por `OrderId` / `TraceId` |
| RabbitMQ | http://localhost:15672 | Colas y mensajes |

## Si algo falla

| Síntoma | Causa probable | Solución |
|---|---|---|
| `Could not get response` | Servicio caído o verificación SSL activa | Paso 2 y paso 3.2 |
| `401` | Sin token o expirado | Reejecutar *Login* |
| «Esperar…» se agota (20 s) | Falta un worker o RabbitMQ | `dev-services.sh status` y logs |
| «Elegir producto» falla (`< 3 disponibles`) | Poco stock en la base | Script de restauración |
| `404` o rechazo al crear la nota | El producto no tiene precio en Orders | Usar otro `productId` con precio |
| `415` al cobrar | Colección editada sin `Content-Type: application/json` | Reimportar la original |
| `409` al entregar | Inventory aún no procesó `OrderPaid` | Ejecutar antes el paso «Inventory marca la venta como entregable» |

## Por consola (opcional)

Requiere instalar Newman (`npm`):

```bash
npx newman run Store/postman/Store-Saga.postman_collection.json --insecure
```
