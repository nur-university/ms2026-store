#!/bin/bash
# End-to-end check of the sales flow against locally running services:
#   sales advisor creates the sales note (Orders) -> stock is reserved (Inventory) -> a pending charge order appears at the
#   cashier (Payments) -> the cashier collects it (cash / transfer / POS card) and an invoice is issued -> the customer
#   picks the goods up at the warehouse (Inventory) -> the sale is completed.
#
# Prerequisites: infrastructure up (start-infrastructure.*), RabbitMQ topology loaded from
# docker-infrastructure/rabbitmq/definitions.json, and Identity, Inventory, Orders and Payments (WebApi + WorkerService
# each) running, e.g. through Store.AppHost. The products must have a price in the Orders database (it comes from Catalog's
# ProductCreated).
#
# Scenarios: A) full sale: pay at the cashier, then pick up   B) cancel an unpaid sale   C) partial reservation
#            D) price comes from the catalog   E) request validation   F) payment methods and invoice
#            G) a paid sale cannot be canceled   I) draft sales note   J) invoice detail and pickup by invoice
#            K) a paid sale nobody picked up: listing and manual annulment
#            L) write-offs and opening balance: created pending, approved or rejected   M) inventory queries and kardex
#            H) permissions per role
#
# WARNING: it writes to the local development databases: it creates orders, payments, invoices, reservations, write-offs
# and an opening balance, creates five test users (removed at the end), permanently deducts 4 units of ITEM_WITH_STOCK
# (scenarios A, J and L) and adds 2 at its current average cost (L). Run it only against a disposable dev environment;
# dev-restore-demo-data.sh puts the data back.
#
# Overridable through environment variables:
#   STORE_USER / STORE_PASSWORD   administrator login (default: the user seeded by docker-infrastructure/vault/vault-init.sh)
#   ITEM_WITH_STOCK               product id with at least 5 available units
#   ITEM_WITHOUT_STOCK            product id with 0 available units
TV="${ITEM_WITH_STOCK:-650f38f2-08fc-4791-97f6-93f791776b32}"
NOSTOCK="${ITEM_WITHOUT_STOCK:-4afafa0e-f16a-4c66-8756-6075ba7c6032}"
TEST_PASSWORD='E2e-Test#12345'
IDENTITY=https://localhost:7081; ORDERS=https://localhost:7022; PAYMENTS=https://localhost:7210; INVENTORY=https://localhost:7050
FAILED=0

psql() { docker exec postgres-server psql -U postgres -d "$1" -tA -c "$2"; }
login() { curl -sk -m 15 -X POST $IDENTITY/api/security/login -H 'content-type: application/json' \
  -d "{\"username\":\"$1\",\"password\":\"$2\"}" | tr -d '"[:space:]'; }
# http METHOD URL TOKEN [JSON BODY] -> prints the status code
http() { curl -sk -m 20 -o /dev/null -w "%{http_code}" -X "$1" "$2" -H "Authorization: Bearer $3" \
  ${4:+-H 'content-type: application/json' -d "$4"}; }
# json URL TOKEN FIELD -> prints one field of a JSON response
json() { curl -sk -m 20 -H "Authorization: Bearer $2" "$1" | python -c "import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ''))" "$3"; }

item()    { psql StoreInventory "select stock||'/'||reserved||'/'||available from item where \"itemId\"='$1'"; }
ostatus() { psql StoreOrders "select status from \"order\" where \"orderId\"='$1'"; }
pstatus() { psql StorePayments "select status from payment where \"sourceId\"='$1'"; }
tstatus() { psql StoreInventory "select status from transaction where \"sourceId\"='$1'"; }
released() { psql StoreInventory "select case when \"releasedOn\" is null then 'no' else 'yes' end from transaction where \"sourceId\"='$1'"; }

wait_for() { # description, command, expected
  for i in $(seq 1 30); do
    got=$(eval "$2"); [ "$got" = "$3" ] && { echo "  ok   $1 = $got"; return 0; }; sleep 1
  done
  echo "  FAIL $1: expected '$3', got '$got'"; FAILED=1; return 1
}
expect() { # description actual expected
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"; else echo "  FAIL $1: expected '$3', got '$2'"; FAILED=1; fi
}

