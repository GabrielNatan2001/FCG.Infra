# Fase 4 — Passo a passo Azure (AKS + ACR + CI/CD)

Guia detalhado para subir a plataforma **FCG** na nuvem com o **menor gasto possível** de crédito gratuito, **reaproveitando** os manifests Kubernetes e o Docker Compose que já existem.

> Estratégia: **Azure** (já usamos Azure Functions) · **1 node AKS** · **ACR Basic** · dados **dentro do cluster** · **GitHub Actions** · apagar o resource group depois do vídeo.

---

## Visão geral do que vamos entregar


| Requisito Fase 4       | Como vamos cumprir                                                                   |
| ---------------------- | ------------------------------------------------------------------------------------ |
| Kubernetes gerenciado  | **AKS**                                                                              |
| Registry privado       | **ACR**                                                                              |
| Exposição externa      | Kong com Service `LoadBalancer`                                                      |
| CI/CD Users + Catalog  | **GitHub Actions**                                                                   |
| NoSQL / Cache / Search | Mongo + Redis + OpenSearch **in-cluster** (já prontos)                               |
| Serverless             | **Azure Functions** (Consumption) — projeto Notifications                            |
| Secrets                | Kubernetes Secrets (criados/atualizados no deploy; ideal não versionar senhas reais) |


```text
GitHub (push main)
    → Actions: build/test/docker/push ACR
    → kubectl rolling update no AKS
         ↓
Cliente → LoadBalancer (Kong) → Users / Catalog
Catalog → Postgres / Mongo / Redis / OpenSearch / RabbitMQ (pods)
RabbitMQ → Payments Worker / Catalog Worker / Azure Function
```

---



## 0. Pré-requisitos (instalar na máquina)



### 0.1 Softwares


