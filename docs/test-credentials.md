# Credentials de test — ACME Corp (jury)

> Ces comptes sont créés automatiquement au bootstrap LDAP.
> À utiliser pour la démo Wiki.js.

## Comptes Wiki.js / LDAP

| Utilisateur | Mot de passe  | Groupe   | Email                |
|-------------|---------------|----------|----------------------|
| admin1      | Admin1234!    | admins   | admin1@acme.local    |
| editor1     | Editor1234!   | editors  | editor1@acme.local   |
| editor2     | Editor1234!   | editors  | editor2@acme.local   |
| viewer1     | Viewer1234!   | viewers  | viewer1@acme.local   |
| viewer2     | Viewer1234!   | viewers  | viewer2@acme.local   |

## Accès Wiki.js

- URL : `https://wiki.acme.local`
- Ajouter `wiki.acme.local` dans `/etc/hosts` pointant vers l'IP du nœud K3s

## Compte admin LDAP (service)

- DN : `cn=admin,dc=acme,dc=local`
- Mot de passe : valeur de `LDAP_ADMIN_PASSWORD` dans `.env`

## Notes pour le jury

1. Wiki.js demande un wizard de setup au **premier boot** — se connecter une fois manuellement avant la démo.
2. L'authentification LDAP se configure dans Wiki.js > Administration > Authentication > LDAP.
3. Pour tester le blocage réseau : `make test-netpol`
4. Pour visualiser les flux réseau : `make hubble` puis ouvrir l'UI Hubble.