create_order() { # token items-json [extra json fields, e.g. ,"customerName":"Ana"]
  curl -sk -m 20 -X POST $ORDERS/api/order -H "Authorization: Bearer $1" -H 'content-type: application/json' \
    -d "{\"items\":$2$3}" | python -c "import json,sys; d=json.load(sys.stdin); print(d.get('id') or d)"
}
one_tv() { echo "[{\"productId\":\"$TV\",\"quantity\":1}]"; }
collect() { http POST $PAYMENTS/api/payment/orders/$2/collect "$1" "$3"; }   # token orderId json
cancel() { http POST $ORDERS/api/order/$2/cancel "$1"; }                       # token orderId
deliver() { http POST $INVENTORY/api/transaction/orders/$2/deliver "$1"; }    # token orderId
# jget URL TOKEN PYTHON-EXPRESSION -> evaluates the expression over the JSON response, bound to d
jget() { curl -sk -m 20 -H "Authorization: Bearer $2" "$1" | python -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$3"; }
# newtx TOKEN JSON -> creates an inventory transaction by hand and prints its id (or the error response)
newtx() { curl -sk -m 20 -X POST $INVENTORY/api/transaction -H "Authorization: Bearer $1" -H 'content-type: application/json' \
  -d "$2" | python -c "import json,sys; d=json.load(sys.stdin); print(d.get('id') or d)"; }
approve() { http POST $INVENTORY/api/transaction/complete "$1" "{\"transactionId\":\"$2\"}"; }               # token transactionId
reject()  { http POST $INVENTORY/api/transaction/reject "$1" "{\"transactionId\":\"$2\",\"reason\":\"$3\"}"; } # token transactionId reason
itemcost() { psql StoreInventory "select \"unitaryCost\" from item where \"itemId\"='$1'"; }

# ---- test users, one per role (register-user creates the account, the role is assigned in the database)
ADMIN=$(login "${STORE_USER:-joseco48@gmail.com}" "${STORE_PASSWORD:-admin@123}")
[ -n "$ADMIN" ] || { echo "Login failed"; exit 1; }
declare -A ROLE_OF=([advisor]=SalesAdvisor [cashier]=Cashier [clerk]=WarehouseClerk [supervisor]=SalesSupervisor [manager]=InventoryManager)
declare -A TOKEN
cleanup() {
  for u in "${!ROLE_OF[@]}"; do
    id=$(psql StoreIdentity "select \"Id\" from \"AspNetUsers\" where \"UserName\"='e2e-$u@store.test'")
    [ -n "$id" ] || continue
    psql StoreIdentity "delete from \"AspNetUserClaims\" where \"UserId\"='$id'; delete from \"AspNetUserRoles\" where \"UserId\"='$id'; delete from \"AspNetUsers\" where \"Id\"='$id'" >/dev/null
    psql StoreInventory "delete from \"user\" where \"userId\"='$id'" >/dev/null
  done
}
trap cleanup EXIT
cleanup
for u in "${!ROLE_OF[@]}"; do
  http POST $IDENTITY/api/security/register-user "$ADMIN" \
    "{\"email\":\"e2e-$u@store.test\",\"password\":\"$TEST_PASSWORD\",\"firstName\":\"E2E\",\"lastName\":\"$u\"}" >/dev/null
done
sleep 5
for u in "${!ROLE_OF[@]}"; do
  psql StoreIdentity "insert into \"AspNetUserRoles\"(\"UserId\",\"RoleId\") select u.\"Id\", r.\"Id\" from \"AspNetUsers\" u, \"AspNetRoles\" r where u.\"UserName\"='e2e-$u@store.test' and r.\"Name\"='${ROLE_OF[$u]}'" >/dev/null
  TOKEN[$u]=$(login "e2e-$u@store.test" "$TEST_PASSWORD")
  [ -n "${TOKEN[$u]}" ] || { echo "Login of the test user $u failed"; exit 1; }
done
ADVISOR=${TOKEN[advisor]}; CASHIER=${TOKEN[cashier]}; CLERK=${TOKEN[clerk]}; SUPERVISOR=${TOKEN[supervisor]}; MANAGER=${TOKEN[manager]}

echo "== Baseline stock/reserved/available of the product: $(item $TV)"
read S0 R0 A0 <<< "$(item $TV | tr / ' ')"

echo; echo "== A. Full sale: advisor creates it, the cashier collects in cash, the customer picks the goods up"
A=$(create_order "$ADVISOR" "[{\"productId\":\"$TV\",\"quantity\":2}]" ',"customerName":"Ana Perez","customerDocument":"1234567"'); echo "  sales note $A"
wait_for "sales note status"        "ostatus $A" PaymentInProcess
wait_for "stock reserved +2"        "item $TV" "$S0/$((R0+2))/$((A0-2))"
expect   "the reservation is a sale" "$(psql StoreInventory "select concept from transaction where \"sourceId\"='$A'")" Sale
wait_for "charge order is pending"  "pstatus $A" Pending
expect   "customer reaches the charge order" "$(json $PAYMENTS/api/payment/orders/$A "$CASHIER" customerName)" "Ana Perez"
expect   "the pending queue lists it" "$(curl -sk -m 20 -H "Authorization: Bearer $CASHIER" "$PAYMENTS/api/payment/pending?pageSize=100" | python -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i['orderId']=='$A'))")" 1
expect   "warehouse cannot deliver before payment (HTTP)" "$(deliver "$CLERK" $A)" 409
AMOUNT=$(psql StorePayments "select amount from payment where \"sourceId\"='$A'"); AMOUNT=${AMOUNT%.*}
PAID=$((AMOUNT + 500))
COLLECT=$(curl -sk -m 20 -X POST $PAYMENTS/api/payment/orders/$A/collect -H "Authorization: Bearer $CASHIER" -H 'content-type: application/json' \
  -d "{\"method\":\"Cash\",\"amountReceived\":$PAID}")
