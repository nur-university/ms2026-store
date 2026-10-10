#!/bin/bash
# Starts / stops the Store services (WebApi + WorkerService of Identity, Catalog, Inventory, Orders, Payments) as host
# processes, for local verification (for example before running scripts/e2e-order-saga.sh).
#
#   bash Store/scripts/dev-services.sh build    # builds the ten projects (Debug); needed once and after code changes
#   bash Store/scripts/dev-services.sh start    # APIs first (they apply the EF migrations), then the workers
#   bash Store/scripts/dev-services.sh stop     # stops every process it started (and the API gateway, if running)
#   bash Store/scripts/dev-services.sh status   # which service ports answer
#
# Prerequisite: the infrastructure (Postgres, RabbitMQ, Consul, ...) is already up (start-infrastructure.*).
# It is the alternative to Store.AppHost when you want plain processes and plain log files.
#
# Environment variables:
#   SHORT_TIMEOUTS=1   the Orders worker uses very short saga timeouts (25 s for Started/Reserved, 10 min for
#                      PaymentInProcess, checked every 5 s) so they can be exercised in a test. Without it the defaults apply.
#   DEV_LOGS=<dir>     where the logs go (default: Store/.dev-logs, one file per process)
#
# NOTE: when the Orders worker starts it fails the orders that are older than their timeout. The demo orders of the
# development database are old, so they expire; run scripts/dev-restore-demo-data.sh afterwards if you want them back.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVICES="$ROOT/Services"
LOGS="${DEV_LOGS:-$ROOT/Store/.dev-logs}"
PORTS="7081 7291 7050 7022 7210"

web() { # name project port
  ASPNETCORE_ENVIRONMENT=Development ASPNETCORE_URLS="https://localhost:$3" \
    nohup dotnet run --no-build --no-launch-profile --project "$SERVICES/$2" > "$LOGS/$1.web.log" 2>&1 &
}
worker() { # name project [env assignments...]
  local name="$1" project="$2"; shift 2
  env DOTNET_ENVIRONMENT=Development "$@" \
    nohup dotnet run --no-build --no-launch-profile --project "$SERVICES/$project" > "$LOGS/$name.worker.log" 2>&1 &
}

up_count() {
  local up=0
  for p in $PORTS; do curl -sk -o /dev/null -m 2 "https://localhost:$p/swagger/v1/swagger.json" && up=$((up + 1)); done
  echo $up
}

case "$1" in
  build)
    for p in Identity/Identity.WebApi Identity/Identity.WorkerService Catalog/src/Catalog.WebApi Catalog/src/Catalog.WorkerService \
             Inventory/src/Inventory.WebApi Inventory/src/Inventory.WorkerService Orders/src/Orders.WebApi Orders/src/Orders.WorkerService \
             Payments/src/Payments.WebApi Payments/src/Payments.WorkerService; do
      echo "building $p"; dotnet build "$SERVICES/$p" -v q --nologo 2>&1 | grep -E " error |Build succeeded"
    done
    ;;
  start)
    mkdir -p "$LOGS"
    web identity  Identity/Identity.WebApi 7081
    web catalog   Catalog/src/Catalog.WebApi 7291
    web inventory Inventory/src/Inventory.WebApi 7050
    web orders    Orders/src/Orders.WebApi 7022
    web payments  Payments/src/Payments.WebApi 7210
    for _ in $(seq 1 40); do [ "$(up_count)" -eq 5 ] && break; sleep 3; done
    echo "APIs up: $(up_count)/5"

    worker identity  Identity/Identity.WorkerService
    worker catalog   Catalog/src/Catalog.WorkerService
    worker inventory Inventory/src/Inventory.WorkerService
    worker payments  Payments/src/Payments.WorkerService
    if [ -n "$SHORT_TIMEOUTS" ]; then
      worker orders Orders/src/Orders.WorkerService OrderTimeouts__StartedTimeout=00:00:25 OrderTimeouts__ReservedTimeout=00:00:25 \
        OrderTimeouts__PaymentTimeout=00:10:00 OrderTimeouts__CheckInterval=00:00:05
    else
      worker orders Orders/src/Orders.WorkerService
    fi
    sleep 20
    for f in "$LOGS"/*.worker.log; do echo "$(basename "$f"): $(grep -c ' ERR\| FTL\| CRT' "$f") errors"; done
    echo "logs in $LOGS"
    ;;
  stop)
    powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { \$_.Name -eq 'dotnet.exe' -and \$_.CommandLine -match '(Identity|Catalog|Inventory|Orders|Payments)\.(WebApi|WorkerService)' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }; Get-Process | Where-Object { \$_.ProcessName -like 'ApiGateway*' } | Stop-Process -Force" 2>/dev/null
    sleep 2
    echo "APIs still answering: $(up_count)/5"
    ;;
  status)
    for p in $PORTS 7273; do
      curl -sk -o /dev/null -m 2 "https://localhost:$p/" && echo "port $p: up" || echo "port $p: down"
    done
    ;;
  *)
    echo "usage: $0 build|start|stop|status"; exit 1
    ;;
esac
