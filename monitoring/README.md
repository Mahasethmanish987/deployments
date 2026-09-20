# monitoring

kube-prometheus-stack on **rhr-eks** (EKS, eu-north-1), built from scratch.

```bash
./monitoring/install.sh
```

Idempotent — safe to re-run.

---

## What this installs

| Component | Storage | Why it matters |
|---|---|---|
| Prometheus | 20Gi gp3, 15d retention | The time-series database |
| Alertmanager x2 | 2Gi gp3 each | Routing, grouping, silences |
| Grafana | 5Gi gp3 | Dashboards |
| node-exporter | – | Node CPU / memory / disk / network |
| kube-state-metrics | – | Deployment, Pod, PVC, Job object state |

---

## Decisions worth knowing about

### EKS: four components are disabled on purpose

`kubeControllerManager`, `kubeScheduler`, `kubeEtcd` and `kubeProxy` are all
turned off, along with their alert rules.

AWS manages the control plane, so those endpoints are not reachable from inside
the cluster. Left enabled they produce permanently-down scrape targets and
permanently-firing alerts.

That is worse than useless. **An alert list that is always red is an alert list
nobody reads** — which silently disables every real alert you add later.

### `release: monitoring` is mandatory on every ServiceMonitor and PrometheusRule

The values file deliberately does **not** set
`serviceMonitorSelectorNilUsesHelmValues: false`. So Prometheus adopts only
objects carrying:

```yaml
metadata:
  labels:
    release: monitoring
```

Forget that label and your manifest applies cleanly, reports no error, and does
absolutely nothing. It is the single most common "why isn't Prometheus scraping
my app" bug, and it produces no diagnostic anywhere.

### Why a new `gp3` StorageClass

The cluster's only StorageClass was `gp2`, using the deprecated in-tree
provisioner and — the real problem — `allowVolumeExpansion: false`.

When Prometheus outgrows 20Gi you would have to delete the PVC and lose all
history. gp3 expands online, with no downtime and no data loss. It is also
cheaper and gives a flat 3000 IOPS instead of gp2's size-linked burst credits,
which matters because TSDB compaction is bursty IO.

### Two ceilings on Prometheus disk

`retention: 15d` **and** `retentionSize: 15GiB` on a 20Gi volume.

The size ceiling sits well under the volume because compaction needs room to
merge blocks. A genuinely full Prometheus disk wedges the TSDB and needs manual
recovery — at 03:00, not at noon.

### No CPU limit on Prometheus

Requests, yes. A CPU limit, deliberately not.

Throttled Prometheus times out its scrapes, which looks exactly like "all the
targets went down" and sends you chasing an outage that is not happening. The
memory request is what gets it scheduling priority; a CPU limit buys only false
alarms.

### Grafana uses `Recreate`, not `RollingUpdate`

Its PVC is ReadWriteOnce. A rolling update deadlocks as soon as the new pod
lands on a different node: the old pod holds the volume, the new one waits
forever on Multi-Attach, and the rollout never completes. `Recreate` costs ~30s
of downtime per upgrade, which is the right trade for one dashboard server.

### The Grafana password is generated, not committed

`install.sh` generates it with `openssl rand` and prints it once. The chart's
default is `prom-operator` — published in its README and every tutorial — so
leaving it would mean a known password on a Grafana that may be exposed later.

---

## ⚠️ Two AZs, one volume

EBS volumes are locked to a single availability zone, and your nodes are split
across `eu-north-1b` and `eu-north-1c`.

Prometheus is a 1-replica StatefulSet with a ReadWriteOnce volume, so its pod is
effectively **pinned to whichever AZ it first landed in**. If that node dies and
the replacement comes up in the other AZ, the pod stays `Pending` on a volume
node-affinity conflict.

That is an acceptable trade at this size — but know it now rather than during
the incident. Recovery is to delete the PVC (losing history) or restore from a
snapshot. Real HA here means Thanos or remote-write to AMP, which is a bigger
change than it is worth today.

---

## ⚠️ Do not expose Prometheus publicly

Grafana at least has a login. Prometheus has **none** — its UI hands over every
metric, every scrape target, every namespace and internal service name, plus the
full `/config` page. That is a map of your infrastructure.

When an ingress controller goes on this cluster, put basic auth in front of both
before creating any route.

---

## 🚨 What is still missing

### 1. Nothing scrapes your applications

This stack watches **nodes, pods and Kubernetes objects**. It does not watch
what your code is actually doing.

Today you would find out about:

| Failure | Caught? |
|---|---|
| A pod crash-looping | ✅ kube-state-metrics |
| A node running out of memory | ✅ node-exporter |
| A PVC filling up | ✅ kube-state-metrics |
| **An endpoint returning 200 with empty data** | ❌ silent |
| **A third-party API you depend on failing** | ❌ silent |
| **A DB connection pool exhausted** | ❌ silent |
| **A background job that stopped running** | ❌ silent |

Kubernetes metrics tell you the **containers** are healthy. Only application
metrics tell you the **work** is getting done — and the expensive incidents are
the ones where the container is perfectly healthy and the work silently is not.

Next step: expose `/metrics` from the services and add a ServiceMonitor per
chart (carrying `release: monitoring`).

### 2. No alert routing — alerts fire into the void

Alertmanager is running, but nothing is configured to receive anything. Alerts
will fire and stop at the Alertmanager UI, where nobody is looking.

Add an `AlertmanagerConfig` CRD labelled `release: monitoring` (that is what the
`alertmanagerConfigSelector` in the values file is for). Routing lives in a CRD
rather than Helm values so changing who gets paged never needs a `helm upgrade`.

### 3. No dead-man's switch

The stack ships a `Watchdog` alert that fires constantly, on purpose. It is
meant to be routed to an external service that alerts you when it **stops**
arriving.

Without it, if Alertmanager or Prometheus dies you get total silence — and
silence is indistinguishable from "everything is fine". The entire alerting
pipeline fails open and nobody notices for days.

Route `Watchdog` to a free https://healthchecks.io ping URL. Ten minutes of
work, and it is the alert that makes every other alert trustworthy.

### 4. No ingress

There is no ingress controller on this cluster, so Grafana and Prometheus are
reachable by `kubectl port-forward` only. That is fine, and it is the safe
default until auth is in place.

---

## Upgrading

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --version <NEW> -f monitoring/kube-prometheus-stack-values.yaml
```

Always pass `--version`. Without it, Helm moves you to whatever is newest that
day — which is how a one-line values change becomes an unplanned major upgrade.

**Chart upgrades do not upgrade CRDs.** The Prometheus Operator CRDs must be
applied manually before a major chart bump; the chart's release notes say when.

---

## Uninstalling

```bash
helm uninstall monitoring -n monitoring
```

Leaves behind, on purpose: **CRDs**, **PVCs** and the **admission webhooks**.

Deleting the CRDs destroys every `ServiceMonitor` and `PrometheusRule` in the
cluster, including ones other charts own. Check first:

```bash
kubectl get servicemonitors,prometheusrules -A
```

If you plan to reinstall, leave the CRDs and PVCs alone — your dashboards and
metric history come straight back.
