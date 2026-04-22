# Architecture — ACME Corp Hackathon (Itadaki)

## Stack déployée

| Couche | Technologie | Namespace |
|--------|-------------|-----------|
| Ingress | NGINX (via terraform-kube) | dmz |
| Frontend | Next.js :3000 | services |
| Backend | Java Spring Boot :8080 | services |
| Base de données | H2 (fichier persistant sur PVC) | services |
| Annuaire | OpenLDAP :389 (StatefulSet) | services |
| Logs | Loki + Promtail | monitoring |
| Métriques | Prometheus + Grafana + Alertmanager (via terraform-kube) | monitoring |
| Backup K8s | Velero + Minio S3 | velero |
| Réseau secondaire | Multus (macvlan sur eth0) | cluster-wide |

## Schéma

```mermaid
graph TD
    subgraph internet["🌐 Internet"]
        USER([Utilisateur])
    end

    subgraph dmz["namespace: dmz"]
        INGRESS["Ingress NGINX\nport 80 / 443"]
    end

    subgraph services["namespace: services"]
        FRONT["itadaki-frontend\nNext.js  :3000"]
        BACK["itadaki-backend\nJava  :8080"]
        LDAP["openldap\n:389"]
        H2[("PVC itadaki-h2\n2Gi")]
        LDAP_D[("PVC ldap-data\n1Gi")]
        LDAP_C[("PVC ldap-config\n100Mi")]
        BK_PVC[("PVC backup\n10Gi")]
        CRON["CronJob h2-backup\n@ 2h du matin"]
    end

    subgraph monitoring["namespace: monitoring"]
        PROM["Prometheus"]
        GRAFANA["Grafana"]
        LOKI["Loki"]
        PROMTAIL["Promtail"]
        AM["Alertmanager"]
    end

    subgraph velero["namespace: velero"]
        VEL["Velero + node-agent"]
        MINIO["Minio S3\n:9000"]
        MINIO_PVC[("PVC minio\n20Gi")]
    end

    %% Flux utilisateur
    USER -->|HTTPS| INGRESS
    INGRESS -->|"/ "| FRONT
    INGRESS -->|/api| BACK

    %% Flux interne services
    BACK -->|LDAP :389| LDAP
    BACK --- H2
    LDAP --- LDAP_D
    LDAP --- LDAP_C
    CRON -->|cp .mv.db| BK_PVC

    %% Monitoring
    PROMTAIL -.->|scrape logs| FRONT
    PROMTAIL -.->|scrape logs| BACK
    PROMTAIL -->|push| LOKI
    PROM -.->|scrape metrics| BACK
    PROM -.->|scrape metrics| INGRESS
    GRAFANA -->|query| PROM
    GRAFANA -->|query| LOKI
    PROM --> AM

    %% Velero backup
    VEL -->|"backup PVCs (kopia)"| H2
    VEL -->|"backup PVCs (kopia)"| LDAP_D
    VEL -->|"backup PVCs (kopia)"| LOKI
    VEL -->|store| MINIO
    MINIO --- MINIO_PVC

    %% Styles namespaces
    style dmz fill:#fef3c7,stroke:#f59e0b
    style services fill:#dbeafe,stroke:#3b82f6
    style monitoring fill:#d1fae5,stroke:#10b981
    style velero fill:#ede9fe,stroke:#8b5cf6
    style internet fill:#fee2e2,stroke:#ef4444
```

## NetworkPolicies

| Règle | Source | Destination | Port |
|-------|--------|-------------|------|
| allow-internet-to-ingress | 0.0.0.0/0 | ingress-nginx (dmz) | 80, 443 |
| allow-dmz-to-itadaki | dmz | itadaki-frontend | 3000 |
| allow-dmz-to-itadaki | dmz | itadaki-backend | 8080 |
| allow-frontend-to-backend | itadaki-frontend | itadaki-backend | 8080 |
| allow-backend-to-ldap | itadaki-backend | openldap | 389 |
| allow-monitoring-scrape | monitoring | dmz + services | 9090, 9100, 8080 |
| default-deny | — | dmz, services, monitoring | tout bloqué par défaut |

## Persistance des données

| Donnée | PVC | Taille | Survit à la suppression |
|--------|-----|--------|------------------------|
| H2 (Itadaki) | `itadaki-h2-pvc` | 2Gi | Oui |
| LDAP data | `ldap-data-openldap-0` | 1Gi | Oui |
| LDAP config | `ldap-config-openldap-0` | 100Mi | Oui |
| Backup H2 | `backup-pvc` | 10Gi | Oui |
| Loki logs | PVC Helm loki-stack | 5Gi | Oui |
| Minio (Velero) | `minio-pvc` | 20Gi | Oui |
