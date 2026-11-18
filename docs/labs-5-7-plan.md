# Labs 5–7: план гілки `labs-5-7`

Гілка відгалужена від `main` (тег `lab3-lab4`). Лаби 5→6→7 будуються одна на одній, тому
працюють в **одній** гілці; стан кожної фіксується тегом (`lab5`, `lab6`, `lab7`), коли лаба готова.

## Правила гілки

- `k8s/` і `chart/portal/` **не змінюються** — це здані Lab 3/4. Тому з цієї ж гілки
  `./scripts/lab.sh demo 3|4` працює без `git checkout`.
- Новий чарт — копія в `charts/portal/` (його розвивають Lab 5–7), варіант **b** з Lab 5:
  каталоги `bootstrap/`, `argocd-apps/`, `charts/` у репозиторії застосунку.
- Argo CD читає **GitHub**, а не локальну копію: `targetRevision: labs-5-7`. Кожна зміна для
  Argo CD = `git commit` + `git push`. Локальний `git checkout main` на кластер не впливає.
- Namespace застосунку під Argo CD — `dudko-gitops` (окремо від `dudko` і `dudko-helm`).

## Структура (план)

```text
bootstrap/
  root-lab5.yaml        # кореневий Application (App of Apps) -> argocd-apps/lab5
  root-lab6.yaml        # -> argocd-apps/lab6
  root-lab7.yaml        # -> argocd-apps/lab7
argocd-apps/
  apps/                 # по одному Application на компонент
    portal.yaml         #   charts/portal + envs/minikube/values.yaml -> dudko-gitops
    argo-rollouts.yaml  #   Lab 6
    kube-prometheus-stack.yaml, loki.yaml, alloy.yaml   # Lab 7
  lab5/kustomization.yaml   # resources: [../apps/portal.yaml]
  lab6/kustomization.yaml   # + argo-rollouts
  lab7/kustomization.yaml   # + моніторинг
charts/portal/          # Lab 5: образ з GHCR; Lab 6: rollout.enabled + Rollout; Lab 7: ServiceMonitor,
                        # AnalysisTemplate, дашборд (ConfigMap grafana_dashboard)
envs/minikube/values.yaml   # тег образу, який змінюється комітом (Lab 5 п.5, Lab 6 п.4)
scripts/labs/lab5.sh, lab6.sh, lab7.sh   # демо для scripts/lab.sh
```

**Окремий root на кожну лабу** — головне рішення через RAM: `demo 5` вмикає лише застосунок,
`demo 6` — ще Rollouts, і лише `demo 7` — стек моніторингу. Перемикання = видалити один root
(каскадно видаляє його дочірні Application) і застосувати інший. Сам Argo CD для Labs 3/4
масштабується до 0 (`kubectl scale deploy,sts -n argocd --all --replicas=0`), а не видаляється.

## Відомі пастки

| Питання | Рішення |
|---|---|
| Паролі не в Git (Lab 5 п.1) | чарт: `secrets.existingSecret`; Secret створює скрипт перед застосуванням root (або Sealed Secrets, але це ще ~50 MiB) |
| Образ у реєстрі (Lab 5 п.2) | CI вже пушить `ghcr.io/volodymyrdudko1/backend:<sha>` на кожен push; додати семвер-тег при `git tag v*` і зробити пакет **public** (інакше потрібен imagePullSecret) |
| Argo CD опитує Git раз на ~3 хв | у демо після push: `argocd app get portal --refresh` (або webhook — недоступний з minikube) |
| `kubectl argo rollouts`, `argocd` CLI | встановити заздалегідь; перевірити в `lab.sh demo N` (крок 1) |
| Lab 7 «погана версія» | змінна `FAIL_RATE` у застосунку (без окремого образу) — release через зміну values у Git |

## Бюджет RAM (minikube, виміряно / оцінка)

| Що працює | RAM у minikube |
|---|---|
| система (apiserver, etcd, ingress-nginx, metrics-server, ...) | ~0.9 GiB (виміряно) |
| Lab 4 prod: 3× portal-api + PostgreSQL | +~0.2 GiB (виміряно, разом 1.4 GiB) |
| Argo CD (мінімум: без dex і notifications) | +~0.4–0.6 GiB (оцінка) |
| Argo Rollouts, 4 репліки застосунку | +~0.2 GiB (оцінка) |
| kube-prometheus-stack + Loki single binary + Alloy, урізані | +~1.2–1.6 GiB (оцінка) |
| **Lab 7 разом** | **~3–3.5 GiB — більше за поточний ліміт 3 GiB** |

Для Lab 7 потрібні: Docker Desktop VM ≥ 5 GiB (Settings → Resources) і `minikube` ≥ 4.5 GiB
(ліміт змінюється лише перестворенням: `minikube delete && minikube start --memory=4600`),
і урізані values моніторингу: retention Prometheus 2h, Alertmanager 1 репліка з малими limits,
`nodeExporter.enabled: false` (CPU/RAM pod-ів беруться з cAdvisor у kubelet, node-exporter для
дашборду не потрібен), Grafana без зайвих плагінів, `resources.limits` на всіх компонентах.
Альтернатива — перейти з Docker Desktop на нативний Docker Engine (`docker-ce`): тоді немає
окремої VM з фіксованою пам'яттю (вона тримає ~1 GiB навіть при зупиненому minikube), RAM займає
лише сам контейнер minikube, а `minikube ip` доступний напряму (без port-forward і tunnel).
Кластер у такому разі доведеться створити заново (`minikube start --driver=docker`).
