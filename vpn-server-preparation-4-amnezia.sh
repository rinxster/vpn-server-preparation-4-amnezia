#!/bin/bash

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите от имени root"
    exit 1
fi

# Ввод пароля с проверкой на совпадение
echo '########################################'
while true; do
    read -sp 'Введите пароль для пользователя: ' password1
    echo
    read -sp 'Подтвердите пароль: ' password2
    echo
    if [ "$password1" == "$password2" ]; then
        break
    else
        echo "Пароли не совпадают. Попробуйте еще раз."
    fi
done
echo '########################################'

# Установка пароля для root
echo "root:$password1" | chpasswd

# Установка обновлений и необходимых программ
apt update -y && apt upgrade -y
apt install -y mc fail2ban curl speedtest-cli ufw unattended-upgrades update-notifier-common || { echo "Установка пакетов не удалась"; exit 1; }

# Настройка автоматических обновлений
echo -e "APT::Periodic::Update-Package-Lists \"1\";\nAPT::Periodic::Unattended-Upgrade \"1\";" | tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null
systemctl restart unattended-upgrades || { echo "Не удалось перезапустить unattended-upgrades"; exit 1; }
systemctl enable unattended-upgrades

# Настройка fail2ban
cp /etc/fail2ban/jail.{conf,local}
sed -i -e 's/bantime  = 10m/bantime  = 1d/g' /etc/fail2ban/jail.local
systemctl restart fail2ban || { echo "Не удалось перезапустить fail2ban"; exit 1; }
systemctl enable fail2ban

# Настройка ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 2222
ufw allow 443
ufw enable

# Изменение порта SSH
echo '########################################'
echo 'Настройка порта SSH на 2222.' 
echo '########################################'
sed -i -e 's/#Port 22/Port 2222/g' /etc/ssh/sshd_config
ufw allow 2222
service sshd reload

# Создание не-root пользователя и установка пароля
nonroot="0dmin4eg"
if id "$nonroot" &>/dev/null; then
    echo "Пользователь $nonroot уже существует."
else
    useradd -m -c "$nonroot" $nonroot -s /bin/bash
    usermod -aG sudo $nonroot
    echo "$nonroot:$password1" | chpasswd
fi

# Отключение root-доступа по SSH
sed -i 's/PermitRootLogin yes/PermitRootLogin no/g' /etc/ssh/sshd_config
service ssh reload

# Добавление NOPASSWD для sudo пользователя
echo "$nonroot ALL=(ALL) NOPASSWD: ALL" | tee -a /etc/sudoers > /dev/null

# Полное отключение логирования
echo '########################################'
echo 'Отключение логирования...'
echo '########################################'

# Отключение rsyslog
systemctl stop rsyslog
systemctl disable rsyslog

# Отключение journald (возможно, потребует дополнительной настройки)
mkdir -p /etc/systemd/journald.conf.d/
echo -e "[Journal]\nStorage=none" > /etc/systemd/journald.conf.d/no-logs.conf

# Перезапуск systemd-journald для применения изменений
systemctl restart systemd-journald

# Очистка системы с помощью стороннего скрипта (проверка на наличие)
if ! command -v wget &> /dev/null; then
    echo "wget не установлен. Установка..."
    apt install wget -y || { echo "Не удалось установить wget"; exit 1; }
fi

wget -qO uc https://raw.githubusercontent.com/enishant/ubuntu-cleaner/1.0/ubuntu-cleaner.sh && sh uc

# Запуск очистки перед завершением
sudo uc

# Настройка cron для автоматической очистки
(crontab -l; echo "0 0 * * 0 sudo uc") | crontab -

echo 'Подготовка и предварительная настройка сервера завершена!'
