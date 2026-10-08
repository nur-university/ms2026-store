#!/bin/bash
# End-to-end check of the order saga (Orders -> Inventory -> Payments) against locally running services.
#
# Prerequisites: infrastructure up (start-infrastructure.*), RabbitMQ topology loaded from
# docker-infrastructure/rabbitmq/definitions.json, and Identity, Inventory, Orders and Payments
# (WebApi + WorkerService each) running, e.g. through Store.AppHost.
#
# Scenarios: A) happy path, B) payment failure + stock release, C) partial reservation (2nd item has no stock),
# D) prices come from the catalog, E) request validation, F) cancel an unpaid order, G) a paid order cannot be canceled.
#
# WARNING: it writes to the local development databases (creates orders/payments/transactions and, in
# scenarios A and G, permanently deducts 3 units of ITEM_WITH_STOCK).
# The products must have a price in the Orders database (it comes from Catalog's ProductCreated). Run it only against a disposable dev environment.
#
# Overridable through environment variables:
#   STORE_USER / STORE_PASSWORD   login (defaults: the user seeded by docker-infrastructure/vault/vault-init.sh)
#   ITEM_WITH_STOCK               product id with at least 3 available units
#   ITEM_WITHOUT_STOCK            product id with 0 available units
TV="${ITEM_WITH_STOCK:-650f38f2-08fc-4791-97f6-93f791776b32}"
NOSTOCK="${ITEM_WITHOUT_STOCK:-4afafa0e-f16a-4c66-8756-6075ba7c6032}"
TOKEN=$(curl -sk -m 15 -X POST https://localhost:7081/api/security/login -H 'content-type: application/json' \
  -d "{\"username\":\"${STORE_USER:-joseco48@gmail.com}\",\"password\":\"${STORE_PASSWORD:-admin@123}\"}" | tr -d '"[:space:]')
[ -n "$TOKEN" ] || { echo "Login failed"; exit 1; }

psql() { docker exec postgres-server psql -U postgres -d "$1" -tA -c "$2"; }
item()  { psql StoreInventory "select stock||'/'||reserved||'/'||available from item where \"itemId\"='$1'"; }
ostatus() { psql StoreOrders "select status from \"order\" where \"orderId\"='$1'"; }
pstatus() { psql StorePayments "select status from payment where \"sourceId\"='$1'"; }
tstatus() { psql StoreInventory "select status from transaction where \"sourceId\"='$1'"; }

wait_for() { # description, command, expected
  for i in $(seq 1 30); do
    got=$(eval "$2"); [ "$got" = "$3" ] && { echo "  ok   $1 = $got"; return 0; }; sleep 1
  done
  echo "  FAIL $1: expected '$3', got '$got'"; FAILED=1; return 1
}

create_order() { # json items
  curl -sk -m 20 -X POST https://localhost:7022/api/order -H "Authorization: Bearer $TOKEN" \
    -H 'content-type: application/json' -d "{\"items\":$1}" | python -c "import json,sys; d=json.load(sys.stdin); print(d.get('id') or d)"
}
payment() { # orderId action [body]
  curl -sk -m 20 -o /dev/null -w "%{http_code}" -X POST "https://localhost:7210/api/payment/orders/$1/$2" \
    -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' ${3:+-d "$3"}
}
FAILED=0
api_field() { curl -sk -m 20 -H "Authorization: Bearer $TOKEN" "https://localhost:7022/api/order/$1" | python -c "import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ''))" "$2"; }
cancel() { curl -sk -m 20 -o /dev/null -w "%{http_code}" -X POST "https://localhost:7022/api/order/$1/cancel" -H "Authorization: Bearer $TOKEN"; }
check_code() { # description expected items-json
  got=$(curl -sk -m 20 -o /dev/null -w "%{http_code}" -X POST https://localhost:7022/api/order -H "Authorization: Bearer $TOKEN"     -H 'content-type: application/json' -d "{\"items\":$3}")
  if [ "$got" = "$2" ]; then echo "  ok   $1 -> HTTP $got"; else echo "  FAIL $1: expected HTTP $2, got $got"; FAILED=1; fi
}

echo "== Baseline stock/reserved/available of TV: $(item $TV)"
BASE=$(item $TV)
IFS=/ read S0 R0 A0 <<< "$BASE"

echo; echo "== A. Happy path: order 2 units, then payment completed"
A=$(create_order "[{\"productId\":\"$TV\",\"price\":4000,\"quantity\":2}]"); echo "  order $A"
wait_for "order status"            "ostatus $A" PaymentInProcess
wait_for "inventory transaction"   "tstatus $A" Created
wait_for "TV reserved +2"          "item $TV"   "$S0/$((R0+2))/$((A0-2))"
echo "  payment complete -> HTTP $(payment $A complete)"
wait_for "payment status"          "pstatus $A" Completed
wait_for "order status"            "ostatus $A" Paid
wait_for "inventory transaction"   "tstatus $A" Completed
wait_for "TV stock -2 (confirmed)" "item $TV"   "$((S0-2))/$R0/$((A0-2))"
BASE=$(item $TV); IFS=/ read S1 R1 A1 <<< "$BASE"

echo; echo "== B. Compensation: order 1 unit, then payment failed"
B=$(create_order "[{\"productId\":\"$TV\",\"price\":4000,\"quantity\":1}]"); echo "  order $B"
wait_for "order status"            "ostatus $B" PaymentInProcess
wait_for "TV reserved +1"          "item $TV"   "$S1/$((R1+1))/$((A1-1))"
echo "  payment fail -> HTTP $(payment $B fail '{"reason":"card declined"}')"
wait_for "order status"            "ostatus $B" Failed
wait_for "inventory transaction"   "tstatus $B" Canceled
wait_for "TV reservation released" "item $TV"   "$S1/$R1/$A1"

echo; echo "== C. Partial reservation: 1 unit with stock + 1 unit without stock"
C=$(create_order "[{\"productId\":\"$TV\",\"price\":4000,\"quantity\":1},{\"productId\":\"$NOSTOCK\",\"price\":3000,\"quantity\":1}]"); echo "  order $C"
wait_for "order status"            "ostatus $C" Failed
echo "  reason: $(psql StoreOrders "select \"failureReason\" from \"order\" where \"orderId\"='$C'")"
wait_for "no inventory transaction persisted" "psql StoreInventory \"select count(*) from transaction where \\\"sourceId\\\"='$C'\"" 0
wait_for "TV stock untouched"      "item $TV"   "$S1/$R1/$A1"