INVOICE=$(echo "$COLLECT" | python -c "import json,sys; print(json.load(sys.stdin).get('invoiceNumber',''))")
echo "  collected in cash: $COLLECT"
expect   "invoice number has the F-######## format" "$(echo "$INVOICE" | grep -cE '^F-[0-9]{8}$')" 1
expect   "change given"             "$(echo "$COLLECT" | python -c "import json,sys; print(int(json.load(sys.stdin)['changeGiven']))")" 500
wait_for "payment status"           "pstatus $A" Completed
wait_for "sales note status"        "ostatus $A" Paid
expect   "the sales note carries the invoice" "$(json $ORDERS/api/order/$A "$ADVISOR" invoiceNumber)" "$INVOICE"
wait_for "reservation released for pickup" "released $A" yes
expect   "stock is NOT deducted by the payment" "$(item $TV)" "$S0/$((R0+2))/$((A0-2))"
expect   "invoice endpoint"         "$(json $PAYMENTS/api/payment/orders/$A/invoice "$CASHIER" invoiceNumber)" "$INVOICE"
expect   "warehouse delivers (HTTP)" "$(deliver "$CLERK" $A)" 200
wait_for "inventory transaction"    "tstatus $A" Completed
wait_for "stock deducted at pickup" "item $TV" "$((S0-2))/$R0/$((A0-2))"
wait_for "sales note completed"     "ostatus $A" Completed
expect   "delivering again is harmless" "$(deliver "$CLERK" $A)" 200
expect   "stock deducted only once" "$(item $TV)" "$((S0-2))/$R0/$((A0-2))"
read S1 R1 A1 <<< "$(item $TV | tr / ' ')"

echo; echo "== B. Cancel an unpaid sale: stock released and the charge order canceled"
B=$(create_order "$ADVISOR" "$(one_tv)"); echo "  sales note $B"
wait_for "stock reserved +1"        "item $TV" "$S1/$((R1+1))/$((A1-1))"
wait_for "charge order is pending"  "pstatus $B" Pending
expect   "cancel (HTTP)"            "$(cancel "$ADVISOR" $B)" 200
wait_for "sales note status"        "ostatus $B" Canceled
wait_for "inventory transaction"    "tstatus $B" Canceled
wait_for "stock released"           "item $TV" "$S1/$R1/$A1"
wait_for "charge order status"      "pstatus $B" Cancelled
expect   "collecting a canceled charge order (HTTP)" "$(collect "$CASHIER" $B '{"method":"Cash","amountReceived":999999}')" 409

echo; echo "== C. Partial reservation: 1 unit with stock + 1 unit without stock"
C=$(create_order "$ADVISOR" "[{\"productId\":\"$TV\",\"quantity\":1},{\"productId\":\"$NOSTOCK\",\"quantity\":1}]"); echo "  sales note $C"
wait_for "sales note status"        "ostatus $C" Failed
echo "  reason: $(psql StoreOrders "select \"failureReason\" from \"order\" where \"orderId\"='$C'")"
wait_for "no inventory transaction persisted" "psql StoreInventory \"select count(*) from transaction where \\\"sourceId\\\"='$C'\"" 0
wait_for "stock untouched"          "item $TV" "$S1/$R1/$A1"

echo; echo "== D. The price comes from the catalog, not from the client"
PRICE=$(psql StoreOrders "select price from product where \"productId\"='$TV'")
D=$(curl -sk -m 20 -X POST $ORDERS/api/order -H "Authorization: Bearer $ADVISOR" -H 'content-type: application/json' \
  -d "{\"items\":[{\"productId\":\"$TV\",\"quantity\":1,\"price\":1}]}" | python -c "import json,sys; print(json.load(sys.stdin).get('id'))")
