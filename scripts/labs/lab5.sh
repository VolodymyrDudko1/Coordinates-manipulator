# shellcheck shell=bash
# Lab 5: GitOps з Argo CD. Чарт charts/portal + envs/minikube/values.yaml, namespace dudko-gitops,
# хост portal-gitops.local. Вручну застосовується лише bootstrap/root-lab5.yaml (App of Apps).
# Демо комітить і пушить у гілку labs-5-7: Argo CD читає GitHub, а не локальні файли.

L5_BRANCH=labs-5-7
L5_REPO=https://github.com/VolodymyrDudko1/Coordinates-manipulator.git
L5_GH_USER=VolodymyrDudko1
L5_IMAGE=ghcr.io/volodymyrdudko1/backend
L5_RELEASES=(1.2.0 1.3.0)          # git-теги v1.2.0 / v1.3.0 => CI публікує ці образи
L5_BAD_TAG=9.9.9-does-not-exist    # п.6b: тег, якого немає в реєстрі
L5_NS=dudko-gitops
L5_HOST=portal-gitops.local
L5_VALUES=envs/minikube/values.yaml
L5_APP=argocd-apps/lab5/portal.yaml
L5_ROOT=bootstrap/root-lab5.yaml
L5_TOKEN_FILE="${LABS_CFG}/github-token"   # лише для приватного репозиторію/пакета; поза Git

lab5_title() { echo "Lab 5 — GitOps з Argo CD (App of Apps, namespace dudko-gitops)"; }
lab5_is_up() { kubectl get application root-lab5 -n argocd >/dev/null 2>&1; }

