# Keycloak realm configuration

[`banking-realm.json`](./banking-realm.json) is the reviewed definition of the
`banking` realm. [`configure_realm.py`](./configure_realm.py) applies it through
the Keycloak admin API. It creates anything missing and puts any setting the file
covers back to the file's value. It changes nothing else in the realm.

```sh
python keycloak/configure_realm.py --dry-run          # show what would change
python keycloak/configure_realm.py --env-file techbleat-global-bank-backend/.env
```

The file contains no secrets. Keycloak generates the `banking-provisioner`
secret, and `--env-file` copies it into a git-ignored `.env` without printing it.

## Settings

| Variable | Default | Deployed value |
|---|---|---|
| `KEYCLOAK_URL` | `http://localhost:8080` | Keycloak admin URL reachable from where you run the script |
| `KEYCLOAK_ADMIN_USERNAME` | `admin` | Master-realm admin |
| `KEYCLOAK_ADMIN_PASSWORD` | prompted | From your secret store; do not put it in shell history |
| `FRONTEND_URL` | `http://localhost:3000` | `https://<your-domain>`: an exact origin, no wildcard |
| `KEYCLOAK_SSL_REQUIRED` | `external` | `all` |
| `KEYCLOAK_VERIFY_EMAIL` | `false` | `true` once SMTP is configured in the realm |

## What it enforces

| Area | Setting | Why |
|---|---|---|
| Browser login | `banking-frontend` is public, standard flow only, PKCE `S256`; implicit, password and service-account grants off | Authorization Code with PKCE is the only login path (A3) |
| Redirects | Redirect URI `FRONTEND_URL/`, web origin and post-logout URI `FRONTEND_URL` | No wildcards, so codes and tokens cannot be sent to another site |
| Token audience | Audience mapper adds `banking-api` | The APIs reject tokens issued for anything else |
| Token roles | `fullScopeAllowed: false`; scope limited to the three banking roles | Frontend tokens carry no admin or unrelated client roles |
| Provisioning | `banking-provisioner` service account and scope: `realm-management` → `manage-users` only | User service can create users and set passwords but not change realm or client configuration |
| Identity | `editUsernameAllowed: false`, unique emails, self-registration off | The bank account is bound to `preferred_username`; sign-up goes through the user service |
| Passwords | Length 12–128, not username or email, last 3 not reused | |
| Brute force | Lock out after 5 failures, wait increasing by 60 s up to 15 min | Limits account takeover by password guessing |
| Sessions | 5-minute access tokens, 30-minute idle, 8-hour max, refresh tokens single-use | Limits the window for a stolen token |
| Audit | Login and admin events on, kept 30 days; admin event bodies off | Evidence for incident response without storing request bodies |

## Known limitations

- `manage-users` lets the provisioner assign any realm role, including
  `banking-transact`. If the user service were compromised, it could grant
  itself transaction rights. Keycloak fine-grained admin permissions can
  restrict this further.
- Email verification stays off until SMTP is configured. Until then, an email
  address is not proven to belong to the person who registered it.
- Self-service password reset needs SMTP as well.
