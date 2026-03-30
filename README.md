# LiveKit-Ubuntu-24.04
# LiveKit Production Setup — Ubuntu 24.04

A fully automated production installer for **LiveKit**, **Coturn**, **Nginx**, **SSL**, and **LiveKit Egress** on a single Ubuntu 24.04 server with two IP addresses.

Designed and tested for environments where WebRTC traffic is filtered or restricted — such as Iran — with TURN over port 443 (TCP + UDP) as the primary relay strategy.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Single Ubuntu 24.04 Server               │
│                                                             │
│   IP1 (194.x.x.x)              IP2 (45.x.x.x)              │
│   call.example.com             call-turn.example.com        │
│                                                             │
│   ┌─────────────┐              ┌─────────────────────────┐  │
│   │    Nginx    │              │        Coturn           │  │
│   │  :80  HTTP  │              │  :443  TURN/TLS TCP+UDP │  │
│   │  :443 WSS   │              │  :3478 TURN standard    │  │
│   └──────┬──────┘              │  :49152-65535 UDP relay │  │
│          │                     └─────────────────────────┘  │
│   ┌──────▼──────┐                                           │
│   │   LiveKit   │              ┌─────────────────────────┐  │
│   │  :7880 int  │              │    LiveKit Egress       │  │
│   │  :7881 RTC  │              │    (Docker container)   │  │
│   └──────┬──────┘              └─────────────────────────┘  │
│          │                                                   │
│   ┌──────▼──────┐                                           │
│   │    Redis    │                                           │
│   │  :6379 int  │                                           │
│   └─────────────┘                                           │
└─────────────────────────────────────────────────────────────┘
```

---

## What the script does

### System preparation
- Updates and upgrades all system packages
- Installs all required dependencies
- Sets **timezone to UTC** (required for time-based HMAC TURN credentials)
- Enables **chrony** for NTP clock synchronization — prevents TURN auth failures caused by clock drift
- Applies kernel tuning parameters for 100+ simultaneous calls
- Enables **BBR** congestion control for better TCP throughput and lower latency
- Optimizes UDP buffer sizes for direct WebRTC media
- Increases file descriptor limits

### Security
- Configures **UFW firewall** with the exact ports needed
- Sets up **fail2ban** with:
  - Coturn jail — blocks IPs with repeated 401 TURN auth failures
  - Nginx jail — protects the WSS signaling endpoint
- Adds **Nginx rate limiting** — 30 connections per minute per IP on the WSS endpoint
- All sensitive config files are `chmod 600`

### SSL certificates
- Validates DNS records before attempting certificate issuance
- Obtains **Let's Encrypt SSL** certificates via `certbot --standalone` (not `--nginx`) — required when two IPs share one server
- Configures automatic renewal with hooks:
  - `pre` — stops Nginx before renewal
  - `post` — starts Nginx after renewal
  - `deploy` — copies new cert to Coturn and reloads it
  - `deploy` — restarts LiveKit after renewal

### Coturn (TURN server)
- Binds exclusively to the **second IP** — no conflict with Nginx
- Configures TURN/TLS on **port 443** (TCP + UDP) — bypasses most firewalls
- Configures standard TURN on **port 3478**
- Uses **HMAC shared secret** authentication (time-based credentials)
- Sets `relay-ip` explicitly to prevent relay on wrong interface
- Cipher list includes both **RSA and ECDSA** — required since Let's Encrypt issues ECDSA certs
- Blocks relay to private IP ranges (security)
- Grants `cap_net_bind_service` capability so Coturn can bind port 443 without root

### LiveKit Server
- Downloads the correct binary (format: `livekit_VERSION_linux_amd64.tar.gz`)
- Creates a dedicated system user `livekit`
- Generates initial **HMAC TURN credentials** and injects them into config
- Configures `rtc.turn_servers` pointing to Coturn — **not** the `turn:` block which would conflict with Coturn on port 443
- Installs as a **systemd service** with auto-restart
- Optionally configures **webhook** URLs for PHP backend event delivery

### TURN credential refresh
- HMAC credentials are **time-based and expire after 24 hours**
- A **cron job** runs daily at 3 AM UTC:
  - Generates new HMAC username and password
  - Updates `config.yaml` in-place
  - Restarts LiveKit

### Nginx
- Handles ACME challenges for **both domains** on port 80
- Proxies **WSS** (WebSocket Secure) to LiveKit on the first IP
- Applies rate limiting on the signaling endpoint
- Compatible with **nginx 1.24** (`listen ... ssl http2` not `http2 on`)

### LiveKit Egress
- Installs Docker
- Runs `livekit/egress:latest` as a Docker container
- Config file is `chmod 644` — required since Docker reads it as an internal container user
- Recording output goes to `/var/lib/livekit-egress/recordings` (persistent across reboots, unlike `/tmp`)

### livekit-cli
- Downloads the correct binary (format: `lk_VERSION_linux_amd64.tar.gz`)
- Configures the project using livekit-cli v2 syntax (`lk project add NAME`)

### Final verification
- Checks all service statuses
- Tests SSL renewal with `certbot renew --dry-run`
- Generates a valid TURN test credential for immediate use with trickle-ice
- Prints all key values to terminal (also saved to `/etc/livekit/.secrets`)

---

## Requirements

- Ubuntu 24.04 LTS
- Root access
- Two public IP addresses on the same server
- Two DNS A records pointing to the correct IPs **before running the script**
- Ports open: `22`, `80`, `443` (TCP+UDP), `3478` (TCP+UDP), `7881` (TCP), `49152–65535` (UDP)

---

## Usage

```bash
chmod +x livekit-install.sh
sudo ./livekit-install.sh
```

The script will interactively ask for:

| Input | Example |
|---|---|
| IP1 (LiveKit) | `194.62.55.250` |
| IP2 (TURN) | `45.94.4.203` |
| LiveKit domain | `call.example.com` |
| TURN domain | `call-turn.example.com` |
| SSL email | `admin@example.com` |
| Webhook URLs | One per line, empty Enter to finish |

All generated secrets are saved to `/etc/livekit/.secrets`.

---

## TURN credentials for clients

Since TURN credentials are HMAC-based, generate them server-side for each session. Example in Bash:

```bash
TURN_SECRET=$(grep static-auth-secret /etc/turnserver.conf | cut -d'=' -f2)
TIMESTAMP=$(( $(date +%s) + 86400 ))
USERNAME="${TIMESTAMP}:user"
PASSWORD=$(echo -n "$USERNAME" | openssl dgst -sha1 -hmac "$TURN_SECRET" -binary | base64)
```

Example in PHP:

```php
function getTurnCredentials(string $secret, string $user = 'user'): array {
    $timestamp = time() + 86400;
    $username  = "{$timestamp}:{$user}";
    $password  = base64_encode(hash_hmac('sha1', $username, $secret, true));
    return ['username' => $username, 'password' => $password];
}
```

Example in Dart (Flutter):

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';

Map<String, String> getTurnCredentials(String turnSecret) {
  final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 86400;
  final username  = '$timestamp:user';
  final hmac      = Hmac(sha1, utf8.encode(turnSecret));
  final password  = base64.encode(hmac.convert(utf8.encode(username)).bytes);
  return {'username': username, 'password': password};
}
```

