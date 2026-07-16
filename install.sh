#!/bin/bash

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

# генерация UUID, генерация пары для vless, reality   (https://xtls.github.io/ru/document/command.html) - дока по командам
echo "Генерация UUID и ключей x25519..."
#UUID=$(xray uuid)
UUID=$(/usr/local/bin/xray uuid)  # заменил на абсолютный путь
echo "Сгенерированный UUID: $UUID"

# id для разных клиентов (передумал, для одного)
SHORTSID=$(openssl rand -hex 8)

# xray x25519 >> /usr/local/etc/xray/.keys
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

# конфиг (по примерам из xray-examples, не по доке, по доке - не работает)
# touch /usr/local/etc/xray/config.json
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
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "level": 0,
            "email": "main"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "cloudflare.com:443",
          "xver": 0,
          "serverNames": [
            "cloudflare.com",
            "www.cloudflare.com"
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

# Вывод данных
echo "========================================================="
echo "UUID: $UUID"
echo "PublicKey: $PUBLIC_KEY"
echo "========================================================="

# Получение ip
ip=$(curl -4 -s ifconfig.me)
if [ $? -eq 0 ] && [ -n "$ip" ]; then
echo "ок! IP-адрес: $ip"
else
  echo "ошибка. не сработал (curl -4 -s ifconfig.me)"
  exit 1
fi

protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)

# VLESS-ссылка (https://xtls.github.io/ru/config/outbounds/vless.html)
link="$protocol://$UUID@$ip:$port?security=reality&sni=$sni&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORTSID&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#main"

# записываем данные в файл
cat <<EOF > /root/xray-users.txt
UUID: $UUID
PublicKey: $PUBLIC_KEY
ShortId: $SHORTSID
Link: $link
EOF
chmod 600 /root/xray-users.txt

echo ""
echo "vless ссылка:"
echo "$link"
echo ""
echo "QR-код:"
echo "${link}" | qrencode -t ansiutf8
echo ""

