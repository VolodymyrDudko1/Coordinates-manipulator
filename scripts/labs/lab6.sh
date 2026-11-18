# shellcheck shell=bash
# Lab 6: progressive delivery — canary з Argo Rollouts під Argo CD.
# root-lab6 -> Application argo-rollouts (контролер з Helm-чарту) + portal (charts/portal з
# envs/minikube/values.yaml + values-lab6.yaml: Rollout, 4 репліки). Namespace dudko-gitops (як Lab 5).
# Реліз — зміна image.tag у envs/minikube/values.yaml (спільний з Lab 5) + commit + push.
# Використовує допоміжні функції l5_* з lab5.sh (тег, commit+push, секрети, образи).

L6_ROOT=bootstrap/root-lab6.yaml
L6_RO=portal-api                   # ім'я Rollout
L6_TRAFFIC=l6-traffic              # pod з циклом запитів усередині кластера

lab6_title() { echo "Lab 6 — canary з Argo Rollouts (root-lab6, namespace dudko-gitops)"; }
lab6_is_up() { kubectl get application root-lab6 -n argocd >/dev/null 2>&1; }

# ---------- допоміжні ----------
ro_phase() { kubectl get rollout "${L6_RO}" -n "${L5_NS}" -o jsonpath='{.status.phase}' 2>/dev/null; }

# ro_wait <Healthy|Paused|Degraded> [timeout] — чекати фазу Rollout (status.phase).
ro_wait() {
  local want="$1" timeout="${2:-240}" t=0 p
  while ((t < timeout)); do
    p="$(ro_phase)"
    [[ "${p}" == "${want}" ]] && { echo "Rollout ${L6_RO}: ${p}"; return 0; }
    sleep 2; t=$((t + 2))
  done
  warn "Rollout ${L6_RO}: ${p:-?} (очікував ${want})"; return 1
}

# Після abort: дочекатися, поки canary-ReplicaSet справді масштабується до 0 (pod-и ще кілька
# секунд відповідають), і лише тоді рахувати відповіді.
ro_wait_canary_gone() {
  local hash t=0
  hash=$(kubectl get rollout "${L6_RO}" -n "${L5_NS}" -o jsonpath='{.status.currentPodHash}')
  while ((t < 90)); do
    [[ "$(kubectl get pods -n "${L5_NS}" -l "rollouts-pod-template-hash=${hash}" -o name | wc -l)" == 0 ]] \
      && { echo "canary-pod-и (${hash}) видалено"; sleep 3; return 0; }
    sleep 2; t=$((t + 2))
  done
  warn "canary-pod-и ще працюють"
}

# Дочірній Application з'являється лише після синхронізації root. До того argocd CLI
# відповідає PermissionDenied (Argo CD не розкриває, чи існує застосунок), тому чекаємо через kubectl.
app_exists() {
  local t=0
  until kubectl get application "$1" -n argocd >/dev/null 2>&1; do
    ((t++ < 60)) || { warn "Application $1 не з'явився"; return 1; }
    sleep 2
  done
}

# Цикл запитів УСЕРЕДИНІ кластера: pod busybox -> Service portal-api (без Ingress і port-forward).
l6_traffic_start() {
  kubectl delete pod "${L6_TRAFFIC}" -n "${L5_NS}" --ignore-not-found --wait=true >/dev/null
  kubectl run "${L6_TRAFFIC}" -n "${L5_NS}" --image=busybox:1.36 --restart=Never -- sh -c \
    'while true; do v=$(wget -qO- -T 2 http://portal-api/version | sed -n "s/.*\"version\":\"\([^\"]*\)\".*/\1/p");
       echo "$(date +%T) ${v:-ERROR}"; sleep 0.25; done' >/dev/null
  kubectl wait --for=condition=ready pod "${L6_TRAFFIC}" -n "${L5_NS}" --timeout=60s >/dev/null
  info "Цикл запитів у кластері: pod ${L6_TRAFFIC} -> http://portal-api/version (4 запити/с)"
}
# l6_traffic <секунд> — скільки відповідей кожної версії за останні N секунд.
l6_traffic() {
  echo "${C_B}Відповіді за останні $1 с (версія: кількість):${C_0}"
  kubectl logs "${L6_TRAFFIC}" -n "${L5_NS}" --since="$1s" | awk '{print $2}' | sort | uniq -c
}
l6_traffic_stop() { kubectl delete pod "${L6_TRAFFIC}" -n "${L5_NS}" --ignore-not-found --wait=false >/dev/null; }

