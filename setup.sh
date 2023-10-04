#!/bin/bash
set -e

kind create cluster --name=caas-offsite --config=kind-config.yaml
kubectx kind-caas-offsite

kubectl create namespace crossplane-system
kubectl apply -f init/pv.yaml

helm install crossplane --namespace crossplane-system --create-namespace https://charts.crossplane.io/stable/crossplane-1.13.2.tgz --set args='{--debug}'

# setup local-storage and patch crossplane container
kubectl -n crossplane-system patch deployment/crossplane --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/1","value":{"image":"alpine","name":"dev","command":["sleep","infinity"],"volumeMounts":[{"mountPath":"/tmp/cache","name":"package-cache"}]}},{"op":"add","path":"/spec/template/metadata/labels/patched","value":"true"}]'
kubectl -n crossplane-system wait deploy crossplane --for condition=Available --timeout=60s
kubectl -n crossplane-system wait pods -l app=crossplane,patched=true --for condition=Ready --timeout=60s

kubectl apply -f .up/examples/configuration-caas.yaml

echo "Waiting until configuration package is healthy/installed..."
kubectl wait configuration.pkg configuration-caas --for=condition=Installed --timeout 5m
kubectl wait configuration.pkg configuration-caas --for=condition=Healthy --timeout 5m

echo "Waiting until all installed provider packages are healthy..."
kubectl wait provider.pkg --all --for condition=Healthy --timeout 5m

echo "Creating aws cloud credential secret..."
kubectl -n crossplane-system create secret generic aws-creds --from-literal=credentials="${UPTEST_AWS_CLOUD_CREDENTIALS}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "Creating a default aws providerconfig..."
cat <<EOF | kubectl apply -f -
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    secretRef:
      key: credentials
      name: aws-creds
      namespace: crossplane-system
    source: Secret
EOF
