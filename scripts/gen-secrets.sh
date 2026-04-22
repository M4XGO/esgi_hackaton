#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Copy .env.example and fill in values." >&2
  exit 1
fi

source .env

kubectl create secret generic ldap-secret \
  --from-literal=LDAP_ADMIN_PASSWORD="$LDAP_ADMIN_PASSWORD" \
  --from-literal=LDAP_BIND_PASSWORD="$LDAP_BIND_PASSWORD" \
  -n services --dry-run=client -o yaml | kubectl apply -f -

# Mots de passe des comptes utilisateurs LDAP (utilisés par l'initContainer pour générer les hashes SSHA)
kubectl create secret generic ldap-users-secret \
  --from-literal=ADMIN1_PASSWORD="$LDAP_ADMIN1_PASSWORD" \
  --from-literal=EDITOR_PASSWORD="$LDAP_EDITOR_PASSWORD" \
  --from-literal=VIEWER_PASSWORD="$LDAP_VIEWER_PASSWORD" \
  -n services --dry-run=client -o yaml | kubectl apply -f -

# ConfigMap LDAP bootstrap — généré depuis le fichier source (single source of truth)
kubectl create configmap ldap-bootstrap \
  --from-file=bootstrap.ldif=k8s/ldap/bootstrap.ldif \
  -n services --dry-run=client -o yaml | kubectl apply -f -

# Minio credentials (namespace velero)
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic minio-secret \
  --from-literal=MINIO_ROOT_USER="$MINIO_ROOT_USER" \
  --from-literal=MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
  -n velero --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic velero-s3-credentials \
  --from-literal=cloud="[default]
aws_access_key_id=${MINIO_ROOT_USER}
aws_secret_access_key=${MINIO_ROOT_PASSWORD}" \
  -n velero --dry-run=client -o yaml | kubectl apply -f -

echo "Secrets + ConfigMaps created/updated."