# Push => одразу refresh, щоб Argo CD не чекав на опитування Git.
l6_refresh() { argocd app get portal --refresh >/dev/null; }

# ---------- інтерфейс для lab.sh ----------
lab6_prepare() {
  command -v argocd >/dev/null || die "немає argocd CLI — див. docs/argocd-commands.md"
  command -v kubectl-argo-rollouts >/dev/null \
    || die "немає плагіна kubectl argo rollouts — див. docs/rollouts-commands.md (встановлення)"
  git_check_pushed "${L5_BRANCH}"
  if [[ ! " ${L5_RELEASES[*]} " == *" $(l5_tag) "* ]]; then
    l5_set_tag "${L5_RELEASES[0]}"
    l5_commit_push "lab6 demo: reset (image $(l5_tag))" "${L5_VALUES}" || warn "push не вдався"
  fi
  argocd_wake
  argocd_pf
  l5_secrets
  l5_pull_images
  minikube image ls 2>/dev/null | grep -q 'busybox:1.36' || minikube image pull busybox:1.36   # цикл запитів
  argocd_login_quiet || warn "argocd CLI: не вдалося увійти (пароль у $(argocd_password_file))"
}

lab6_up() {
  lab6_prepare
  kubectl apply -f "${L6_ROOT}"
  sleep 5
  app_wait argo-rollouts Healthy 300 && app_wait portal Healthy 300
}

lab6_down() {
  l6_traffic_stop 2>/dev/null || true
  if lab6_is_up; then
    argocd_wake
    info "Видаляю root-lab6 (каскадно: portal, argo-rollouts і їхні об'єкти)"
    kubectl delete -f "${L6_ROOT}" --wait --timeout=180s >/dev/null || warn "root-lab6 видаляється довше за 3 хв"
    kubectl wait --for=delete application/portal application/argo-rollouts -n argocd --timeout=120s >/dev/null 2>&1 || true
  fi
  [[ "${TARGET_LAB:-}" =~ ^[5-9]$ ]] || argocd_sleep
}

