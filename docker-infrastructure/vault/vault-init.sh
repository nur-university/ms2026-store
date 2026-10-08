#!/bin/sh
# VAULT_ADDR/POSTGRES_HOST default to the plain host workflow (Vault and
# Postgres reachable at localhost). Override via env vars to reuse this same
# script when it runs in its own container instead of `docker exec`-ed into
# vault-server directly - see Store/docker-compose.yml's vault-init service.
: "${VAULT_ADDR:=http://localhost:8200}"
export VAULT_ADDR
: "${POSTGRES_HOST:=localhost}"

sleep 5s
echo "Initializing Vault..."
vault login vaultroot

cat <<EOF | vault kv put -mount=secret IdentityDatabaseConnectionString -
{
  "ConnectionString": "Host=$POSTGRES_HOST;Port=5432;Database=StoreIdentity;Username=postgres;Password=postgresspassword;Include Error Detail=true"
}
EOF

cat <<EOF | vault kv put -mount=secret CatalogDatabaseConnectionString -
{
  "ConnectionString": "Host=$POSTGRES_HOST;Port=5432;Database=StoreCatalog;Username=postgres;Password=postgresspassword;Include Error Detail=true"
}
EOF

cat <<EOF | vault kv put -mount=secret InventoryDatabaseConnectionString -
{
  "ConnectionString": "Host=$POSTGRES_HOST;Port=5432;Database=StoreInventory;Username=postgres;Password=postgresspassword;Include Error Detail=true"
}
EOF

cat <<EOF | vault kv put -mount=secret JwtOptions -
{
  "Lifetime": 30,
  "SecretKey": "HL#6j=4;5H{5qZ#M=6J!1[W<YvWdbzEif|M]:ZB<6<{ap^K!@Tg{];OD0E",
  "ValidAudience": "storeApp",
  "ValidIssuer": "identity",
  "ValidateAudience": true,
  "ValidateIssuer": true,
  "ValidateLifetime": false
}
EOF

cat <<EOF | vault kv put -mount=secret RabbitMqSettings -
{
  "Password": "storeUserPass",
  "UseSsl": true,
  "UserName": "storeUser",
  "VirtualHost": "/"
}
EOF

cat <<EOF | vault kv put -mount=secret DefaultUser -
{
  "email": "joseco48@gmail.com",
  "firstName": "Jose Carlos",
  "lastName": "Gutierrez",
  "password": "admin@123",
  "user": "joseco48@gmail.com"
}
EOF

