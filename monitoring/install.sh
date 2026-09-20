#!/usr/bin/env bash
# Installs kube-prometheus-stack on the rhr-eks cluster from scratch.
#
# Safe to re-run: every step is idempotent (helm upgrade --install,
# kubectl apply, and a guarded secret create).
#
# Run from the repo root:  ./monitoring/install.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS=monitoring
RELEASE=monitoring

# Pin the chart version. Without a pin, a re-run months from now silently
# performs a major upgrade instead of the no-op you expected.
CHART_VERSION="${CHART_VERSION:-77.14.0}"

echo "==> Target cluster"
kubectl config current-context
read -rp "    Is this the right cluster? [y/N] " ok
[[ "$ok" == "y" || "$ok" == "Y" ]] || { echo "aborted"; exit 1; }

echo
echo "==> gp3 StorageClass"
# The cluster's only StorageClass is the in-tree gp2, which cannot expand.
# Prometheus outgrowing a volume it cannot grow means losing history.
kubectl apply -f "${DIR}/storageclass-gp3.yaml"

echo
echo "==> Namespace"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "==> Grafana admin secret"
if kubectl get secret grafana-admin -n "$NS" >/dev/null 2>&1; then
  echo "    exists, leaving it alone"
else
  # Generated, not typed, and never written to git.
  GRAFANA_PW="$(openssl rand -base64 24)"
  kubectl create secret generic grafana-admin -n "$NS" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$GRAFANA_PW"
  echo
  echo "    ┌──────────────────────────────────────────────────────┐"
  echo "    │ Grafana admin password (save it now, shown once):    │"
  echo "    │ $GRAFANA_PW"
  echo "    └──────────────────────────────────────────────────────┘"
  echo
fi

echo "==> Helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update prometheus-community >/dev/null

echo
echo "==> Installing kube-prometheus-stack ${CHART_VERSION}"
helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$NS" \
  --version "$CHART_VERSION" \
  -f "${DIR}/kube-prometheus-stack-values.yaml" \
  --wait --timeout 10m

cat <<'MSG'

Installed. Verify in this order — each step is blind if the previous one failed:

  1. Everything running, nothing Pending?
     kubectl get pods -n monitoring

     A PVC stuck Pending means the gp3 StorageClass did not apply, or the
     EBS CSI driver lost its IAM permissions:
       kubectl get pvc -n monitoring
       kubectl describe pvc -n monitoring <name>

  2. Any targets DOWN?
     kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
     # http://localhost:9090  ->  Status -> Target health
     #
     # Expect ZERO down targets. If kube-scheduler / kube-controller-manager /
     # etcd / kube-proxy appear at all, the EKS toggles in the values file did
     # not take effect — they are unreachable on a managed control plane.

  3. Are the default alerts loaded and quiet?
     # Prometheus UI -> Alerts
     # Watchdog should be FIRING. That is correct — see README, it is a
     # dead-man's switch. Everything else should be green.

  4. Grafana up?
     kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
     # http://localhost:3000  -> log in as admin with the password above
     # Dashboards -> the stack ships ~20 of them for nodes, pods, workloads

  5. How big is it actually?
     # Prometheus UI -> Graph:  prometheus_tsdb_head_series
     # That number x ~10KB is your Prometheus memory floor. If it approaches
     # 200k, raise the memory request before it gets OOMKilled.

Next: nothing scrapes your applications yet. See README "What is still missing".
MSG
