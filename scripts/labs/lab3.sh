# shellcheck shell=bash
# Lab 3: "сирі" маніфести k8s/, namespace dudko, Ingress host portal.local.
# Інтерфейс для scripts/lab.sh: lab3_title, lab3_is_up, lab3_up, lab3_down, lab3_prepare, lab3_steps.

lab3_title() { echo "Lab 3 — Kubernetes-маніфести (k8s/, namespace dudko)"; }
lab3_is_up() { kubectl get ns dudko >/dev/null 2>&1; }
lab3_prepare() { ensure_images; }
lab3_up() {
  ./scripts/lab3-up.sh
  kubectl wait --for=condition=available deploy --all -n dudko --timeout=180s
}
lab3_down() {
  lab3_is_up || return 0
  ./scripts/lab3-down.sh
}

lab3_steps() {
  local SEL='-l app.kubernetes.io/name=portal-api'

  step "Кластер і аддони" \
    "вузол minikube Ready; ingress і metrics-server enabled" \
    "kubectl get nodes -o wide
minikube addons list | grep -E 'ingress|metrics-server' | grep -v dns"

  step "Образи всередині minikube (без registry, без :latest)" \
    "docker.io/library/portal-api:1.0.0 і :1.1.0" \
    "minikube image ls | grep portal-api"

  step "Розгортання" \
    "9 рядків '... created': namespace, configmap, secret, pvc, 2 deployment, 2 service, ingress" \
    "kubectl apply -f k8s/"

  step "Стан об'єктів" \
    "2 pod-и portal-api і 1 portal-db Running 1/1; deploy 2/2; 1 ReplicaSet; ingress portal.local; PVC Bound" \
    "kubectl wait --for=condition=available deploy --all -n dudko --timeout=180s
kubectl get pods,deploy,rs,svc,ingress,pvc -n dudko"

  step "IP, мітки та споживання ресурсів pod-ів" \
    "у кожного pod-а свій IP і мітка app.kubernetes.io/name; CPU/RAM з metrics-server" \
    "kubectl get pods -n dudko -o wide --show-labels
kubectl top pods -n dudko || echo '(metrics-server ще збирає дані — повторіть за хвилину)'"

  step "Застосунок через Ingress (portal.local)" \
    "{\"version\":\"1.0.0\",...,\"api_key\":\"de***\"}, {\"status\":\"ok\"}, {\"status\":\"ready\"}; у браузері http://portal.local:${INGRESS_PORT}/" \
    "icurl portal.local /info
icurl portal.local /health
icurl portal.local /ready
echo \"Браузер: http://portal.local:${INGRESS_PORT}/   Swagger: http://portal.local:${INGRESS_PORT}/docs\""

  step "ConfigMap і Secret усередині контейнера" \
    "APP_GREETING, LOG_LEVEL, DB_HOST=portal-db, POSTGRES_PASSWORD=dev-only-...; DATABASE_URL зібраний kubelet-ом; Secret у base64" \
    "kubectl exec -n dudko deploy/portal-api -- env | grep -E '^(APP_|LOG_LEVEL|ENVIRONMENT|DEBUG|API_KEY|POSTGRES_|DB_)' | sort
kubectl exec -n dudko deploy/portal-api -- printenv DATABASE_URL
kubectl get secret portal-secret -n dudko -o jsonpath='{.data.API_KEY}'; echo '   <- base64'
kubectl get secret portal-secret -n dudko -o jsonpath='{.data.API_KEY}' | base64 -d; echo '   <- після base64 -d'"

  step "uvicorn — PID 1 у контейнері" \
    "PID 1: ... uvicorn src.main:app --host 0.0.0.0 --port 8000 (exec у CMD => SIGTERM доходить до застосунку)" \
    "kubectl exec -n dudko deploy/portal-api -- sh -c 'for p in /proc/[0-9]*; do echo \"PID \${p#/proc/}: \$(tr \"\\0\" \" \" < \$p/cmdline)\"; done'"

  step "Самовідновлення: видалити pod" \
    "старий pod Terminating, новий Pending -> ContainerCreating -> Running 1/1 (20 с спостереження)" \
    "POD=\$(kubectl get pod -n dudko ${SEL} -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod -n dudko \"\$POD\" --wait=false
timeout 20 kubectl get pods -n dudko ${SEL} -w || true"

  step "Масштабування до 4 і балансування" \
    "4 pod-и Running; 20 запитів розподілені між 4 hostname; потім назад до 2" \
    "kubectl scale deployment/portal-api -n dudko --replicas=4
kubectl rollout status deployment/portal-api -n dudko
kubectl get pods -n dudko ${SEL}
for i in \$(seq 1 20); do icurl portal.local /info | grep -o '\"hostname\":\"[^\"]*\"'; done | sort | uniq -c
kubectl scale deployment/portal-api -n dudko --replicas=2"

  step "Rolling update до 1.1.0 під трафіком" \
    "rollout 'successfully rolled out'; у підсумку трафіку version=1.0.0 і 1.1.0, помилок 0" \
    "traffic_start portal.local
kubectl set image deployment/portal-api -n dudko portal-api=portal-api:1.1.0
kubectl annotate deployment/portal-api -n dudko --overwrite kubernetes.io/change-cause='Update to portal-api:1.1.0'
kubectl rollout status deployment/portal-api -n dudko
sleep 3; traffic_stop
kubectl get rs -n dudko ${SEL}"

  step "Історія та відкат" \
    "REVISION 1 Initial deploy, 2 Update to 1.1.0; після undo знову version 1.0.0" \
    "kubectl rollout history deployment/portal-api -n dudko
kubectl rollout history deployment/portal-api -n dudko --revision=2 | grep -E 'Image|change-cause'
kubectl rollout undo deployment/portal-api -n dudko
kubectl rollout status deployment/portal-api -n dudko
icurl portal.local /info"

  step "Діагностика 1/3: зламати — неіснуючий тег" \
    "новий pod ErrImagePull/ImagePullBackOff 0/1, старі 2 pod-и працюють; rollout status — timed out" \
    "kubectl set image deployment/portal-api -n dudko portal-api=portal-api:9.9.9-does-not-exist
kubectl annotate deployment/portal-api -n dudko --overwrite kubernetes.io/change-cause='BROKEN: portal-api:9.9.9-does-not-exist'
sleep 8
kubectl get pods -n dudko ${SEL}
kubectl rollout status deployment/portal-api -n dudko --timeout=20s
icurl portal.local /info"

  step "Діагностика 2/3: розслідувати" \
    "Events: Failed to pull image ... not found, Back-off; logs: 'image can't be pulled'; робочий pod — логи uvicorn" \
    "BAD=\$(kubectl get pods -n dudko ${SEL} --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod -n dudko \"\$BAD\" | sed -n '/State:/,/Ready:/p;/^Events:/,\$p'
kubectl get events -n dudko --sort-by=.lastTimestamp | tail -8
kubectl logs -n dudko \"\$BAD\"
kubectl logs -n dudko deploy/portal-api --tail=5"

  step "Діагностика 3/3: виправити" \
    "successfully rolled out; 2 pod-и Running; в історії видно BROKEN і ревізію відкату" \
    "kubectl rollout undo deployment/portal-api -n dudko
kubectl rollout status deployment/portal-api -n dudko
kubectl get pods -n dudko ${SEL}
kubectl rollout history deployment/portal-api -n dudko"

  step "(Необов'язково) веб-клієнт Django" \
    "запускати в ОКРЕМОМУ терміналі; Ctrl+C зупиняє" \
    "echo 'В іншому терміналі: ./scripts/client-up.sh lab3   ->  http://localhost:8080/'"
}

# UI для lab.sh ui 3 і кінця демо: сторінка застосунку через Ingress (port-forward 18080 тримає lab.sh).
lab3_ui() {
  ui_line "Застосунок (Ingress)" "http://portal.local:${INGRESS_PORT}/"
  ui_line "Django-клієнт" "http://localhost:8080/" "окремий термінал: ./scripts/client-up.sh lab3"
}
