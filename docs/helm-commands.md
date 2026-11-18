# Шпаргалка команд: Helm (Lab 4)

Усі команди виконуються з кореня репозиторію.

| Параметр | Lab 3 (`k8s/`) | Lab 4 (Helm) |
|---|---|---|
| Namespace | `dudko` | `dudko-helm` |
| Ingress host | `portal.local` | `portal-helm.local` (dev), `portal-helm-prod.local` (prod) |
| Як розгортається | `kubectl apply -f k8s/` | `helm install portal chart/portal -n dudko-helm` |

Ім'я релізу: `portal`. Чарт: `chart/portal`. Після кожної команди рядок **«Очікую:»** показує,
що має бути на екрані/скріншоті.

Образи `portal-api:1.0.0` і `portal-api:1.1.0` уже мають бути в minikube (`./scripts/build-images.sh`).

---

## 0. Підготовка

```bash
helm version
```
Очікую: `version.BuildInfo{Version:"v3.x.y", ...}` — Helm 3 (без Tiller). Чарт (`apiVersion: v2`)
також перевірено з Helm v4.3.1: `lint` і `template` дають той самий результат.

```bash
./scripts/lab3-down.sh
```
Очікую: `... deleted` для кожного об'єкта з `k8s/` і в кінці `No resources found in dudko namespace.`
(або помилку `namespaces "dudko" not found` — це теж означає, що Lab 3 вимкнено).

---

## 1. Перевірка чарту без кластера

```bash
helm lint chart/portal
helm lint chart/portal -f chart/portal/values-dev.yaml
helm lint chart/portal -f chart/portal/values-prod.yaml
```
Очікую: `1 chart(s) linted, 0 chart(s) failed` (рядок `[INFO] Chart.yaml: icon is recommended` — це норма).

```bash
helm template portal chart/portal -n dudko-helm -f chart/portal/values-dev.yaml
```
Очікую: YAML усіх об'єктів: ConfigMap `portal-config`, Secret `portal-secret`, PVC `portal-db-data`,
Service `portal-api` і `portal-db`, Deployment `portal-api` (`replicas: 1`, `image: "portal-api:1.0.0"`)
і `portal-db`, Job `portal-pre-upgrade`, Pod `portal-test-connection`. Ingress **немає** (вимкнено в dev).

### dev vs prod

```bash
helm template portal chart/portal -n dudko-helm -f chart/portal/values-dev.yaml  > /tmp/helm-dev.yaml
helm template portal chart/portal -n dudko-helm -f chart/portal/values-prod.yaml > /tmp/helm-prod.yaml
diff /tmp/helm-dev.yaml /tmp/helm-prod.yaml
```
Очікую відмінності: `replicas: 1` → `3`, `portal-api:1.0.0` → `1.1.0`, більші `resources`,
`ENVIRONMENT: "sandbox"` → `"production"`, `LOG_LEVEL`, інші `checksum/config`, мітки
`app.kubernetes.io/version`, а в кінці prod — новий об'єкт `Ingress` з `host: "portal-helm-prod.local"`.

```bash
grep -E 'replicas:|image:|host:' /tmp/helm-dev.yaml /tmp/helm-prod.yaml
```
Очікую: короткий підсумок тих самих відмінностей.

### Helm vs старі маніфести `k8s/`

Порівнюємо список «тип + ім'я» об'єктів (Ingress у Helm вмикаємо, тести пропускаємо):

```bash
diff \
  <(grep -hE '^kind:|^  name:' k8s/*.yaml | sed 's/[[:space:]]*#.*//' | paste - - | sort) \
  <(helm template portal chart/portal -n dudko-helm --set ingress.enabled=true --skip-tests \
      | grep -E '^kind:|^  name:' | paste - - | sort)
```
Очікую рівно дві відмінності: `< kind: Namespace  name: dudko` (namespace у Helm створює
`--create-namespace`) і `> kind: Job  name: portal-pre-upgrade` (hook з Task 9). Усі інші
об'єкти (ConfigMap, Secret, PVC, 2 Deployment, 2 Service, Ingress) мають ті самі імена.