echo; echo "== D. The price comes from the catalog, not from the client"
PRICE=$(psql StoreOrders "select price from product where \"productId\"='$TV'")
D=$(curl -sk -m 20 -X POST https://localhost:7022/api/order -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json'   -d "{\"items\":[{\"productId\":\"$TV\",\"quantity\":1,\"price\":1}]}" | python -c "import json,sys; print(json.load(sys.stdin).get('id'))")
echo "  order $D (client sent price 1, catalog price $PRICE)"
wait_for "order total = catalog price" "api_field $D total" "$(python -c "print(float('$PRICE'))")"
[ -n "$(api_field $D userId)" ] && echo "  ok   the order stores the authenticated user" || { echo "  FAIL the order has no user"; FAILED=1; }
wait_for "order status" "ostatus $D" PaymentInProcess
cancel $D >/dev/null
wait_for "cleanup: order canceled" "ostatus $D" Canceled

echo; echo "== E. Request validation"
check_code "unknown product"  404 "[{\"productId\":\"$(python -c 'import uuid;print(uuid.uuid4())')\",\"quantity\":1}]"
check_code "empty order"      400 "[]"
check_code "quantity zero"    400 "[{\"productId\":\"$TV\",\"quantity\":0}]"

echo; echo "== F. Cancel an unpaid order: stock released and pending payment canceled"
read S2 R2 A2 <<< "$(item $TV | tr / ' ')"
F=$(create_order "[{\"productId\":\"$TV\",\"quantity\":1}]"); echo "  order $F"
wait_for "TV reserved +1"          "item $TV"   "$S2/$((R2+1))/$((A2-1))"
wait_for "payment pending"         "pstatus $F" Pending
echo "  cancel -> HTTP $(cancel $F)"
wait_for "order status"            "ostatus $F" Canceled
wait_for "inventory transaction"   "tstatus $F" Canceled
wait_for "TV reservation released" "item $TV"   "$S2/$R2/$A2"
wait_for "payment status"          "pstatus $F" Cancelled
code=$(payment $F complete); [ "$code" = 409 ] && echo "  ok   complete a canceled payment -> HTTP 409" || { echo "  FAIL complete a canceled payment: expected HTTP 409, got $code"; FAILED=1; }

echo; echo "== G. A paid order cannot be canceled"
G=$(create_order "[{\"productId\":\"$TV\",\"quantity\":1}]"); echo "  order $G"
wait_for "order status"            "ostatus $G" PaymentInProcess
payment $G complete >/dev/null
wait_for "order status"            "ostatus $G" Paid
code=$(cancel $G); [ "$code" = 409 ] && echo "  ok   cancel a paid order -> HTTP 409" || { echo "  FAIL cancel a paid order: expected HTTP 409, got $code"; FAILED=1; }
wait_for "order is still"          "ostatus $G" Paid

echo; [ $FAILED -eq 0 ] && echo "ALL SCENARIOS PASSED" || echo "SOME CHECKS FAILED"
