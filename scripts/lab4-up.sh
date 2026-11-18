#!/usr/bin/env bash
# Lab 4: встановити Helm-чарт chart/portal у namespace dudko-helm.
# Використання:
#   ./scripts/lab4-up.sh                                   # values-dev.yaml (за замовчуванням)
#   ./scripts/lab4-up.sh chart/portal/values-prod.yaml     # інший файл значень
# Змінні оточення: RELEASE (за замовчуванням portal).
# Перед запуском переконайтесь, що Lab 3 вимкнено: ./scripts/lab3-down.sh
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE="${RELEASE:-portal}"
NAMESPACE="dudko-helm"
CHART="chart/portal"
VALUES_FILE="${1:-${CHART}/values-dev.yaml}"

if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "ERROR: values file '${VALUES_FILE}' not found" >&2
  exit 1
fi

echo ">>> Lab 4: helm install ${RELEASE} ${CHART} -n ${NAMESPACE} --create-namespace -f ${VALUES_FILE}"
helm install "${RELEASE}" "${CHART}" \
  -n "${NAMESPACE}" --create-namespace \
  -f "${VALUES_FILE}"

echo ">>> Resources in namespace ${NAMESPACE}:"
kubectl get pods,svc,ingress -n "${NAMESPACE}"
