#!/bin/bash
set -e

SNI="cdnjs.cloudflare.com"
PORT=443
XHTTP_PORT=10086   # внутренний loopback-порт для второго инбаунда (наружу не торчит)

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

# генерация UUID для двух пользователей, короткого ID и пары x25519  (https://xtls.github.io/ru/document/command.html)
echo "Генерация UUID и ключей x25519..."
UUID_REALITY=$(/usr/local/bin/xray uuid)   # пользователь 1: vless-reality (raw+vision)
UUID_XHTTP=$(/usr/local/bin/xray uuid)     # пользователь 2: vless-xhttp
echo "UUID vless-reality: $UUID_REALITY"
echo "UUID vless-xhttp:   $UUID_XHTTP"

SHORTSID=$(openssl rand -hex 8)
# путь для xhttp-инбаунда, по которому fallback различает трафик двух пользователей на одном порту
XHTTP_PATH="/$(openssl rand -hex 8)"

KEY_PAIR=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep -i 'private' | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep -iE 'password|public' | awk '{print $NF}')
echo "Private Key (для сервера): $PRIVATE_KEY"
echo "Public Key (для клиента): $PUBLIC_KEY"

# Проверка, что ключи не пустые
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "Ошибка: не удалось сгенерировать или распарсить ключи x25519"
    echo "Вывод команды xray x25519:"
    echo "$KEY_PAIR"
    exit 1
fi

# конфиг: два инбаунда на одном порту 443.
# Наружу торчит только "vless-reality" (raw+vision+reality). Если пришедший поток
# после reality-расшифровки не парсится как обычный vless-заголовок, а оказывается
# HTTP-запросом на путь $XHTTP_PATH — xray через fallbacks перекидывает его на
# второй инбаунд "vless-xhttp", слушающий только на 127.0.0.1. Второй инбаунд
# отдельного TLS/reality не поднимает — он получает уже расшифрованный поток.
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
      "port": $PORT,
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
        "decryption": "none",
        "fallbacks": [
          {
            "path": "$XHTTP_PATH",
            "dest": "127.0.0.1:$XHTTP_PORT",
            "xver": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "$SHORTSID"
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
      "listen": "127.0.0.1",
      "port": $XHTTP_PORT,
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
        "security": "none",
        "xhttpSettings": {
          "path": "$XHTTP_PATH",
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

# Получение ip
ip=$(curl -4 -s ifconfig.me)
if [ $? -eq 0 ] && [ -n "$ip" ]; then
echo "ок! IP-адрес: $ip"
else
  echo "ошибка. не сработал (curl -4 -s ifconfig.me)"
  exit 1
fi

# VLESS-ссылки (https://xtls.github.io/ru/config/outbounds/vless.html)
LINK_REALITY="vless://$UUID_REALITY@$ip:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORTSID&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#vless-reality"
LINK_XHTTP="vless://$UUID_XHTTP@$ip:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORTSID&spx=/&type=xhttp&path=$XHTTP_PATH&encryption=none#vless-xhttp"

# записываем данные в файл
cat <<EOF > /root/xray-users.txt
=== vless-reality (tcp + vision) ===
UUID: $UUID_REALITY
PublicKey: $PUBLIC_KEY
ShortId: $SHORTSID
SNI: $SNI
Link: $LINK_REALITY

=== vless-xhttp ===
UUID: $UUID_XHTTP
PublicKey: $PUBLIC_KEY
ShortId: $SHORTSID
SNI: $SNI
Path: $XHTTP_PATH
Link: $LINK_XHTTP
EOF
chmod 600 /root/xray-users.txt

echo ""
echo "========================================================="
echo "vless-reality ссылка:"
echo "$LINK_REALITY"
echo ""
echo "QR-код vless-reality:"
echo "${LINK_REALITY}" | qrencode -t ansiutf8
echo "========================================================="
echo ""
echo "vless-xhttp ссылка:"
echo "$LINK_XHTTP"
echo ""
echo "QR-код vless-xhttp:"
echo "${LINK_XHTTP}" | qrencode -t ansiutf8
echo "========================================================="
