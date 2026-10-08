docker compose -f './docker-compose-only-infrastructure.yml' up -d

# Los microservicios se auto-registran en Consul al arrancar (ver
# Services/*/**/Infrastructure/ServiceRegistration.cs), con su propio health
# check adjunto - ya no hace falta registrarlos a mano aqui.

docker exec vault-server sh /vault-init.sh