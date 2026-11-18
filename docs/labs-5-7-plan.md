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

## Стан

| Лаба | Стан |
|---|---|
| Lab 5 | **готово**: Argo CD, App of Apps, CI-образ з git-тегу, демо `lab.sh demo 5` ([шпаргалка](argocd-commands.md)) |
| Lab 6 | **готово** (очікує репетиції): контролер з Git, Rollout canary, демо `lab.sh demo 6` ([шпаргалка](rollouts-commands.md)) |
| Lab 7 | план: моніторинг, `/metrics`, JSON-логи, `FAIL_RATE`, AnalysisTemplate |

## Структура

```text
bootstrap/
  argocd-values.yaml    # values Helm-чарту argo/argo-cd (урізаний під RAM)
  root-lab5.yaml        # кореневий Application (App of Apps) -> argocd-apps/lab5
  root-lab6.yaml        # -> argocd-apps/lab6   (Lab 6)
  root-lab7.yaml        # -> argocd-apps/lab7   (Lab 7)
argocd-apps/            # каталог на лабу, у ньому прості YAML з Application (без kustomize)
  lab5/portal.yaml      #   charts/portal + envs/minikube/values.yaml -> dudko-gitops
  lab6/portal.yaml, lab6/argo-rollouts.yaml                      # Lab 6: + values з rollout.enabled
  lab7/... + kube-prometheus-stack.yaml, loki.yaml, alloy.yaml   # Lab 7
charts/portal/          # Lab 5: образ з GHCR, existingSecret; Lab 6: Rollout; Lab 7: ServiceMonitor,
                        # AnalysisTemplate, дашборд (ConfigMap grafana_dashboard)
envs/minikube/values.yaml   # тег образу, який змінюється комітом (Lab 5 п.5, Lab 6 п.4)
scripts/labs/lab5.sh, lab6.sh, lab7.sh   # демо для scripts/lab.sh
```

**Чому без kustomize:** kustomize за замовчуванням не дозволяє `resources: [../apps/x.yaml]`
(файли поза коренем kustomization), а окремий каталог на лабу ще й дає змогу Lab 6 мати свій
Application `portal` (з Rollout), не змінюючи демо Lab 5. Спільні компоненти (argo-rollouts)
просто дублюються в lab6/ і lab7/ — це кілька рядків YAML.

**Окремий root на кожну лабу** — головне рішення через RAM: `demo 5` вмикає лише застосунок,
`demo 6` — ще Rollouts, і лише `demo 7` — стек моніторингу. Перемикання = видалити один root
(каскадно видаляє його дочірні Application) і застосувати інший. Сам Argo CD для Labs 3/4
масштабується до 0 (`kubectl scale deploy,sts -n argocd --all --replicas=0`), а не видаляється;
назад — ~15 с (виміряно).

## Відомі пастки

| Питання | Рішення |
|---|---|
| Паролі не в Git (Lab 5 п.1) | зроблено: `secrets.existingSecret`; Secret з випадковими значеннями створює `lab5.sh` (Sealed Secrets — ще ~50 MiB) |
| Образ у реєстрі (Lab 5 п.2) | зроблено: `git tag -a v1.3.0` -> CI публікує `backend:1.3.0` з версією й описом релізу всередині; пакет зробити **public** (або `imagePullSecrets`) |
| Argo CD опитує Git раз на ~3 хв | `timeout.reconciliation: 60s` + у демо після push `argocd app get portal --refresh` |
| Degraded з'являється лише через 10 хв | `progressDeadlineSeconds: 60` у `envs/minikube/values.yaml` |
| Helm-хуки під Argo CD | `pre-upgrade` став би PreSync на кожну синхронізацію, `test` Argo CD не запускає — у `charts/portal` їх прибрано |
| Кожен демо-коміт запускав би CI | `paths-ignore` для `envs/`, `argocd-apps/`, `charts/`, ... (теги `v*` збираються завжди) |
| `kubectl argo rollouts`, `argocd` CLI | встановити заздалегідь; перевірити в `lab.sh demo N` (крок 1) |
| Lab 7 «погана версія» | змінна `FAIL_RATE` у застосунку (без окремого образу) — release через зміну values у Git |

## Бюджет RAM (minikube, виміряно / оцінка)

| Що працює | RAM у minikube |
|---|---|
| система (apiserver, etcd, ingress-nginx, metrics-server, ...) | ~0.9 GiB (виміряно) |
| Lab 4 prod: 3× portal-api + PostgreSQL | +~0.2 GiB (виміряно, разом 1.4 GiB) |
| Argo CD (без dex, notifications, applicationset) | +~0.5 GiB (виміряно: контейнер minikube 1.4 GiB без застосунку) |
| Argo Rollouts, 4 репліки застосунку | +~0.2 GiB (оцінка) |
| kube-prometheus-stack + Loki single binary + Alloy, урізані | +~1.2–1.6 GiB (оцінка) |
| **Lab 7 разом** | **~3–3.5 GiB — вміщується в ліміт minikube 4.5 GiB** |

Хост уже на Docker Engine (`docker-ce`) замість Docker Desktop: окремої VM немає, minikube
створено з `--memory=4600` (це стеля cgroup, а не резерв — займає лише те, що потрібно pod-ам),
`minikube ip` доступний напряму. Для Lab 7 лишається урізати values моніторингу: retention
Prometheus 2h, Alertmanager 1 репліка з малими limits, `nodeExporter.enabled: false` (CPU/RAM
pod-ів беруться з cAdvisor у kubelet), Grafana без зайвих плагінів, `resources.limits` усюди.