echo "  sales note $D (client sent price 1, catalog price $PRICE)"
expect   "total = catalog price"    "$(json $ORDERS/api/order/$D "$ADVISOR" total)" "$(python -c "print(float('$PRICE'))")"
cancel "$ADVISOR" $D >/dev/null
wait_for "cleanup: canceled"        "ostatus $D" Canceled

echo; echo "== E. Request validation"
expect   "unknown product"          "$(http POST $ORDERS/api/order "$ADVISOR" "{\"items\":[{\"productId\":\"$(python -c 'import uuid;print(uuid.uuid4())')\",\"quantity\":1}]}")" 404
expect   "empty sales note"         "$(http POST $ORDERS/api/order "$ADVISOR" '{"items":[]}')" 400
expect   "quantity zero"            "$(http POST $ORDERS/api/order "$ADVISOR" "{\"items\":[{\"productId\":\"$TV\",\"quantity\":0}]}")" 400

echo; echo "== F. Payment methods: reference rules, change, and no double invoicing"
F=$(create_order "$ADVISOR" "$(one_tv)"); echo "  sales note $F"
wait_for "charge order is pending"  "pstatus $F" Pending
FAMOUNT=$(psql StorePayments "select amount from payment where \"sourceId\"='$F'"); FAMOUNT=${FAMOUNT%.*}
expect   "card without POS voucher" "$(collect "$CASHIER" $F '{"method":"Card"}')" 400
expect   "transfer without number"  "$(collect "$CASHIER" $F '{"method":"BankTransfer","reference":"  "}')" 400
expect   "cash that does not cover the amount" "$(collect "$CASHIER" $F "{\"method\":\"Cash\",\"amountReceived\":$((FAMOUNT-1))}")" 400
expect   "unknown method"           "$(collect "$CASHIER" $F '{"method":"Bitcoin"}')" 400
expect   "still pending after the rejected attempts" "$(pstatus $F)" Pending
FIRST=$(curl -sk -m 20 -X POST $PAYMENTS/api/payment/orders/$F/collect -H "Authorization: Bearer $CASHIER" -H 'content-type: application/json' -d '{"method":"Card","reference":"POS-AUTH-5521"}')
echo "  card payment: $FIRST"
INV1=$(echo "$FIRST" | python -c "import json,sys; print(json.load(sys.stdin).get('invoiceNumber',''))")
SECOND=$(curl -sk -m 20 -X POST $PAYMENTS/api/payment/orders/$F/collect -H "Authorization: Bearer $CASHIER" -H 'content-type: application/json' -d '{"method":"Card","reference":"POS-AUTH-5521"}')
expect   "invoice numbers are consecutive (rejected attempts consume none)" "$((10#${INV1#F-} - 10#${INVOICE#F-}))" 1
expect   "collecting again returns the same invoice" "$(echo "$SECOND" | python -c "import json,sys; print(json.load(sys.stdin).get('invoiceNumber',''))")" "$INV1"
expect   "only one payment has that invoice number" "$(psql StorePayments "select count(*) from payment where \"invoiceNumber\"='$INV1'")" 1
expect   "POS voucher is stored"    "$(psql StorePayments "select reference from payment where \"sourceId\"='$F'")" POS-AUTH-5521
expect   "payment by another method afterwards" "$(collect "$CASHIER" $F '{"method":"Cash","amountReceived":999999}')" 409
wait_for "sales note status"        "ostatus $F" Paid

echo; echo "== G. A paid sale cannot be canceled"
expect   "cancel (HTTP)"            "$(cancel "$ADVISOR" $F)" 409
wait_for "sales note is still"      "ostatus $F" Paid

echo; echo "== I. Draft sales note: nothing is reserved until the advisor completes it"
PRICE_TV=$(psql StoreOrders "select price from product where \"productId\"='$TV'")
read S3 R3 A3 <<< "$(item $TV | tr / ' ')"
DRAFT=$(curl -sk -m 20 -X POST $ORDERS/api/order/draft -H "Authorization: Bearer $ADVISOR" -H 'content-type: application/json' \
  -d "{\"items\":$(one_tv),\"customerName\":\"Luis Rojas\"}" | python -c "import json,sys; print(json.load(sys.stdin).get('id'))")
