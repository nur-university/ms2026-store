$env:COMPOSE_PROJECT_NAME = "store-infrastructure"

# Levantar la infraestructura con Docker Compose
docker compose -f './docker-compose-only-infrastructure.yml' up -d

# Los microservicios se auto-registran en Consul al arrancar (ver
# Services/*/**/Infrastructure/ServiceRegistration.cs), con su propio health
# check adjunto - ya no hace falta registrarlos a mano aqui.

# Ejecutar el script de inicialización en el contenedor de Vault
docker exec vault-server sh /vault-init.sh