# product-service chart

FastAPI product catalogue.

Pushing this repo to `main` only rsyncs it to `~/deployments` on the bastion -
nothing is applied to the cluster. Run the upgrade yourself when you want the
chart changes live:

```bash
helm upgrade product-service ~/deployments/charts/product-service \
  --namespace default --reuse-values --wait
```

`--reuse-values` keeps the image tag the app pipeline last deployed, so a
chart-only change does not roll the service back to an older build.

## Upgrading to a new image

```bash
helm upgrade --install product-service ~/deployments/charts/product-service \
  --namespace default \
  --set image.tag=sha-abc1234 \
  --set gitCommit=<full sha> \
  --wait --timeout 5m

kubectl rollout status deploy/product-service
```

`GET /version` echoes the tag and commit the pod was built from — the quickest
way to confirm what is actually running:

```bash
kubectl run curl-check --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s http://product-service:8000/version
```

Rolling back:

```bash
helm history product-service
helm rollback product-service          # or: helm rollback product-service 7
```

## Values

| Value | Default | Notes |
| --- | --- | --- |
| `replicaCount` | `3` | |
| `image.tag` | `latest` | CI passes `sha-<short>` so rollbacks are exact |
| `gitCommit` | `""` | Shown by `/version`; also rolls pods when the tag is unchanged |
| `serviceAccount.name` | `product-service-sa` | OpenBao's Kubernetes auth role binds to this |
| `strategy.maxUnavailable` | `0` | A new pod must be ready before an old one goes |
| `probes.liveness.path` | `/health` | Process is alive |
| `probes.readiness.path` | `/ready` | Ready to take traffic |
| `resources` | 50m/96Mi → 500m/256Mi | Requests and limits |
| `podDisruptionBudget.minAvailable` | `2` | Of 3 pods, during node drains |
| `extraEnv` | `{}` | Map of extra env vars |

Pods run as uid 10001 with a read-only root filesystem and `/tmp` on an
emptyDir, matching the `USER 10001` in the app image.

## Ordering caveat

The readiness probe hits `/ready`, which only exists in product-service 0.2.0
and later. Deploy the app first (which pushes a new image and sets the tag),
then this chart. Applying this chart while an older image is running leaves the
pods permanently unready and the rollout will time out.

## Routing

`traefik/routes/product-service.yaml` publishes `/products`, `/categories`,
`/orders` and `/stats` on `foodonline.run.place`. `/health`, `/ready`,
`/version` and `/docs` stay unrouted — the probes reach them inside the
cluster. Apply route changes with:

```bash
kubectl apply -f ~/deployments/traefik/routes/product-service.yaml
```
