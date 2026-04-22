#!/usr/bin/env bash
set -euo pipefail

echo "=== ACME Corp — Bootstrap complet ==="

echo "[1/7] Namespaces..."
make namespaces

echo "[2/7] Secrets depuis .env..."
make secrets

echo "[3/7] Multus NADs..."
make multus

echo "[4/7] LDAP..."
make ldap

echo "[5/7] Postgres + Wiki.js..."
make app

echo "[6/7] Monitoring (Loki + alertes)..."
make monitoring

echo "[7/7] Backup CronJob..."
make backup

echo ""
echo "=== Tous les workloads sont déployés ==="
echo ""
echo "Vérifier que tous les pods sont Running :"
kubectl get pods -A
echo ""
echo "Quand tout est Ready, appliquer les NetworkPolicies :"
echo "  make netpol"
echo ""
echo "Puis activer Hubble pour les preuves jury :"
echo "  make hubble"
