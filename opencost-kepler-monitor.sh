#!/bin/bash

set -e
set -o pipefail

# Accept dynamic inputs
CLUSTER_NAME=${1:-"default-cluster"}
PROM_URL=${2:-"http://localhost:9090"}
OPENCOST_PROM_ENDPOINT=${3:-"$PROM_URL"}

echo "📌 Cluster Name: $CLUSTER_NAME"
echo "📌 Prometheus Remote Write URL: $PROM_URL"
echo "📌 OpenCost PROMETHEUS_SERVER_ENDPOINT: $OPENCOST_PROM_ENDPOINT"

echo "🚀 Adding Helm repositories..."
helm repo add kepler https://sustainable-computing-io.github.io/kepler-helm-chart
helm repo add opencost https://opencost.github.io/opencost-helm-chart
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

echo "🔄 Updating Helm repositories..."
helm repo update

echo "📦 Installing Kepler..."
kubectl create ns kepler --dry-run=client -o yaml | kubectl apply -f -
helm install kepler kepler/kepler -n kepler

echo "📦 Installing Prometheus..."
kubectl create ns prometheus-system --dry-run=client -o yaml | kubectl apply -f -
helm install prometheus prometheus-community/prometheus \
  --namespace prometheus-system \
  --set prometheus-pushgateway.enabled=false \
  --set alertmanager.enabled=false \
  -f https://raw.githubusercontent.com/opencost/opencost/develop/kubernetes/prometheus/extraScrapeConfigs.yaml

echo "📦 Installing OpenCost..."
kubectl create ns opencost --dry-run=client -o yaml | kubectl apply -f -
helm install opencost opencost/opencost -n opencost

#echo "⏳ Waiting for OpenCost deployment to be ready..."
#kubectl rollout status deployment/opencost -n opencost --timeout=60s || true

echo "🔧 Patching OpenCost deployment with custom PROMETHEUS_SERVER_ENDPOINT..."
kubectl patch deployment opencost -n opencost --type='json' -p="[
  {
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/containers/0/env\",
    \"value\": [
      {
        \"name\": \"PROMETHEUS_SERVER_ENDPOINT\",
        \"value\": \"$OPENCOST_PROM_ENDPOINT\"
      }
    ]
  }
]"

echo "📦 Installing Alloy..."
kubectl create ns alloy --dry-run=client -o yaml | kubectl apply -f -
helm install alloy grafana/alloy -n alloy

echo "🛠️ Creating config.alloy..."
cat <<EOF > config.alloy
prometheus.scrape "opencost" {
  targets = [
    {
      __address__ = "opencost.opencost.svc.cluster.local:9003",
    },
  ]
  scrape_interval = "1m"
  metrics_path = "/metrics"
  forward_to = [prometheus.remote_write.central.receiver]
}

prometheus.scrape "kepler" {
  targets = [
    {
      __address__ = "kepler.kepler.svc.cluster.local:9102",
    },
  ]
  scrape_interval = "1m"
  metrics_path = "/metrics"
  forward_to = [prometheus.remote_write.central.receiver]
}

prometheus.remote_write "central" {
  endpoint {
    url = "$PROM_URL/api/v1/write"
  }
  external_labels = {
    cluster = "$CLUSTER_NAME",
  }
}
EOF

echo "🛠️ Creating ConfigMap alloy-config..."
kubectl create configmap --namespace alloy alloy-config --from-file=config.alloy=./config.alloy --dry-run=client -o yaml | kubectl apply -f -

echo "📝 Creating values.yaml for Alloy..."
cat <<EOF > values.yaml
alloy:
  configMap:
    create: false
    name: alloy-config
    key: config.alloy
EOF

echo "⬆️ Upgrading Alloy with external configuration..."
helm upgrade --namespace alloy alloy grafana/alloy -f values.yaml
helm upgrade opencost opencost/opencost -n opencost -f http://10.0.34.169/file.yaml
echo "✅ Deployment complete! Kepler, OpenCost, Prometheus, and Alloy are configured."