| Ferramenta                                                           | Para quê                     | Como checar                |
| -------------------------------------------------------------------- | ---------------------------- | -------------------------- |
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | Criar AKS/ACR                | `az version`               |
| [kubectl](https://kubernetes.io/docs/tasks/tools/)                   | Deploy no cluster            | `kubectl version --client` |
| [Docker Desktop](https://www.docker.com/products/docker-desktop/)    | Build das imagens            | `docker version`           |
| [GitHub CLI](https://cli.github.com/) (opcional)                     | Secrets do Actions           | `gh auth status`           |
| Conta Azure com crédito                                              | Free / Student / Sponsorship | Portal Azure               |




### 0.2 Contas e repositórios

- Login Azure com a mesma assinatura onde está (ou estará) a Function
- Repos GitHub: `FCG.Users`, `FCG.Catalog`, `FCG.Infra`, `FCG.Payments`, `FCG.Notifications`
- Docker Desktop **ligado**



### 0.3 Variáveis que você vai usar o tempo todo

Defina no PowerShell (ajuste os nomes; ACR precisa ser **único global**, só letras/números):

```powershell
$RG        = "rg-fcg-fase4"
$LOCATION  = "brazilsouth"          # ou eastus se Brazil South estiver caro/indisponível
$ACR_NAME  = "fcgacrSEUNOME"        # ex: fcgacrgabriel13  (sem hífen)
$AKS_NAME  = "aks-fcg-fase4"
$NODE_SIZE = "Standard_B2s"         # barato; se falhar, tente Standard_DS2_v2
```

Confirme:

```powershell
Write-Host "RG=$RG ACR=$ACR_NAME AKS=$AKS_NAME LOC=$LOCATION"
```

---



## 1. Economia de crédito (ler antes de criar recursos)

1. Use **1 node** só.
2. Prefira VM **B2s** (burstable).
3. **Não** crie Azure Database, Redis Cache, Elastic Cloud, Application Gateway caro.
4. Suba Postgres/Mongo/Redis/Rabbit/OpenSearch **no AKS** (manifests atuais).
5. Functions em plano **Consumption**.
6. Deixe o cluster ligado **só** no período de testes + gravação do vídeo.
7. No fim: `az group delete` (apaga tudo de uma vez).
8. Evite deixar Grafana/Prometheus expostos publicamente se não for usar no vídeo (opcional desligar depois).

**Estimativa grosseira:** AKS 1×B2s + ACR Basic costuma caber em crédito de trial se você **não deixar dias ligado**.

---



## 2. Login na Azure e subscription

```powershell
az login
az account list -o table
az account set --subscription "NOME_OU_ID_DA_SUA_SUBSCRIPTION"
az account show -o table
```

Confirme que a subscription é a do crédito gratuito / estudante.

---



## 3. Criar Resource Group

Tudo fica neste grupo para apagar fácil depois.

```powershell
az group create --name $RG --location $LOCATION
```

Validação:

```powershell
az group show --name $RG -o table
```

---



## 4. Criar ACR (registry privado)

```powershell
az acr create `
  --resource-group $RG `
  --name $ACR_NAME `
  --sku Basic `
  --admin-enabled true
```

Anote o login server:

```powershell
$ACR_LOGIN = az acr show -n $ACR_NAME -g $RG --query loginServer -o tsv
Write-Host $ACR_LOGIN
# exemplo: fcgacrgabriel13.azurecr.io
```

Login Docker no ACR:

```powershell
az acr login --name $ACR_NAME
```

---



## 5. Criar AKS (cluster Kubernetes gerenciado)



### 5.1 Criar o cluster (1 node)

```powershell
az aks create `
  --resource-group $RG `
  --name $AKS_NAME `
  --node-count 1 `
  --node-vm-size $NODE_SIZE `
  --generate-ssh-keys `
  --attach-acr $ACR_NAME `
  --enable-managed-identity
```

> Demora **10–20 min**. `--attach-acr` já autoriza o AKS a puxar imagens do ACR (sem imagePullSecrets manuais).

Se `B2s` não estiver disponível na região:

```powershell
$NODE_SIZE = "Standard_DS2_v2"
# rode o az aks create de novo (ou delete o cluster falho antes)
```



### 5.2 Conectar o kubectl

```powershell
az aks get-credentials --resource-group $RG --name $AKS_NAME --overwrite-existing
kubectl get nodes
```

Esperado: 1 node `Ready`.

---



## 6. Build e push das imagens para o ACR

Hoje os manifests apontam para Docker Hub (`gabrielnatan2001/...`). Na cloud vamos usar o ACR.

### 6.1 Tag padrão

Use `:latest` no primeiro deploy manual. No CI/CD depois usamos SHA do commit.

```powershell
# ainda com $ACR_LOGIN definido
cd "C:\Users\Gabriel Natan\Desktop\Gabriel\Pós Arq. Sistemas\fase2"
```



### 6.2 Users API

```powershell
cd FCG.Users
docker build -t "$ACR_LOGIN/fcg-api-users:latest" .
docker push "$ACR_LOGIN/fcg-api-users:latest"
cd ..
```



### 6.3 Catalog API

```powershell
cd FCG.Catalog
docker build -t "$ACR_LOGIN/fcg-api-catalog:latest" -f Dockerfile .
docker push "$ACR_LOGIN/fcg-api-catalog:latest"
```



### 6.4 Catalog Worker

```powershell
docker build -t "$ACR_LOGIN/fcg-worker-catalog:latest" -f Dockerfile.worker .
docker push "$ACR_LOGIN/fcg-worker-catalog:latest"
cd ..
```



### 6.5 Payments Worker

```powershell
cd FCG.Payments
docker build -t "$ACR_LOGIN/fcg-worker-payments:latest" .
docker push "$ACR_LOGIN/fcg-worker-payments:latest"
cd ..
```

Validação:

```powershell
az acr repository list --name $ACR_NAME -o table
```

---



## 7. Ajustes mínimos nos manifests (antes do apply)

Objetivo: **não refazer a arquitetura** — só apontar imagens e expor o Kong.

### 7.1 Trocar imagem Docker Hub → ACR — FEITO

ACR do projeto: `fcgacrgabrielnatan.azurecr.io`

Imagens atualizadas nos manifests:


| Serviço                       | Imagem                                                          |
| ----------------------------- | --------------------------------------------------------------- |
| Users API                     | `fcgacrgabrielnatan.azurecr.io/fcg-api-users:latest`            |
| Catalog API                   | `fcgacrgabrielnatan.azurecr.io/fcg-api-catalog:latest`          |
| Catalog Worker                | `fcgacrgabrielnatan.azurecr.io/fcg-worker-catalog:latest`       |
| Payments Worker               | `fcgacrgabrielnatan.azurecr.io/fcg-worker-payments:latest`      |
| Notifications Worker (legado) | `fcgacrgabrielnatan.azurecr.io/fcg-worker-notifications:latest` |


Arquivos alterados:

- `FCG.Users/k8s/deployment.yaml`
- `FCG.Catalog/k8s/api-deployment.yaml`
- `FCG.Catalog/k8s/worker-deployment.yaml`
- `FCG.Payments/k8s/deployment.yaml`
- `FCG.Notifications/k8s/deployment.yaml`

> Antes do `kubectl apply`, faça o **build + push** dessas imagens para o ACR (etapa 6). Sem isso os pods ficam em `ImagePullBackOff`.
>
> O CI/CD depois pode usar tag `:sha` com `kubectl set image`.



### 7.2 Kong: NodePort → LoadBalancer — FEITO

Arquivo já atualizado: `FCG.Infra/kong/k8s/service.yaml`

```yaml
spec:
  type: LoadBalancer
  selector:
    app: fcg-kong
  ports:
    - name: proxy
      port: 80
      targetPort: 8000
    - name: admin
      port: 8001
      targetPort: 8001
```

**Como “criar” na Azure:** não abra o portal para criar LB. Depois do AKS pronto e do `kubectl apply` do Kong:

```powershell
kubectl apply -f FCG.Infra/kong/k8s/
kubectl get svc fcg-kong -w
```

Espere o `EXTERNAL-IP` (1–3 min). A Azure provisiona o Load Balancer sozinha.

**IP atual do Kong (AKS):** `74.163.113.139`

Acesso (porta **80**):

- `http://74.163.113.139/users/...`
- `http://74.163.113.139/catalog/...`

> Se o IP mudar no futuro: `kubectl get svc fcg-kong`



### 7.3 OpenSearch no AKS (memória) — FEITO

Arquivo: `FCG.Infra/opensearch/k8s/deployment.yaml`

- Heap: `OPENSEARCH_JAVA_OPTS=-Xms256m -Xmx256m`
- `bootstrap.memory_lock=false`
- Requests/limits: `512Mi–1Gi` RAM / até 1 CPU

Isso ajuda o OpenSearch a caber no AKS de **1 node** (`Standard_D2s_v4`).

Se ainda der OOM:

```powershell
kubectl describe pod -l app=fcg-opensearch
# última opção: node maior ou desligar Grafana/Prometheus temporariamente
```



### 7.4 Secrets (sem credencial no Git) — FEITO

**O que mudou**

- Removidos os `secret.yaml` com senhas do repositório
- Criados `*.yaml.example` só com placeholders (extensão que o kubectl **não** aplica)
- Script: `FCG.Infra/scripts/apply-secrets.ps1` injeta os Secrets no cluster em runtime
- `.gitignore` ignora `secret.yaml` / `*-secret.yaml` locais

**Como aplicar (ANTES do deploy dos apps)**

```powershell
cd "C:\Users\Gabriel Natan\Desktop\Gabriel\Pós Arq. Sistemas\fase2"
.\FCG.Infra\scripts\apply-secrets.ps1
```

Override (opcional, para o vídeo / produção):

```powershell
$env:FCG_POSTGRES_PASSWORD = "SenhaForte123!"
$env:FCG_RABBIT_PASSWORD   = "SenhaForte123!"
$env:FCG_JWT_KEY           = "sua-chave-jwt-com-pelo-menos-32-chars"
.\FCG.Infra\scripts\apply-secrets.ps1
```

**Ordem correta no AKS**

1. `apply-secrets.ps1`
2. `kubectl apply` infra (postgres, rabbit, mongo, redis, opensearch)
3. `kubectl apply` kong / apps

> O JWT do Kong (`kong/k8s/configmap.yaml`) precisa ser o **mesmo** `Jwt__Key` aplicado no script (consumer `FCG.Users.API`).
>
> No vídeo diga: “credenciais injetadas via Kubernetes Secrets em runtime, não versionadas no código”.

---



## 8. Deploy no AKS (ordem recomendada)

No PowerShell, a partir da pasta `fase2`:

```powershell
cd "C:\Users\Gabriel Natan\Desktop\Gabriel\Pós Arq. Sistemas\fase2"
```



### 8.1 Infra base

```powershell
# Secrets primeiro (não estão mais nos YAML do Git)
.\FCG.Infra\scripts\apply-secrets.ps1

kubectl apply -f FCG.Infra/postgres/k8s/
kubectl apply -f FCG.Infra/rabbitmq/k8s/
kubectl apply -f FCG.Infra/mongo/k8s/
kubectl apply -f FCG.Infra/redis/k8s/
kubectl apply -f FCG.Infra/opensearch/k8s/
```

Espere ficarem Ready:

```powershell
kubectl get pods -w
# Ctrl+C quando postgres, rabbitmq, mongo, redis, opensearch estiverem Running
```



### 8.2 Observabilidade + Gateway

```powershell
kubectl apply -f FCG.Infra/prometheus/k8s/
kubectl apply -f FCG.Infra/grafana/k8s/
kubectl apply -f FCG.Infra/kong/k8s/
```



### 8.3 Aplicações

```powershell
kubectl apply -f FCG.Payments/k8s/
kubectl apply -f FCG.Catalog/k8s/
kubectl apply -f FCG.Users/k8s/
```



### 8.4 Conferir

```powershell
kubectl get pods
kubectl get svc
```

Todos os pods principais devem estar `Running` / `Ready`.

Se algum falhar:

```powershell
kubectl describe pod NOME_DO_POD
kubectl logs NOME_DO_POD
```

---



## 9. Pegar o IP público e testar



### 9.1 IP do Kong

```powershell
kubectl get svc fcg-kong
```

Coluna `EXTERNAL-IP` (pode ficar `<pending>` por alguns minutos).

```powershell
$KONG_IP = kubectl get svc fcg-kong -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
Write-Host "http://$KONG_IP"
```



### 9.2 Health

```powershell
curl "http://$KONG_IP/users/health"
curl "http://$KONG_IP/catalog/health"
```



### 9.3 Login + busca (OpenSearch)

```powershell
# Login
$login = Invoke-RestMethod -Method POST -Uri "http://$KONG_IP/users/api/Auth/login" `
  -ContentType "application/json" `
  -Body '{"email":"admin@admin.com","senha":"Teste@123"}'
$token = $login.token
if (-not $token) { $token = $login.accessToken }

# Busca fuzzy
Invoke-RestMethod -Uri "http://$KONG_IP/catalog/api/Search?q=cybr" `
  -Headers @{ Authorization = "Bearer $token" }
```



### 9.4 Checklist manual para o vídeo

- [ ] Portal Azure: resource group + AKS + ACR
- [ ] `kubectl get nodes` / `kubectl get pods`
- [ ] Login via Kong no IP público
- [ ] Search fuzzy (`q=cybr`)
- [ ] Cache Redis / avaliação Mongo (fluxo Fase 3)
- [ ] Live deploy via pipeline (etapa 11)

---



## 10. Azure Functions (Notifications) — FEITO (demo)

### Recursos criados
| Recurso | Nome / valor |
|---|---|
| Function App | `fcg-notifications-93692` |
| URL | https://fcg-notifications-93692.azurewebsites.net |
| Storage | `fcgfuncstor24922` |
| Plano | Consumption (Linux) |
| RabbitMQ (público p/ demo) | `amqp://admin:admin@4.203.54.254:5672/` |
| Service K8s | `fcg-rabbitmq` tipo **LoadBalancer** |

### Funções publicadas
- `UserCreatedFunction` → fila `notifications.user-created-queue`
- `PaymentProcessedFunction` → fila `notifications.payment-processed-queue`

### Como ver no portal / vídeo
1. Portal → Resource Group `rg-fcg-fase4` → Function App `fcg-notifications-93692`
2. Menu **Funções** → as 2 triggers
3. **Monitor** / Application Insights → logs `[EMAIL] ...`

### Teste (quando Users estiver no AKS)
```powershell
$KONG = "http://74.163.113.139"
Invoke-RestMethod -Method POST -Uri "$KONG/users/api/Usuario" -ContentType "application/json" -Body '{
  "nome": "Teste Function",
  "email": "teste.function@fcg.com",
  "senha": "Teste@123"
}'
```
Depois veja os logs da Function (cold start pode levar alguns segundos).

> RabbitMQ público só para demo. Apague o RG após o vídeo.

---



## 11. CI/CD com GitHub Actions (Users + Catalog) — FEITO

Workflows criados:
- `FCG.Users/.github/workflows/ci-cd.yml`
- `FCG.Catalog/.github/workflows/ci-cd.yml`

### O que a pipeline faz (push em `main` ou manual)
1. Restore / Build / Test (.NET 8)
2. Login Azure + ACR
3. Docker build + push (`:sha` e `:latest`)
4. Scan Trivy (desejável; não quebra o pipeline)
5. `kubectl set image` + `rollout status` (Rolling Update no AKS)

### Secrets já configurados nos repos GitHub
| Secret | Valor |
|---|---|
| `AZURE_CREDENTIALS` | Service Principal `sp-fcg-github-actions` |
| `ACR_LOGIN_SERVER` | `fcgacrgabrielnatan.azurecr.io` |
| `ACR_USERNAME` / `ACR_PASSWORD` | admin do ACR |
| `AKS_RESOURCE_GROUP` | `rg-fcg-fase4` |
| `AKS_CLUSTER_NAME` | `aks-fcg-fase4` |

### Como disparar
```powershell
# Commit + push do workflow (primeira vez) ou qualquer mudança em main
cd FCG.Users
git add .github/workflows/ci-cd.yml
git commit -m "ci: adicionar pipeline CI/CD para Users API"
git push origin main

cd ../FCG.Catalog
git add .github/workflows/ci-cd.yml
git commit -m "ci: adicionar pipeline CI/CD para Catalog API"
git push origin main
```

Ou no GitHub: Actions → workflow → **Run workflow**.

### Live deploy (vídeo)
1. Altere um detalhe no código
2. `git push` em `main`
3. Mostre a aba Actions rodando
4. `kubectl get pods -w` / `kubectl rollout status ...`
5. Teste a API no IP do Kong

---

## 12. Troubleshooting rápido


| Problema                 | O que fazer                                                                                          |
| ------------------------ | ---------------------------------------------------------------------------------------------------- |
| `EXTERNAL-IP` pending    | Esperar 2–5 min; checar quota de IP público na subscription                                          |
| `ImagePullBackOff`       | Conferir `--attach-acr` e nome da imagem; `az aks update -g $RG -n $AKS_NAME --attach-acr $ACR_NAME` |
| OpenSearch OOM / Pending | Reduzir heap Java ou VM maior                                                                        |
| Pod CrashLoop Catalog    | `kubectl logs` — connection string / OpenSearch / JWT                                                |
| Search 404               | Imagem antiga sem endpoint; rebuild + push Catalog + rollout                                         |
| Actions 403 ACR          | Secrets `ACR_*` errados ou SP sem role no RG                                                         |
| Crédito acabando         | `az group delete` imediatamente                                                                      |


---



## 13. Apagar tudo (economizar crédito)

**Depois do vídeo / entrega**, apague o resource group inteiro:

```powershell
az group delete --name $RG --yes --no-wait
```

Isso remove AKS, ACR, IPs, discos do node, etc.

Confirme no portal que o grupo sumiu.

> **Não** delete a Function App se ainda precisar dela em outra entrega — se ela estiver **no mesmo** RG, mova antes ou use outro RG só para AKS/ACR.

Sugestão de organização:

- `rg-fcg-fase4` → AKS + ACR (descartável)
- `rg-fcg-functions` → Function App (permanente / barata)

---



## 14. Checklist final da Fase 4 (entrega)



### Infra / Cloud

- [ ] AKS rodando (print portal + `kubectl get nodes`)
- [ ] Imagens no ACR (não só Docker Hub)
- [ ] App acessível via Load Balancer / IP público
- [ ] Stack in-cluster: Postgres, Mongo, Redis, OpenSearch, Rabbit, Kong



### App

- [ ] Search fuzzy + relevância
- [ ] Mongo avaliações + Redis cache (já da Fase 3)



### CI/CD

- [ ] Pipeline Users (build/test/push/deploy)
- [ ] Pipeline Catalog (build/test/push/deploy)
- [ ] Live deploy no vídeo



### Serverless

- [ ] Azure Function no portal + demonstração



### Docs / entrega

- [ ] README atualizado (este arquivo + READMEs dos repos)
- [ ] Relatório com links dos repos + vídeo
- [ ] Resource group apagado após a entrega (crédito)

---



## 15. Ordem prática resumida (cola rápida)

```text
1. az login + set subscription
2. criar RG
3. criar ACR Basic + az acr login
4. criar AKS 1 node + attach-acr + get-credentials
5. docker build/push (users, catalog, workers)
6. ajustar imagens nos YAML + Kong LoadBalancer
7. kubectl apply (infra → kong → apps)
8. pegar EXTERNAL-IP e testar
9. configurar secrets GitHub + workflows Users/Catalog
10. gravar vídeo (portal + pods + search + live deploy + function)
11. az group delete
```

---



## 16. Próximo passo sugerido

Quando for implementar de fato:

1. Provisionar RG + ACR + AKS (etapas 2–5)
2. Só depois criar os arquivos `.github/workflows` nos repos Users e Catalog

Se quiser, no chat peça: **“implementa os workflows”** ou **“me ajuda a provisionar o AKS”** que seguimos etapa por etapa com os comandos já preenchidos com os nomes reais da sua conta.