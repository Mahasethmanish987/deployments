#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="cert-manager"
VERSION="v1.18.2"

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace ${NAMESPACE} \
  --create-namespace \
  --version ${VERSION} \
  --set crds.enabled=true

kubectl rollout status deployment/cert-manager \
  -n ${NAMESPACE} \
  --timeout=5m

kubectl rollout status deployment/cert-manager-webhook \
  -n ${NAMESPACE} \
  --timeout=5m

kubectl rollout status deployment/cert-manager-cainjector \
  -n ${NAMESPACE} \
  --timeout=5m

kubectl get pods -n ${NAMESPACE}