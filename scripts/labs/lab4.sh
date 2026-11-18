# shellcheck shell=bash
# Lab 4: Helm-чарт chart/portal, реліз portal, namespace dudko-helm,
# хости portal-helm.local (dev) / portal-helm-prod.local (prod).

lab4_title() { echo "Lab 4 — Helm-чарт (chart/portal, namespace dudko-helm)"; }
lab4_is_up() { helm status portal -n dudko-helm >/dev/null 2>&1; }
lab4_prepare() { ensure_images busybox:1.36; }   # busybox: pre-upgrade hook і helm test
lab4_up() {
  ./scripts/lab4-up.sh "${1:-chart/portal/values-dev.yaml}"
  kubectl wait --for=condition=available deploy --all -n dudko-helm --timeout=180s
}
lab4_down() {
  lab4_is_up || return 0
  ./scripts/lab4-down.sh
}

lab4_steps() {
  local NS='-n dudko-helm' CH='chart/portal'
  local DEV="-f ${CH}/values-dev.yaml" PROD="-f ${CH}/values-prod.yaml"

  step "Helm" \
    "version.BuildInfo{Version:\"v3...\" або \"v4...\"}" \
    "helm version"

  step "helm lint: values.yaml, dev, prod" \
    "тричі '1 chart(s) linted, 0 chart(s) failed' ([INFO] icon is recommended — норма)" \
    "helm lint ${CH}
helm lint ${CH} ${DEV}
helm lint ${CH} ${PROD}"

  step "helm template (dev): які об'єкти створить чарт" \
    "Secret, ConfigMap, PVC, 2 Service, 2 Deployment, Pod тесту, Job hook; Ingress немає (вимкнено в dev)" \
    "helm template portal ${CH} ${NS} ${DEV} | grep -E '^kind:|^  name:' | paste - -"

  step "dev vs prod" \
    "replicas 1 -> 3, образ 1.0.0 -> 1.1.0, ресурси, ENVIRONMENT/LOG_LEVEL, у prod додається Ingress portal-helm-prod.local" \
    "helm template portal ${CH} ${NS} ${DEV}  > \"\${DEMO_TMP}/dev.yaml\"
helm template portal ${CH} ${NS} ${PROD} > \"\${DEMO_TMP}/prod.yaml\"
diff \"\${DEMO_TMP}/dev.yaml\" \"\${DEMO_TMP}/prod.yaml\" | grep -E '^[<>] .*(replicas|image:|host:|ENVIRONMENT|LOG_LEVEL|cpu:|memory:|kind: Ingress)' || true"

  step "Helm vs старі маніфести k8s/" \
    "відрізняються лише Namespace dudko (його створює --create-namespace) і Job portal-pre-upgrade (hook)" \
    "diff <(grep -hE '^kind:|^  name:' k8s/*.yaml | sed 's/[[:space:]]*#.*//' | paste - - | sort) \\
     <(helm template portal ${CH} ${NS} --set ingress.enabled=true --skip-tests | grep -E '^kind:|^  name:' | paste - - | sort) || true"

  step "Встановлення (scripts/lab4-up.sh)" \
    "STATUS: deployed, REVISION: 1, NOTES з командою port-forward; pod-и portal-api і portal-db" \
    "./scripts/lab4-up.sh
kubectl wait --for=condition=available deploy --all ${NS} --timeout=180s
svc_get dudko-helm portal-api /info"

  step "Стан релізу" \
    "portal deployed portal-0.1.0 1.0.0; USER-SUPPLIED = лише values-dev.yaml; COMPUTED = усе" \
    "helm list ${NS}
helm status portal ${NS} | head -7
helm get values portal ${NS}
helm get values portal ${NS} --all | head -25"

  step "Де Helm зберігає стан: Secret на кожну ревізію" \
    "sh.helm.release.v1.portal.v1   helm.sh/release.v1" \
    "kubectl get secrets ${NS} -l owner=helm"

  step "Ревізія 2: --set image.tag=1.1.0 (+ лишаємо Job hook, щоб показати його логи)" \
    "REVISION 2; логи hook: Release portal, Revision 2, Image portal-api:1.1.0; /info -> 1.1.0" \
    "helm upgrade portal ${CH} ${NS} ${DEV} --set image.tag=1.1.0 \\
  --set hooks.preUpgrade.deletePolicy=before-hook-creation --description 'Upgrade image to 1.1.0'
kubectl logs ${NS} job/portal-pre-upgrade
kubectl rollout status deployment/portal-api ${NS}
svc_get dudko-helm portal-api /info"

  step "Ревізія 3: prod-профіль" \
    "3 pod-и portal-api, Ingress portal-helm-prod.local; Job hook видалено після успіху (політика за замовчуванням)" \
    "helm upgrade portal ${CH} ${NS} ${PROD} --description 'Switch to prod values: 3 replicas, ingress portal-helm-prod.local'
kubectl rollout status deployment/portal-api ${NS}
kubectl get pods,svc,ingress,jobs ${NS}
icurl portal-helm-prod.local /info"

  step "Історія" \
    "3 ревізії: 1-2 superseded, 3 deployed; у DESCRIPTION — тексти --description" \
    "helm history portal ${NS}"

  step "Відкат до ревізії 1" \
    "Rollback was a success; ревізія 4 'Rollback to 1'; 1 pod 1.0.0, Ingress зник" \
    "helm rollback portal 1 ${NS}
helm history portal ${NS}
kubectl rollout status deployment/portal-api ${NS}
kubectl get pods,ingress ${NS}"

  step "helm test" \
    "Phase: Succeeded; у логах HTTP/1.1 200 OK і 'OK: /health returned 200'" \
    "helm test portal ${NS} --logs"

  step "Пріоритет значень на helm template: values.yaml < -f < --set" \
    "replicas: 1, потім 3, потім 2" \
    "helm template portal ${CH} ${NS} -s templates/deployment.yaml | grep replicas
helm template portal ${CH} ${NS} -s templates/deployment.yaml ${PROD} | grep replicas
helm template portal ${CH} ${NS} -s templates/deployment.yaml ${PROD} --set replicaCount=2 | grep replicas"

  step "Пріоритет значень на живому релізі" \
    "USER-SUPPLIED: replicaCount: 2 (+ ключі values-prod); deploy portal-api 2/2; tag 1.1.0" \
    "helm upgrade portal ${CH} ${NS} ${PROD} --set replicaCount=2 --description 'Precedence demo: values.yaml=1, values-prod=3, --set=2'
helm get values portal ${NS}
helm get values portal ${NS} --all | grep -E '^replicaCount|^image:' -A3
kubectl rollout status deployment/portal-api ${NS}
kubectl get deploy portal-api ${NS}"

  step "Видалення (scripts/lab4-down.sh)" \
    "release \"portal\" uninstalled; No resources found; helm list порожній; Secret-ів sh.helm.release немає" \
    "./scripts/lab4-down.sh
kubectl wait --for=delete pod --all ${NS} --timeout=90s 2>/dev/null || true
kubectl get all ${NS}
kubectl get pvc ${NS}
kubectl get secrets ${NS} -l owner=helm
helm list ${NS}"
}