echo "  draft $DRAFT"
sleep 3
expect   "status is Draft"           "$(json $ORDERS/api/order/$DRAFT "$ADVISOR" status)" Draft
expect   "no stock was reserved"     "$(item $TV)" "$S3/$R3/$A3"
expect   "no charge order exists"    "$(psql StorePayments "select count(*) from payment where \"sourceId\"='$DRAFT'")" 0
expect   "another advisor cannot edit it (HTTP)" "$(http PUT $ORDERS/api/order/$DRAFT/items "$SUPERVISOR" "{\"items\":$(one_tv)}")" 404
expect   "lines can be replaced (HTTP)" "$(http PUT $ORDERS/api/order/$DRAFT/items "$ADVISOR" "{\"items\":[{\"productId\":\"$TV\",\"quantity\":2}]}")" 200
expect   "estimated total follows the lines" "$(json $ORDERS/api/order/$DRAFT "$ADVISOR" total)" "$(python -c "print(float('$PRICE_TV') * 2)")"
expect   "customer can be changed (HTTP)" "$(http PUT $ORDERS/api/order/$DRAFT/customer "$ADVISOR" '{"customerName":"Luis Rojas M.","customerDocument":"7654321"}')" 200
expect   "completing it (HTTP)"       "$(http POST $ORDERS/api/order/$DRAFT/confirm "$ADVISOR")" 200
wait_for "sale status"               "ostatus $DRAFT" PaymentInProcess
wait_for "stock reserved +2"         "item $TV" "$S3/$((R3+2))/$((A3-2))"
wait_for "charge order is pending"   "pstatus $DRAFT" Pending
expect   "completing it twice (HTTP)" "$(http POST $ORDERS/api/order/$DRAFT/confirm "$ADVISOR")" 409
expect   "editing a started sale (HTTP)" "$(http PUT $ORDERS/api/order/$DRAFT/items "$ADVISOR" "{\"items\":$(one_tv)}")" 409
cancel "$ADVISOR" $DRAFT >/dev/null
wait_for "stock released"            "item $TV" "$S3/$R3/$A3"
EMPTY=$(curl -sk -m 20 -X POST $ORDERS/api/order/draft -H "Authorization: Bearer $ADVISOR" -H 'content-type: application/json' -d '{}' | python -c "import json,sys; print(json.load(sys.stdin).get('id'))")
expect   "completing an empty draft (HTTP)" "$(http POST $ORDERS/api/order/$EMPTY/confirm "$ADVISOR")" 400
expect   "discarding a draft (HTTP)" "$(http DELETE $ORDERS/api/order/$EMPTY "$ADVISOR")" 200
expect   "discarded draft status"    "$(json $ORDERS/api/order/$EMPTY "$ADVISOR" status)" Discarded
expect   "completing a discarded draft (HTTP)" "$(http POST $ORDERS/api/order/$EMPTY/confirm "$ADVISOR")" 409

echo; echo "== J. Invoice with the detail of the sale, and pickup identified by the invoice"
J=$(create_order "$ADVISOR" "$(one_tv)" ',"customerName":"Marta Gomez","customerDocument":"998877"'); echo "  sales note $J"
wait_for "charge order is pending"  "pstatus $J" Pending
LINE_NAME=$(curl -sk -m 20 -H "Authorization: Bearer $CASHIER" $PAYMENTS/api/payment/orders/$J | python -c "import json,sys; d=json.load(sys.stdin); print(d['lines'][0]['productName'])")
expect   "charge order lists the product" "$LINE_NAME" "$(psql StoreOrders "select name from product where \"productId\"='$TV'")"
expect   "the sale is not entregable by invoice yet" "$(http GET $INVENTORY/api/transaction/pending-exits "$CLERK")" 200
expect   "pending queue shows it unpaid" "$(curl -sk -m 20 -H "Authorization: Bearer $CLERK" "$INVENTORY/api/transaction/pending-exits?pageSize=100" | python -c "import json,sys; print([i['paid'] for i in json.load(sys.stdin)['items'] if i['orderId']=='$J'])")" "[False]"
JINV=$(curl -sk -m 20 -X POST $PAYMENTS/api/payment/orders/$J/collect -H "Authorization: Bearer $CASHIER" -H 'content-type: application/json' -d '{"method":"BankTransfer","reference":"TRX-445566"}' | python -c "import json,sys; print(json.load(sys.stdin).get('invoiceNumber',''))")
echo "  invoice $JINV"
expect   "invoice lists the lines"   "$(curl -sk -m 20 -H "Authorization: Bearer $CASHIER" $PAYMENTS/api/payment/orders/$J/invoice | python -c "import json,sys; d=json.load(sys.stdin); print(len(d['lines']), d['lines'][0]['subtotal']==d['total'])")" "1 True"
wait_for "reservation released for pickup" "released $J" yes
expect   "the clerk looks the invoice up" "$(json $INVENTORY/api/transaction/invoices/$JINV "$CLERK" customerName)" "Marta Gomez"
expect   "unknown invoice (HTTP)"    "$(http GET $INVENTORY/api/transaction/invoices/F-99999999 "$CLERK")" 404
read S4 R4 A4 <<< "$(item $TV | tr / ' ')"
expect   "delivering by invoice (HTTP)" "$(http POST $INVENTORY/api/transaction/invoices/$JINV/deliver "$CLERK")" 200
wait_for "stock deducted at pickup"  "item $TV" "$((S4-1))/$((R4-1))/$A4"
wait_for "sales note completed"      "ostatus $J" Completed

