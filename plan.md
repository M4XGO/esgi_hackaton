# Plan d'implémentation — ACME Corp Hackathon
## Repo autonome — ne touche pas à l'infra K3s existante

> **Prérequis** : le cluster K3s est déjà up (via le projet existant).
> Ce repo part du kubeconfig exporté et déploie tout par-dessus.
> Aucun fichier du projet existant n'est modifié.

---

## Hypothèses de départ

- Cluster K3s single-node déjà opérationnel
- `kubectl` configuré localement avec le kubeconfig exporté
- Cilium déjà installé comme CNI (sinon préciser dans les points d'attention)
- Ingress NGINX déjà installé
- cert-manager déjà installé
- Interface réseau du nœud : `eth0` (adapter si différent — vérifier avec `ip link` sur le nœud)

---

## Structure du repo à créer

```
acme-hackathon/
├── Makefile
├── .env.example               ← template des secrets à copier en .env
├── scripts/
│   ├── bootstrap.sh           ← ordre complet depuis zéro
│   ├── gen-secrets.sh         ← génère les Secrets K8s depuis .env
│   └── test-netpol.sh         ← test de blocage réseau pour preuves jury
└── k8s/
    ├── namespaces/
    │   └── namespaces.yaml
    ├── multus/
    │   ├── nad-dmz.yaml
    │   ├── nad-services.yaml
    │   └── nad-users.yaml
    ├── networkpolicies/
    │   ├── default-deny-dmz.yaml
    │   ├── default-deny-services.yaml
    │   ├── default-deny-monitoring.yaml
    │   ├── allow-internet-to-ingress.yaml
    │   ├── allow-dmz-to-wikijs.yaml
    │   ├── allow-wikijs-to-ldap.yaml
    │   ├── allow-wikijs-to-postgres.yaml
    │   └── allow-monitoring-scrape.yaml
    ├── ldap/
    │   ├── secret.yaml
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   └── bootstrap.ldif
    ├── postgres/
    │   ├── secret.yaml
    │   ├── pvc.yaml
    │   ├── statefulset.yaml
    │   └── service.yaml
    ├── wikijs/
    │   ├── secret.yaml
    │   ├── configmap.yaml
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   └── ingress.yaml
    ├── monitoring/
    │   ├── loki-values.yaml
    │   ├── grafana-dashboard-acme.json
    │   └── alertmanager-rules.yaml
    └── backup/
        ├── pvc-backup.yaml
        ├── cronjob.yaml
        └── restore-job.yaml
```

---

## Détail de chaque fichier

### Makefile

Targets :

```
make all             → namespaces + secrets + multus + ldap + app + monitoring + backup
make namespaces      → kubectl apply -f k8s/namespaces/
make secrets         → exécute scripts/gen-secrets.sh
make multus          → kubectl apply -f k8s/multus/
make ldap            → kubectl apply -f k8s/ldap/ + wait pod ready
make app             → kubectl apply -f k8s/postgres/ + wait + kubectl apply -f k8s/wikijs/
make monitoring      → helm upgrade loki-stack + kubectl apply alertmanager-rules
make backup          → kubectl apply -f k8s/backup/
make netpol          → kubectl apply -f k8s/networkpolicies/  ← toujours en dernier
make hubble          → cilium hubble enable --ui
make restore         → kubectl create job restore-now --from=cronjob/pg-backup -n services
make test-netpol     → exécute scripts/test-netpol.sh
```

> `make netpol` est volontairement séparé de `make all`.
> Les NetworkPolicies default-deny bloquent tout si appliquées avant que les pods soient Running.
> Lancer `make netpol` uniquement quand tous les pods sont en état Ready.

---

### `.env.example`

```bash
LDAP_ADMIN_PASSWORD=changeme
LDAP_BIND_PASSWORD=changeme
POSTGRES_PASSWORD=changeme
WIKIJS_SECRET=changeme_32chars_minimum
LETSENCRYPT_EMAIL=admin@acme.local
NODE_INTERFACE=eth0        # interface réseau du noeud Proxmox (ip link pour vérifier)
```

---

### `scripts/gen-secrets.sh`

Génère les Secrets K8s depuis le fichier `.env` :

```bash
source .env

kubectl create secret generic ldap-secret \
  --from-literal=LDAP_ADMIN_PASSWORD=$LDAP_ADMIN_PASSWORD \
  --from-literal=LDAP_BIND_PASSWORD=$LDAP_BIND_PASSWORD \
  -n services --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_USER=wikijs \
  --from-literal=POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
  --from-literal=POSTGRES_DB=wikijs \
  -n services --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic wikijs-secret \
  --from-literal=SECRET=$WIKIJS_SECRET \
  -n services --dry-run=client -o yaml | kubectl apply -f -
```

---

### `scripts/test-netpol.sh`

Lance un pod temporaire dans le namespace `dmz` et tente d'atteindre
directement les services du namespace `services` — pour prouver le blocage au jury :

```bash
# Doit échouer (timeout) — preuve du blocage L3
kubectl run test-block --image=busybox --rm -it --restart=Never -n dmz -- \
  wget -T5 http://postgres.services.svc.cluster.local:5432

# Doit réussir — preuve que le flux autorisé fonctionne
kubectl run test-allow --image=busybox --rm -it --restart=Never -n dmz -- \
  wget -T5 http://wikijs.services.svc.cluster.local:3000/healthz
```

---

### `k8s/namespaces/namespaces.yaml`

3 namespaces :
- `dmz` — label `zone: dmz`, annotation `cilium.io/policy-enforcement: always`
- `services` — label `zone: services`, annotation `cilium.io/policy-enforcement: always`
- `monitoring` — label `zone: monitoring`

---

### `k8s/multus/nad-dmz.yaml`
### `k8s/multus/nad-services.yaml`
### `k8s/multus/nad-users.yaml`

Kind : `NetworkAttachmentDefinition` (apiVersion: `k8s.cni.cncf.io/v1`)

Spec JSON pour chaque NAD :
- `type: macvlan`
- `master: eth0` (valeur depuis `NODE_INTERFACE` dans `.env`)
- `mode: bridge`
- `ipam.type: host-local`
- Ranges :
  - dmz      → `10.0.1.0/24`, gateway `10.0.1.1`
  - services → `10.0.2.0/24`, gateway `10.0.2.1`
  - users    → `10.0.3.0/24`, gateway `10.0.3.1`

Annotation à ajouter sur chaque pod dans le namespace correspondant :
`k8s.v1.cni.cncf.io/networks: nad-dmz` (ou nad-services selon le namespace)

---

### `k8s/networkpolicies/default-deny-*.yaml` (3 fichiers)

Un fichier par namespace (`dmz`, `services`, `monitoring`) :
- `podSelector: {}` — s'applique à tous les pods du namespace
- `policyTypes: [Ingress, Egress]`
- Aucune règle → tout est bloqué par défaut

---

### `k8s/networkpolicies/allow-internet-to-ingress.yaml`

- Namespace : `dmz`
- `podSelector` : `app.kubernetes.io/name: ingress-nginx`
- Ingress depuis `0.0.0.0/0` sur port `443`
- Ingress depuis `0.0.0.0/0` sur port `80` (redirect)

---

### `k8s/networkpolicies/allow-dmz-to-wikijs.yaml`

- Namespace source : `dmz`
- Namespace destination : `services`
- `namespaceSelector` sur `zone: services`
- `podSelector` sur `app: wikijs`
- Port : `3000`

---

### `k8s/networkpolicies/allow-wikijs-to-ldap.yaml`

- Namespace : `services`
- `podSelector` source : `app: wikijs`
- `podSelector` destination : `app: openldap`
- Port : `389`

---

### `k8s/networkpolicies/allow-wikijs-to-postgres.yaml`

- Namespace : `services`
- `podSelector` source : `app: wikijs`
- `podSelector` destination : `app: postgres`
- Port : `5432`

---

### `k8s/networkpolicies/allow-monitoring-scrape.yaml`

- Ingress depuis namespace `monitoring` vers tous les namespaces
- Port : `9090`, `9100`, `8080` (métriques standards)

---

### `k8s/ldap/secret.yaml`

Secret K8s (généré par `gen-secrets.sh`, ne pas écrire les valeurs en dur) :
- Clés : `LDAP_ADMIN_PASSWORD`, `LDAP_BIND_PASSWORD`
- Namespace : `services`

---

### `k8s/ldap/deployment.yaml`

- Image : `osixia/openldap:1.5.0`
- Namespace : `services`
- Annotation Multus : `k8s.v1.cni.cncf.io/networks: nad-services`
- Variables d'environnement :
  - `LDAP_ORGANISATION: ACME Corp`
  - `LDAP_DOMAIN: acme.local`
  - `LDAP_BASE_DN: dc=acme,dc=local`
  - `LDAP_ADMIN_PASSWORD` depuis Secret `ldap-secret`
- InitContainer `ldap-bootstrap` :
  - Image : `osixia/openldap:1.5.0`
  - Attend que slapd soit prêt puis exécute `ldapadd -f /bootstrap/bootstrap.ldif`
  - Volume : ConfigMap contenant `bootstrap.ldif` monté sur `/bootstrap/`
- Pas de readinessProbe avant fin du bootstrap (délai 30s)
- Labels : `app: openldap`

---

### `k8s/ldap/service.yaml`

- ClusterIP
- Port : `389`
- Selector : `app: openldap`
- Namespace : `services`

---

### `k8s/ldap/bootstrap.ldif`

Structure complète à générer :

```ldif
# Base
dn: dc=acme,dc=local
objectClass: top
objectClass: dcObject
objectClass: organization
o: ACME Corp
dc: acme

# OUs
dn: ou=users,dc=acme,dc=local
dn: ou=groups,dc=acme,dc=local

# Groupes
dn: cn=admins,ou=groups,dc=acme,dc=local
dn: cn=editors,ou=groups,dc=acme,dc=local
dn: cn=viewers,ou=groups,dc=acme,dc=local

# Users (5 comptes)
# admin1   → groupe admins   (mot de passe : Admin1234!)
# editor1  → groupe editors  (mot de passe : Editor1234!)
# editor2  → groupe editors  (mot de passe : Editor1234!)
# viewer1  → groupe viewers  (mot de passe : Viewer1234!)
# viewer2  → groupe viewers  (mot de passe : Viewer1234!)
```

Passwords en SHA hashé via `slappasswd -s MonMotDePasse`.
Les mots de passe en clair sont documentés dans `docs/test-credentials.md` pour le jury.

---

### `k8s/postgres/pvc.yaml`

- `storageClassName: local-path` (provisioner K3s par défaut)
- `accessModes: [ReadWriteOnce]`
- `storage: 5Gi`
- Namespace : `services`

---

### `k8s/postgres/statefulset.yaml`

- Image : `postgres:15-alpine`
- Namespace : `services`
- Annotation Multus : `k8s.v1.cni.cncf.io/networks: nad-services`
- Env depuis Secret `postgres-secret` : `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`
- VolumeMount : PVC `postgres-pvc` sur `/var/lib/postgresql/data`
- LivenessProbe : `pg_isready -U wikijs`
- ReadinessProbe : `pg_isready -U wikijs`
- Labels : `app: postgres`

---

### `k8s/postgres/service.yaml`

- ClusterIP
- Port : `5432`
- Selector : `app: postgres`
- Namespace : `services`

---

### `k8s/wikijs/configmap.yaml`

Contient `config.yml` Wiki.js complet :
- `db.type: postgres`
- `db.host: postgres.services.svc.cluster.local`
- `db.port: 5432`
- `db.user: wikijs`
- `db.pass:` depuis env var `POSTGRES_PASSWORD`
- `db.db: wikijs`
- `auth.ldap.enabled: true`
- `auth.ldap.url: ldap://openldap.services.svc.cluster.local:389`
- `auth.ldap.bindDN: cn=admin,dc=acme,dc=local`
- `auth.ldap.bindCredentials:` depuis env var `LDAP_BIND_PASSWORD`
- `auth.ldap.searchBase: ou=users,dc=acme,dc=local`
- `auth.ldap.searchFilter: (uid={{username}})`
- `auth.ldap.mappingUsername: uid`
- `auth.ldap.mappingEmail: mail`
- `port: 3000`
- `ssl.enabled: false`

---

### `k8s/wikijs/deployment.yaml`

- Image : `ghcr.io/requarks/wiki:2`
- Namespace : `services`
- Annotation Multus : `k8s.v1.cni.cncf.io/networks: nad-services`
- VolumeMount : ConfigMap `wikijs-config` monté sur `/wiki/config.yml` (subPath)
- Env :
  - `POSTGRES_PASSWORD` depuis Secret `postgres-secret`
  - `LDAP_BIND_PASSWORD` depuis Secret `ldap-secret`
  - `SECRET` depuis Secret `wikijs-secret`
- ReadinessProbe : GET `/healthz` port 3000
- Labels : `app: wikijs`

---

### `k8s/wikijs/service.yaml`

- ClusterIP
- Port : `3000`
- Selector : `app: wikijs`
- Namespace : `services`

---

### `k8s/wikijs/ingress.yaml`

- `ingressClassName: nginx`
- Host : `wiki.acme.local`
- Annotation : `cert-manager.io/cluster-issuer: letsencrypt-prod`
- TLS : secret `wikijs-tls`
- Backend : service `wikijs`, port `3000`

> Si pas d'accès internet (réseau local uniquement), remplacer l'annotation par
> `cert-manager.io/cluster-issuer: selfsigned-issuer` et ajuster en conséquence.

---

### `k8s/monitoring/loki-values.yaml`

Helm values pour `grafana/loki-stack` :

```yaml
loki:
  enabled: true
  persistence:
    enabled: true
    storageClassName: local-path
    size: 5Gi

promtail:
  enabled: true
  config:
    scrape_configs:
      # Source 1 : logs Wiki.js
      - job_name: wikijs
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names: [services]
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app]
            regex: wikijs
            action: keep
      # Source 2 : logs Nginx Ingress
      - job_name: nginx-ingress
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names: [ingress-nginx]
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
            regex: ingress-nginx
            action: keep

grafana:
  enabled: false   # Grafana déjà installé via kube-prometheus-stack existant
  sidecar:
    datasources:
      enabled: true  # ajoute la datasource Loki automatiquement au Grafana existant
```

---

### `k8s/monitoring/alertmanager-rules.yaml`

Kind : `PrometheusRule`
- **Alerte 1 — AcmePodDown** :
  - Expr : `kube_pod_status_phase{namespace=~"dmz|services",phase!="Running"} > 0`
  - For : `2m`
  - Severity : `critical`
- **Alerte 2 — AcmeHighErrorRate** :
  - Expr : `rate(nginx_ingress_controller_requests{status=~"5.."}[1m]) / rate(nginx_ingress_controller_requests[1m]) > 0.05`
  - For : `1m`
  - Severity : `warning`

---

### `k8s/monitoring/grafana-dashboard-acme.json`

Dashboard Grafana (JSON à importer) avec les panels suivants :
1. Statut des pods — namespaces `dmz` et `services` (table, vert/rouge)
2. Requêtes/s vers Wiki.js — `rate(nginx_ingress_controller_requests[1m])`
3. Taux d'erreurs 5xx — `rate(nginx_ingress_controller_requests{status=~"5.."}[1m])`
4. Logs Wiki.js en temps réel — datasource Loki, label `app=wikijs`
5. Logs Nginx Ingress — datasource Loki, label `app=ingress-nginx`

---

### `k8s/backup/pvc-backup.yaml`

- Nom : `backup-pvc`
- `storageClassName: local-path`
- `accessModes: [ReadWriteOnce]`
- `storage: 10Gi`
- Namespace : `services`

---

### `k8s/backup/cronjob.yaml`

- Schedule : `"0 2 * * *"`
- Namespace : `services`
- Image : `postgres:15-alpine`
- Commande :
  ```bash
  pg_dump -h postgres.services.svc.cluster.local \
          -U $POSTGRES_USER $POSTGRES_DB \
          > /backup/wikijs-$(date +%Y%m%d-%H%M).sql
  ```
- Env depuis Secret `postgres-secret`
- VolumeMount : PVC `backup-pvc` sur `/backup`
- `successfulJobsHistoryLimit: 3`
- `failedJobsHistoryLimit: 1`
- `restartPolicy: OnFailure`

---

### `k8s/backup/restore-job.yaml`

Job K8s one-shot (pour la démo jury — lancer via `make restore`) :
- Image : `postgres:15-alpine`
- Commande :
  ```bash
  psql -h postgres.services.svc.cluster.local \
       -U $POSTGRES_USER $POSTGRES_DB \
       < /backup/$(ls /backup/*.sql | sort | tail -1)
  ```
  (restaure automatiquement le dump le plus récent)
- Env depuis Secret `postgres-secret`
- VolumeMount : PVC `backup-pvc` sur `/backup`
- `restartPolicy: Never`

---

## Ordre d'exécution

```bash
# 1. Copier et remplir les secrets
cp .env.example .env
vim .env

# 2. Déploiement complet
make all      # namespaces + secrets + multus + ldap + app + monitoring + backup

# 3. NetworkPolicies EN DERNIER (quand tous les pods sont Running)
kubectl get pods -A   # vérifier que tout est Ready
make netpol

# 4. Hubble pour les preuves jury
make hubble

# 5. Test de blocage réseau (preuve jury)
make test-netpol
```

---

## Points d'attention pour l'agent de code

1. **Interface Multus** : le champ `master` dans les NAD doit correspondre à l'interface
   réseau réelle du nœud. Lire depuis la variable `NODE_INTERFACE` du `.env`.

2. **Let's Encrypt en réseau local** : si `wiki.acme.local` n'est pas résolvable depuis
   internet, Let's Encrypt ne peut pas valider le domaine. Dans ce cas, utiliser
   `cert-manager.io/cluster-issuer: selfsigned-issuer` sur l'Ingress.

3. **Wiki.js premier boot** : Wiki.js affiche un wizard de setup au premier démarrage.
   Pour la démo, se connecter une fois manuellement pour finir le setup avant de
   présenter au jury.

4. **NetworkPolicies Cilium vs natif K8s** : si Cilium est le CNI actif, les ressources
   `CiliumNetworkPolicy` (CRD Cilium) permettent le contrôle L7. Si on veut rester
   compatible standard, utiliser `NetworkPolicy` K8s natif (L3/L4 uniquement).
   Choisir l'un ou l'autre — ne pas mixer les deux.

5. **Grafana existant** : le `grafana.enabled: false` dans `loki-values.yaml` évite
   de déployer un second Grafana. La datasource Loki est ajoutée au Grafana existant
   via le sidecar. Vérifier que le Grafana existant a le sidecar datasource activé.