---

## When is TURN used?

WebRTC uses ICE and tries candidates in order:

1. **Direct UDP** — fastest, used when both peers have open UDP
2. **Direct TCP** — fallback when UDP is blocked
3. **TURN relay** — used when direct connection is impossible

TURN is triggered by:
- UDP filtering (common on Iranian mobile networks)
- Symmetric NAT (enterprise/corporate routers)
- Strict firewalls (only ports 80/443 open)
- ISP-level UDP restrictions
- `force_relay: true` in LiveKit config

---

## File structure after installation

```
/etc/livekit/
  config.yaml          # LiveKit server config
  .secrets             # All generated keys and secrets (chmod 600)

/etc/turnserver.conf   # Coturn config

/etc/livekit-egress/
  config.yaml          # Egress config (chmod 644)

/var/lib/livekit-egress/
  recordings/          # Egress output (persistent)

/usr/local/bin/
  livekit-server       # LiveKit binary
  lk                   # livekit-cli binary
  livekit-turn-refresh.sh  # TURN credential refresh script

/etc/cron.d/
  livekit-turn-refresh # Daily cron at 3 AM UTC

/etc/letsencrypt/renewal-hooks/
  pre/stop-nginx.sh
  post/start-nginx.sh
  deploy/coturn-reload.sh
  deploy/livekit-restart.sh

/etc/fail2ban/
  jail.d/coturn.conf
  jail.d/nginx-livekit.conf
  filter.d/coturn.conf
```

---

## License

MIT