lab6_steps() {
  local NS="-n ${L5_NS}" cur new
  cur="$(l5_tag)"; new="$(l5_next_tag)"

  step "п.1a Контролер Argo Rollouts — з Git, як і застосунок (App of Apps)" \
    "root-lab6 створює argo-rollouts (Helm-чарт argo-rollouts 2.43.12) і portal; обидва Synced/Healthy; pod контролера Running" \
    "ls argocd-apps/lab6
grep -nE 'chart:|targetRevision|sync-wave' argocd-apps/lab6/*.yaml
kubectl apply -f ${L6_ROOT}
app_exists root-lab6 && argocd app wait root-lab6 --sync --timeout 120
app_exists argo-rollouts && argocd app wait argo-rollouts --sync --health --timeout 300
app_exists portal && argocd app wait portal --sync --health --timeout 300
argocd app list
kubectl get pods -n argo-rollouts"

  step "п.1b Плагін kubectl argo rollouts" \
    "kubectl-argo-rollouts: v1.10.x" \
    "kubectl argo rollouts version --short"

  step "п.2 Rollout у Helm-чарті: rollout.enabled замінює Deployment, 4 репліки" \
    "deployment.yaml рендериться лише коли rollout.enabled=false; у кластері Rollout portal-api (4/4), Deployment лише portal-db" \
    "grep -n 'rollout.enabled' charts/portal/templates/deployment.yaml charts/portal/templates/rollout.yaml
grep -nE 'enabled|replicaCount' envs/minikube/values-lab6.yaml
kubectl get rollout,deploy ${NS}"

  step "п.3 Стратегія canary у values (пояснити вибір)" \
    "3 кроки setWeight (25/50/75), ручна pause: {} і дві з таймером; без traffic routing частка = частка pod-ів (1/2/3 з 4)" \
    "sed -n '/^rollout:/,\$p' envs/minikube/values-lab6.yaml"

  step "Початковий стан: стабільна версія ${cur}" \
    "Status: ✔ Healthy, Strategy: Canary, 4 pod-и однієї ревізії; цикл запитів у кластері — лише ${cur}" \
    "kubectl argo rollouts get rollout ${L6_RO} ${NS}
l6_traffic_start
sleep 5; l6_traffic 5"

  step "п.4a Реліз через Git: тег ${cur} -> ${new}; Rollout зупиняється на ручній паузі (25%)" \
    "Status: ॥ Paused (CanaryPauseStep), Step 1/6, SetWeight 25: 1 canary + 3 stable; Argo CD: Synced / Suspended; у циклі ~25% відповідей ${new}" \
    "l5_set_tag ${new}
l5_commit_push 'Release ${new} (canary)' ${L5_VALUES}
l6_refresh
ro_wait Paused 180
kubectl argo rollouts get rollout ${L6_RO} ${NS}
argocd app get portal | grep -E 'Sync Status|Health Status'
sleep 10; l6_traffic 10"

  step "п.4a promote на ручній паузі: далі кроки 50% і 75% з таймерами — само" \
    "фаза Progressing -> Healthy (~1 хв: pause 30s і 20s); усі 4 pod-и — ${new}; Argo CD: Synced / Healthy; у циклі лише ${new}" \
    "kubectl argo rollouts promote ${L6_RO} ${NS}
ro_wait Healthy 240
kubectl argo rollouts get rollout ${L6_RO} ${NS}
argocd app get portal | grep -E 'Sync Status|Health Status'
l6_traffic 10"

  step "п.5 Ще один реліз (${new} -> ${cur}) і abort на ручній паузі" \
    "після abort: усі pod-и знову stable (${new}), canary-ReplicaSet scaled down, Status: ✖ Degraded (RolloutAborted); у циклі лише ${new}" \
    "l5_set_tag ${cur}
l5_commit_push 'Release ${cur} (to be aborted)' ${L5_VALUES}
l6_refresh
ro_wait Paused 180
l6_traffic 8
kubectl argo rollouts abort ${L6_RO} ${NS}
ro_wait Degraded 120
ro_wait_canary_gone
kubectl argo rollouts get rollout ${L6_RO} ${NS}
sleep 5; l6_traffic 5"

  step "п.5 Argo CD після abort: Synced, але Degraded — пояснити" \
    "Synced: spec у кластері = Git (тег ${cur}); Degraded: Rollout перерваний і працює стара версія — бажаний стан НЕ досягнуто" \
    "argocd app get portal | grep -E 'Sync Status|Health Status|Rollout'"

  step "п.5 Завершити відкат через Git: git revert релізу" \
    "Revert -> тег знову ${new} = stable ReplicaSet: Rollout одразу Healthy (без кроків canary); Argo CD Synced / Healthy" \
    "git revert --no-edit HEAD
git push -q origin ${L5_BRANCH}
l6_refresh
ro_wait Healthy 180
argocd app wait portal --sync --health --timeout 180
kubectl argo rollouts get rollout ${L6_RO} ${NS}
git log --oneline -4
l6_traffic 8
l6_traffic_stop"

  step "(Необов'язково) Дашборд Rollouts у браузері" \
    "http://localhost:3100/rollouts — вкладка dudko-gitops, Rollout portal-api, кнопки Promote/Abort (Ctrl+C — вийти)" \
    "echo 'У другому терміналі: kubectl argo rollouts dashboard -n ${L5_NS}  ->  http://localhost:3100/rollouts'"
}
