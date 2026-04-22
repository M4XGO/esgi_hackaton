# Architecture — ACME Corp Hackathon (Itadaki)

## Stack déployée

| Couche | Technologie | Namespace |
|--------|-------------|-----------|
| CNI | Flannel (K3s défaut) | cluster-wide |
| Réseau secondaire | Multus (macvlan) | cluster-wide |
| Visualisation réseau | Weave Scope :4040 (app + agent + cluster-agent) | weave |
| Ingress controller | ingress-nginx (LoadBalancer via K3s ServiceLB) | ingress-nginx |
| TLS | cert-manager + ca-issuer (self-signed CA) | cert-manager |
| Frontend | React Router 7 (SSR, Bun) :3000 | services |
| Backend | Java Spring Boot 4 + H2 :8080 | services |
| Base de données | H2 fichier persistant sur PVC (2Gi) | services |
| Uploads | PVC 5Gi (images food) | services |
| Annuaire | OpenLDAP :389 (StatefulSet) | services |
| Logs | Loki + Promtail | monitoring |
| Métriques | Prometheus + Grafana + Alertmanager | monitoring |
| Backup K8s | Velero + Kopia + Minio S3 (20Gi) | velero |

## URLs exposées via Ingress

| Service | URL | Port pod |
|---------|-----|---------|
| Itadaki (app) | `https://itadaki.acme.test` | frontend:3000 / backend:8080 |
| Grafana | `https://grafana.acme.test` | :3000 (svc :80) |
| Prometheus | `https://prometheus.acme.test` | :9090 |
| Alertmanager | `https://alertmanager.acme.test` | :9093 |
| Weave Scope | `https://scope.acme.test` | :4040 |

> DNS : entrées dans `/etc/hosts` → `10.230.105.254` (`make hosts`)
> Ingress-nginx : LoadBalancer `10.230.105.254:443` (NodePort 30376) / `:80` (NodePort 31300)

## Schéma d'architecture général

```mermaid
graph TD
    subgraph client["Client (Mac)"]
        USER(["Utilisateur *.acme.test"])
    end

    subgraph ingress_ns["namespace: ingress-nginx"]
        INGRESS["ingress-nginx - LoadBalancer 10.230.105.254 - :443 (NodePort 30376) - :80 (NodePort 31300)"]
    end

    subgraph services["namespace: services  [zone=services]"]
        FRONT["itadaki-frontend - React Router 7 - :3000"]
        BACK["itadaki-backend - Spring Boot 4 - :8080"]
        LDAP["openldap - :389"]
        H2[("PVC itadaki-h2 - 2Gi")]
        UP[("PVC uploads - 5Gi")]
        LC[("PVC ldap-config - 100Mi")]
        LD[("PVC ldap-data - 1Gi")]
    end

    subgraph monitoring["namespace: monitoring  [zone=monitoring]"]
        GRAFANA["Grafana - svc:80 -> pod:3000"]
        PROM["Prometheus - :9090"]
        AM["Alertmanager - :9093"]
        LOKI["Loki - :3100"]
        PROMTAIL["Promtail (DaemonSet)"]
        PROM_DB[("PVC prometheus-db")]
        LOKI_PVC[("PVC loki - 5Gi")]
    end

    subgraph weave_ns["namespace: weave"]
        SCOPE["weave-scope-app - :4040"]
        AGENT["weave-scope-agent (DaemonSet)"]
        CAGENT["weave-scope-cluster-agent"]
    end

    subgraph velero_ns["namespace: velero"]
        VEL["Velero + Kopia"]
        MINIO[("Minio S3 - 20Gi")]
    end

    subgraph dmz["namespace: dmz  [zone=dmz]  (vide)"]
    end

    %% Flux utilisateur → Ingress
    USER -->|"HTTPS :443"| INGRESS

    %% Ingress → apps
    INGRESS -->|"itadaki.acme.test /"| FRONT
    INGRESS -->|"itadaki.acme.test /api"| BACK
    INGRESS -->|"grafana.acme.test"| GRAFANA
    INGRESS -->|"prometheus.acme.test"| PROM
    INGRESS -->|"alertmanager.acme.test"| AM
    INGRESS -->|"scope.acme.test"| SCOPE

    %% Flux services internes
    FRONT -->|":8080"| BACK
    BACK --- H2
    BACK --- UP
    LDAP --- LD
    LDAP --- LC

    %% Monitoring
    PROMTAIL -.->|"scrape logs"| FRONT
    PROMTAIL -.->|"scrape logs"| BACK
    PROMTAIL -->|"push"| LOKI
    PROM -.->|"scrape :8080"| BACK
    GRAFANA -->|"query"| PROM
    GRAFANA -->|"query"| LOKI
    PROM -->|"alertes"| AM
    PROM --- PROM_DB
    LOKI --- LOKI_PVC

    %% Weave Scope
    AGENT -.->|"observe"| services
    AGENT -.->|"observe"| monitoring
    CAGENT -.->|"cluster info"| SCOPE

    %% Velero
    VEL -->|"Kopia backup"| H2
    VEL -->|"Kopia backup"| LD
    VEL -->|"store"| MINIO

    %% Styles
    style client fill:#fee2e2,stroke:#ef4444
    style ingress_ns fill:#fef3c7,stroke:#f59e0b
    style services fill:#dbeafe,stroke:#3b82f6
    style monitoring fill:#d1fae5,stroke:#10b981
    style weave_ns fill:#e0f2fe,stroke:#0284c7
    style velero_ns fill:#ede9fe,stroke:#8b5cf6
    style dmz fill:#f3f4f6,stroke:#9ca3af,stroke-dasharray:5 5
```

