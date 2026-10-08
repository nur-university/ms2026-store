var builder = DistributedApplication.CreateBuilder(args);

// Infrastructure (Postgres, RabbitMQ, Vault, Consul, Jaeger, Seq) is not managed here:
// start it separately with Store/start-infrastructure.ps1 (or .sh) before running this AppHost.
// Each project below keeps using its own appsettings.Development.json for connection info,
// exactly as it does when launched individually from Visual Studio.

builder.AddProject<Projects.Identity_WebApi>("identity-webapi");
builder.AddProject<Projects.Identity_WorkerService>("identity-workerservice");

builder.AddProject<Projects.Catalog_WebApi>("catalog-webapi");
builder.AddProject<Projects.Catalog_WorkerService>("catalog-workerservice");

builder.AddProject<Projects.Inventory_WebApi>("inventory-webapi");
builder.AddProject<Projects.Inventory_WorkerService>("inventory-workerservice");

builder.AddProject<Projects.Orders_WebApi>("orders-webapi"); 
builder.AddProject<Projects.Orders_WorkerService>("orders-workerservice");

builder.AddProject<Projects.Payments_WebApi>("payments-webapi");
builder.AddProject<Projects.Payments_WorkerService>("payments-workerservice");

// The gateway resolves the other services dynamically through Consul at runtime (see
// ConsulYarpConfigProvider), so it has no hard startup dependency on them here.
builder.AddProject<Projects.ApiGateway_WebApp>("apigateway-webapp");

builder.Build().Run();
