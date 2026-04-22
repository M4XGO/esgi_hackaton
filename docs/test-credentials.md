# Credentials de test — ACME Corp (jury)

> Ces comptes sont créés automatiquement au bootstrap LDAP.
> Les mots de passe sont stockés dans le Secret K8s `ldap-users-secret` (namespace `services`).
> Pour les consulter : `kubectl get secret ldap-users-secret -n services -o jsonpath='{.data}' | base64 -d`

## Comptes Itadaki / LDAP

| Utilisateur | Groupe   | Email                | Secret key         |
|-------------|----------|----------------------|--------------------|
| admin1      | admins   | admin1@acme.local    | ADMIN1_PASSWORD    |
| editor1     | editors  | editor1@acme.local   | EDITOR_PASSWORD    |
| editor2     | editors  | editor2@acme.local   | EDITOR_PASSWORD    |
| viewer1     | viewers  | viewer1@acme.local   | VIEWER_PASSWORD    |
| viewer2     | viewers  | viewer2@acme.local   | VIEWER_PASSWORD    |

## Accès Itadaki

- URL : `https://itadaki.acme.local`
- Ajouter `itadaki.acme.local` dans `/etc/hosts` pointant vers l'IP du nœud K3s

## Compte admin LDAP (service)

- DN : `cn=admin,dc=acme,dc=local`
- Mot de passe : `kubectl get secret ldap-secret -n services -o jsonpath='{.data.LDAP_ADMIN_PASSWORD}' | base64 -d`

## Notes pour le jury

1. Pour tester le blocage réseau : `make test-netpol`
2. Pour visualiser les flux réseau : `make hubble` puis ouvrir l'UI Hubble.
3. Pour déclencher un backup immédiat : `make velero-backup-now`
4. Pour lister les backups : `make velero-list`
