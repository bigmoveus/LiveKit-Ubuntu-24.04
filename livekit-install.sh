#!/bin/bash
set -euo pipefail

# ============================================================
# LiveKit Production Auto-Install Script
# Ubuntu 24.04 -- Two IPs on one server
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
TEAL='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${TEAL}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
sep()  { echo -e "${BLUE}------------------------------------------------------------${NC}"; }

make_turn_creds() {
    local secret="$1" user="$2"
    local ts=$(( $(date +%s) + 86400 ))
    local tu="${ts}:${user}"
    local tp=$(echo -n "$tu" | openssl dgst -sha1 -hmac "$secret" -binary | base64)
    echo "${tu}|${tp}"
}

[[ $EUID -ne 0 ]] && err "This script must be run as root"

clear
echo -e "${BOLD}"
cat << 'BANNER'
  _     _           _  ___ _
 | |   (_)_   _____| |/ (_) |_
 | |   | \ \ / / _ \ ' /| | __|
 | |___| |\ V /  __/ . \| | |_
 |_____|_| \_/ \___|_|\_\_|\__|

 Production Auto-Install -- Livekit
BANNER
echo -e "${NC}"
sep

# ============================================================
# Input
# ============================================================
echo -e "\n${BOLD}Enter server information:${NC}\n"
read -p "  IP1 (LiveKit)  e.g. 194.62.55.250         : " IP1
read -p "  IP2 (TURN)     e.g. 45.94.4.203           : " IP2
read -p "  LiveKit domain e.g. livekit.yourdomain.com     : " DOMAIN1
read -p "  TURN domain    e.g. livekit-turn.yourdomain: " DOMAIN2
read -p "  SSL email      e.g. youremail@yourdomain.com      : " EMAIL

echo ""
echo -e "  ${BOLD}Webhook URLs${NC} (PHP backend endpoints -- one URL per line -- empty Enter to finish):"
WEBHOOK_URLS=()
while true; do
    read -p "  Webhook URL (or Enter to finish): " WH_URL
    [ -z "$WH_URL" ] && break
    WEBHOOK_URLS+=("$WH_URL")
done

