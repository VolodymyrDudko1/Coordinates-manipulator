# Lab 6: canary з Argo Rollouts — підготовка і шпаргалка

Гілка `labs-5-7`, поверх Lab 5 (Argo CD, App of Apps). Демо: `./scripts/lab.sh demo 6`.

## Що де лежить

| Шлях | Роль |
|---|---|
| `bootstrap/root-lab6.yaml` | кореневий Application Lab 6 (застосовується вручну замість root-lab5) |
| `argocd-apps/lab6/argo-rollouts.yaml` | контролер Argo Rollouts: Helm-чарт `argo-rollouts` 2.43.12 з argo-helm, 1 репліка, sync-wave -1 |
| `argocd-apps/lab6/portal.yaml` | застосунок: `charts/portal` + `envs/minikube/values.yaml` + `envs/minikube/values-lab6.yaml` |
| `charts/portal/templates/rollout.yaml` | Rollout, коли `rollout.enabled: true` (тоді `deployment.yaml` не рендериться) |
| `charts/portal/templates/_pod.tpl` | спільний шаблон pod-а для Deployment і Rollout |
| `envs/minikube/values-lab6.yaml` | `rollout.enabled`, `replicaCount: 4`, кроки canary |

Реліз — як у Lab 5: `image.tag` у `envs/minikube/values.yaml` + commit + push.

## Одноразова підготовка

Плагін `kubectl argo rollouts` (та сама версія, що й контролер, v1.10.2):

```bash
curl -sSL -o ~/.local/bin/kubectl-argo-rollouts \
  https://github.com/argoproj/argo-rollouts/releases/download/v1.10.2/kubectl-argo-rollouts-linux-amd64
chmod +x ~/.local/bin/kubectl-argo-rollouts && kubectl argo rollouts version --short
```

Репетиція: `./scripts/lab.sh demo 6 --yes` (Lab 5 вимкнеться сам, Argo CD лишиться працювати).

## Стратегія: canary (п.3)

```yaml
steps:
  - setWeight: 25           # 1 з 4 pod-ів — нова версія
  - pause: {}               # ручна: promote або abort
  - setWeight: 50
  - pause: {duration: 30s}
  - setWeight: 75
  - pause: {duration: 20s}
```

**Чому canary, а не blue-green:**
- API stateless, а БД спільна й між версіями не змінюється, тож дві версії можуть
  обслуговувати запити одночасно.
- Нова версія спершу отримує лише ~25% запитів: помилки видно на малій частці трафіку,
  і їх можна зупинити (`abort`) до повного викочування.
- Blue-green тримав би 2×4 pod-и під час релізу, а на ноутбуці з дзвінком у Meet RAM обмежена.
- Без traffic routing (Ingress/mesh) частка трафіку = частка pod-ів: Service `portal-api`
  вибирає і stable-, і canary-pod-и. Тому реплік 4, і `setWeight` 25/50/75 = 1/2/3 pod-и.

## Шпаргалка

```bash
kubectl apply -f bootstrap/root-lab6.yaml
argocd app wait argo-rollouts --sync --health
argocd app wait portal --sync --health

# Реліз (п.4)
sed -i 's/^  tag: .*/  tag: "1.3.0"/' envs/minikube/values.yaml
git commit -m "Release 1.3.0" -- envs/minikube/values.yaml && git push
argocd app get portal --refresh
kubectl argo rollouts get rollout portal-api -n dudko-gitops --watch   # Paused на кроці 1 (25%)
kubectl argo rollouts promote portal-api -n dudko-gitops               # далі 50% -> 75% -> 100%

# Цикл запитів усередині кластера
kubectl run l6-traffic -n dudko-gitops --image=busybox:1.36 --restart=Never -- \
  sh -c 'while true; do wget -qO- -T 2 http://portal-api/version; echo; sleep 0.25; done'
kubectl logs l6-traffic -n dudko-gitops --since=10s | grep -o '"version":"[^"]*"' | sort | uniq -c

# Скасування (п.5)
kubectl argo rollouts abort portal-api -n dudko-gitops
argocd app get portal          # Synced / Degraded
git revert --no-edit HEAD && git push && argocd app get portal --refresh   # -> Healthy

kubectl argo rollouts dashboard -n dudko-gitops    # UI: http://localhost:3100/rollouts
```

## Що пояснити на захисті

- **Health в Argo CD під час релізу:** на паузі Rollout — `Suspended`, після promote —
  `Progressing`, потім `Healthy`. Argo CD має вбудовану перевірку здоров'я для Rollout.
- **Synced / Degraded після abort:** Git і spec Rollout у кластері збігаються (новий тег
  застосовано — Synced), але Rollout перерваний: усі pod-и повернуто на stable-версію,
  бажаний стан не досягнуто — Degraded. Abort не змінює Git, тому Argo CD нічого не
  «виправляє»; щоб стан став Healthy, Git треба привести до stable-версії — `git revert`.
- Після `git revert` тег у Git = stable ReplicaSet, тому Rollout одразу Healthy, без кроків canary.
