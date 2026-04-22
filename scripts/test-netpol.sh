#!/usr/bin/env bash
set -euo pipefail

echo "=== Test NetworkPolicies — preuves jury ==="
echo ""

echo "[TEST 1] dmz → LDAP:389 (doit ÉCHOUER — bloqué par default-deny-services)"
kubectl run test-block-ldap --image=busybox --rm -it --restart=Never -n dmz -- \
  wget -T5 http://openldap.services.svc.cluster.local:389 && \
  echo "FAIL: connexion réussie — NetworkPolicy ne bloque pas !" || \
  echo "PASS: connexion bloquée (timeout) — NetworkPolicy OK"

echo ""
echo "[TEST 2] dmz → itadaki-frontend:3000 (doit RÉUSSIR — allow-dmz-to-itadaki)"
kubectl run test-allow-front --image=busybox --rm -it --restart=Never -n dmz -- \
  wget -T5 -O/dev/null http://itadaki-frontend.services.svc.cluster.local:3000 && \
  echo "PASS: frontend accessible depuis dmz" || \
  echo "FAIL: frontend inaccessible — vérifier allow-dmz-to-itadaki.yaml"

echo ""
echo "[TEST 3] dmz → itadaki-backend:8080 (doit RÉUSSIR — allow-dmz-to-itadaki)"
kubectl run test-allow-back --image=busybox --rm -it --restart=Never -n dmz -- \
  wget -T5 -O/dev/null http://itadaki-backend.services.svc.cluster.local:8080/actuator/health && \
  echo "PASS: backend accessible depuis dmz" || \
  echo "FAIL: backend inaccessible — vérifier allow-dmz-to-itadaki.yaml"

echo ""
echo "[TEST 4] frontend → LDAP:389 (doit ÉCHOUER — seul le backend peut joindre LDAP)"
kubectl run test-block-front-ldap --image=busybox --rm -it --restart=Never \
  -l app=itadaki-frontend -n services -- \
  wget -T5 http://openldap.services.svc.cluster.local:389 && \
  echo "FAIL: frontend peut joindre LDAP — NetworkPolicy trop permissive !" || \
  echo "PASS: frontend bloqué vers LDAP — NetworkPolicy OK"
