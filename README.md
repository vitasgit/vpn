# vpn
скрипт по установке и настройке чистого xray-core. без панелей и прочего.
По умолчанию создается конфиг на одного пользователя с протоколом - VLESS, безопасность(маскрировка) - Reality (cloudflare.com:443), порт - 443.

# Минимальные требования (чистый xray-core)
Проверено на голом debian 13. На ubuntu есть риск, что 512 МБ не хватит.

- ОС: ubuntu/debian
- Ресурсы: 512 МБ ОЗУ, 2-3 ГБ диска

# Инструкция по настройке debian
Предпологается, что изначально debian пустой. Соответвенно, нужно установить минимальные пакеты.
 - wget, curl - для скачивания файлов, установки xray-core из репозитория
 - ufw - фаервол
 - qrencode, jq - для формирования qr-кодов и парсинга JSON конфигов
 
Алгоримт настройки:
```shell
    apt update && apt upgrade -y
    reboot
    apt install ufw wget curl qrencode jq -y
    # открываем порты для ssh, http, https
    ufw allow OpenSSH  # для ssh
    ufw allow 80/tcp
    ufw allow 443/tcp  # для xray reality
    ufw enable
    ufw status
```

Или одной командой:
```shell
apt update && apt install -y ufw && ufw allow OpenSSH && ufw allow 80/tcp && ufw allow 443/tcp && echo "y" | ufw enable && ufw status
```

# Инструкция по настройке xray-core
1) скачиваем install.sh на сервер
2) делаем исполняемым и запускаем
3) при установке xray - жмем везде enter (16.07.2026 такая схема работала)
4) install.sh устанавливает xray-core и создает конфиг в /usr/local/etc/xray/config.json
5) если все прошло успешно - будет выведена ссылка и qr-код для подключения к клиенту. Скрипт создает одного пользователя (один ключ)
6) если ключ работает: подключение есть и трафик идет - можно ничего не делать. В противном случае, нужно менять SNI и(или) безопасность(маскировку) Reality --> xHTTP.

Команды:
```shell
scp /home/vitaly/Документы/GitHub/vpn/install.sh root@88.77.99.125:/root  # !!! не забудь поменять ip на свой 
chmod +x install.sh && ./install.sh
```

# RealiTLScanner
По умолчанию скрипт создает конфиг на основе vless, reality. SNI - cloudflire.com
Есть смысл после установки xray просканировать сеть (соседние ip адреса) и поменять домен(cloudflire.com) на что-то другое.
Если макировка под cloudflire.com работает и RealiTLScanner выдает домены cloudflire - можно ничего не менять.
российские домены вроде ozon, vk и т.д. работать не будут(банят зарубежный трафик). Если нужна маскировка под российские домены - лучше найти что-то через RealiTLScanner (https://github.com/xtls/RealiTLScanner)

Пример:
```shell
# скачиваем свежий релиз и делаем испольняемым
wget https://github.com/XTLS/RealiTLScanner/releases/download/v0.2.3/RealiTLScanner-linux-amd64
chmod +x RealiTLScanner-linux-amd64 

# запускаем
# утилита сканирует соседние адреса и выводит о них информацию
./RealiTLScanner-linux-amd64 --addr 88.77.99.125  # не забудь поменять ip на свой 
```

# Ссылки на amneziawg-installer(cli) и т.д.
Если на сервере есть 1 ГБ ОЗУ и не планируется много пользователей(~10 человек), то можно установить второй протокол amneziaWG2.0(16.07.2026). Если вышла новая версия amneziaWG, можно обновить и пересобрать ядро, или полностью переустановить amneziawg. Соответвенно, на сервере будет работать 2 независимых протокола: 
- vless(Reality, xHTTP и проч)
- amneziaWG.


amneziawg-installer(cli) - ставит AmneziaWG 2.0 (модуль ядра через DKMS), настраивает firewall и форвардинг, создаёт первого клиента, печатает QR-код и vpn:// ссылку для импорта в Amnezia Client. Делает все то же самое, что и официальный клиент. Отличие: вся настройка через текстовые конфиги (консоль). Преимущество: устанавливает в ядре, без Docker и панелей - нет накладных расходов.
Ссылка на amneziawg-installer(cli):
https://github.com/bivlked/amneziawg-installer