# ---------- допоміжні ----------
l5_tag()      { sed -n 's/^  tag: "\([^"]*\)".*/\1/p' "${L5_VALUES}"; }
l5_selfheal() { sed -n 's/^ *selfHeal: \([a-z]*\).*/\1/p' "${L5_APP}"; }
l5_next_tag() { [[ "$(l5_tag)" == "${L5_RELEASES[0]}" ]] && echo "${L5_RELEASES[1]}" || echo "${L5_RELEASES[0]}"; }
l5_set_tag()  { sed -i "s/^  tag: .*/  tag: \"$1\"/" "${L5_VALUES}"; }
l5_set_selfheal() { sed -i "s/^\( *selfHeal:\) [a-z]*/\1 $1/" "${L5_APP}"; }
l5_rand()     { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# commit + push лише вказаних файлів (інші незакомічені зміни в репозиторії не зачіпаються).
l5_commit_push() {
  local msg="$1"; shift
  git commit -q -m "${msg}" -- "$@" && git log --oneline -1
  git push -q origin "${L5_BRANCH}"
}

# Стан Git перед демо: selfHeal=false і робочий тег образу (після минулої репетиції могло лишитися інше).
l5_reset_git() {
  local files=()
  if [[ "$(l5_selfheal)" != false ]]; then l5_set_selfheal false; files+=("${L5_APP}"); fi
  if [[ ! " ${L5_RELEASES[*]} " == *" $(l5_tag) "* ]]; then l5_set_tag "${L5_RELEASES[0]}"; files+=("${L5_VALUES}"); fi
  [[ ${#files[@]} -eq 0 ]] && return 0
  info "Скидаю стан демо в Git (selfHeal: false, тег $(l5_tag)) і пушу"
  l5_commit_push "lab5 demo: reset (selfHeal: false, image $(l5_tag))" "${files[@]}" \
    || warn "push не вдався — зробіть 'git push origin ${L5_BRANCH}' вручну"
}

# Секрети поза Git: паролі застосунку (генеруються один раз) і, за потреби, доступ до GHCR.
l5_secrets() {
  kubectl create namespace "${L5_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if ! kubectl get secret portal-secret -n "${L5_NS}" >/dev/null 2>&1; then
    info "Створюю Secret portal-secret (випадкові паролі, у Git їх немає)"
    kubectl create secret generic portal-secret -n "${L5_NS}" \
      --from-literal=POSTGRES_PASSWORD="$(l5_rand 16)" \
      --from-literal=SECRET_KEY="$(l5_rand 32)" \
      --from-literal=API_KEY="$(l5_rand 8)" >/dev/null
  fi
  if [[ -s "${L5_TOKEN_FILE}" ]]; then
    kubectl create secret docker-registry ghcr-pull -n "${L5_NS}" --docker-server=ghcr.io \
      --docker-username="${L5_GH_USER}" --docker-password="$(cat "${L5_TOKEN_FILE}")" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  fi
}

# Заздалегідь затягнути образи в minikube, щоб реліз на захисті не чекав на завантаження.
l5_pull_images() {
  local have img; have="$(minikube image ls 2>/dev/null)"
  for img in "${L5_RELEASES[@]/#/${L5_IMAGE}:}" postgres:16-alpine; do
    grep -q "${img}" <<<"${have}" && continue
    info "Завантажую ${img} у minikube"
    minikube image pull "${img}" >/dev/null 2>&1 \
      || warn "не вдалося завантажити ${img}: чи опубліковано образ (git tag v${img##*:}) і чи пакет public?"
  done
}

l5_check_access() {
  if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${L5_REPO%.git}")" != 200 \
        && ! -s "${L5_TOKEN_FILE}" ]]; then
    warn "Репозиторій приватний, а ${L5_TOKEN_FILE} немає: Argo CD не зможе читати Git."
    warn "Або зробіть репозиторій public, або збережіть classic PAT (repo, read:packages) у цей файл (chmod 600)."
  fi
}

# ---------- інтерфейс для lab.sh ----------
lab5_prepare() {
  command -v argocd >/dev/null || die "немає argocd CLI — див. docs/argocd-commands.md (встановлення)"
  git_check_pushed "${L5_BRANCH}"
  l5_check_access
  l5_reset_git
  argocd_wake
  argocd_pf
  l5_secrets
  l5_pull_images
  argocd_login_quiet || true
}

lab5_up() {
  lab5_prepare
  kubectl apply -f "${L5_ROOT}"
  sleep 5
  app_wait portal Healthy 300
}

lab5_down() {
  if kubectl get application root-lab5 -n argocd >/dev/null 2>&1; then
    argocd_wake   # фіналізатори Application обробляє контролер Argo CD — він має працювати
    info "Видаляю root-lab5 (каскадно: Application portal і всі його об'єкти)"
    kubectl delete -f "${L5_ROOT}" --wait --timeout=180s >/dev/null || warn "root-lab5 видаляється довше за 3 хв"
    kubectl wait --for=delete application/portal -n argocd --timeout=120s >/dev/null 2>&1 || true
  fi
  # Наступна лаба теж на Argo CD (6, 7)? Тоді його не гасимо.
  [[ "${TARGET_LAB:-}" =~ ^[5-9]$ ]] || argocd_sleep
}

lab5_steps() {
  local NS="-n ${L5_NS}" cur new pwf
  cur="$(l5_tag)"; new="$(l5_next_tag)"; pwf="$(argocd_password_file)"

  step "п.1 Репозиторій конфігурації (варіант b): bootstrap/, argocd-apps/, charts/, envs/" \
    "чарт з Lab 4 у charts/portal, значення minikube в envs/; паролів у Git немає — existingSecret, Secret створено скриптом" \
    "ls bootstrap argocd-apps/lab5 charts/portal charts/portal/templates envs/minikube
grep -n 'existingSecret\\|tag:' ${L5_VALUES}
git grep -c 'dev-only-not-real' -- envs argocd-apps bootstrap || echo 'у envs/argocd-apps/bootstrap паролів немає'
kubectl get secret portal-secret ${NS} -o go-template='{{range \$k, \$v := .data}}{{\$k}} {{end}}'; echo"

  step "п.2a Образ у GHCR з конкретним тегом (git tag v* -> CI -> ${L5_IMAGE}:<версія>)" \
    "теги v1.2.0/v1.3.0 з описом релізу; образ існує в реєстрі (Name/MediaType/Digest)" \
    "git tag -l 'v*' -n1
sed -n '/Push version tag/,/docker push/p' .github/workflows/ci-cd.yml
docker buildx imagetools inspect ${L5_IMAGE}:${cur} | sed -n 1,3p"

  step "п.3 Argo CD у namespace argocd (Helm, урізані values) і CLI" \
    "реліз argocd (argo-cd-${ARGOCD_CHART_VERSION}); pod-и server, repo-server, application-controller, redis — Running" \
    "helm list -n argocd
kubectl get pods -n argocd
argocd version --client --short"

  step "п.3 Веб-інтерфейс: вхід як admin" \
    "відкрити http://localhost:${ARGOCD_PORT}, увійти як admin з цим паролем (початковий — лише при першому запуску)" \
    "argocd_pf
if argocd_initial_password_left; then argocd admin initial-password -n argocd | head -1
else echo \"пароль: \$(cat ${pwf})  (початковий уже змінено)\"; fi
echo 'UI: http://localhost:${ARGOCD_PORT}'"

  step "п.3 Змінити пароль admin (CLI); початковий секрет — видалити" \
    "Password updated; Logged In: true. Новий пароль — поза Git у ${pwf} (у UI тепер вхід з ним)" \
    "argocd_initial_password_left && CUR=\$(argocd admin initial-password -n argocd | head -1) || CUR=\$(cat ${pwf})
NEW=lab-\$(l5_rand 6)
argocd login --username admin --password \"\$CUR\" &&
argocd account update-password --current-password \"\$CUR\" --new-password \"\$NEW\" &&
(umask 077; echo \"\$NEW\" > ${pwf}) &&
kubectl delete secret argocd-initial-admin-secret -n argocd --ignore-not-found
echo \"новий пароль: \$(cat ${pwf})\"
argocd login --username admin --password \"\$(cat ${pwf})\"
argocd account get-user-info"

  step "п.3 Підключити приватний репозиторій (токен із файлу поза Git)" \
    "repository '${L5_REPO}' added; STATUS Successful (для public-репозиторію крок не потрібен)" \
    "[[ -s ${L5_TOKEN_FILE} ]] && argocd repo add ${L5_REPO} --upsert \\
  --username ${L5_GH_USER} --password \"\$(cat ${L5_TOKEN_FILE})\"
argocd repo list"

  step "п.4 App of Apps: вручну застосовуємо ЛИШЕ кореневий Application" \
    "root-lab5 створює Application portal з Git; обидва Synced" \
    "grep -v '^#' ${L5_ROOT}
kubectl apply -f ${L5_ROOT}
argocd app wait root-lab5 --sync --timeout 120
argocd app list"

  step "п.4 Застосунок portal: Synced / Healthy, дерево об'єктів" \
    "у UI: root-lab5 -> portal -> Deployment/ReplicaSet/Pod, Service, Ingress, PVC, ConfigMap; Synced + Healthy" \
    "argocd app wait portal --sync --health --timeout 300
argocd app get portal
echo 'UI: http://localhost:${ARGOCD_PORT}/applications/argocd/portal?view=tree'"

  step "п.2b Застосунок відповідає своєю версією" \
    "{\"version\":\"${cur}\",...}; 2 pod-и portal-api" \
    "kubectl get pods ${NS} -o wide
icurl ${L5_HOST} /version"

  step "п.5 Реліз через Git: тег ${cur} -> ${new}, commit, push — Argo CD сам перерозгортає" \
    "diff тегу; після push і refresh: rolling update, у трафіку ${cur} -> ${new}, помилок 0" \
    "traffic_start ${L5_HOST}
l5_set_tag ${new}            # sed: image.tag у ${L5_VALUES}
git diff -- ${L5_VALUES}
l5_commit_push 'Release ${new}' ${L5_VALUES}
argocd app get portal --refresh >/dev/null    # не чекати на опитування Git (~1 хв)
argocd app wait portal --sync --health --timeout 300
kubectl rollout status deploy/portal-api ${NS}
traffic_stop
icurl ${L5_HOST} /version"

  step "п.6a Дрейф без selfHeal: ручний kubectl scale => OutOfSync, Argo CD НЕ виправляє" \
    "Sync Status: OutOfSync; diff replicas 2 -> 4; через 20 с у кластері досі 4 репліки" \
    "grep -n 'selfHeal' ${L5_APP}
kubectl scale deploy/portal-api ${NS} --replicas=4
sleep 5; argocd app get portal --refresh | grep -E 'Sync Status|Health Status'
argocd app diff portal | grep -E '^[<>].*replicas' || true
sleep 15; kubectl get deploy portal-api ${NS}"

  step "п.6a selfHeal: true — теж через Git (змінюємо Application у argocd-apps/)" \
    "root-lab5 оновлює Application portal; Argo CD повертає replicas: 2 з Git; Synced" \
    "l5_set_selfheal true        # sed: selfHeal у ${L5_APP}
git diff -- ${L5_APP}
l5_commit_push 'Lab 5: enable selfHeal for portal' ${L5_APP}
argocd app get root-lab5 --refresh >/dev/null
argocd app wait root-lab5 --sync --timeout 120
kubectl get application portal -n argocd -o jsonpath='{.spec.syncPolicy.automated}'; echo
argocd app wait portal --sync --health --timeout 120
kubectl get deploy portal-api ${NS}"

  step "п.6a Ще одна ручна зміна — selfHeal повертає її за секунди" \
    "READY 2/2 -> 5 -> назад 2 (видно в -w); в UI — подія auto-sync (self-heal)" \
    "kubectl scale deploy/portal-api ${NS} --replicas=5
timeout 20 kubectl get deploy portal-api ${NS} -w || true"

  step "п.6b Неіснуючий тег образу => Synced, але Degraded" \
    "ImagePullBackOff у новому pod-і; через ~60 с (progressDeadlineSeconds) Synced + Degraded; старі pod-и й далі відповідають ${new}" \
    "l5_set_tag ${L5_BAD_TAG}
l5_commit_push 'Release ${L5_BAD_TAG} (broken tag)' ${L5_VALUES}
argocd app get portal --refresh >/dev/null
argocd app wait portal --sync --degraded --timeout 240
argocd app get portal | grep -E 'Sync Status|Health Status|Deployment'
kubectl get pods ${NS} -l app.kubernetes.io/component=api
icurl ${L5_HOST} /version"

  step "п.6c Відкат через git revert: історія в git log і argocd app history" \
    "коміт Revert \"Release ${L5_BAD_TAG}...\"; Synced + Healthy; argocd app history — кожна ревізія Git = рядок" \
    "git revert --no-edit HEAD
git push -q origin ${L5_BRANCH}
argocd app get portal --refresh >/dev/null
argocd app wait portal --sync --health --timeout 300
git log --oneline -5
argocd app history portal
icurl ${L5_HOST} /version"

  step "п.7 (За запитом викладача) змінити будь-яке значення в Git — напр. APP_GREETING" \
    "ConfigMap змінився => checksum/config => rolling update; на сторінці новий текст" \
    "sed -i \"s/^  APP_GREETING: .*/  APP_GREETING: \\\"Привіт від GitOps! \$(date +%H:%M)\\\"/\" ${L5_VALUES}
git diff -- ${L5_VALUES}
l5_commit_push 'Change APP_GREETING' ${L5_VALUES}
argocd app get portal --refresh >/dev/null
argocd app wait portal --sync --health --timeout 300
kubectl rollout status deploy/portal-api ${NS}
icurl ${L5_HOST} /info"
}
