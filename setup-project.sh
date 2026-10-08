#!/bin/bash

# declaring a variable with the current directory path
current_dir=$(dirname "$(realpath "$0")")
# declaring a variable with the parent directory path
parent_dir=$(dirname "$current_dir")

"$current_dir/scripts/clone-repository.sh" https://github.com/nur-university/ms2026-store-identity.git "$parent_dir/Services/Identity"
"$current_dir/scripts/clone-repository.sh" https://github.com/nur-university/ms2026-store-api-gateway.git "$parent_dir/Services/ApiGateway"
"$current_dir/scripts/clone-repository.sh" https://github.com/nur-university/ms2026-store-catalog.git "$parent_dir/Services/Catalog"
"$current_dir/scripts/clone-repository.sh" https://github.com/nur-university/ms2026-store-inventory.git "$parent_dir/Services/Inventory"
"$current_dir/scripts/clone-repository.sh" https://github.com/nur-university/ms2026-store-orders.git "$parent_dir/Services/Orders"
"$current_dir/scripts/clone-repository.sh" https://github.com/nur-university/ms2026-store-payments.git "$parent_dir/Services/Payments"
"$current_dir/scripts/clone-repository.sh" https://github.com/nur-university/sk2026-store-access.git "$parent_dir/SharedKernel/Nur.Store2026.Access"
"$current_dir/scripts/clone-repository.sh" https://github.com/nur-university/sk2026-store-integration.git "$parent_dir/SharedKernel/Nur.Store2026.Integration"
"$current_dir/scripts/clone-repository.sh" https://github.com/nur-university/sk2026-store-security.git "$parent_dir/SharedKernel/Nur.Store2026.Security"
"$current_dir/scripts/clone-repository.sh" https://github.com/nur-university/sk2026-store-observability.git "$parent_dir/SharedKernel/Nur.Store2026.Observability"
