#!/bin/bash

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

# Настройка TFTP сервера
sudo mkdir -p /var/lib/tftpboot
cd /var/lib/tftpboot

# Копирование файлов загрузчика
wget https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/syslinux-6.03.tar.gz

tar -xzf syslinux-6.03.tar.gz
cp syslinux-6.03/bios/com32/pxelinux/pxelinux.0 /var/lib/tftpboot/
cp syslinux-6.03/bios/com32/elflink/ldlinux/ldlinux.c32 /var/lib/tftpboot/
cp syslinux-6.03/bios/com32/menu/menu.c32 /var/lib/tftpboot/
sudo chown -R nobody:nobody /var/lib/tftpboot/
sudo chmod -R 755 /var/lib/tftpboot/

sudo systemctl restart dnsmasq && sudo systemctl restart tftp.socket

# Создание конфигурации PXE
mkdir -p /var/lib/tftpboot/pxelinux.cfg
cat <<EOF | sudo tee /var/lib/tftpboot/pxelinux.cfg/default > /dev/null
DEFAULT menu.c32
TIMEOUT 600
PROMPT 0
ONTIMEOUT local
LABEL alma
    MENU LABEL AlmaLinux 9.3
    KERNEL /almalinux/vmlinuz
    APPEND initrd=/almalinux/initrd.img
LABEL ubuntu
    MENU LABEL Ubuntu 24.04.1
    KERNEL /ubuntu/vmlinuz
    APPEND initrd=/ubuntu/initrd.img
EOF

# Проверка доступности и монтирование шары для копирования дистрибутивов
HOST="192.168.2.200"
MOUNT_POINT="/mnt/OS"
ISO_DIR="/var/lib/tftpboot"
ALMA_ISO="AlmaLinux-9.3-x86_64-boot.iso"
UBUNTU_ISO="ubuntu-24.04.1-desktop-amd64.iso"

# Проверка доступности хоста
ping -c 1 $HOST > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "Хост $HOST доступен, монтируем шару..."
    sudo mount -t cifs //$HOST/Distrib/OS/Linux/AlmaLinux $MOUNT_POINT -o username=lomakin,password=123,domain=workgroup,iocharset=utf8,file_mode=0777,dir_mode=0777
    
    if mountpoint -q $MOUNT_POINT; then
        echo "Шара успешно примонтирована."

        # Копирование необходимых ISO-образов
        rsync -av --progress $MOUNT_POINT/$ALMA_ISO $ISO_DIR/almalinux/
        rsync -av --progress $MOUNT_POINT/$UBUNTU_ISO $ISO_DIR/ubuntu/

        # Размонтирование шары
        sudo umount $MOUNT_POINT
        echo "Шара успешно отмонтирована."
    else
        echo "Ошибка: Не удалось примонтировать шару."
    fi
else
    echo "Ошибка: Хост $HOST недоступен."
fi

# Настройка NFS для раздачи файлов
echo "/var/lib/tftpboot *(ro,sync,no_root_squash)" | sudo tee -a /etc/exports

# Перезапуск NFS
sudo exportfs -r
sudo systemctl restart nfs-server

# Открытие портов на firewall
sudo firewall-cmd --permanent --zone=public --add-service=tftp
sudo firewall-cmd --permanent --zone=public --add-service=nfs
sudo firewall-cmd --reload

echo "PXE сервер установлен и настроен. Перезагрузите сервер."
