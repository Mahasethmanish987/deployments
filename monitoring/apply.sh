#!/bin/bash
# Applies the metrics half: Traefik scrape + 5xx alert rules + Teams routing +
# dashboard. Nothing here reinstalls or upgrades kube-prometheus-stack — it all
# plugs into the release you already run.
#
# The log half is separate: monitoring/logs/install-logs.sh
#
# Run from the repo root on the bastion:  ./monitoring/apply.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The ServiceMonitor lives in the traefik namespace, so Traefik must be
# installed first. Fail here with a clear message rather than on a namespace
# error three lines down.
if ! kubectl get namespace traefik >/dev/null 2>&1; then
  echo "ERROR: namespace 'traefik' does not exist — run traefik/install.sh first." >&2
  exit 1
fi

echo "==> Traefik metrics scrape (Service + ServiceMonitor)"
kubectl apply -f "${DIR}/traefik-metrics.yaml"

echo "==> 5xx alert rules"
kubectl apply -f "${DIR}/rules/"

echo "==> Grafana dashboard"
kubectl apply -f "${DIR}/dashboards/"

echo "==> Teams routing"
if kubectl get secret teams-webhooks -n monitoring >/dev/null 2>&1; then
  kubectl apply -f "${DIR}/alerting/alertmanagerconfig-teams.yaml"
else
  # Applying the AlertmanagerConfig without its Secret makes the operator
  # reject the whole generated Alertmanager config, which would take the
  # EXISTING alert routing down with it. Refuse instead.
  echo "SKIPPED: Secret 'teams-webhooks' not found in namespace monitoring."
  echo "         Create it first (see alerting/teams-webhooks-secret.yaml.template),"
  echo "         then: kubectl apply -f monitoring/alerting/alertmanagerconfig-teams.yaml"
fi

cat <<'MSG'

Applied. Verify in this order — each step is blind if the previous one failed:

  1. Is Prometheus scraping Traefik?
     kubectl get servicemonitor -n traefik traefik
     # then Prometheus UI -> Status -> Target health -> look for traefik-metrics = UP

  2. Are the 5xx counters arriving?
     # Prometheus UI -> Graph:
     #   sum by (service, code) (rate(traefik_service_requests_total[5m]))
     # Empty result with an UP target means no traffic has flowed yet.

  3. Did the rules load?
     kubectl get prometheusrule -n monitoring traefik-5xx-alerts
     # Prometheus UI -> Alerts -> group "traefik-ingress-5xx" (6 rules)

  4. Did Alertmanager pick up the Teams route?
     kubectl get alertmanagerconfig -n monitoring teams-traefik
     kubectl logs -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager-0 -c alertmanager --tail=30

  5. Send a real card to Teams without breaking anything:
     kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &
     curl -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
       "labels": {"alertname":"TraefikHigh5xxRate","severity":"critical","service":"smoke-test"},
       "annotations": {"summary":"routing smoke test","description":"safe to ignore"}
     }]'

MSG
