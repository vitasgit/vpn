#!/bin/bash
set -e

# --- vless-reality ---
PORT_REALITY=443
SNI_REALITY="cdnjs.cloudflare.com"

# --- vless-xhttp (полностью независимый inbound, свой порт/ключи/SNI) ---
PORT_XHTTP=2053
SNI_XHTTP="cdnjs.cloudflare.com"

# Включаем bbr
bbr=$(sysctl -a | grep net.ipv4.tcp_congestion_control)
if [ "$bbr" = "net.ipv4.tcp_congestion_control = bbr" ]; then
echo "bbr уже включен"
else
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
echo "bbr включен"
fi

# Xray-install (official), basic usage
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# останавливаем для редактирования конфигов
systemctl stop xray

# генерация UUID, shortId и пар x25519 отдельно для каждого пользователя
# (https://xtls.github.io/ru/document/command.html)
echo "Генерация UUID и ключей x25519..."

UUID_REALITY=$(/usr/local/bin/xray uuid)
UUID_XHTTP=$(/usr/local/bin/xray uuid)
echo "UUID vless-reality: $UUID_REALITY"
echo "UUID vless-xhttp:   $UUID_XHTTP"

SHORTID_REALITY=$(openssl rand -hex 8)
SHORTID_XHTTP=$(openssl rand -hex 8)

KEY_PAIR_REALITY=$(/usr/local/bin/xray x25519)
PRIVATE_KEY_REALITY=$(echo "$KEY_PAIR_REALITY" | grep -i 'private' | awk '{print $NF}')
PUBLIC_KEY_REALITY=$(echo "$KEY_PAIR_REALITY" | grep -iE 'password|public' | awk '{print $NF}')

KEY_PAIR_XHTTP=$(/usr/local/bin/xray x25519)
PRIVATE_KEY_XHTTP=$(echo "$KEY_PAIR_XHTTP" | grep -i 'private' | awk '{print $NF}')
PUBLIC_KEY_XHTTP=$(echo "$KEY_PAIR_XHTTP" | grep -iE 'password|public' | awk '{print $NF}')

echo "vless-reality — Private Key: $PRIVATE_KEY_REALITY / Public Key: $PUBLIC_KEY_REALITY"
echo "vless-xhttp   — Private Key: $PRIVATE_KEY_XHTTP / Public Key: $PUBLIC_KEY_XHTTP"

# Проверка, что ключи не пустые
if [ -z "$PRIVATE_KEY_REALITY" ] || [ -z "$PUBLIC_KEY_REALITY" ] || [ -z "$PRIVATE_KEY_XHTTP" ] || [ -z "$PUBLIC_KEY_XHTTP" ]; then
    echo "Ошибка: не удалось сгенерировать или распарсить ключи x25519"
    echo "vless-reality: $KEY_PAIR_REALITY"
    echo "vless-xhttp:   $KEY_PAIR_XHTTP"
    exit 1
fi

# конфиг: два полностью независимых inbound'а на разных портах.
# У каждого свой privateKey/shortId/SNI — правки одного никак не затрагивают другой.
cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": $PORT_REALITY,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID_REALITY",
            "flow": "xtls-rprx-vision",
            "level": 0,
            "email": "vless-reality"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI_REALITY:443",
          "xver": 0,
          "serverNames": [
            "$SNI_REALITY"
          ],
          "privateKey": "$PRIVATE_KEY_REALITY",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "$SHORTID_REALITY"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "tag": "vless-xhttp",
      "listen": "0.0.0.0",
      "port": $PORT_XHTTP,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID_XHTTP",
            "level": 0,
            "email": "vless-xhttp"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI_XHTTP:443",
          "xver": 0,
          "serverNames": [
            "$SNI_XHTTP"
          ],
          "privateKey": "$PRIVATE_KEY_XHTTP",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "$SHORTID_XHTTP"
          ]
        },
        "xhttpSettings": {
          "path": "/",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 3,
        "connIdle": 180
      }
    }
  }
}
EOF

# Проверка JSON
if ! jq empty /usr/local/etc/xray/config.json 2>/dev/null; then
    echo "ошибка json"
    exit 1
fi

# Перезапуск и включение автозагрузки Xray
systemctl daemon-reload
systemctl restart xray
systemctl enable xray

# проверка что Xray работает
if systemctl is-active --quiet xray; then
    echo "ок - Xray работает"
else
    echo "xray служба не работает!!!  journalctl -u xray -n 50 --no-pager"
    exit 1
fi

# открываем оба порта в ufw (если ufw активен)
if command -v ufw >/dev/null 2>&1; then
    ufw allow "$PORT_REALITY"/tcp >/dev/null 2>&1 || true
    ufw allow "$PORT_XHTTP"/tcp >/dev/null 2>&1 || true
    echo "ufw: открыты порты $PORT_REALITY и $PORT_XHTTP"
fi

# Получение ip
ip=$(curl -4 -s ifconfig.me)
if [ $? -eq 0 ] && [ -n "$ip" ]; then
echo "ок! IP-адрес: $ip"
else
  echo "ошибка. не сработал (curl -4 -s ifconfig.me)"
  exit 1
fi

# VLESS-ссылки (https://xtls.github.io/ru/config/outbounds/vless.html)
LINK_REALITY="vless://$UUID_REALITY@$ip:$PORT_REALITY?security=reality&sni=$SNI_REALITY&fp=chrome&pbk=$PUBLIC_KEY_REALITY&sid=$SHORTID_REALITY&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#vless-reality"
LINK_XHTTP="vless://$UUID_XHTTP@$ip:$PORT_XHTTP?security=reality&sni=$SNI_XHTTP&fp=chrome&pbk=$PUBLIC_KEY_XHTTP&sid=$SHORTID_XHTTP&spx=/&type=xhttp&path=/&encryption=none#vless-xhttp"

# записываем данные в файл
cat <<EOF > /root/xray-users.txt
=== vless-reality (tcp + vision), порт $PORT_REALITY ===
UUID: $UUID_REALITY
PublicKey: $PUBLIC_KEY_REALITY
ShortId: $SHORTID_REALITY
SNI: $SNI_REALITY
Link: $LINK_REALITY

=== vless-xhttp, порт $PORT_XHTTP ===
UUID: $UUID_XHTTP
PublicKey: $PUBLIC_KEY_XHTTP
ShortId: $SHORTID_XHTTP
SNI: $SNI_XHTTP
Link: $LINK_XHTTP
EOF
chmod 600 /root/xray-users.txt

echo ""
echo "========================================================="
echo "vless-reality ссылка (порт $PORT_REALITY):"
echo "$LINK_REALITY"
echo ""
echo "QR-код vless-reality:"
echo "${LINK_REALITY}" | qrencode -t ansiutf8
echo "========================================================="
echo ""
echo "vless-xhttp ссылка (порт $PORT_XHTTP):"
echo "$LINK_XHTTP"
echo ""
echo "QR-код vless-xhttp:"
echo "${LINK_XHTTP}" | qrencode -t ansiutf8
echo "========================================================="
