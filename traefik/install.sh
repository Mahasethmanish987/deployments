#!/bin/bash

set -e

helm upgrade --install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  --version 39.0.7 \
  --set service.type=LoadBalancer \
  --set-string 'service.annotations.loadbalancer\.openstack\.org/proxy-protocol=true' \
  --set 'ports.web.proxyProtocol.trustedIPs={192.168.10.0/24\,10.233.64.0/18}' \
  --set 'ports.websecure.proxyProtocol.trustedIPs={192.168.10.0/24\,10.233.64.0/18}' \
  --set ports.web.port=8000 \
  --set ports.web.exposedPort=80 \
  --set ports.web.http.redirections.entryPoint.to=websecure \
  --set ports.web.http.redirections.entryPoint.scheme=https \
  --set ports.web.http.redirections.entryPoint.permanent=true \
  --set ports.websecure.port=8443 \
  --set ports.websecure.exposedPort=443 \
  --set ports.websecure.transport.respondingTimeouts.readTimeout=600s \
  --set providers.kubernetesCRD.enabled=true \
  --set providers.kubernetesCRD.allowCrossNamespace=true \
  --set providers.kubernetesCRD.allowExternalNameServices=true \
  --set providers.kubernetesIngress.enabled=true \
  --set logs.general.level=INFO \
  --set logs.access.enabled=true \
  --set metrics.prometheus.enabled=true \
  --set ingressRoute.dashboard.enabled=false


kubectl rollout status deployment/traefik \
  -n traefik \
  --timeout=5m


kubectl get svc traefik -n traefik