echo; echo "== K. A paid sale nobody picked up: it stays reserved until a supervisor intervenes"
read S5 R5 A5 <<< "$(item $TV | tr / ' ')"
expect   "the paid sale of scenario F is listed (oldest first)" "$(curl -sk -m 20 -H "Authorization: Bearer $SUPERVISOR" "$ORDERS/api/order?status=Paid&paidBeforeDays=0&pageSize=100" | python -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i['id']=='$F'))")" 1
expect   "a sale picked up is not listed" "$(curl -sk -m 20 -H "Authorization: Bearer $SUPERVISOR" "$ORDERS/api/order?status=Paid&paidBeforeDays=0&pageSize=100" | python -c "import json,sys; print(sum(1 for i in json.load(sys.stdin)['items'] if i['id']=='$A'))")" 0
expect   "an advisor cannot annul (HTTP)" "$(http POST $ORDERS/api/order/$F/annul "$ADVISOR" '{"reason":"x"}')" 403
expect   "annulling needs a reason (HTTP)" "$(http POST $ORDERS/api/order/$F/annul "$SUPERVISOR" '{"reason":"  "}')" 400
expect   "a picked up sale cannot be annulled (HTTP)" "$(http POST $ORDERS/api/order/$A/annul "$SUPERVISOR" '{"reason":"x"}')" 409
expect   "the supervisor annuls it (HTTP)" "$(http POST $ORDERS/api/order/$F/annul "$SUPERVISOR" '{"reason":"customer never came back"}')" 200
wait_for "sales note status"         "ostatus $F" Canceled
expect   "flagged for refund"        "$(json $ORDERS/api/order/$F "$SUPERVISOR" refundRequired)" True
wait_for "inventory transaction"     "tstatus $F" Canceled
wait_for "stock released"            "item $TV" "$S5/$((R5-1))/$((A5+1))"
expect   "the invoice is still the issued one" "$(json $PAYMENTS/api/payment/orders/$F/invoice "$CASHIER" invoiceNumber)" "$INV1"

