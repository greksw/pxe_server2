#!/bin/bash

# Функция для вывода сообщений
log_and_notify() {
    echo "$1"
}

# Переменные для SMB сервера и шар
SMB_HOST="192.168.2.200"
SHARE_PATH="//192.168.2.200/Distrib/OS/Linux"
MOUNT_POINT="/mnt/OS"
USERNAME="tex"
PASSWORD="123"
DOMAIN="workgroup"

# Обновление системы
sudo dnf update -y

# Установка необходимых пакетов
sudo dnf install -y dnsmasq tftp-server nfs-utils syslinux wget vim git curl tmux tar cifs-utils rsync

# Включение и запуск необходимых сервисов
sudo systemctl enable --now dnsmasq
sudo systemctl enable --now tftp.socket
sudo systemctl enable --now nfs-server

# Настройка dnsmasq для PXE, без раздачи IP
cat <<EOF | sudo tee /etc/dnsmasq.conf > /dev/null
# Настройки для PXE сервера
interface=ens18                  # Используем интерфейс eth0, замените на нужный
dhcp-boot=pxelinux.0,192.168.2.244  # Имя файла загрузчика и IP PXE-сервера
enable-tftp                     # Включаем TFTP
tftp-root=/var/lib/tftpboot     # Папка с TFTP файлами
EOF

# Перезапуск dnsmasq с новыми настройками
sudo systemctl restart dnsmasq

# Проверка доступности SMB сервера
ping -c 1 $SMB_HOST > /dev/null 2>&1
HOST_STATUS=$?

if [ $HOST_STATUS -eq 0 ]; then
    log_and_notify "✅ SMB сервер доступен, монтируем шару..."

    # Монтируем SMB шару
    sudo mkdir -p $MOUNT_POINT
    sudo mount -t cifs $SHARE_PATH $MOUNT_POINT -o username=$USERNAME,password=$PASSWORD,domain=$DOMAIN,iocharset=utf8,file_mode=0777,dir_mode=0777
    MOUNT_STATUS=$?

    # Если монтирование успешно
    if [ $MOUNT_STATUS -eq 0 ]; then
        log_and_notify "✅ Шара примонтирована, выполняем копирование образов..."

        # Копирование образов в TFTP-директорию
        sudo rsync -ruP --delete $MOUNT_POINT/AlmaLinux /var/lib/tftpboot/almalinux-9.4
        sudo rsync -ruP --delete $MOUNT_POINT/Ubuntu /var/lib/tftpboot/ubuntu-installer

        log_and_notify "✅ Образы скопированы, отмонтируем шару."
        sudo umount $MOUNT_POINT
    else
        log_and_notify "❌ Ошибка при монтировании шары."
    fi
else
    log_and_notify "❌ SMB сервер недоступен."
fi

# Настройка TFTP сервера
sudo mkdir -p /var/lib/tftpboot
cd /var/lib/tftpboot

# Копирование файлов загрузчика (syslinux)
wget https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/syslinux-6.03.tar.gz
tar -xzf syslinux-6.03.tar.gz
cp syslinux-6.03/bios/core/pxelinux.0 /var/lib/tftpboot/
cp syslinux-6.03/bios/com32/elflink/ldlinux/ldlinux.c32 /var/lib/tftpboot/
cp syslinux-6.03/bios/com32/menu/menu.c32 /var/lib/tftpboot/
sudo chown -R nobody:nobody /var/lib/tftpboot/
sudo chmod -R 755 /var/lib/tftpboot/

# Перезапуск dnsmasq и tftp
sudo systemctl restart dnsmasq && sudo systemctl restart tftp.socket

# Создание конфигурации PXE с меню выбора дистрибутива
mkdir -p /var/lib/tftpboot/pxelinux.cfg
cat <<EOF | sudo tee /var/lib/tftpboot/pxelinux.cfg/default > /dev/null
DEFAULT menu.c32
TIMEOUT 600
PROMPT 0
ONTIMEOUT local

LABEL ubuntu
    MENU LABEL Ubuntu 24.04.1 LTS
    KERNEL /ubuntu-installer/amd64/linux
    APPEND initrd=/ubuntu-installer/amd64/initrd.gz

LABEL almalinux
    MENU LABEL AlmaLinux 9.4
    KERNEL /almalinux-9.4/isolinux/vmlinuz
    APPEND initrd=/almalinux-9.4/isolinux/initrd.img
EOF

# Настройка NFS для раздачи файлов
echo "/var/lib/tftpboot *(ro,sync,no_root_squash)" | sudo tee -a /etc/exports

# Перезапуск NFS
sudo exportfs -r
sudo systemctl restart nfs-server

# Открытие портов на firewall
sudo firewall-cmd --permanent --zone=public --add-service=tftp
sudo firewall-cmd --permanent --zone=public --add-service=nfs
sudo firewall-cmd --reload

log_and_notify "PXE сервер установлен и настроен. Перезагрузите сервер."
