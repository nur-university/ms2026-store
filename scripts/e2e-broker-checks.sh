#!/bin/bash
# Broker-level checks of the saga's reliability: duplicate delivery, duplicated compensation and poison messages.
#
# Prerequisites: infrastructure up, and Inventory (WebApi + WorkerService) running.
# WARNING: writes to the dev databases (a reservation for a made-up order, released again by the script).
# Overridable: ITEM_WITH_STOCK (product id with at least 1 available unit).
TV="${ITEM_WITH_STOCK:-650f38f2-08fc-4791-97f6-93f791776b32}"
RMQ="http://localhost:15672/api"; AUTH="storeUser:storeUserPassword"
FAILED=0
q() { docker exec postgres-server psql -U postgres -d "$1" -tA -c "$2"; }
item() { q StoreInventory "select stock||'/'||reserved||'/'||available from item where \"itemId\"='$TV'"; }
check() { # description actual expected
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"; else echo "  FAIL $1: expected '$3', got '$2'"; FAILED=1; fi
}
publish() { # exchange json
  python - "$1" "$2" <<'PY' | curl -s -u "$AUTH" -H 'content-type: application/json' -X POST "$RMQ/exchanges/%2F/$1/publish" -d @- -o /dev/null -w "  published to $1: %{http_code}\n"
import json,sys
print(json.dumps({"properties":{},"routing_key":"","payload":sys.argv[2],"payload_encoding":"string"}))
PY
}
uuid() { python -c "import uuid; print(uuid.uuid4())"; }

echo "== A. Duplicates: the same OrderStarted delivered twice, and republished with a new message Id"
read S0 R0 A0 <<< "$(item | tr / ' ')"
ORDER=$(uuid); M1=$(uuid); M2=$(uuid)
J1="{\"OrderId\":\"$ORDER\",\"Items\":[{\"ProductId\":\"$TV\",\"Price\":4000,\"Quantity\":1}],\"Id\":\"$M1\",\"CreatedAt\":\"2026-10-08T00:00:00+00:00\"}"
J2="{\"OrderId\":\"$ORDER\",\"Items\":[{\"ProductId\":\"$TV\",\"Price\":4000,\"Quantity\":1}],\"Id\":\"$M2\",\"CreatedAt\":\"2026-10-08T00:00:00+00:00\"}"
publish order-started "$J1"; publish order-started "$J1"; publish order-started "$J2"
sleep 8
check "reservations for the order"   "$(q StoreInventory "select count(*) from transaction where \"sourceId\"='$ORDER'")" 1
check "TV reserved only once (+1)"   "$(item)" "$S0/$((R0+1))/$((A0-1))"
check "inbox rows (2 distinct ids)"  "$(q StoreInventory "select count(*) from \"inboxMessage\" where \"messageId\" in ('$M1','$M2')")" 2

echo; echo "== B. Duplicated compensation: OrderStockReleaseRequested twice releases once"
R1=$(uuid); R2=$(uuid)
publish order-stock-release-requested "{\"OrderId\":\"$ORDER\",\"Reason\":\"test\",\"Id\":\"$R1\",\"CreatedAt\":\"2026-10-08T00:00:00+00:00\"}"
publish order-stock-release-requested "{\"OrderId\":\"$ORDER\",\"Reason\":\"test\",\"Id\":\"$R2\",\"CreatedAt\":\"2026-10-08T00:00:00+00:00\"}"
sleep 6
check "transaction status"           "$(q StoreInventory "select status from transaction where \"sourceId\"='$ORDER'")" Canceled
check "TV back to baseline"          "$(item)" "$S0/$R0/$A0"

echo; echo "== C. Poison message goes to the error queue after the consumer gives up"
curl -s -u "$AUTH" -X DELETE "$RMQ/queues/%2F/inventory-order-paid.error" -o /dev/null
publish order-paid "this is not json"
sleep 4
check "inventory-order-paid.error holds the message" "$(curl -s -u "$AUTH" "$RMQ/queues/%2F/inventory-order-paid.error" | python -c "import json,sys; print(json.load(sys.stdin).get('messages'))")" 1
check "main queue is empty (not stuck unacked)"      "$(curl -s -u "$AUTH" "$RMQ/queues/%2F/inventory-order-paid" | python -c "import json,sys; d=json.load(sys.stdin); print(d.get('messages'))")" 0
echo "  reason header: $(curl -s -u "$AUTH" -X POST "$RMQ/queues/%2F/inventory-order-paid.error/get" -H 'content-type: application/json' -d '{"count":1,"ackmode":"ack_requeue_true","encoding":"auto"}' | python -c "import json,sys; d=json.load(sys.stdin); print(d[0]['properties']['headers'].get('x-failure-reason'))")"
curl -s -u "$AUTH" -X DELETE "$RMQ/queues/%2F/inventory-order-paid.error" -o /dev/null

echo; [ $FAILED -eq 0 ] && echo "ALL BROKER CHECKS PASSED" || echo "SOME CHECKS FAILED"