echo ""
sep
echo -e "  IP1     : ${TEAL}$IP1${NC}"
echo -e "  IP2     : ${TEAL}$IP2${NC}"
echo -e "  DOMAIN1 : ${TEAL}$DOMAIN1${NC}"
echo -e "  DOMAIN2 : ${TEAL}$DOMAIN2${NC}"
echo -e "  EMAIL   : ${TEAL}$EMAIL${NC}"
if [ ${#WEBHOOK_URLS[@]} -gt 0 ]; then
    echo -e "  WEBHOOK :"
    for WU in "${WEBHOOK_URLS[@]}"; do echo -e "    ${TEAL}$WU${NC}"; done
else
    echo -e "  WEBHOOK : ${TEAL}(none)${NC}"
fi
sep
read -p "Confirm and continue? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && err "Cancelled"

# ============================================================
# Generate secrets
# ============================================================
log "Generating API Key and TURN Secret..."
TURN_SECRET=$(openssl rand -hex 32)
API_KEY="API$(openssl rand -hex 6 | tr '[:lower:]' '[:upper:]')"
API_SECRET=$(openssl rand -hex 32)

echo ""
sep
echo -e "  API Key     : ${GREEN}$API_KEY${NC}"
echo -e "  API Secret  : ${GREEN}$API_SECRET${NC}"
echo -e "  TURN Secret : ${GREEN}$TURN_SECRET${NC}"
sep

mkdir -p /etc/livekit
cat > /etc/livekit/.secrets << EOF
API_KEY=$API_KEY
API_SECRET=$API_SECRET
TURN_SECRET=$TURN_SECRET
DOMAIN1=$DOMAIN1
DOMAIN2=$DOMAIN2
IP1=$IP1
IP2=$IP2
EOF
chmod 600 /etc/livekit/.secrets
ok "Secrets saved to /etc/livekit/.secrets"
read -p "Press Enter to start installation..." _

# ============================================================
# STEP 1 -- Packages
# ============================================================
sep; log "Step 1 -- Installing packages..."; sep
apt update -y && apt upgrade -y
apt install -y curl wget git ufw nginx coturn redis-server certbot \
    dnsutils chrony fail2ban
ok "Packages installed"

# ============================================================
# STEP 2 -- UTC timezone + chrony
# Critical: HMAC TURN credentials are time-based
# If server clock drifts, TURN authentication will fail
# ============================================================
sep; log "Step 2 -- Setting UTC timezone and chrony..."; sep

timedatectl set-timezone UTC
systemctl enable chrony
systemctl restart chrony
sleep 2

CURRENT_TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
if [ "$CURRENT_TZ" = "UTC" ]; then
    ok "Timezone: UTC"
else
    warn "Timezone not set correctly: $CURRENT_TZ"
fi
ok "chrony (NTP sync) enabled"

# ============================================================
# STEP 3 -- Kernel tuning + BBR + UDP
# ============================================================
sep; log "Step 3 -- Kernel tuning..."; sep

if ! grep -q "LiveKit production tuning" /etc/sysctl.conf; then
    cat >> /etc/sysctl.conf << 'EOF'

# LiveKit production tuning
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.core.netdev_max_backlog=10000
net.core.somaxconn=65535
fs.file-max=1000000

# BBR congestion control -- better TCP throughput and latency
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# UDP optimization -- for direct WebRTC media
net.ipv4.udp_mem=65536 131072 262144
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
EOF
fi
sysctl -p > /dev/null 2>&1

BBR_CHECK=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
[ "$BBR_CHECK" = "bbr" ] && ok "BBR enabled" || warn "BBR not enabled -- kernel may not support it"

if ! grep -q "nofile 1000000" /etc/security/limits.conf; then
    cat >> /etc/security/limits.conf << 'EOF'
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF
fi
ok "Kernel tuning done"

# ============================================================
# STEP 4 -- Firewall
# ============================================================
sep; log "Step 4 -- Firewall..."; sep
ufw --force reset > /dev/null 2>&1
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow 3478/tcp
ufw allow 3478/udp
ufw allow 7881/tcp
ufw allow 49152:65535/udp
ufw --force enable
ok "Firewall configured"

# ============================================================
# STEP 5 -- fail2ban
# Protection against Coturn brute force and Nginx abuse
# ============================================================
sep; log "Step 5 -- fail2ban..."; sep

# Coturn jail -- block IPs with repeated 401 errors
cat > /etc/fail2ban/jail.d/coturn.conf << 'EOF'
[coturn]
enabled  = true
port     = 3478,443
protocol = udp
filter   = coturn
logpath  = /var/log/coturn/turnserver.log
maxretry = 5
bantime  = 3600
findtime = 600
EOF

cat > /etc/fail2ban/filter.d/coturn.conf << 'EOF'
[Definition]
failregex = <HOST>.*\(401\)
ignoreregex =
EOF

# Nginx jail -- protection for WSS signaling endpoint
cat > /etc/fail2ban/jail.d/nginx-livekit.conf << 'EOF'
[nginx-livekit]
enabled  = true
port     = 443
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log
maxretry = 10
bantime  = 1800
findtime = 300
EOF

systemctl enable fail2ban
systemctl restart fail2ban
ok "fail2ban configured"

# ============================================================
# STEP 6 -- Redis
# ============================================================
sep; log "Step 6 -- Redis..."; sep
sed -i 's/^bind .*/bind 127.0.0.1/' /etc/redis/redis.conf
if ! grep -q "maxmemory 512mb" /etc/redis/redis.conf; then
    cat >> /etc/redis/redis.conf << 'EOF'
maxmemory 512mb
maxmemory-policy allkeys-lru
EOF
fi
systemctl enable redis-server
systemctl restart redis-server
ok "Redis started"

# ============================================================
# STEP 7 -- Nginx initial (for ACME challenge)
# ============================================================
sep; log "Step 7 -- Nginx initial config..."; sep
rm -f /etc/nginx/sites-enabled/default
mkdir -p /var/www/html/.well-known/acme-challenge
chown -R www-data:www-data /var/www/html

cat > /etc/nginx/sites-available/livekit << EOF
server {
    listen ${IP1}:80;
    server_name ${DOMAIN1};
    root /var/www/html;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
        default_type "text/plain";
        try_files \$uri =404;
    }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen ${IP2}:80;
    server_name ${DOMAIN2};
    root /var/www/html;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
        default_type "text/plain";
        try_files \$uri =404;
    }
    location / { return 444; }
}
EOF

ln -sf /etc/nginx/sites-available/livekit /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx
ok "Nginx initial config done"

