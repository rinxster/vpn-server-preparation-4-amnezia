#!/bin/bash

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
fi

# Ввод пароля
echo '########################################'
read -sp 'Введите пароль для root и non-root пользователя: ' password
echo
echo '########################################'

# Установка пароля для root
echo "root:$password" | chpasswd

# Установка обновлений и необходимых программ
apt update -y && apt upgrade -y
apt install -y mc fail2ban curl speedtest-cli ufw unattended-upgrades update-notifier-common

# Настройка автоматических обновлений
echo -e "APT::Periodic::Update-Package-Lists \"1\";\nAPT::Periodic::Unattended-Upgrade \"1\";" | tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null
systemctl restart unattended-upgrades
systemctl enable unattended-upgrades

# Настройка fail2ban
cp /etc/fail2ban/jail.{conf,local}
sed -i -e 's/bantime  = 10m/bantime  = 1d/g' /etc/fail2ban/jail.local
systemctl restart fail2ban
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
echo 'Setting up SSH port to 2222.' 
echo '########################################'
sed -i -e 's/#Port 22/Port 2222/g' /etc/ssh/sshd_config
ufw allow 2222
service sshd reload

# Создание не-root пользователя и установка пароля
nonroot="0dmin4eg"
useradd -m -c "$nonroot" $nonroot -s /bin/bash
usermod -aG sudo $nonroot
echo "$nonroot:$password" | chpasswd

# Отключение root-доступа по SSH
sed -i 's/PermitRootLogin yes/PermitRootLogin no/g' /etc/ssh/sshd_config
service ssh reload

# Добавление NOPASSWD для sudo пользователя
echo "$nonroot ALL=(ALL) NOPASSWD: ALL" | tee -a /etc/sudoers > /dev/null

# Очистка системы с помощью стороннего скрипта
wget -qO uc https://raw.githubusercontent.com/enishant/ubuntu-cleaner/1.0/ubuntu-cleaner.sh && sh uc

# Запуск очистки перед завершением
sudo uc

# Настройка cron для автоматической очистки
(crontab -l; echo "0 0 * * 0 sudo uc") | crontab -

echo 'Установка завершена!'