echo; echo "== L. Write-offs and opening balance: created pending by the clerk, approved or rejected by the inventory manager"
read S6 R6 A6 <<< "$(item $TV | tr / ' ')"
COST=$(itemcost $TV)
ONE_TV="[{\"itemId\":\"$TV\",\"quantity\":1,\"unitaryCost\":10}]"
expect   "a sale cannot be created by hand (HTTP)"     "$(http POST $INVENTORY/api/transaction "$CLERK" "{\"concept\":\"Sale\",\"items\":$ONE_TV}")" 400
expect   "a purchase cannot be created by hand (HTTP)" "$(http POST $INVENTORY/api/transaction "$CLERK" "{\"concept\":\"Purchase\",\"items\":$ONE_TV}")" 400
expect   "a write-off needs a note (HTTP)"             "$(http POST $INVENTORY/api/transaction "$CLERK" "{\"concept\":\"Damaged\",\"items\":$ONE_TV,\"notes\":\" \"}")" 400
expect   "unknown concept (HTTP)"                      "$(http POST $INVENTORY/api/transaction "$CLERK" "{\"concept\":\"Stolen\",\"items\":$ONE_TV,\"notes\":\"x\"}")" 400
expect   "more than the available stock (HTTP)"        "$(http POST $INVENTORY/api/transaction "$CLERK" "{\"concept\":\"Lost\",\"items\":[{\"itemId\":\"$TV\",\"quantity\":999999}],\"notes\":\"x\"}")" 400
expect   "nothing was reserved by the rejected requests" "$(item $TV)" "$S6/$R6/$A6"
expect   "a cashier cannot report a write-off (HTTP)"  "$(http POST $INVENTORY/api/transaction "$CASHIER" "{\"concept\":\"Damaged\",\"items\":$ONE_TV,\"notes\":\"x\"}")" 403
DMG=$(newtx "$CLERK" "{\"concept\":\"Damaged\",\"items\":$ONE_TV,\"notes\":\"e2e: screen broken in the warehouse\"}"); echo "  write-off (damaged) $DMG"
expect   "the write-off is pending"   "$(json $INVENTORY/api/transaction/$DMG "$MANAGER" status)" Created
expect   "it reserves the stock"      "$(item $TV)" "$S6/$((R6+1))/$((A6-1))"
expect   "the clerk cannot approve it (HTTP)" "$(approve "$CLERK" $DMG)" 403
expect   "the manager approves it (HTTP)" "$(approve "$MANAGER" $DMG)" 200
expect   "the stock is deducted"      "$(item $TV)" "$((S6-1))/$R6/$((A6-1))"
expect   "approving it again is harmless (HTTP)" "$(approve "$MANAGER" $DMG)" 200
expect   "rejecting it afterwards (HTTP)" "$(reject "$MANAGER" $DMG x)" 409
expect   "deducted only once"         "$(item $TV)" "$((S6-1))/$R6/$((A6-1))"
MANAGER_ID=$(psql StoreIdentity "select \"Id\" from \"AspNetUsers\" where \"UserName\"='e2e-manager@store.test'")
expect   "the reviewer is recorded"   "$(json $INVENTORY/api/transaction/$DMG "$MANAGER" reviewedBy)" "$MANAGER_ID"
LOST=$(newtx "$CLERK" "{\"concept\":\"Lost\",\"items\":$ONE_TV,\"notes\":\"e2e: not found in the stocktaking\"}"); echo "  write-off (lost) $LOST"
expect   "it reserves the stock"      "$(item $TV)" "$((S6-1))/$((R6+1))/$((A6-2))"
expect   "the manager rejects it (HTTP)" "$(reject "$MANAGER" $LOST "found it in the back room")" 200
expect   "the reservation is given back" "$(item $TV)" "$((S6-1))/$R6/$((A6-1))"
expect   "rejected status and reason" "$(jget $INVENTORY/api/transaction/$LOST "$MANAGER" "d['status'] + '|' + d['rejectionReason']")" "Canceled|found it in the back room"
TA=$(psql StoreInventory "select \"transactionId\" from transaction where \"sourceId\"='$A'")
expect   "the reservation of a sale is not approved by hand (HTTP)" "$(approve "$MANAGER" $TA)" 409
OPEN=$(newtx "$MANAGER" "{\"concept\":\"OpeningBalance\",\"items\":[{\"itemId\":\"$TV\",\"quantity\":2,\"unitaryCost\":$COST}]}"); echo "  opening balance $OPEN"
expect   "nothing enters while it is pending" "$(item $TV)" "$((S6-1))/$R6/$((A6-1))"
expect   "the manager approves it (HTTP)" "$(approve "$MANAGER" $OPEN)" 200
expect   "the stock goes up"          "$(item $TV)" "$((S6+1))/$R6/$((A6+1))"
expect   "same cost, same average"    "$(itemcost $TV)" "$COST"
expect   "concepts stored"            "$(psql StoreInventory "select string_agg(concept, ',' order by \"creationDate\") from transaction where \"transactionId\" in ('$DMG','$LOST','$OPEN')")" "Damaged,Lost,OpeningBalance"

