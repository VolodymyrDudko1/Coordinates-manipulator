#!/usr/bin/env bash
# Lab 3: видалити всі об'єкти з k8s/ (включно з namespace dudko і PVC з даними БД).
set -euo pipefail
cd "$(dirname "$0")/.."

NAMESPACE="dudko"

echo ">>> Lab 3: kubectl delete -f k8s/ --ignore-not-found  (namespace ${NAMESPACE})"
kubectl delete -f k8s/ --ignore-not-found

echo ">>> Resources in namespace ${NAMESPACE} (expected: none):"
kubectl get pods,svc,ingress -n "${NAMESPACE}"
