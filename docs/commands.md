

Namespace: `dudko`, образ: `portal-api`,
хост: `portal.local`.

Зручна змінна, щоб не писати `-n dudko` щоразу (необов'язково):

```bash
alias kn='kubectl -n dudko'
```

---

## 1. Кластер

```bash
minikube start --driver=docker
```
Очікую: `Done! kubectl is now configured to use "minikube" cluster and "default" namespace by default`.

```bash
kubectl get nodes -o wide
```
Очікую: один вузол `minikube`, `STATUS Ready`, `ROLES control-plane`, версія Kubernetes.

```bash
kubectl get pods -n kube-system
```
Очікую: `coredns`, `etcd-minikube`, `kube-apiserver-minikube`, `kube-controller-manager-minikube`,
`kube-proxy`, `kube-scheduler-minikube`, `storage-provisioner` — усі `Running`.

```bash
minikube addons enable metrics-server
minikube addons enable ingress
```
Очікую: `The 'metrics-server' addon is enabled` та `The 'ingress' addon is enabled`.

```bash
kubectl wait -n ingress-nginx --for=condition=ready pod \
  -l app.kubernetes.io/component=controller --timeout=180s
```
Очікую: `pod/ingress-nginx-controller-... condition met` (ingress готовий приймати трафік).

```bash
minikube addons list | grep -E 'ingress|metrics-server'
```
Очікую: `ingress` і `metrics-server` зі статусом `enabled`.

### Рядок у /etc/hosts

Спершу перевірте, яким Docker ви користуєтесь:

```bash
docker info --format '{{.OperatingSystem}}'
```
Очікую: `Docker Desktop` або назву дистрибутиву (напр. `Ubuntu 24.04`) для нативного Docker Engine.

**Linux з нативним Docker Engine** (IP minikube доступний напряму):

```bash
echo "$(minikube ip) portal.local" | sudo tee -a /etc/hosts
```
Очікую: виведено рядок на кшталт `192.168.49.2 portal.local`.

**Linux з Docker Desktop, Windows, macOS**: Docker працює всередині VM, тому IP minikube
(`192.168.49.2`) з хоста **недоступний** (`curl` зависає). Перевірено на цьому ноутбуці. Тому:

1. У `/etc/hosts` (Windows: `C:\Windows\System32\drivers\etc\hosts`, редактор від адміністратора) додати:
   ```text
   127.0.0.1 portal.local
   ```
2. В окремому терміналі тримати запущеним (попросить пароль адміністратора):
   ```bash
   minikube tunnel
   ```
   Очікую: `Tunnel successfully started`; термінал не закривати, поки працюєте з Ingress.
   На Linux tunnel просить `sudo`-пароль, бо відкриває порт 80.

**Запасний варіант без hosts і без tunnel**: трафік однаково проходить через Ingress-правило
для `portal.local`:

```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80
# в іншому терміналі:
curl -s -H 'Host: portal.local' http://127.0.0.1:18080/info; echo
```
Очікую: `Forwarding from 127.0.0.1:18080 -> 80` і JSON від застосунку. У всіх командах нижче
можна замінити `http://portal.local` на `-H 'Host: portal.local' http://127.0.0.1:18080`.

---

## 2. Образи

```bash
./scripts/build-images.sh
```
Очікую: дві збірки `portal-api:1.0.0` і `portal-api:1.1.0`, потім список `minikube image ls`
з рядками `docker.io/library/portal-api:1.0.0` і `...:1.1.0`.

```bash
minikube image ls | grep portal-api
```
Очікую: обидва теги всередині minikube (тегу `latest` немає).

---

## 3. Розгортання

```bash
kubectl apply -f k8s/
```
Очікую: 9 рядків `... created`: namespace, configmap, secret, persistentvolumeclaim,
deployment `portal-db`, service `portal-db`, deployment `portal-api`, service `portal-api`, ingress.

```bash
kubectl get pods,deploy,rs,svc,ingress,pvc -n dudko
```
Очікую: 2 pod-и `portal-api-...` і 1 `portal-db-...` у `Running`, `READY 1/1`;
deploy `portal-api 2/2`; один ReplicaSet `portal-api-<hash>` з `DESIRED 2`;
сервіси `portal-api` (ClusterIP, 80) і `portal-db` (ClusterIP, 5432); ingress з `HOSTS portal.local`
і `ADDRESS` (IP minikube); PVC `portal-db-data` у статусі `Bound`.

> Перші ~10–30 с pod-и `portal-api` можуть бути `0/1`: вони чекають готовності БД
> (readinessProbe `/ready` повертає 503, поки не створено таблиці). Це нормально;
> `RESTARTS` при цьому лишається `0`, бо `/health` відповідає одразу.

```bash
kubectl get pods -n dudko -o wide --show-labels
```
Очікую: у кожного pod-а свій IP і мітка `app.kubernetes.io/name=portal-api` (або `portal-db`).

```bash
kubectl top pods -n dudko
```
Очікую: CPU (`m`) і пам'ять (`Mi`) по кожному pod-у (через ~1 хв після ввімкнення metrics-server).

### Відкрити в браузері

```text
http://portal.local/          — головна сторінка: версія, hostname pod-а, APP_GREETING, LOG_LEVEL, API_KEY = de***
http://portal.local/info      — те саме у JSON
http://portal.local/docs      — Swagger UI
```

```bash
curl -s http://portal.local/info; echo
curl -s http://portal.local/health; echo
curl -s http://portal.local/ready; echo
```
Очікую: `{"version":"1.0.0",...,"hostname":"portal-api-...","api_key":"de***"}`,
`{"status":"ok"}`, `{"status":"ready"}`.

Запасний варіант без Ingress:

```bash
kubectl port-forward -n dudko svc/portal-api 8080:80
```
Очікую: `Forwarding from 127.0.0.1:8080 -> 8000`; відкрити `http://localhost:8080/`.

### Довести, що ConfigMap і Secret потрапили в контейнер

```bash
kubectl exec -n dudko deploy/portal-api -- env | grep -E '^(APP_|LOG_LEVEL|ENVIRONMENT|DEBUG|API_KEY|POSTGRES_|DB_)' | sort
```
Очікую: `APP_GREETING=Привіт з Kubernetes!...`, `APP_VERSION=1.0.0` (з образу), `LOG_LEVEL=INFO`,
`DB_HOST=portal-db`, `POSTGRES_PASSWORD=dev-only-not-real-db-password`, `API_KEY=dev-only-not-real`.
Тобто всередині контейнера секрет є повністю (це нормально), а на сторінці — лише `de***`.

```bash
kubectl exec -n dudko deploy/portal-api -- printenv DATABASE_URL
```
Очікую: `postgresql+asyncpg://portal:dev-only-not-real-db-password@portal-db:5432/portal_db` —
kubelet підставив `$(VAR)` із ConfigMap і Secret.

```bash
kubectl get configmap portal-config -n dudko -o yaml
kubectl get secret portal-secret -n dudko -o jsonpath='{.data.API_KEY}' | base64 -d; echo
```
Очікую: ключі ConfigMap відкритим текстом; у Secret поле `data` у base64, після `base64 -d` — `dev-only-not-real`.

### Процес застосунку: PID у контейнері та на вузлі

У образі `python:3.12-slim` немає `ps`, тому процеси читаємо з `/proc`:

```bash
kubectl exec -n dudko deploy/portal-api -- sh -c \
  'for p in /proc/[0-9]*; do echo "PID ${p#/proc/}: $(tr "\0" " " < $p/cmdline)"; done'
```
Очікую: `PID 1: /usr/local/bin/python3.12 /usr/local/bin/uvicorn src.main:app --host 0.0.0.0 --port 8000`
і рядок самої команди `sh -c for p in ...`. Завдяки `exec` у `CMD` Dockerfile uvicorn є PID 1:
саме він отримує SIGTERM від Kubernetes і коректно завершується. Без `exec` PID 1 був би
`sh -c uvicorn ...`, який ігнорує SIGTERM, і pod убивався б через 30 с (SIGKILL).

Той самий процес з боку вузла minikube (runtime containerd):

```bash
minikube ssh -- sudo crictl ps --name portal-api
CID=$(minikube ssh -- sudo crictl ps --name portal-api -q | head -1 | tr -d '\r')
HPID=$(minikube ssh -- sudo crictl inspect --output go-template --template '{{.info.pid}}' "$CID" | tr -d '\r')
minikube ssh -- ps -o pid,ppid,cmd -p "$HPID"
```
Очікую: таблицю контейнерів з колонками `POD` і `NAMESPACE dudko`, потім той самий uvicorn із
**іншим PID** (напр. `44479`). Висновок: PID namespace ізолює процеси; всередині контейнера
застосунок бачить себе як PID 1, а на вузлі це звичайний процес з іншим номером.

### Веб-клієнт (Django dashboard)

Клієнт запускається локально і ходить до API в кластері через `kubectl port-forward`.
Працює для Lab 3 і Lab 4 (namespace визначається автоматично):

```bash
./scripts/client-up.sh          # або явно: ./scripts/client-up.sh lab3 | lab4
```
Очікую: `>>> lab3: Service portal-api у namespace dudko`, рядок `>>> API: {"version":"1.0.0",...}`
і список посилань:
`http://localhost:8080/` — клієнт; `http://portal.local:18080/` — API через Ingress (лише якщо в
namespace є Ingress: Lab 3 завжди, Lab 4 — при `ingress.enabled=true`); `http://localhost:8000/` —
API напряму. У браузері клієнта: login → register → dashboard → запуск симуляції.
Термінал не закривати; `Ctrl+C` => `>>> Клієнт і port-forward зупинено`.
Якщо pod, до якого прив'язаний port-forward, зник (delete/rollout), скрипт перепідключається сам.

---

## 4. Життєвий цикл

### 4.1 Самовідновлення: видалити pod

Термінал 1:
```bash
kubectl get pods -n dudko -l app.kubernetes.io/name=portal-api -w
```
Термінал 2:
```bash
POD=$(kubectl get pod -n dudko -l app.kubernetes.io/name=portal-api -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod -n dudko "$POD"
```
Очікую (термінал 1): старий pod `Terminating`, майже одразу новий `portal-api-<hash>-<new>`
`Pending → ContainerCreating → Running 0/1 → 1/1`. ReplicaSet відновив кількість реплік до 2.

### 4.2 Масштабування до 4 і балансування

```bash
kubectl scale deployment/portal-api -n dudko --replicas=4
kubectl get pods -n dudko -l app.kubernetes.io/name=portal-api
```
Очікую: `deployment.apps/portal-api scaled`, потім 4 pod-и `Running 1/1`.

```bash
for i in $(seq 1 20); do curl -s http://portal.local/info | grep -o '"hostname":"[^"]*"'; done | sort | uniq -c
```
Очікую: 4 різні hostname, кожен приблизно по 5 разів — Ingress/Service розподіляє запити між репліками.

```bash
kubectl scale deployment/portal-api -n dudko --replicas=2
```
Очікую: зайві 2 pod-и переходять у `Terminating`, лишається 2.

### 4.3 Цикл перевірки відсутності простою (запустити в ДРУГОМУ терміналі до оновлення)

```bash
while true; do curl -s --max-time 2 -w ' HTTP %{http_code}\n' http://portal.local/info || echo "FAIL $(date +%T)"; sleep 0.3; done
```
Очікую: безперервні рядки `{"version":"1.0.0",...} HTTP 200`; під час rollout з'являються
`"version":"1.1.0"` упереміш, далі лише 1.1.0. **Жодного `FAIL`, `502` чи `503`.**
Зупинити: `Ctrl+C`.

### 4.4 Rolling update до 1.1.0

```bash
kubectl set image deployment/portal-api -n dudko portal-api=portal-api:1.1.0
kubectl annotate deployment/portal-api -n dudko --overwrite \
  kubernetes.io/change-cause="Update to portal-api:1.1.0"
kubectl rollout status deployment/portal-api -n dudko
```
Очікую: `image updated`, `annotated`, потім
`Waiting for deployment "portal-api" rollout to finish: 1 out of 2 new replicas have been updated...`
→ `deployment "portal-api" successfully rolled out`.

```bash
kubectl get rs -n dudko -l app.kubernetes.io/name=portal-api
```
Очікую: два ReplicaSet — новий з `DESIRED 2 / READY 2`, старий з `0` (зберігається для відкату).

Оновити `http://portal.local/` у браузері — Очікую: `APP_VERSION 1.1.0` і текст
`Release 1.1.0: NEW rolling update...`.

> Чому немає простою: `maxUnavailable: 0` + `maxSurge: 1` — спершу стартує 1 новий pod, і лише
> коли він пройшов readinessProbe, видаляється 1 старий; `preStop: sleep 5` дає Ingress-у
> час прибрати pod з балансування до SIGTERM.

### 4.5 Історія та відкат

```bash
kubectl rollout history deployment/portal-api -n dudko
```
Очікую: `REVISION 1  Initial deploy: portal-api:1.0.0` і `REVISION 2  Update to portal-api:1.1.0`.

```bash
kubectl rollout history deployment/portal-api -n dudko --revision=2
```
Очікую: шаблон pod-а ревізії 2 з `Image: portal-api:1.1.0`.

```bash
kubectl rollout undo deployment/portal-api -n dudko
kubectl rollout status deployment/portal-api -n dudko
curl -s http://portal.local/info; echo
```
Очікую: `rolled back`, `successfully rolled out`, у JSON знову `"version":"1.0.0"`.
Нові версії kubectl додають `Warning: ... previously managed with 'kubectl apply'. Rolling back will
not update the kubectl.kubernetes.io/last-applied-configuration annotation...`. Це нормально:
kubectl нагадує, що наступний `kubectl apply -f k8s/` візьме образ із файлу, а не з відкату.
У `rollout history` ревізія 1 зникає і з'являється як ревізія 3 (той самий шаблон).

> `kubectl apply -f k8s/` повертає образ з файлу (`1.0.0`). Для «офіційної» зміни версії
> правильно редагувати `image:` і `change-cause` у `20-deployment.yaml` та робити `apply`.

---

## 5. Діагностика

### 5.1 Зламати: неіснуючий тег

```bash
kubectl set image deployment/portal-api -n dudko portal-api=portal-api:9.9.9-does-not-exist
kubectl annotate deployment/portal-api -n dudko --overwrite \
  kubernetes.io/change-cause="BROKEN: portal-api:9.9.9-does-not-exist"
kubectl get pods -n dudko -l app.kubernetes.io/name=portal-api
```
Очікую: новий pod зі `STATUS ErrImagePull`, потім `ImagePullBackOff`, `READY 0/1`.
Два старі pod-и **продовжують працювати** (`Running 1/1`) — завдяки `maxUnavailable: 0`
застосунок доступний; curl-цикл з 4.3 не показує помилок.

```bash
kubectl rollout status deployment/portal-api -n dudko --timeout=30s
```
Очікую: `Waiting for deployment ... 1 out of 2 new replicas have been updated...`, потім
`error: timed out waiting for the condition` — rollout застряг.

### 5.2 Розслідувати

```bash
BAD=$(kubectl get pods -n dudko -l app.kubernetes.io/name=portal-api \
  --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod -n dudko "$BAD"
```
Очікую: у `Containers → State: Waiting, Reason: ImagePullBackOff`; внизу `Events`:
`Pulling image "portal-api:9.9.9-does-not-exist"`, `Failed to pull image ... pull access denied /
repository does not exist`, `Back-off pulling image`.

```bash
kubectl get events -n dudko --sort-by=.lastTimestamp
```
Очікую: хронологія останніх подій: `ScalingReplicaSet`, `Scheduled`, `Pulling`, `Failed`, `BackOff`.

```bash
kubectl logs -n dudko "$BAD"
```
Очікую: `Error from server (BadRequest): container "portal-api" in pod ... is waiting to start:
image can't be pulled` — контейнер навіть не стартував, тому логів застосунку немає.

```bash
kubectl logs -n dudko deploy/portal-api --tail=20
```
Очікую: логи робочого pod-а: `Started: {...}`, `Uvicorn running on http://0.0.0.0:8000`,
рядки `GET /ready HTTP/1.1 200` від probes.

```bash
kubectl exec -it -n dudko deploy/portal-api -- sh
```
Усередині контейнера:
```sh
hostname                      # ім'я pod-а
env | grep APP_               # змінні з ConfigMap і образу
python -c "import urllib.request as u; print(u.urlopen('http://localhost:8000/ready').read())"
python -c "import socket; print(socket.gethostbyname('portal-db'))"   # DNS Service бази
exit
```
Очікую: `portal-api-...`, `APP_VERSION=1.0.0`/`APP_GREETING=...`, `b'{"status":"ready"}'`,
ClusterIP Service `portal-db` (напр. `10.x.x.x`).

### 5.3 Виправити

```bash
kubectl rollout undo deployment/portal-api -n dudko
# або явно: kubectl set image deployment/portal-api -n dudko portal-api=portal-api:1.1.0
kubectl rollout status deployment/portal-api -n dudko
kubectl get pods -n dudko -l app.kubernetes.io/name=portal-api
```
Очікую: `successfully rolled out`, 2 pod-и `Running 1/1`, pod-а з `ImagePullBackOff` більше немає.

```bash
kubectl rollout history deployment/portal-api -n dudko
```
Очікую: у списку видно ревізію `BROKEN: ...` і ревізію відкату.

---

## 6. Прибирання (коли все зафіксовано)

```bash
kubectl delete namespace dudko   # видаляє ВСІ об'єкти лабораторної, включно з PVC і даними БД
minikube stop                    # зупинити кластер (дані minikube зберігаються)
```
Очікую: `namespace "dudko" deleted`; `1 node stopped.`
