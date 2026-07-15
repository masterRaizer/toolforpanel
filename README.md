# Remnawave Panel 2.8.0 Installer

One-click installer for [Remnawave](https://remnawave.com) Panel 2.8.0.

## Quick Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/masterRaizer/toolforpanel/main/remnawave-install.sh)
```

## Non-Interactive

```bash
bash <(curl -Ls https://raw.githubusercontent.com/masterRaizer/toolforpanel/main/remnawave-install.sh) install panel.example.com sub.example.com
```

## After Install

1. Open panel URL in browser
2. Create superadmin account
3. Go to Settings → API Tokens → create token
4. Edit /opt/remnawave/subscription/.env and set REMNAWAVE_API_TOKEN
5. cd /opt/remnawave/subscription && docker compose restart

## Components

- Remnawave Panel 2.8.0
- PostgreSQL 18.4
- Valkey (Redis)
- Nginx + SSL (auto via acme.sh)
- Subscription Page