```bash
diff <(grep -oE '^  [A-Z_]+:' k8s/10-configmap.yaml | sort) \
     <(helm template portal chart/portal -n dudko-helm -s templates/configmap.yaml | grep -oE '^  [A-Z_]+:' | sort)
```
Очікую: порожній вивід — набір ключів ConfigMap однаковий (`APP_GREETING`, `DB_HOST`, `DB_PORT`, `DEBUG`,
`ENVIRONMENT`, `LOG_LEVEL`, `POSTGRES_DB`, `POSTGRES_USER`). Те саме для Secret:

```bash
diff <(grep -oE '^  [A-Z_]+:' k8s/11-secret.yaml | sort) \
     <(helm template portal chart/portal -n dudko-helm -s templates/secret.yaml | grep -oE '^  [A-Z_]+:' | sort)
```
Очікую: порожній вивід (`API_KEY`, `POSTGRES_PASSWORD`, `SECRET_KEY`).

---

## 2. Встановлення

```bash
./scripts/lab4-up.sh
```
або повна команда:
```bash
helm install portal chart/portal -n dudko-helm --create-namespace -f chart/portal/values-dev.yaml
```
Очікую: `STATUS: deployed`, `REVISION: 1` і текст NOTES з командою `kubectl port-forward ...`;
далі таблиця з 2 pod-ами (`portal-api-...`, `portal-db-...`) і 2 Service, Ingress немає.

```bash
kubectl get pods -n dudko-helm -w
```
Очікую: обидва pod-и `1/1 Running` (portal-api стає Ready після того, як піднялась БД). Ctrl+C.

```bash
kubectl port-forward -n dudko-helm svc/portal-api 8080:80
# в іншому терміналі:
curl -s http://127.0.0.1:8080/info; echo
```
Очікую: JSON з `"version": "1.0.0"` і привітанням `Привіт з Helm! ...`.

---

## 3. Стан релізу

```bash
helm list -n dudko-helm
```
Очікую: рядок `portal  dudko-helm  1  ...  deployed  portal-0.1.0  1.0.0`.

```bash
helm status portal -n dudko-helm
```
Очікую: `STATUS: deployed`, `REVISION: 1` і повторно NOTES.

```bash
helm get values portal -n dudko-helm
```
Очікую: `USER-SUPPLIED VALUES:` — лише те, що прийшло з `values-dev.yaml` (replicaCount, image.tag, ...).

```bash
helm get values portal -n dudko-helm --all
```
Очікую: `COMPUTED VALUES:` — повний набір (values.yaml + values-dev.yaml), включно з `postgres`, `secrets`.

```bash
helm get manifest portal -n dudko-helm | grep -E '^kind:|^  name:'
```
Очікую: список об'єктів, які Helm реально створив.

### Де Helm зберігає стан релізу

```bash
kubectl get secrets -n dudko-helm -l owner=helm
```
Очікую: `sh.helm.release.v1.portal.v1   helm.sh/release.v1` — по одному Secret на кожну ревізію.
Саме з них `helm history` і `helm rollback` беруть попередні версії.

---

## 4. Оновлення, історія, відкат

**Ревізія 2** — лише новий тег образу:
```bash
helm upgrade portal chart/portal -n dudko-helm \
  -f chart/portal/values-dev.yaml --set image.tag=1.1.0 \
  --description "Upgrade image to 1.1.0"
```
Очікую: `Release "portal" has been upgraded`, `REVISION: 2`. Перед цим відпрацьовує pre-upgrade hook.

```bash
kubectl rollout status deployment/portal-api -n dudko-helm
curl -s http://127.0.0.1:8080/info; echo     # port-forward перезапустити, якщо обірвався
```
Очікую: `successfully rolled out`, у JSON `"version": "1.1.0"`.

> `-f values-dev.yaml` повторюємо свідомо: `helm upgrade` без `-f`/`--reuse-values` бере
> значення лише з `values.yaml` + `--set` цієї команди.

