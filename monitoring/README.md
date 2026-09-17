# monitoring — Traefik 5xx: metrics, logs, alerts, Teams

Everything here **plugs into the kube-prometheus-stack release you already run**
(`monitoring`, in namespace `monitoring`). Nothing reinstalls or upgrades it, and
`custom_kube_prometheus_stack.yml` does not need to change.

Two independent halves:

| | What it answers | Needs |
|---|---|---|
| **Metrics** (`traefik-metrics.yaml`, `rules/`, `alerting/`) | *Are we serving 5xx, on which backend, how badly* — and pages you in Teams | Nothing beyond the existing stack |
| **Logs** (`logs/`) | *Which exact request failed* — path, method, client, status | Loki + Promtail, plus JSON access logs on Traefik |

That split is deliberate: **alert on metrics, investigate in logs.** Alerting off
log queries means your paging path depends on a log pipeline staying healthy, and
a Loki outage becomes a silent alerting outage.

---

## Why 5xx alerting did not exist before

Traefik was already exporting the numbers — `traefik/install.sh` sets
`metrics.prometheus.enabled=true`, so it serves Prometheus metrics on port 9100.
But the Helm-managed LoadBalancer Service only publishes 80 and 443, so **nothing
could reach 9100** and Prometheus never scraped it. `traefik-metrics.yaml` adds
the ClusterIP Service for that port plus the ServiceMonitor.

## The label that makes or breaks all of this

`custom_kube_prometheus_stack.yml` does not set
`serviceMonitorSelectorNilUsesHelmValues: false`, which means Prometheus adopts
**only** ServiceMonitors and PrometheusRules carrying:

```yaml
labels:
  release: monitoring
```

Every object here has it. If you copy these files into another cluster whose Helm
release is named something else, that label must change to match — otherwise the
manifests apply cleanly, report no error, and silently do nothing.

The same idea drives the Teams config: you already set
`alertmanagerConfigSelector: {matchLabels: {release: monitoring}}` and
`alertmanagerConfigMatcherStrategy: {type: None}`, so Teams routing ships as an
**AlertmanagerConfig CRD**, not as Helm values. No `helm upgrade` in the paging
path.

---

## Install

### 1. Metrics, alerts, dashboard, Teams

```bash
# Teams webhooks first — apply.sh refuses to wire up routing without them.
# See alerting/teams-webhooks-secret.yaml.template for how to get the URLs.
kubectl create secret generic teams-webhooks -n monitoring \
  --from-literal=warning_url='https://prod-XX....logic.azure.com/...' \
  --from-literal=critical_url='https://prod-XX....logic.azure.com/...'

./monitoring/apply.sh
```

`apply.sh` prints a five-step verification sequence, ending with a synthetic
alert you can push through the real path to confirm the card arrives in Teams.

### 2. Traefik access logs as JSON — **required for the log panels**

`traefik/install.sh` enables the access log but leaves it in Common Log Format,
which is a pain to parse and has no stable field names. One flag fixes it:

```diff
   --set logs.general.level=INFO \
   --set logs.access.enabled=true \
+  --set logs.access.format=json \
   --set metrics.prometheus.enabled=true \
```

Then re-run `traefik/install.sh`. Traefik rolls its pods; ingress keeps serving
through the rollout.

Without this flag the metrics alerts still work perfectly — but Promtail's JSON
stage extracts nothing, the `status` label is never set, and the four
Loki-backed dashboard panels stay empty.

### 3. Logs

```bash
./monitoring/logs/install-logs.sh
```

Installs Loki (SingleBinary, filesystem, 7-day retention) and Promtail, and
registers the Loki datasource in Grafana through the sidecar — again, no Helm
upgrade of the monitoring release.

**Already running Loki?** Skip the Loki install, edit the `config.clients` URL
in `logs/promtail-values.yaml`, and install Promtail alone.

---

## What fires, and when

| Alert | Condition | Severity |
|---|---|---|
| `TraefikHigh5xxRate` | a backend serves >2% 5xx for 10m | warning |
| `TraefikHigh5xxRate` | a backend serves >10% 5xx for 5m | critical |
| `TraefikBackendUnreachable` | Traefik itself emits 502/503/504 above 0.1 req/s for 5m | critical |
| `TraefikGlobal5xxRate` | >5% of all ingress requests are 5xx for 10m | critical |
| `TraefikConfigReloadFailed` | dynamic config has not loaded for 5m | critical |
| `TraefikMetricsDown` | the scrape target is down for 5m | warning |

Both per-backend rules carry a **traffic floor of 0.05 req/s** (≈3 requests per
minute). Without it, one failed request against an idle service reads as a 100%
error rate and pages at 03:00. If a quiet service still flaps, raise the floor
rather than the percentage — the percentage is what makes the alert meaningful.

`TraefikMetricsDown` is the one that keeps the rest honest: absent data never
fires, so a broken scrape would otherwise look exactly like a healthy cluster.

---

## Notes

- **`service` vs `entrypoint`.** `traefik_service_requests_total` means a backend
  answered 5xx — an application bug. `traefik_entrypoint_requests_total` counts
  what Traefik returned, so entrypoint 5xx exceeding the sum of service 5xx means
  the request never reached a pod. Different metric, different fix: Endpoints and
  readiness probes, not application logs.
- **No per-domain breakdown.** The chart defaults
  `metrics.prometheus.addRoutersLabels=false`. Add
  `--set metrics.prometheus.addRoutersLabels=true` to `traefik/install.sh` if you
  want `traefik_router_requests_total{router=...}` split by Host. It raises metric
  cardinality, so it is a deliberate choice, not a default.
- **Grouping by `service`.** The per-backend alert expressions use
  `sum by (service)(...)`, which drops every other label — these alerts have **no
  `instance` label at all**. The AlertmanagerConfig groups and inhibits on
  `[alertname, service]` for that reason. Grouping on `instance` instead would
  collapse every failing backend into one card, and the inhibit rule would let an
  outage on one service silence warnings for all the others.
- **Log label cardinality.** Promtail promotes only `status` and `backend` to Loki
  stream labels — both bounded. `path`, `client` and `method` are extracted at
  query time with `| json` instead. Promoting a request path to a stream label is
  the standard way to make a Loki install unqueryable.
- **Promtail is end-of-life** (March 2026), pinned at chart 6.17.1. It works and
  is well understood; it simply receives no further fixes. Grafana Alloy is the
  migration target when that becomes worth doing. Nothing else in this directory
  depends on which collector you run — swapping it later means replacing
  `logs/promtail-values.yaml` and leaving the rules, dashboard and Teams routing
  untouched.
- **The `cri: {}` pipeline stage is not optional.** containerd wraps every line
  in `<timestamp> <stream> <flags> <message>`; without that stage the JSON parse
  silently fails on every line. It must stay first in the list.
- **Unrelated, but worth a look:** `traefik/routes/monitoring/monitoring.yaml`
  publishes `prometheus.foodonline.run.place` with no auth middleware, while
  Grafana at least sits behind a login. That exposes every metric — and every
  target, label and internal service name — to the internet. The `basic-auth`
  middleware pattern from the sibling cluster would close it.
