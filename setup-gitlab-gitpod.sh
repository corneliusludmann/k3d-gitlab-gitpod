#!/usr/bin/env bash

set -euo pipefail

print_usage() {
    >&2 echo "Usage: $0 <your.domain.com> [<dns server>]"
    >&2 echo ""
    >&2 echo "your.domain.com   Base domain, e.g. dev.example.com → gitpod.dev.example.com and gitlab.dev.example.com"
    >&2 echo "dns server        DNS server that resolves your base domain. Optional, helpful when you DNS servers is not public reachable."
}

if [[ $# -lt 1 ]] || [[ "$1" == "help" ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    print_usage
    exit 1
fi

DOMAIN="$1"
DNSSERVER="$2"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR=$SCRIPT_DIR
GPSH_DIR=$ROOT_DIR/gitpod-self-hosted
GITLAB_DIR=$ROOT_DIR/gitlab
CERTS=$GPSH_DIR/secrets/https-certificates

if [[ ! -f "$CERTS/fullchain.pem" ]] || [[ ! -f "$CERTS/privkey.pem" ]]; then
    >&2 echo "SSL certs missing"
    >&2 echo "please provide the following files and retry:"
    >&2 echo "-  $CERTS/fullchain.pem"
    >&2 echo "-  $CERTS/privkey.pem"
    exit 2
fi

echo "Using domain:     $DOMAIN"
if [[ -n "$DNSSERVER" ]]; then
    echo "Using DNS server: $DNSSERVER"
fi



echo "Removing existing installation if exists ..."

k3d delete cluster gitlab || true
k3d delete cluster gitpod || true
docker stop nginx-proxy || true


echo "Creating docker network ..."
docker network create -d bridge k3d || true


# GitLab
echo "Installing GitLab cluster ..."

k3d create cluster \
    --network k3d \
    -p 1443:443@loadbalancer \
    --k3s-server-arg --disable=traefik \
    --switch \
    gitlab

if [[ -n "$DNSSERVER" ]]; then
    # let your domain resolve by the given DNS server
    kubectl get configmap -n kube-system coredns -o json | \
        sed -e "s+.:53+$DOMAIN {\\\\n  forward . $DNSSERVER\\\\n}\\\\n.:53+g" | \
        kubectl apply -f -
fi


kubectl create secret tls tls-certs \
    --cert="$CERTS/fullchain.pem" \
    --key="$CERTS/privkey.pem"
helm repo add gitlab https://charts.gitlab.io/
helm install gitlab gitlab/gitlab \
    --set global.hosts.domain=$DOMAIN \
    --set certmanager.install=false \
    --set global.ingress.configureCertmanager=false \
    --set global.ingress.tls.secretName=tls-certs \
    --version 4.0.4


# Gitpod
echo "Installing Gitpod cluster ..."

mkdir -p /tmp/workspaces
k3d create cluster \
    --network k3d \
    -p 2443:443@loadbalancer \
    -v /tmp/workspaces:/var/gitpod/workspaces:shared \
    --k3s-server-arg --disable=traefik \
    --switch \
    gitpod

if [[ -n "$DNSSERVER" ]]; then
    # let your domain resolve by the given DNS server
    kubectl get configmap -n kube-system coredns -o json | \
        sed -e "s+.:53+$DOMAIN {\\\\n  forward . $DNSSERVER\\\\n}\\\\n.:53+g" | \
        kubectl apply -f -
fi
docker exec k3d-gitpod-master-0 mount --make-shared /sys/fs/cgroup

cd "$GPSH_DIR"
helm repo add charts.gitpod.io https://charts.gitpod.io
helm dep update


# Newest helm leads to this error:
# Error: template: gitpod-selfhosted/charts/gitpod/charts/minio/templates/deployment.yaml:192:20: executing "gitpod-selfhosted/charts/gitpod/charts/minio/templates/deployment.yaml" at <(not .Values.gcsgateway.enabled) (not .Values.azuregateway.enabled) (not .Values.s3gateway.enabled) (not .Values.b2gateway.enabled)>: can't give argument to non-function not .Values.gcsgateway.enabled
# this patch helps:
(
cd "$GPSH_DIR/charts"
tar -xzf gitpod-0.4.0.tgz
cd gitpod
patch -p1 < "$GPSH_DIR/minio-deployment.patch"
cd ..
rm gitpod-0.4.0.tgz
tar -czf gitpod-0.4.0.tgz gitpod/
rm -r gitpod
)


helm upgrade --install -f values.yaml gitpod . \
    --timeout 60m \
    --set gitpod.hostname=gitpod.$DOMAIN \
    --set gitpod.authProviders[0].host=gitlab.$DOMAIN \
    --set gitpod.authProviders[0].oauth.callBackUrl=https://gitpod.$DOMAIN/auth/gitlab/callback \
    --set gitpod.authProviders[0].oauth.settingsUrl=gitlab.$DOMAIN/profile/applications \
    --set gitpod.components.wsManagerNode.containerdSocket=/run/k3s/containerd/containerd.sock
cd -
# We remove all network policies since there are issues for our setting that need to be fixed in the long term.
kubectl delete networkpolicies.networking.k8s.io --all


# Add GitLab OAuth config
echo "Adding GitLab OAuth config ..."
k3d get kubeconfig gitlab --switch

# Wait for GitLab DB
echo "Waiting for GitLab DB ..."
while [[ -z $(kubectl get pods | grep gitlab-migrations | grep Completed) ]]; do printf .; sleep 10; done
echo ""
DBPASSWD=$(kubectl get secret gitlab-postgresql-password -o jsonpath='{.data.postgresql-postgres-password}' | base64 --decode)
SQL=$(sed "s+example.com+$DOMAIN+" "$GITLAB_DIR/insert_oauth_application.sql")
kubectl exec -it gitlab-postgresql-0 -- bash -c "PGPASSWORD=$DBPASSWD psql -U postgres -d gitlabhq_production -c \"$SQL\""


# Start reverse proxy
echo "Starting reverse proxy ..."
sed "s+example.com+$DOMAIN+g" "$ROOT_DIR/proxy/nginx-virtual-servers.conf" > "$ROOT_DIR/proxy/default.conf"
docker run --rm --name nginx-proxy \
    -v "$ROOT_DIR/proxy/default.conf:/etc/nginx/conf.d/default.conf" \
    -v "$CERTS/fullchain.pem:/etc/nginx/certs/fullchain.pem" \
    -v "$CERTS/privkey.pem:/etc/nginx/certs/privkey.pem" \
    --network k3d \
    -p 0.0.0.0:443:443 -d nginx

echo "Done."
