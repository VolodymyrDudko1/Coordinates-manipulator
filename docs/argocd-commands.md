# Lab 5: GitOps з Argo CD — підготовка і шпаргалка

Гілка `labs-5-7`. Argo CD читає **GitHub** (`targetRevision: labs-5-7`), тому кожна зміна
бажаного стану = `git commit` + `git push`. Демо: `./scripts/lab.sh demo 5`.

## Що де лежить

| Шлях | Роль |
|---|---|
| `bootstrap/argocd-values.yaml` | values Helm-чарту `argo/argo-cd` (без Dex/Notifications/ApplicationSet, HTTP на localhost) |
| `bootstrap/root-lab5.yaml` | кореневий Application (App of Apps) — **єдиний** об'єкт, що застосовується вручну |
| `argocd-apps/lab5/portal.yaml` | Application застосунку: `charts/portal` + `envs/minikube/values.yaml` -> `dudko-gitops` |
| `charts/portal/` | копія чарту з Lab 4 (`chart/portal` не змінюється): образ з GHCR, `secrets.existingSecret` |
| `envs/minikube/values.yaml` | бажаний стан для minikube: тег образу, репліки, Ingress `portal-gitops.local` |
| `.github/workflows/ci-cd.yml` | `git tag -a v1.3.0` -> образ `ghcr.io/volodymyrdudko1/backend:1.3.0` |
| `~/.config/portal-labs/` | поза Git: пароль admin Argo CD, токен GitHub (якщо репозиторій приватний) |

Паролі застосунку в Git не потрапляють: `envs/minikube/values.yaml` задає
`secrets.existingSecret: portal-secret`, а сам Secret з випадковими значеннями створює
`scripts/labs/lab5.sh` (`kubectl create secret generic ...`) до застосування root.

## Одноразова підготовка (до першої репетиції)

1. **argocd CLI** (версія як у кластері, v3.6.1):
   ```bash
   mkdir -p ~/.local/bin
   curl -sSL -o ~/.local/bin/argocd \
     https://github.com/argoproj/argo-cd/releases/download/v3.6.1/argocd-linux-amd64
   chmod +x ~/.local/bin/argocd && argocd version --client --short
   ```
2. **Доступ Argo CD до Git і GHCR.** Репозиторій приватний — обрати одне:
   - зробити репозиторій **public** (Settings → General → Danger Zone) — тоді крок 6 демо не потрібен;
   - або classic PAT зі scope `repo` + `read:packages` у файл поза Git:
     ```bash
     mkdir -p ~/.config/portal-labs && chmod 700 ~/.config/portal-labs
     (umask 077; cat > ~/.config/portal-labs/github-token)   # вставити токен, Enter, Ctrl+D
     ```
   Пакет образу в GHCR найпростіше зробити **public**: GitHub → Packages → `backend` →
   Package settings → Change visibility. Якщо лишити приватним — у `envs/minikube/values.yaml`
   `imagePullSecrets: [{name: ghcr-pull}]` (Secret `ghcr-pull` скрипт створює з того ж токена).
3. **Гілка й образи в реєстрі:**
   ```bash
   git push -u origin labs-5-7
   git tag -a v1.2.0 -m "Release 1.2.0: перший реліз через Argo CD"
   git tag -a v1.3.0 -m "Release 1.3.0: НОВА версія, викочена комітом у Git"
   git push origin v1.2.0 v1.3.0          # CI збирає й публікує backend:1.2.0 і backend:1.3.0
   ```
   Дочекатися зеленого CI (вкладка Actions), перевірити: `docker buildx imagetools inspect ghcr.io/volodymyrdudko1/backend:1.3.0`.
4. **`git push` з терміналу** має працювати без діалогів (демо пушить саме з терміналу):
   `GIT_TERMINAL_PROMPT=0 git push --dry-run origin labs-5-7`.
5. Репетиція: `./scripts/lab.sh demo 5 --yes`. Argo CD встановиться сам при першому запуску (~1 хв).

## Шпаргалка (вручну, без скрипта)

```bash
# Встановлення Argo CD (п.3)
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd --version 10.18.1 -n argocd --create-namespace \
  -f bootstrap/argocd-values.yaml --wait
kubectl port-forward -n argocd svc/argocd-server 18090:80 &      # UI: http://localhost:18090
argocd admin initial-password -n argocd
argocd login 127.0.0.1:18090 --plaintext --username admin --password '<початковий>'
argocd account update-password
kubectl delete secret argocd-initial-admin-secret -n argocd
argocd repo add https://github.com/VolodymyrDudko1/Coordinates-manipulator.git \
  --username VolodymyrDudko1 --password "$(cat ~/.config/portal-labs/github-token)"   # лише для приватного

# App of Apps (п.4)
kubectl apply -f bootstrap/root-lab5.yaml
argocd app list
argocd app wait portal --sync --health
argocd app get portal

# Реліз через Git (п.5)
sed -i 's/^  tag: .*/  tag: "1.3.0"/' envs/minikube/values.yaml
git commit -m "Release 1.3.0" -- envs/minikube/values.yaml && git push
argocd app get portal --refresh        # не чекати на опитування Git (timeout.reconciliation 60s)
curl -s -H 'Host: portal-gitops.local' http://127.0.0.1:18080/version   # Ingress через port-forward

# Дрейф і selfHeal (п.6a)
kubectl scale deploy/portal-api -n dudko-gitops --replicas=4
argocd app get portal --refresh | grep 'Sync Status'      # OutOfSync (selfHeal: false)
argocd app diff portal
#   selfHeal: true в argocd-apps/lab5/portal.yaml -> commit, push, argocd app get root-lab5 --refresh

# Битий тег => Synced + Degraded (п.6b), відкат (п.6c)
argocd app wait portal --degraded       # Degraded після progressDeadlineSeconds (60 с у envs/minikube)
git revert --no-edit HEAD && git push
git log --oneline -5
argocd app history portal

# Вимкнути / звільнити RAM
kubectl delete -f bootstrap/root-lab5.yaml       # каскадно: Application portal і всі його об'єкти
kubectl scale deploy,sts -n argocd --all --replicas=0
```

## Що пояснити на захисті

- **Synced, але Degraded** (п.6b): Git і кластер збігаються (тег застосовано), але новий
  ReplicaSet не може завантажити образ — `ProgressDeadlineExceeded`. Старі pod-и працюють
  (`maxUnavailable: 0`), тому застосунок далі відповідає попередньою версією.
- **selfHeal: false** — авто-синхронізація реагує лише на зміни в Git; ручна зміна кластера
  лишається, Argo CD лише показує OutOfSync. **selfHeal: true** — повертає стан із Git.
- **Відкат через `git revert`**, а не `argocd app rollback`: з увімкненим auto-sync Argo CD
  одразу повернув би стан із Git; історія змін живе в Git (`git log`), а `argocd app history`
  показує, які ревізії Git розгортались.
- Чому `argocd app get --refresh`: Argo CD опитує Git раз на `timeout.reconciliation` (60 с);
  webhook від GitHub до minikube за NAT не дістанеться.
