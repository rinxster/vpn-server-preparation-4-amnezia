# vpn-server-preparation-4-amnezia

Подготовка VPS под Amnezia VPN (отключение IPv6 для firstbyte, hardening, fail2ban, ufw).

## Поддерживаемые версии Ubuntu LTS

18.04, 20.04, 22.04, 24.04, 26.04

## Важно: самоуничтожение на сервере

После успешного завершения скрипт **автоматически удаляется с сервера** примерно через 2 минуты (через `systemd-run`). Также очищается история bash.

**Сохраните локальную копию** репозитория или скрипта перед запуском — повторный деплой возможен только с вашей копии.

## Деплой через wget (firstbyte, с отключением IPv6)

```
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 && sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1 && sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1 && sudo wget https://raw.githubusercontent.com/rinxster/vpn-server-preparation-4-amnezia/main/vpn-server-preparation-4-amnezia.sh -O vpn-server-preparation-4-amnezia.sh && sudo chmod +x vpn-server-preparation-4-amnezia.sh && sudo bash vpn-server-preparation-4-amnezia.sh
```

## Деплой через wget (без отключения IPv6)

```
sudo wget https://raw.githubusercontent.com/rinxster/vpn-server-preparation-4-amnezia/main/vpn-server-preparation-4-amnezia.sh -O vpn-server-preparation-4-amnezia.sh && sudo chmod +x vpn-server-preparation-4-amnezia.sh && sudo bash vpn-server-preparation-4-amnezia.sh
```

## Альтернатива: деплой через scp

```bash
scp vpn-server-preparation-4-amnezia.sh root@YOUR_SERVER:/root/
ssh root@YOUR_SERVER 'chmod +x /root/vpn-server-preparation-4-amnezia.sh && bash /root/vpn-server-preparation-4-amnezia.sh'
```

## Что делает скрипт

- Меняет SSH-порт на **2222**, отключает root login по SSH
- Создаёт пользователя `0dmin4eg` с sudo (NOPASSWD)
- Включает **UFW** (2222, 443) и **fail2ban** (bantime 1d)
- Настраивает unattended-upgrades и еженедельные cron-задачи
- Отключает ICMP echo, включает **TCP BBR** (fq + bbr), отключает rsyslog/journald logging
- Очищает систему и историю bash, удаляет себя с сервера
