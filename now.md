# État du repo — mis à jour 2026-04-21

## Ce qui a été fait

Le repo était vide (seul `plan.md` existait). Toute l'infra K8s a été générée.
L'app cible est **Itadaki** (front Next.js + back Java/H2), remplaçant Wiki.js.

---

## Contexte infra existante (terraform-kube)

Le cluster K3s a déjà installé via Terraform :
- **kube-prometheus-stack** (Prometheus + Grafana + Alertmanager + node-exporter)
  - Prometheus : PVC `local-path`, rétention configurée
  - Grafana : sidecar activé pour auto-découverte des datasources (label `grafana_datasource: "1"`)
- **cert-manager**, **ingress-nginx**, **Cilium** (CNI)

Ce repo **ne touche pas** à cette infra — il déploie par-dessus.

---

## État du déploiement (session 2026-04-21)

| Composant | État | Notes |
|-----------|------|-------|
| Namespaces | ✅ OK | dmz, services, monitoring |
| Secrets | ✅ OK | ldap-secret, minio-secret, velero-s3-credentials |
| Multus NADs | ⚠️ À redéployer | Cluster recréé — relancer `make multus-install` puis `make multus` |
| LDAP | ✅ OK | StatefulSet Rolling out OK après fix initContainer + emptyDir |
| App Itadaki | ⏳ Commenté | Images pas encore buildées — décommenter dans Makefile quand prêt |
| Loki stack | ✅ OK | Helm installé, datasource ConfigMap créé |
| AlertManager rules | ✅ OK | PrometheusRule créé |
| Backup CronJob | ✅ OK | h2-backup CronJob + backup-pvc |
| Velero + Minio | ⏳ Pas encore fait | Lancer `make velero` |
| NetworkPolicies | ⏳ Pas encore fait | Lancer `make netpol` EN DERNIER |

---

## Problème Multus rencontré (résolu partiellement)

**Problème** : Multus thick DaemonSet montait `/etc/cni/net.d` en hostPath, mais K3s stocke la config CNI dans `/var/lib/rancher/k3s/agent/etc/cni/net.d`. Le répertoire standard était vide.

**Tentatives** :
- Symlink `/etc/cni/net.d` → `/var/lib/rancher/k3s/agent/etc/cni/net.d` : échoue car kubelet ne peut pas monter un symlink comme hostPath
- DaemonSet fix-cni-symlink avec copie des fichiers : plusieurs itérations

**Décision** : cluster recréé sur nouveau nœud. Sur le nouveau cluster, vérifier si le problème persiste. Si oui, la solution qui fonctionne est de copier les fichiers (pas de symlink) via le DaemonSet (fichier supprimé du repo — le régénérer si besoin).

---

## Structure des fichiers

```
.env.example              ← template (LDAP_ADMIN_PASSWORD, LDAP_BIND_PASSWORD,
                            LETSENCRYPT_EMAIL, NODE_INTERFACE, MINIO_ROOT_USER,
                            MINIO_ROOT_PASSWORD)
Makefile
scripts/
  bootstrap.sh
  gen-secrets.sh          ← ldap-secret + ldap-bootstrap ConfigMap + minio secrets
  test-netpol.sh
k8s/
  namespaces/namespaces.yaml
  multus/
    nad-dmz.yaml          ← macvlan 10.0.1.0/24 — master: eth0 à vérifier
    nad-services.yaml     ← macvlan 10.0.2.0/24
    nad-users.yaml        ← macvlan 10.0.3.0/24
  networkpolicies/        ← 8 fichiers (default-deny × 3 + allow × 5)
  ldap/
    bootstrap.ldif        ← SOURCE UNIQUE users/groupes
    service.yaml
    statefulset.yaml      ← osixia/openldap, initContainer copy-ldif, 2 PVCs auto
  itadaki/
    backend-pvc.yaml      ← H2 2Gi
    backend-deployment.yaml   ← localhost:5000/itadaki-backend:latest
    backend-service.yaml
    frontend-deployment.yaml  ← localhost:5000/itadaki-frontend:latest
    frontend-service.yaml
    ingress.yaml          ← itadaki.acme.local, /api→back, /→front
  monitoring/
    loki-values.yaml
    loki-datasource.yaml  ← ConfigMap auto-import dans Grafana existant
    alertmanager-rules.yaml
    grafana-dashboard-acme.json
  backup/
    pvc-backup.yaml
    configmap-scripts.yaml    ← backup.sh + restore.sh
    cronjob.yaml              ← h2-backup
    restore-job.yaml          ← NE PAS appliquer via make backup — utiliser make restore
  velero/
    minio.yaml            ← Minio StatefulSet + Job create-bucket
    velero-values.yaml    ← Helm values Velero + plugin AWS
    schedule.yaml         ← backup quotidien 1h, TTL 7 jours
docs/
  test-credentials.md     ← comptes LDAP jury
archi.md                  ← schéma Mermaid + tableaux
```

---

## Ordre de déploiement (nouveau cluster)

```bash
# 1. Remplir .env
cp .env.example .env && vim .env

# 2. Vérifier l'interface réseau du nœud et adapter si ≠ eth0
ip link   # sur le nœud
# Modifier master: eth0 dans k8s/multus/nad-*.yaml si besoin

# 3. Installer Multus (une seule fois)
make multus-install

# 4. Déploiement complet (sans app pour l'instant)
make all

# 5. Builder et pousser les images Itadaki, décommenter make app dans Makefile
# docker build + push vers localhost:5000/itadaki-{frontend,backend}:latest
# puis : make app

# 6. Déployer Velero + Minio
make velero

# 7. NetworkPolicies EN DERNIER
kubectl get pods -A   # vérifier tout Running
make netpol

# 8. Hubble + test jury
make hubble
make test-netpol
```

---

## Points à vérifier / TODO

- [ ] `master: eth0` dans les 3 NADs Multus — vérifier avec `ip link` sur le nœud
- [ ] Si réseau local sans internet : changer `letsencrypt-prod` → `selfsigned-issuer` dans `k8s/itadaki/ingress.yaml`
- [ ] Registry K3s local : configurer `/etc/rancher/k3s/registries.yaml` pour accepter `localhost:5000`
- [ ] Spring Boot : exposer `/actuator/health` (ajouter `spring-boot-starter-actuator`)
- [ ] H2 datasource URL dans l'app : `jdbc:h2:file:/data/itadaki`
- [ ] `make restore` : supprimer l'ancien Job avant de relancer (`kubectl delete job h2-restore -n services`)
- [ ] Grafana dashboard : importer `k8s/monitoring/grafana-dashboard-acme.json` manuellement
- [ ] Velero CLI à installer localement : `brew install velero`
- [ ] Si Multus pose encore problème sur le nouveau cluster : voir section ci-dessus
