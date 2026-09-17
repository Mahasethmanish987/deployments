#!/bin/bash
# Installs the log half of the stack: Loki (storage) + Promtail (collector).
#
# Skip Loki here if you already run it — install Promtail alone and point
# config.clients in promtail-values.yaml at your existing endpoint.
#
# Run from the repo root on the bastion:  ./monitoring/logs/install-logs.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update grafana >/dev/null

# Loki — release name "loki" so the Service resolves as loki.monitoring:3100,
# which is the URL used by promtail-values.yaml and loki-datasource.yaml.
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --create-namespace \
  --version 7.3.0 \
  -f "${DIR}/loki-values.yaml"

kubectl rollout status statefulset/loki -n monitoring --timeout=5m

# Promtail — DaemonSet, one pod per node, tails /var/log/pods.
# 6.17.1 is the final release; the chart is end-of-life and will not move again.
helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --version 6.17.1 \
  -f "${DIR}/promtail-values.yaml"

kubectl rollout status daemonset/promtail -n monitoring --timeout=5m

# Grafana picks this up via the datasource sidecar within ~60s.
kubectl apply -f "${DIR}/loki-datasource.yaml"

cat <<'MSG'

Loki + Promtail installed. Verify:

  kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail
  kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=20

Then in Grafana -> Explore -> Loki:

  {namespace="traefik"}                 # is anything arriving at all?
  {namespace="traefik", status=~"5.."}  # the 5xx access-log lines

If the second query returns nothing while the first returns lines, Traefik is
still writing Common Log Format — add `--set logs.access.format=json` to
traefik/install.sh and re-run it. See ../README.md.
MSG