**Ревізія 3** — prod-профіль:
```bash
helm upgrade portal chart/portal -n dudko-helm \
  -f chart/portal/values-prod.yaml \
  --description "Switch to prod values: 3 replicas, ingress portal-helm-prod.local"
```
Очікую: `REVISION: 3`, NOTES тепер показують `http://portal-helm-prod.local/`.

```bash
kubectl get pods,svc,ingress -n dudko-helm
```
Очікую: 3 pod-и `portal-api-...` + 1 `portal-db-...`, Ingress `portal-api` з HOSTS `portal-helm-prod.local`.

```bash
curl -s http://portal-helm-prod.local/info; echo
```
Очікую: JSON від застосунку (потрібен рядок у /etc/hosts — див. розділ 8).

```bash
helm history portal -n dudko-helm
```
Очікую: 3 рядки; 1 і 2 — `superseded`, 3 — `deployed`; у колонці DESCRIPTION — ваші `--description`.

**Відкат** до ревізії 1:
```bash
helm rollback portal 1 -n dudko-helm
```
Очікую: `Rollback was a success! Happy Helming!`

```bash
helm history portal -n dudko-helm
```
Очікую: новий рядок `4  deployed  ...  Rollback to 1`; ревізія 3 стала `superseded`.
Відкат не «стирає» історію, а створює нову ревізію з вмістом старої.

```bash
kubectl get pods,ingress -n dudko-helm
```
Очікую: знову 1 pod portal-api з образом 1.0.0, Ingress зник.

---

## 5. Task 9: helm test і pre-upgrade hook

```bash
helm test portal -n dudko-helm --logs
```
Очікую: `Phase: Succeeded` для `portal-test-connection` і в логах `HTTP/1.1 200 OK`,
`OK: /health returned 200`.

```bash
kubectl logs -n dudko-helm portal-test-connection
```
Очікую: ті самі логи (pod лишається до наступного `helm test` / `lab4-down.sh`).

### Логи pre-upgrade hook

Job `portal-pre-upgrade` за замовчуванням видаляється одразу після успіху
(`hook-delete-policy: before-hook-creation,hook-succeeded`). Два способи побачити логи:

**Спосіб А — залишити Job** (тимчасово перевизначити політику видалення):
```bash
helm upgrade portal chart/portal -n dudko-helm -f chart/portal/values-dev.yaml \
  --set hooks.preUpgrade.deletePolicy=before-hook-creation \
  --description "Upgrade with kept pre-upgrade hook"
kubectl logs -n dudko-helm job/portal-pre-upgrade
```
Очікую:
```text
=== Helm pre-upgrade hook ===
Release:   portal
Namespace: dudko-helm
Revision:  5
Image:     portal-api:1.0.0
...
```

**Спосіб Б — дивитися наживо** (у другому терміналі ДО `helm upgrade`):
```bash
kubectl get jobs,pods -n dudko-helm -l app.kubernetes.io/component=pre-upgrade-hook -w
```
Очікую: pod `portal-pre-upgrade-...` проходить `ContainerCreating → Completed`, потім Job зникає.
Події лишаються ще близько години:
```bash
kubectl get events -n dudko-helm --field-selector involvedObject.kind=Job
```
Також `helm upgrade ... --debug` друкує `Starting hook` / `hook ... succeeded`.

---

## 6. Пріоритет значень: values.yaml < -f < --set

Один ключ `replicaCount` у трьох місцях: `values.yaml` = 1, `values-prod.yaml` = 3, `--set` = 2.

```bash
helm template portal chart/portal -n dudko-helm -s templates/deployment.yaml | grep replicas
```
Очікую: `replicas: 1` (лише values.yaml).

```bash
helm template portal chart/portal -n dudko-helm -s templates/deployment.yaml \
  -f chart/portal/values-prod.yaml | grep replicas
```
Очікую: `replicas: 3` (файл `-f` переміг values.yaml).

```bash
helm template portal chart/portal -n dudko-helm -s templates/deployment.yaml \
  -f chart/portal/values-prod.yaml --set replicaCount=2 | grep replicas
```
Очікую: `replicas: 2` (`--set` переміг усіх).

