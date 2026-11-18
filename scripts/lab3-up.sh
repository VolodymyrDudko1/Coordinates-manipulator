#!/usr/bin/env bash
# Lab 3: розгорнути "сирі" маніфести з k8s/ у namespace dudko (хост portal.local).
# Перед запуском переконайтесь, що Lab 4 вимкнено: ./scripts/lab4-down.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAMESPACE="dudko"

echo ">>> Lab 3: kubectl apply -f k8s/  (namespace ${NAMESPACE})"
kubectl apply -f k8s/

echo ">>> Resources in namespace ${NAMESPACE}:"
kubectl get pods,svc,ingress -n "${NAMESPACE}"