# ============================================================
# STEP 8 -- DNS check before SSL
# certbot will fail silently if DNS is not pointing to this server
# ============================================================
sep; log "Step 8 -- Checking DNS..."; sep

check_dns() {
    local domain="$1" expected_ip="$2"
    local resolved
    resolved=$(dig +short "$domain" | head -1)
    if [ "$resolved" = "$expected_ip" ]; then
        ok "DNS: $domain -> $resolved"
    else
        warn "DNS: $domain -> '$resolved' (expected: $expected_ip)"
        warn "DNS may not have propagated yet. Wait and re-run if needed."
        read -p "Continue anyway? [y/N]: " DNS_CONFIRM
        [[ "$DNS_CONFIRM" != "y" && "$DNS_CONFIRM" != "Y" ]] && err "Cancelled"
    fi
}

check_dns "$DOMAIN1" "$IP1"
check_dns "$DOMAIN2" "$IP2"

# ============================================================
# STEP 9 -- SSL with standalone
# Do NOT use --nginx: two IPs on one server causes conflict
# certbot --standalone temporarily binds port 80 itself
# ============================================================
sep; log "Step 9 -- Getting SSL certificates..."; sep
systemctl stop nginx

certbot certonly --standalone \
    -d "$DOMAIN1" --agree-tos --non-interactive --email "$EMAIL"

certbot certonly --standalone \
    -d "$DOMAIN2" --agree-tos --non-interactive --email "$EMAIL"

systemctl start nginx

# Ensure standalone is set in renewal configs
for CONF in \
    /etc/letsencrypt/renewal/${DOMAIN1}.conf \
    /etc/letsencrypt/renewal/${DOMAIN2}.conf; do
    [ -f "$CONF" ] && sed -i 's/authenticator = nginx/authenticator = standalone/' "$CONF" || true
done

# pre hook -- stop nginx before renewal
cat > /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh << 'EOF'
#!/bin/bash
systemctl stop nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh

# post hook -- start nginx after renewal
cat > /etc/letsencrypt/renewal-hooks/post/start-nginx.sh << 'EOF'
#!/bin/bash
systemctl start nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/post/start-nginx.sh

ok "SSL certificates obtained"