На живому релізі:
```bash
helm upgrade portal chart/portal -n dudko-helm \
  -f chart/portal/values-prod.yaml --set replicaCount=2 \
  --description "Precedence demo: values.yaml=1, values-prod=3, --set=2"
helm get values portal -n dudko-helm
```
Очікую: у `USER-SUPPLIED VALUES` — `replicaCount: 2` (і решта ключів з values-prod.yaml);
`kubectl get deploy portal-api -n dudko-helm` показує `2/2`.

```bash
helm get values portal -n dudko-helm --all | grep -E '^replicaCount|^image:' -A3
```
Очікую: `replicaCount: 2`, а в блоці `image:` — `tag: 1.1.0` (з values-prod.yaml, а не порожній з values.yaml).

---

## 7. Видалення

```bash
./scripts/lab4-down.sh
```
або вручну:
```bash
helm uninstall portal -n dudko-helm
kubectl delete job,pod -n dudko-helm -l app.kubernetes.io/instance=portal --ignore-not-found
```
Очікую: `release "portal" uninstalled`. Другий рядок прибирає pod `portal-test-connection`
(hook-ресурси не входять у реліз, тому `helm uninstall` їх не чіпає).

```bash
kubectl get all -n dudko-helm
kubectl get pvc,secrets -n dudko-helm
helm list -n dudko-helm
```
Очікую: `No resources found in dudko-helm namespace.` (через кілька секунд, поки pod-и
Terminating), жодних `sh.helm.release.*` Secret, порожній `helm list`.
Сам namespace лишається; прибрати повністю: `kubectl delete namespace dudko-helm`.

---

## 8. Перемикання між Lab 3 і Lab 4

Лаби запускаються **по черзі**, кожна у своєму namespace і зі своїм хостом:

| Скрипт | Що робить | Namespace |
|---|---|---|
| `./scripts/lab3-up.sh` | `kubectl apply -f k8s/` | `dudko` |
| `./scripts/lab3-down.sh` | `kubectl delete -f k8s/ --ignore-not-found` | `dudko` |
| `./scripts/lab4-up.sh [values-файл]` | `helm install portal chart/portal -n dudko-helm --create-namespace -f chart/portal/values-dev.yaml` (або вказаний файл) | `dudko-helm` |
| `./scripts/lab4-down.sh` | `helm uninstall portal -n dudko-helm` + прибирання тестових pod-ів | `dudko-helm` |

Кожен скрипт у кінці друкує `kubectl get pods,svc,ingress -n <namespace>`.

```bash
# Lab 3 -> Lab 4
./scripts/lab3-down.sh && ./scripts/lab4-up.sh
# prod-профіль одразу:
./scripts/lab4-up.sh chart/portal/values-prod.yaml
# Lab 4 -> Lab 3
./scripts/lab4-down.sh && ./scripts/lab3-up.sh
```

### /etc/hosts для всіх трьох хостів

**Linux, нативний Docker Engine:**
```bash
MIP=$(minikube ip)
echo "$MIP portal.local portal-helm.local portal-helm-prod.local" | sudo tee -a /etc/hosts
```
Очікую: рядок на кшталт `192.168.49.2 portal.local portal-helm.local portal-helm-prod.local`.

**Windows / macOS / Linux з Docker Desktop (docker-драйвер):** IP minikube з хоста недоступний,
тому всі три хости вказують на `127.0.0.1`, а в окремому терміналі працює `minikube tunnel`:
```text
127.0.0.1 portal.local portal-helm.local portal-helm-prod.local
```
(Windows: `C:\Windows\System32\drivers\etc\hosts`, редактор від імені адміністратора.)

```bash
minikube tunnel
```
Очікую: `Tunnel successfully started`; не закривати, поки працюєте з Ingress.

Перевірка, що хости не перетинаються:
```bash
kubectl get ingress -A
```
Очікую: в один момент часу — лише Ingress однієї лаби (`dudko`/`portal.local` **або**
`dudko-helm`/`portal-helm*.local`).
