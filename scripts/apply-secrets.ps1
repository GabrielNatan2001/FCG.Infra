# Aplica Kubernetes Secrets sem versionar senhas no Git.
# Uso (a partir de fase2 ou FCG.Infra):
#   .\FCG.Infra\scripts\apply-secrets.ps1
#
# Override opcional via variáveis de ambiente antes de rodar:
#   $env:FCG_POSTGRES_PASSWORD = "senha-forte"
#   $env:FCG_RABBIT_PASSWORD   = "senha-forte"
#   $env:FCG_JWT_KEY           = "chave-jwt-com-32+chars"

$ErrorActionPreference = "Stop"

$PostgresUser = if ($env:FCG_POSTGRES_USER) { $env:FCG_POSTGRES_USER } else { "postgres" }
$PostgresPass = if ($env:FCG_POSTGRES_PASSWORD) { $env:FCG_POSTGRES_PASSWORD } else { "postgres" }
$RabbitUser   = if ($env:FCG_RABBIT_USER) { $env:FCG_RABBIT_USER } else { "admin" }
$RabbitPass   = if ($env:FCG_RABBIT_PASSWORD) { $env:FCG_RABBIT_PASSWORD } else { "admin" }
$JwtKey       = if ($env:FCG_JWT_KEY) { $env:FCG_JWT_KEY } else { "rN8#kL2vQ9@xT5mP1!zC7`$dH4^bW6&yU" }

$PgUsers    = "Host=fcg-postgres;Port=5432;Database=fcg_users;Username=$PostgresUser;Password=$PostgresPass"
$PgCatalog  = "Host=fcg-postgres;Port=5432;Database=fcg_catalog;Username=$PostgresUser;Password=$PostgresPass"
$PgPayments = "Host=fcg-postgres;Port=5432;Database=fcg_payments;Username=$PostgresUser;Password=$PostgresPass"
$RabbitUri  = "amqp://${RabbitUser}:${RabbitPass}@fcg-rabbitmq:5672/"

function Set-FcgSecret {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Literals
    )

    $args = @("create", "secret", "generic", $Name, "--dry-run=client", "-o", "yaml")
    foreach ($key in $Literals.Keys) {
        $args += "--from-literal=$key=$($Literals[$key])"
    }

    Write-Host "→ Secret $Name"
    $yaml = & kubectl @args
    $yaml | kubectl apply -f -
}

Write-Host "Aplicando secrets FCG no cluster atual..."
kubectl config current-context

Set-FcgSecret -Name "fcg-postgres-secret" -Literals @{
    POSTGRES_USER     = $PostgresUser
    POSTGRES_PASSWORD = $PostgresPass
}

Set-FcgSecret -Name "fcg-rabbitmq-secret" -Literals @{
    RABBITMQ_DEFAULT_USER = $RabbitUser
    RABBITMQ_DEFAULT_PASS = $RabbitPass
}

Set-FcgSecret -Name "fcg-users-api-secret" -Literals @{
    ConnectionStrings__DefaultConnection = $PgUsers
    MessageBusConfigs__Host              = $RabbitUri
    Jwt__Key                             = $JwtKey
}

Set-FcgSecret -Name "fcg-catalog-api-secret" -Literals @{
    ConnectionStrings__DefaultConnection = $PgCatalog
    ConnectionStrings__MongoDB           = "mongodb://fcg-mongodb:27017"
    ConnectionStrings__Redis             = "fcg-redis:6379"
    ConnectionStrings__OpenSearch        = "http://fcg-opensearch:9200"
    MessageBusConfigs__Host              = $RabbitUri
    Jwt__Key                             = $JwtKey
}

Set-FcgSecret -Name "fcg-catalog-worker-secret" -Literals @{
    ConnectionStrings__DefaultConnection = $PgCatalog
    MessageBusConfigs__Host              = $RabbitUri
}

Set-FcgSecret -Name "fcg-payments-worker-secret" -Literals @{
    ConnectionStrings__DefaultConnection = $PgPayments
    MessageBusConfigs__Host              = $RabbitUri
}

Set-FcgSecret -Name "fcg-notifications-worker-secret" -Literals @{
    MessageBusConfigs__Host = $RabbitUri
}

Write-Host ""
Write-Host "Secrets aplicados. IMPORTANTE:"
Write-Host " - Jwt__Key do script deve ser o MESMO do consumer JWT no Kong (kong/k8s/configmap.yaml)."
Write-Host " - Não commite senhas reais. Use env vars em produção/vídeo se quiser valores diferentes."