# ============================================================
# STEP 10 -- Coturn certs + deploy hooks
# ============================================================
sep; log "Step 10 -- Coturn certificates..."; sep
mkdir -p /etc/coturn/certs
cp /etc/letsencrypt/live/${DOMAIN2}/fullchain.pem /etc/coturn/certs/
cp /etc/letsencrypt/live/${DOMAIN2}/privkey.pem   /etc/coturn/certs/
chmod 640 /etc/coturn/certs/*.pem
chown root:turnserver /etc/coturn/certs/*.pem

# deploy hook -- copy cert and reload Coturn after renewal
cat > /etc/letsencrypt/renewal-hooks/deploy/coturn-reload.sh << EOF
#!/bin/bash
cp /etc/letsencrypt/live/${DOMAIN2}/fullchain.pem /etc/coturn/certs/fullchain.pem
cp /etc/letsencrypt/live/${DOMAIN2}/privkey.pem   /etc/coturn/certs/privkey.pem
chmod 640 /etc/coturn/certs/*.pem
chown root:turnserver /etc/coturn/certs/*.pem
systemctl reload coturn
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/coturn-reload.sh

# deploy hook -- restart LiveKit after renewal
cat > /etc/letsencrypt/renewal-hooks/deploy/livekit-restart.sh << 'EOF'
#!/bin/bash
systemctl restart livekit
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/livekit-restart.sh

ok "Coturn certs copied + deploy hooks configured"

# ============================================================
# STEP 11 -- Coturn config
# Important:
#   - No inline comments on value lines (coturn fails to parse)
#   - relay-ip is required
#   - cipher-list must include ECDSA (Let's Encrypt uses ECDSA)
# ============================================================
sep; log "Step 11 -- Coturn config..."; sep
cat > /etc/turnserver.conf << EOF
listening-ip=${IP2}
external-ip=${IP2}
relay-ip=${IP2}

listening-port=3478
tls-listening-port=443

min-port=49152
max-port=65535

fingerprint
use-auth-secret
static-auth-secret=${TURN_SECRET}

realm=${DOMAIN2}
server-name=${DOMAIN2}

cert=/etc/coturn/certs/fullchain.pem
pkey=/etc/coturn/certs/privkey.pem
cipher-list=ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384
no-tlsv1
no-tlsv1_1

no-multicast-peers
no-loopback-peers
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=169.254.0.0-169.254.255.255

proc-user=turnserver
proc-group=turnserver
EOF

mkdir -p /var/log/coturn
chown -R turnserver:turnserver /var/log/coturn
setcap cap_net_bind_service=+ep /usr/bin/turnserver
systemctl enable coturn
systemctl restart coturn
sleep 2
ok "Coturn started"

# ============================================================
# STEP 12 -- LiveKit Server binary
# Important: filename format is livekit_VERSION_linux_amd64.tar.gz
# ============================================================
sep; log "Step 12 -- Installing LiveKit Server..."; sep
cd /tmp
LIVEKIT_VERSION=$(curl -s https://api.github.com/repos/livekit/livekit/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
LIVEKIT_VER=${LIVEKIT_VERSION#v}

log "Downloading LiveKit ${LIVEKIT_VERSION}..."
wget -q "https://github.com/livekit/livekit/releases/download/${LIVEKIT_VERSION}/livekit_${LIVEKIT_VER}_linux_amd64.tar.gz"
tar -xzf livekit_${LIVEKIT_VER}_linux_amd64.tar.gz
mv livekit-server /usr/local/bin/livekit-server
chmod +x /usr/local/bin/livekit-server
rm -f livekit_${LIVEKIT_VER}_linux_amd64.tar.gz

useradd -r -s /bin/false livekit 2>/dev/null || true
mkdir -p /etc/livekit /var/log/livekit
chown livekit:livekit /var/log/livekit
ok "LiveKit installed"

# ============================================================
# STEP 13 -- LiveKit config
# Important:
#   - Do NOT use turn: section -- conflicts with Coturn on port 443
#   - Use rtc.turn_servers with HMAC credential
#   - Empty credential causes LiveKit to send TURN without auth
#   - HMAC credential expires after 24h -- cron job handles refresh
# ============================================================
sep; log "Step 13 -- LiveKit config..."; sep

CREDS=$(make_turn_creds "$TURN_SECRET" "livekit")
TURN_USER=$(echo "$CREDS" | cut -d'|' -f1)
TURN_PASS=$(echo "$CREDS" | cut -d'|' -f2)

cat > /etc/livekit/config.yaml << EOF
port: 7880
bind_addresses:
  - "127.0.0.1"

rtc:
  tcp_port: 7881
  port_range_start: 50100
  port_range_end: 60000
  use_external_ip: true
  turn_servers:
    - host: ${DOMAIN2}
      port: 443
      protocol: tls
      username: "${TURN_USER}"
      credential: "${TURN_PASS}"

keys:
  ${API_KEY}: ${API_SECRET}

redis:
  address: 127.0.0.1:6379

logging:
  level: info
  pion_level: error
  json: true
EOF

# Add webhook if URLs were provided
if [ ${#WEBHOOK_URLS[@]} -gt 0 ]; then
    {
        echo ""
        echo "webhook:"
        echo "  api_key: ${API_KEY}"
        echo "  urls:"
        for WU in "${WEBHOOK_URLS[@]}"; do
            echo "    - '${WU}'"
        done
    } >> /etc/livekit/config.yaml
    ok "Webhook configured with ${#WEBHOOK_URLS[@]} URL(s)"
fi

chmod 600 /etc/livekit/config.yaml
chown livekit:livekit /etc/livekit/config.yaml

cat > /etc/systemd/system/livekit.service << 'EOF'
[Unit]
Description=LiveKit Server
After=network.target redis.service

[Service]
Type=simple
User=livekit
Group=livekit
ExecStart=/usr/local/bin/livekit-server --config /etc/livekit/config.yaml
Restart=always
RestartSec=5
LimitNOFILE=1000000
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log/livekit

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable livekit
systemctl start livekit
sleep 3

if systemctl is-active --quiet livekit; then
    ok "LiveKit started"
else
    warn "LiveKit failed to start:"
    journalctl -u livekit -n 10 --no-pager || true
fi

# Cron job -- refresh TURN credential daily at 3 AM
# HMAC credentials expire after 24h
cat > /usr/local/bin/livekit-turn-refresh.sh << 'SCRIPT'
#!/bin/bash
source /etc/livekit/.secrets

TS=$(( $(date +%s) + 86400 ))
TURN_USER="${TS}:livekit"
TURN_PASS=$(echo -n "$TURN_USER" | openssl dgst -sha1 -hmac "$TURN_SECRET" -binary | base64)

sed -i "s|username:.*|username: \"${TURN_USER}\"|" /etc/livekit/config.yaml
sed -i "s|credential:.*|credential: \"${TURN_PASS}\"|" /etc/livekit/config.yaml

chmod 600 /etc/livekit/config.yaml
chown livekit:livekit /etc/livekit/config.yaml
systemctl restart livekit
SCRIPT
chmod +x /usr/local/bin/livekit-turn-refresh.sh
echo "0 3 * * * root /usr/local/bin/livekit-turn-refresh.sh" > /etc/cron.d/livekit-turn-refresh
ok "TURN credential refresh cron configured (daily at 3 AM UTC)"

# ============================================================
# STEP 14 -- Nginx final config with rate limiting
# Important: nginx 1.24 uses "listen ... ssl http2" not "http2 on"
# ============================================================
sep; log "Step 14 -- Nginx final config..."; sep
cat > /etc/nginx/sites-available/livekit << EOF
# Rate limit zone -- 30 new connections per minute per IP
limit_req_zone \$binary_remote_addr zone=livekit_ws:10m rate=30r/m;

server {
    listen ${IP1}:80;
    server_name ${DOMAIN1};
    root /var/www/html;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
        default_type "text/plain";
        try_files \$uri =404;
    }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen ${IP2}:80;
    server_name ${DOMAIN2};
    root /var/www/html;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
        default_type "text/plain";
        try_files \$uri =404;
    }
    location / { return 444; }
}
server {
    listen ${IP1}:443 ssl http2;
    server_name ${DOMAIN1};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN1}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN1}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;

    proxy_read_timeout 7200s;
    proxy_send_timeout 7200s;

    location / {
        limit_req zone=livekit_ws burst=20 nodelay;
        proxy_pass http://127.0.0.1:7880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_cache off;
    }
}
EOF

nginx -t && systemctl reload nginx
ok "Nginx final config applied"

# ============================================================
# STEP 15 -- Docker + Egress
# Important:
#   - Use /var/lib/livekit-egress/recordings NOT /tmp (cleared on reboot)
#   - egress config must be chmod 644 NOT 600
#     (Docker container reads it as its own internal user)
# ============================================================
sep; log "Step 15 -- Docker and Egress..."; sep
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | bash > /dev/null 2>&1
fi
systemctl enable docker
systemctl start docker

mkdir -p /etc/livekit-egress /var/lib/livekit-egress/recordings

cat > /etc/livekit-egress/config.yaml << EOF
api_key:    ${API_KEY}
api_secret: ${API_SECRET}
ws_url:     wss://${DOMAIN1}

redis:
  address: 127.0.0.1:6379

health_port:   9090
template_port: 7980

file_output:
  local_dir: /var/lib/livekit-egress/recordings

log_level: info
EOF

chmod 644 /etc/livekit-egress/config.yaml

cat > /etc/systemd/system/livekit-egress.service << 'EOF'
[Unit]
Description=LiveKit Egress
After=docker.service livekit.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker stop livekit-egress
ExecStartPre=-/usr/bin/docker rm livekit-egress
ExecStart=/usr/bin/docker run \
    --name livekit-egress \
    --rm \
    --network host \
    --cap-add SYS_ADMIN \
    -v /etc/livekit-egress:/config \
    -v /var/lib/livekit-egress/recordings:/var/lib/livekit-egress/recordings \
    -e EGRESS_CONFIG_FILE=/config/config.yaml \
    livekit/egress:latest

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable livekit-egress
systemctl start livekit-egress
ok "Egress started"

# ============================================================
# STEP 16 -- livekit-cli
# Important: filename format is lk_VERSION_linux_amd64.tar.gz
#            v2 command: lk project add NAME (not --name flag)
# ============================================================
sep; log "Step 16 -- livekit-cli..."; sep
cd /tmp
CLI_VERSION=$(curl -s https://api.github.com/repos/livekit/livekit-cli/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
CLI_VER=${CLI_VERSION#v}

log "Downloading livekit-cli ${CLI_VERSION}..."
wget -q "https://github.com/livekit/livekit-cli/releases/download/${CLI_VERSION}/lk_${CLI_VER}_linux_amd64.tar.gz"
tar -xzf lk_${CLI_VER}_linux_amd64.tar.gz
mv lk /usr/local/bin/
chmod +x /usr/local/bin/lk
rm -f lk_${CLI_VER}_linux_amd64.tar.gz

lk project add livekit-prod \
    --url "wss://${DOMAIN1}" \
    --api-key "$API_KEY" \
    --api-secret "$API_SECRET"
ok "livekit-cli installed"

# ============================================================
# STEP 17 -- Test SSL renewal
# ============================================================
sep; log "Step 17 -- Testing SSL renewal..."; sep
certbot renew --dry-run > /dev/null 2>&1 \
    && ok "SSL renewal test passed" \
    || warn "SSL renewal test failed -- run 'certbot renew --dry-run' manually"

# ============================================================
# Final status check
# ============================================================
sep
echo ""
echo -e "${BOLD}${GREEN}Installation complete!${NC}"
echo ""
echo -e "${BOLD}Service status:${NC}"
sep

check_svc() {
    if systemctl is-active --quiet "$1"; then
        echo -e "  ${GREEN}[OK]${NC}  $1"
    else
        echo -e "  ${RED}[ERR]${NC} $1"
    fi
}

check_svc nginx
check_svc coturn
check_svc livekit
check_svc livekit-egress
check_svc redis-server
check_svc fail2ban
check_svc chrony

sep
echo ""
echo -e "${BOLD}Security:${NC}"
sep
echo -e "  ${GREEN}[OK]${NC}  fail2ban    -- Coturn and Nginx brute force protection"
echo -e "  ${GREEN}[OK]${NC}  rate limit  -- 30 req/min per IP on WSS endpoint"
echo -e "  ${GREEN}[OK]${NC}  timezone    -- UTC (required for HMAC TURN auth)"
echo -e "  ${GREEN}[OK]${NC}  chrony      -- NTP clock sync"

sep
echo ""
echo -e "${BOLD}SSL Renewal hooks:${NC}"
sep
echo -e "  ${GREEN}[pre]${NC}    stop-nginx.sh"
echo -e "  ${GREEN}[post]${NC}   start-nginx.sh"
echo -e "  ${GREEN}[deploy]${NC} coturn-reload.sh"
echo -e "  ${GREEN}[deploy]${NC} livekit-restart.sh"
echo -e "  ${GREEN}[cron]${NC}   TURN credential refresh daily at 3 AM UTC"

sep
echo ""
echo -e "${BOLD}Key values -- also saved in /etc/livekit/.secrets:${NC}"
sep
echo -e "  WSS URL     : ${TEAL}wss://${DOMAIN1}${NC}"
echo -e "  TURN URL    : ${TEAL}turns:${DOMAIN2}:443${NC}"
echo -e "  API Key     : ${GREEN}${API_KEY}${NC}"
echo -e "  API Secret  : ${GREEN}${API_SECRET}${NC}"
echo -e "  TURN Secret : ${GREEN}${TURN_SECRET}${NC}"
if [ ${#WEBHOOK_URLS[@]} -gt 0 ]; then
    echo -e "  Webhook Key : ${GREEN}${API_KEY}${NC}"
    echo -e "  Webhook URLs:"
    for WU in "${WEBHOOK_URLS[@]}"; do
        echo -e "    ${TEAL}${WU}${NC}"
    done
fi

sep
echo ""
echo -e "${BOLD}Quick test:${NC}"
echo -e "  lk room create test-room"
echo -e "  lk room join --room test-room --identity test-cli \\"
echo -e "    --url ws://127.0.0.1:7880 \\"
echo -e "    --api-key ${API_KEY} --api-secret ${API_SECRET}"
echo ""
echo -e "${BOLD}TURN test (trickle-ice):${NC}"
TS_T=$(( $(date +%s) + 86400 ))
U_T="${TS_T}:testuser"
P_T=$(echo -n "$U_T" | openssl dgst -sha1 -hmac "$TURN_SECRET" -binary | base64)
echo -e "  URI:        ${YELLOW}turns:${DOMAIN2}:443${NC}"
echo -e "  Username:   ${YELLOW}${U_T}${NC}"
echo -e "  Password:   ${YELLOW}${P_T}${NC}"
echo ""
echo -e "${BOLD}Important files:${NC}"
echo -e "  /etc/livekit/config.yaml"
echo -e "  /etc/livekit/.secrets"
echo -e "  /etc/turnserver.conf"
echo -e "  /etc/livekit-egress/config.yaml"
echo -e "  /var/lib/livekit-egress/recordings"
echo ""
