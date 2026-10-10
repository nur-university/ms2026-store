#!/bin/bash
# Puts the demo data of the LOCAL development databases back to the state this workspace was developed against, after
# running e2e scripts or experiments:
#
#   bash Store/scripts/dev-restore-demo-data.sh [YYYY-MM-DD]
#
# The date (default: today, UTC) is the first day whose rows are considered test data: every order, payment, inventory
# transaction and catalog row created on or after it is deleted. The script is idempotent.
#
# Demo baseline it restores:
#   - 5 old orders (4 PaymentInProcess, 1 Started) and their 4 Pending payments (the saga timeouts expire them when the
#     Orders worker starts, which also cancels their payments);
#   - inventory item "Smart TV LG 4k 55inch": stock 15, reserved 4, available 11, average cost 4000; the other two items
#     without stock (write-offs, opening balances and sales created by tests are deleted with the other transactions);
#   - Orders product prices equal to Catalog's (6000 / 5000 / 7000);
#   - invoice numbers start again at F-00000001; inbox tables empty; test users (@store.test) removed.
#
# WARNING: destructive. It only makes sense against the disposable development databases of this workspace.

SINCE="${1:-$(date -u +%F)}"
TV=650f38f2-08fc-4791-97f6-93f791776b32
psql() { docker exec postgres-server psql -U postgres -d "$1" -tA -c "$2"; }

echo "restoring demo data (rows created since $SINCE are removed)"

# 1. rows created by tests
psql StoreOrders "delete from \"orderItem\" where \"orderId\" in (select \"orderId\" from \"order\" where \"startedOn\" >= '$SINCE'); delete from \"order\" where \"startedOn\" >= '$SINCE'" >/dev/null
psql StoreInventory "delete from \"transactionItem\" where \"transactionId\" in (select \"transactionId\" from transaction where \"creationDate\" >= '$SINCE'); delete from transaction where \"creationDate\" >= '$SINCE'" >/dev/null
psql StorePayments "delete from payment where \"createdOn\" >= '$SINCE'" >/dev/null
psql StoreCatalog "delete from catalog.product where name like 'Flow check%'; delete from catalog.category where name like 'Flow check%'" >/dev/null 2>&1

# 2. the five demo orders and their pending payments
for row in "d61e4b3d-6834-43b7-8d35-ea19b0103ce6|Started" "a3c9b508-a2c5-4c4e-ad36-4e55c95b996c|PaymentInProcess" \
           "d69e04ac-2eae-457e-9762-45c5158bd197|PaymentInProcess" "b335dec2-6694-4ca8-b64f-62543826f971|PaymentInProcess" \
           "81ca72bd-9fe1-4df7-8077-bd81c9dcc6fb|PaymentInProcess"; do
  id="${row%%|*}"; status="${row##*|}"
  psql StoreOrders "update \"order\" set status='$status', \"failedOn\"=null, \"failureReason\"=null, \"canceledOn\"=null where \"orderId\"='$id'" >/dev/null
  psql StorePayments "update payment set status='Pending' where \"sourceId\"='$id' and status='Cancelled'" >/dev/null
done

# 3. stock, prices, numbering, inbox, test users
psql StoreInventory "update item set stock=15, reserved=4, available=11, \"unitaryCost\"=4000 where \"itemId\"='$TV'; update item set stock=0, reserved=0, available=0, \"unitaryCost\"=0 where \"itemId\"<>'$TV'" >/dev/null
psql StoreOrders "update product set price=6000 where \"productId\"='$TV'; update product set price=5000 where \"productId\"='4afafa0e-f16a-4c66-8756-6075ba7c6032'; update product set price=7000 where \"productId\"='5b28a21b-914e-4193-84b2-a92570ff6a3d'" >/dev/null
psql StorePayments "ALTER SEQUENCE invoice_number_seq RESTART WITH 1" >/dev/null 2>&1
for db in StoreOrders StoreInventory StorePayments; do psql $db 'delete from "inboxMessage"' >/dev/null 2>&1; done
for id in $(psql StoreIdentity "select \"Id\" from \"AspNetUsers\" where \"UserName\" like '%@store.test'"); do
  psql StoreIdentity "delete from \"AspNetUserClaims\" where \"UserId\"='$id'; delete from \"AspNetUserRoles\" where \"UserId\"='$id'; delete from \"AspNetUsers\" where \"Id\"='$id'" >/dev/null
  psql StoreInventory "delete from \"user\" where \"userId\"='$id'" >/dev/null
done

echo "orders      : $(psql StoreOrders 'select count(*) from "order"') (expected 5)  states: $(psql StoreOrders "select status||'='||count(*) from \"order\" group by status" | paste -sd, -)"
echo "payments    : $(psql StorePayments 'select count(*) from payment') (expected 4)  states: $(psql StorePayments "select status||'='||count(*) from payment group by status" | paste -sd, -)"
echo "transactions: $(psql StoreInventory 'select count(*) from transaction') (expected 6)"
echo "TV stock    : $(psql StoreInventory "select stock||'/'||reserved||'/'||available||' cost '||\"unitaryCost\" from item where \"itemId\"='$TV'") (expected 15/4/11 cost 4000.00)"
echo "users       : identity $(psql StoreIdentity 'select count(*) from "AspNetUsers"') (expected 1), inventory $(psql StoreInventory 'select count(*) from "user"') (expected 2)"
