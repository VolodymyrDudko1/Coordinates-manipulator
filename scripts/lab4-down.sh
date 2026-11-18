#!/usr/bin/env bash
# Lab 4: видалити Helm-реліз з namespace dudko-helm.
# Сам namespace dudko-helm лишається (Helm його не видаляє); прибрати повністю:
#   kubectl delete namespace dudko-helm
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE="${RELEASE:-portal}"
NAMESPACE="dudko-helm"

echo ">>> Lab 4: helm uninstall ${RELEASE} -n ${NAMESPACE}"
helm uninstall "${RELEASE}" -n "${NAMESPACE}"

# Hook-ресурси (pod helm test, Job pre-upgrade, якщо його залишили) не входять у маніфест
# релізу, тому helm uninstall їх не видаляє. Прибираємо за міткою релізу.
echo ">>> Removing leftover hook/test pods and jobs of release ${RELEASE}"
kubectl delete job,pod -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" --ignore-not-found

echo ">>> Resources in namespace ${NAMESPACE} (expected: none; pod-и можуть ще бути Terminating):"
kubectl get pods,svc,ingress -n "${NAMESPACE}"
