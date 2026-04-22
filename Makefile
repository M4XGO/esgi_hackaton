SHELL := /bin/bash
.PHONY: all namespaces secrets multus-install multus ldap app monitoring backup velero netpol restore test-netpol scope scope-ui

all: namespaces secrets multus ldap monitoring backup

# Installer le CRD + DaemonSet Multus (à faire UNE SEULE FOIS avant make all)
multus-install:
	kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.1.0/deployments/multus-daemonset-thick.yml
	kubectl rollout status daemonset/kube-multus-ds -n kube-system --timeout=120s

namespaces:
	kubectl apply -f k8s/namespaces/

secrets:
	bash scripts/gen-secrets.sh

multus:
	kubectl apply -f k8s/multus/

ldap:
	kubectl apply -f k8s/ldap/
	kubectl rollout status statefulset/openldap -n services --timeout=120s

# app:
# 	kubectl apply -f k8s/itadaki/
# 	kubectl rollout status deployment/itadaki-backend -n services --timeout=120s
# 	kubectl rollout status deployment/itadaki-frontend -n services --timeout=120s

monitoring:
	helm repo add grafana https://grafana.github.io/helm-charts || true
	helm repo update
	helm upgrade --install loki-stack grafana/loki-stack \
		-n monitoring --create-namespace \
		-f k8s/monitoring/loki-values.yaml
	kubectl apply -f k8s/monitoring/loki-datasource.yaml
	kubectl apply -f k8s/monitoring/alertmanager-rules.yaml

backup:
	kubectl apply -f k8s/backup/pvc-backup.yaml
	kubectl apply -f k8s/backup/configmap-scripts.yaml
	kubectl apply -f k8s/backup/cronjob.yaml
	# restore-job.yaml appliqué uniquement via : make restore

# Toujours en dernier — appliquer APRES que tous les pods sont Running
netpol:
	kubectl apply -f k8s/networkpolicies/


restore:
	kubectl create job restore-now --from=cronjob/h2-backup -n services

test-netpol:
	bash scripts/test-netpol.sh

# ── Weave Scope — visualisation des flux réseau ───────────────────────────────
scope:
	kubectl apply -f https://github.com/weaveworks/scope/releases/download/v1.13.2/k8s-scope.yaml
	kubectl rollout status deployment/weave-scope-app -n weave --timeout=120s

# Ouvre l'UI sur http://localhost:4040
scope-ui:
	@echo "Weave Scope UI → http://localhost:4040"
	kubectl port-forward -n weave svc/weave-scope-app 4040:80

# ── Velero + Minio ────────────────────────────────────────────────────────────
# Prérequis : make secrets (génère minio-secret + velero-s3-credentials)
velero:
	kubectl apply -f k8s/velero/minio.yaml
	kubectl rollout status deployment/minio -n velero --timeout=120s
	kubectl wait --for=condition=complete job/minio-create-bucket -n velero --timeout=60s
	helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts || true
	helm repo update
	helm upgrade --install velero vmware-tanzu/velero \
		-n velero \
		-f k8s/velero/velero-values.yaml
	kubectl rollout status deployment/velero -n velero --timeout=120s
	kubectl apply -f k8s/velero/schedule.yaml

# Déclencher un backup immédiat (pour la démo jury)
velero-backup-now:
	velero backup create demo-backup-$$(date +%Y%m%d-%H%M) \
		--include-namespaces services,monitoring,dmz \
		--default-volumes-to-fs-backup \
		--wait

# Lister les backups disponibles
velero-list:
	velero backup get

# Restaurer depuis le dernier backup (remplacer BACKUP_NAME)
# Usage : make velero-restore BACKUP=demo-backup-20260421-1400
velero-restore:
	velero restore create --from-backup $(BACKUP) --wait
