SHELL := /bin/bash
DOCKER_HUB_USER ?= m4xgo

.PHONY: all namespaces secrets multus-install multus ldap app monitoring backup velero netpol restore test-netpol scope ingresses hosts build push build-push

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
	kubectl rollout status deployment/phpldapadmin -n services --timeout=120s

app:
	kubectl apply -f k8s/itadaki/
	kubectl rollout status deployment/itadaki-backend -n services --timeout=180s
	kubectl rollout status deployment/itadaki-frontend -n services --timeout=120s

# ── Docker build & push vers Docker Hub ──────────────────────────────────────
# Prérequis : docker login
build:
	docker build --platform linux/amd64 -t $(DOCKER_HUB_USER)/itadaki-backend:latest ../itadaki/backend
	docker build --platform linux/amd64 -t $(DOCKER_HUB_USER)/itadaki-frontend:latest ../itadaki/frontend

push:
	docker push $(DOCKER_HUB_USER)/itadaki-backend:latest
	docker push $(DOCKER_HUB_USER)/itadaki-frontend:latest

build-push: build push

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
	kubectl delete job h2-restore -n services --ignore-not-found
	kubectl apply -f k8s/backup/restore-job.yaml

test-netpol:
	bash scripts/test-netpol.sh

# ── Weave Scope — visualisation des flux réseau ───────────────────────────────
scope:
	kubectl apply -f https://github.com/weaveworks/scope/releases/download/v1.13.2/k8s-scope.yaml
	kubectl rollout status deployment/weave-scope-app -n weave --timeout=120s
	kubectl apply -f k8s/ingresses/scope-ingress.yaml

# ── Ingress pour les UIs (Grafana, Prometheus, Alertmanager, Scope) ───
ingresses:
	kubectl apply -f k8s/ingresses/

# Injecte les entrées acme.test dans /etc/hosts de ta machine locale (nécessite sudo)
hosts:
	@NODE_IP=$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}') && \
	sudo sed -i '' '/acme\.test/d' /etc/hosts && \
	echo "$$NODE_IP  itadaki.acme.test grafana.acme.test prometheus.acme.test alertmanager.acme.test scope.acme.test phpldapadmin.acme.test" | sudo tee -a /etc/hosts && \
	echo "✓ /etc/hosts mis à jour → $$NODE_IP"

# ── Velero + Minio ────────────────────────────────────────────────────────────
# Prérequis : make secrets (génère minio-secret + velero-s3-credentials)
velero:
	kubectl apply -f k8s/velero/minio.yaml
	kubectl rollout status deployment/minio -n velero --timeout=120s
	kubectl wait --for=condition=complete job/minio-create-bucket -n velero --timeout=200s
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
