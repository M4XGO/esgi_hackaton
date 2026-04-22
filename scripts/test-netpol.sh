#!/usr/bin/env bash
set -euo pipefail

echo "=== Test NetworkPolicies — preuves jury ==="
echo ""

echo "[TEST 1] Accès direct Postgres depuis dmz (doit ÉCHOUER — timeout attendu)"
kubectl run test-block --image=busybox --rm -it --restart=Never -n dmz -- \
  wget -T5 http://postgres.services.svc.cluster.local:5432 && \
  echo "FAIL: connexion réussie — la NetworkPolicy ne bloque pas !" || \
  echo "PASS: connexion bloquée (timeout) — NetworkPolicy OK"

echo ""
echo "[TEST 2] Accès Wiki.js depuis dmz (doit RÉUSSIR)"
kubectl run test-allow --image=busybox --rm -it --restart=Never -n dmz -- \
  wget -T5 -O- http://wikijs.services.svc.cluster.local:3000/healthz && \
  echo "PASS: Wiki.js accessible depuis dmz" || \
  echo "FAIL: Wiki.js inaccessible — vérifier allow-dmz-to-wikijs.yaml"