## Flux réseau & NetworkPolicies

```mermaid
graph LR
    subgraph EXT["Externe"]
        U(["Client"])
    end

    subgraph NI["ingress-nginx [kubernetes.io/metadata.name=ingress-nginx]"]
        NG["nginx - LB :443/:80"]
    end

    subgraph DMZ["dmz [zone=dmz] — vide"]
    end

    subgraph SVC["services ■ default-deny-all [Ingress+Egress]"]
        FE["frontend - :3000"]
        BE["backend - :8080"]
        OP["openldap - :389"]
    end

    subgraph MON["monitoring ■ default-deny-all [Ingress+Egress]"]
        GR["grafana - :3000"]
        PR["prometheus - :9090"]
        AL["alertmanager - :9093"]
        LK["loki - :3100"]
    end

    subgraph WV["weave"]
        SC["scope - :4040"]
    end

    %% Flux autorisés
    U -->|"HTTPS"| NG

    NG -->|":3000 allow-ingress-to-frontend"| FE
    NG -->|":8080 allow-ingress-to-backend"| BE
    NG -->|":3000 allow-ingress-to-grafana"| GR
    NG -->|":9090 allow-ingress-to-prometheus"| PR
    NG -->|":9093 allow-ingress-to-alertmanager"| AL
    NG -->|":4040 allow-ingress-to-weave-scope"| SC

    FE -->|":8080 allow-frontend-to-backend"| BE
    BE -->|":389 allow-backend-to-ldap"| OP

    PR -.->|"scrape :8080 allow-monitoring-scrape"| BE
    PR -.->|"internal"| GR
    GR -.->|"internal"| LK

    %% Flux bloqués
    U --->|"direct denied"| FE
    U --->|"direct denied"| BE
    FE --->|"denied"| OP

    style EXT fill:#fee2e2,stroke:#ef4444
    style NI fill:#fef3c7,stroke:#f59e0b
    style DMZ fill:#f3f4f6,stroke:#9ca3af,stroke-dasharray:5 5
    style SVC fill:#dbeafe,stroke:#3b82f6
    style MON fill:#d1fae5,stroke:#10b981
    style WV fill:#e0f2fe,stroke:#0284c7
```

## NetworkPolicies (état cluster)

| Namespace | Règle | Type | Source | Destination | Port |
|-----------|-------|------|--------|-------------|------|
| dmz | allow-internet-to-ingress | Ingress | 0.0.0.0/0 | ingress-nginx pods | 80, 443 |
| dmz | allow-monitoring-scrape-dmz | Ingress | zone=monitoring | (all) | 8080, 9090, 9100 |
| dmz | default-deny-all | Ingress+Egress | — | — | — |
| monitoring | allow-ingress-to-grafana | Ingress | ingress-nginx ns | grafana | 3000 |
| monitoring | allow-ingress-to-prometheus | Ingress | ingress-nginx ns | prometheus | 9090 |
| monitoring | allow-ingress-to-alertmanager | Ingress | ingress-nginx ns | alertmanager | 9093 |
| monitoring | allow-monitoring-internal | Ingress+Egress | pods within ns | pods within ns | all |
| monitoring | allow-monitoring-egress | Egress | (all) | zone=dmz, zone=services | 8080, 9090, 9100 |
| monitoring | default-deny-all | Ingress+Egress | — | — | — |
| services | allow-ingress-to-frontend | Ingress | ingress-nginx ns | itadaki-frontend | 3000 |
| services | allow-ingress-to-backend | Ingress | ingress-nginx ns | itadaki-backend | 8080 |
| services | allow-dmz-to-itadaki-frontend | Ingress | zone=dmz ns | itadaki-frontend | 3000 |
| services | allow-dmz-to-itadaki-backend | Ingress | zone=dmz ns | itadaki-backend | 8080 |
| services | allow-frontend-to-backend-egress | Egress | itadaki-frontend | itadaki-backend | 8080 |
| services | allow-frontend-to-backend-ingress | Ingress | itadaki-frontend | itadaki-backend | 8080 |
| services | allow-backend-to-ldap-egress | Egress | itadaki-backend | openldap | 389 |
| services | allow-backend-to-ldap-ingress | Ingress | itadaki-backend | openldap | 389 |
| services | allow-monitoring-scrape-services | Ingress | zone=monitoring | (all) | 8080, 9090, 9100 |
| services | default-deny-all | Ingress+Egress | — | — | — |
| weave | allow-ingress-to-weave-scope | Ingress | ingress-nginx ns | weave-scope-app | 4040 |

## Persistance des données (PVCs actifs)

| Donnée | PVC | Taille | Namespace |
|--------|-----|--------|-----------|
| H2 (Itadaki DB) | `itadaki-h2-pvc` | 2Gi | services |
| Uploads (images) | `itadaki-uploads-pvc` | 5Gi | services |
| LDAP data | `ldap-data-openldap-0` | 1Gi | services |
| LDAP config | `ldap-config-openldap-0` | 100Mi | services |
| Prometheus | `prometheus-db-prometheus-...` | auto | monitoring |
| Loki logs | `storage-loki-stack-0` | 5Gi | monitoring |
| Minio (Velero S3) | `minio-pvc` | 20Gi | velero |

> Backup : Velero + Kopia sauvegarde automatiquement les namespaces `services` et `monitoring` vers Minio.