echo; echo "== M. Inventory queries: transactions, item stock and kardex"
expect   "list by concept"            "$(jget "$INVENTORY/api/transaction?concept=Damaged&pageSize=100" "$MANAGER" "sum(1 for i in d['items'] if i['id']=='$DMG')")" 1
expect   "list by type, status and concept" "$(jget "$INVENTORY/api/transaction?type=Exit&status=Canceled&concept=lost&pageSize=100" "$MANAGER" "[i['id'] for i in d['items']].count('$LOST')")" 1
expect   "list by source"             "$(jget "$INVENTORY/api/transaction?sourceType=orders&concept=Sale&from=$(date -u +%F)&to=$(date -u +%F)&pageSize=100" "$MANAGER" "sum(1 for i in d['items'] if i['id']=='$TA')")" 1
expect   "invalid filter (HTTP)"      "$(http GET "$INVENTORY/api/transaction?concept=Stolen" "$MANAGER")" 400
expect   "transaction detail"         "$(jget $INVENTORY/api/transaction/$DMG "$MANAGER" "d['concept'], d['lines'][0]['quantity'], d['notes']")" "('Damaged', 1, 'e2e: screen broken in the warehouse')"
expect   "unknown transaction (HTTP)" "$(http GET $INVENTORY/api/transaction/$(python -c 'import uuid;print(uuid.uuid4())') "$MANAGER")" 404
expect   "item stock"                 "$(jget $INVENTORY/api/item/$TV "$CLERK" "f\"{d['stock']}/{d['reserved']}/{d['available']}\"")" "$(item $TV)"
expect   "unknown item (HTTP)"        "$(http GET $INVENTORY/api/item/$(python -c 'import uuid;print(uuid.uuid4())') "$CLERK")" 404
MOVES=$(json "$INVENTORY/api/item/$TV/movements?pageSize=1" "$MANAGER" total)
expect   "the kardex ends at the current stock" "$(json "$INVENTORY/api/item/$TV/movements?pageSize=1&page=$MOVES" "$MANAGER" balanceAfter)" "$(item $TV | cut -d/ -f1)"
TODAY_MOVES=$(curl -sk -m 20 -H "Authorization: Bearer $MANAGER" "$INVENTORY/api/item/$TV/movements?from=$(date -u +%F)&pageSize=200")
expect   "today's kardex shows the write-off as an exit" "$(echo "$TODAY_MOVES" | python -c "import json,sys; print([(m['concept'], m['quantityOut']) for m in json.load(sys.stdin)['movements'] if m['transactionId']=='$DMG'])")" "[('Damaged', 1)]"
expect   "and the opening balance as an entry at its cost" "$(echo "$TODAY_MOVES" | python -c "import json,sys; print([(m['quantityIn'], m['unitaryCost']) for m in json.load(sys.stdin)['movements'] if m['transactionId']=='$OPEN'])")" "[(2, $(python -c "print(float('$COST'))"))]"
expect   "the rejected write-off did not move the stock" "$(echo "$TODAY_MOVES" | python -c "import json,sys; print(sum(1 for m in json.load(sys.stdin)['movements'] if m['transactionId']=='$LOST'))")" 0
expect   "the clerk reads the inventory (HTTP)" "$(http GET $INVENTORY/api/item "$CLERK")" 200
expect   "an advisor cannot read the inventory (HTTP)" "$(http GET $INVENTORY/api/item/$TV "$ADVISOR")" 403
expect   "a cashier cannot list transactions (HTTP)" "$(http GET $INVENTORY/api/transaction "$CASHIER")" 403

echo; echo "== H. Permissions per role"
H=$(create_order "$ADMIN" "$(one_tv)"); echo "  sales note $H (created by the administrator)"
wait_for "charge order is pending"  "pstatus $H" Pending
expect   "advisor cannot collect"               "$(collect "$ADVISOR" $H '{"method":"Cash","amountReceived":999999}')" 403
expect   "advisor cannot deliver"               "$(deliver "$ADVISOR" $H)" 403
expect   "cashier cannot create sales notes"    "$(http POST $ORDERS/api/order "$CASHIER" "{\"items\":$(one_tv)}")" 403
expect   "cashier cannot deliver"               "$(deliver "$CASHIER" $H)" 403
expect   "warehouse clerk cannot collect"       "$(collect "$CLERK" $H '{"method":"Cash","amountReceived":999999}')" 403
expect   "warehouse clerk cannot read payments" "$(http GET $PAYMENTS/api/payment/pending "$CLERK")" 403
expect   "no token"                             "$(curl -sk -m 10 -o /dev/null -w '%{http_code}' $PAYMENTS/api/payment/pending)" 401
expect   "cashier reads the queue"              "$(http GET $PAYMENTS/api/payment/pending "$CASHIER")" 200
expect   "advisor cannot read another advisor's sales note" "$(http GET $ORDERS/api/order/$H "$ADVISOR")" 404
expect   "advisor cannot cancel it either"      "$(cancel "$ADVISOR" $H)" 404
expect   "advisor reads the own sales note"     "$(http GET $ORDERS/api/order/$A "$ADVISOR")" 200
expect   "advisor's list only has own notes"    "$(curl -sk -m 20 -H "Authorization: Bearer $ADVISOR" "$ORDERS/api/order?pageSize=100" | python -c "import json,sys; print(len(set(i['userId'] for i in json.load(sys.stdin)['items'])))")" 1
expect   "supervisor reads any sales note"      "$(http GET $ORDERS/api/order/$H "$SUPERVISOR")" 200
expect   "supervisor can cancel any sales note" "$(cancel "$SUPERVISOR" $H)" 200
wait_for "sales note canceled"      "ostatus $H" Canceled

echo; [ $FAILED -eq 0 ] && echo "ALL SCENARIOS PASSED" || echo "SOME CHECKS FAILED"
