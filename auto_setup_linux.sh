#!/bin/bash

# =============================================
# Скрипт автоматической настройки Linux-системы
# Выполняет следующие шаги:
#
# 0. Проверка запуска с root-правами (sudo/root)
# 1. Проверка наличия SSH-ключа для root
# 2. Обновление системы и установка базовых пакетов (curl, wget, git, htop, mc)
#    - Устанавливает только отсутствующие пакеты
#    - Проверяет успешность установки каждого пакета
# 3. (По желанию) Создание нового пользователя, добавление в sudo, копирование SSH-ключа
# 4. Настройка SSH:
#    - Запрос нового порта (или использование текущего)
#    - Изменение порта, резервная копия конфига, перезапуск sshd (с проверкой успешности)
# 5. Отключение входа под root:
#    - Если есть другие пользователи, спрашивает, отключать ли root
#    - Если нет — пропускает
# 6. Отключение входа по паролю (PasswordAuthentication no) в cloud-init конфиге (с проверкой успешности)
# 7. (По желанию) Установка Docker и docker-compose, добавление пользователя в группу docker
#    - Пропускает, если уже установлены
#    - После установки Docker временный файл get-docker.sh удаляется
#    - Проверяет успешность установки
# 8. (По желанию) Создание swap-файла при малом объёме RAM
#    - Перед добавлением swap в /etc/fstab проверяет отсутствие дублирования
# 9. (По желанию) Установка unattended-upgrades (автообновления)
#    - Только security-обновления, автоматическая настройка, без диалогов
#    - Пропускает, если уже установлен
# 10. (По желанию) Установка и настройка ufw (фаервола), разрешение SSH-порта
#     - Пропускает, если уже установлен
# 11. Очистка системы (apt autoremove, apt clean)
# 12. Финальное сообщение и чек-лист по результатам настройки:
#     - Созданные пользователи, SSH-порт, статус Docker, swap, UFW, открытые порты, путь к лог-файлу
# =============================================

# Лог-файл
LOGFILE="setup.log"

# 1. Проверка наличия root-прав
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт с root-правами (sudo)!"
  exit 1
fi

# Список пакетов для установки
PACKAGES=(curl wget git htop mc)

# Проверка наличия SSH-ключа для рута
if [ ! -f /root/.ssh/authorized_keys ] || [ ! -s /root/.ssh/authorized_keys ]; then
    echo "Добавьте ssh ключ на сервер и мы продолжим"
    exit 1
fi

echo "Обновление системы..." | tee -a $LOGFILE
sudo apt update | tee -a $LOGFILE
sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" upgrade -y | tee -a $LOGFILE

for pkg in "${PACKAGES[@]}"; do
    if dpkg -s "$pkg" &> /dev/null; then
        echo "$pkg уже установлен." | tee -a $LOGFILE
    else
        echo "Устанавливаю $pkg..." | tee -a $LOGFILE
        sudo apt install -y "$pkg" | tee -a $LOGFILE
        # 4. Проверка успешности установки пакета
        if [ $? -ne 0 ]; then
            echo "Ошибка при установке $pkg!" | tee -a $LOGFILE
        fi
    fi
done

echo
echo "=== Создание нового пользователя ===" | tee -a $LOGFILE
echo | tee -a $LOGFILE
echo "Хотите создать нового пользователя? (y/n): "
read CREATE_NEW_USER
if [[ "$CREATE_NEW_USER" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
    echo | tee -a $LOGFILE
    echo "=== Создание нового пользователя ===" | tee -a $LOGFILE
    read -p "Введите имя нового пользователя: " NEW_USER
    if id "$NEW_USER" &>/dev/null; then
        echo "Пользователь $NEW_USER уже существует." | tee -a $LOGFILE
    else
        sudo adduser "$NEW_USER" | tee -a $LOGFILE
        sudo usermod -aG sudo "$NEW_USER" | tee -a $LOGFILE
        echo "Пользователь $NEW_USER создан и добавлен в группу sudo." | tee -a $LOGFILE
    fi
    echo | tee -a $LOGFILE
    echo "Копирую SSH-ключи для пользователя $NEW_USER..." | tee -a $LOGFILE
    USER_HOME="/home/$NEW_USER"
    sudo mkdir -p "$USER_HOME/.ssh" | tee -a $LOGFILE
    sudo cp /root/.ssh/authorized_keys "$USER_HOME/.ssh/authorized_keys" | tee -a $LOGFILE
    sudo chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh" | tee -a $LOGFILE
    sudo chmod 700 "$USER_HOME/.ssh" | tee -a $LOGFILE
    sudo chmod 600 "$USER_HOME/.ssh/authorized_keys" | tee -a $LOGFILE
    echo "SSH-ключи скопированы для пользователя $NEW_USER." | tee -a $LOGFILE
else
    echo "Создание нового пользователя пропущено." | tee -a $LOGFILE
    # Для совместимости с остальным скриптом NEW_USER= текущий root
    NEW_USER="root"
fi

echo
echo "=== Настройка SSH ===" | tee -a $LOGFILE
read -p "Введите новый порт для SSH (например, 2222): " NEW_SSH_PORT 

if [ -z "$NEW_SSH_PORT" ]; then
    # Получаем текущий порт из конфига
    CURRENT_PORT=$(grep -E '^Port ' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
    if [ -n "$CURRENT_PORT" ]; then
        NEW_SSH_PORT="$CURRENT_PORT"
        echo "Порт не введён. Использую текущий порт из конфига: $NEW_SSH_PORT" | tee -a $LOGFILE
    else
        NEW_SSH_PORT=22
        echo "Порт не введён и не найден в конфиге. Использую порт по умолчанию: 22" | tee -a $LOGFILE
    fi
fi

echo
echo "Изменяю порт SSH на $NEW_SSH_PORT..." | tee -a $LOGFILE
# Резервная копия конфига
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak | tee -a $LOGFILE
# 4. Проверка успешности бэкапа
if [ $? -ne 0 ]; then
    echo "Ошибка при создании резервной копии sshd_config!" | tee -a $LOGFILE
fi
# Изменение или добавление строки Port
if grep -q '^#\?Port ' /etc/ssh/sshd_config; then
    sudo sed -i "s/^#\?Port .*/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config | tee -a $LOGFILE
else
    echo "Port $NEW_SSH_PORT" | sudo tee -a /etc/ssh/sshd_config > /dev/null
fi
# Перезапуск sshd
sudo systemctl restart sshd | tee -a $LOGFILE
# 4. Проверка успешности перезапуска sshd
if [ $? -ne 0 ]; then
    echo "Ошибка при перезапуске sshd!" | tee -a $LOGFILE
fi
echo "Порт SSH изменён и служба перезапущена." | tee -a $LOGFILE 

# Отключение входа под root
# Проверка наличия других пользователей кроме root с shell /bin/bash или /bin/sh
OTHER_USERS=$(awk -F: '($3>=1000)&&($1!="root")&&(($7=="/bin/bash")||($7=="/bin/sh")) {print $1}' /etc/passwd)
if [ -z "$OTHER_USERS" ]; then
    echo | tee -a $LOGFILE
    echo "Нет других пользователей кроме root с shell /bin/bash или /bin/sh. Отключение входа под root пропущено." | tee -a $LOGFILE
else
    echo | tee -a $LOGFILE
    echo "Обнаружены пользователи: $OTHER_USERS" | tee -a $LOGFILE
    read -p "Отключить вход по SSH под root? (y/n): " DISABLE_ROOT_LOGIN
    if [[ "$DISABLE_ROOT_LOGIN" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
        echo | tee -a $LOGFILE
        echo "Отключаю вход по SSH под root..." | tee -a $LOGFILE
        if grep -q '^#\?PermitRootLogin ' /etc/ssh/sshd_config; then
            sudo sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config | tee -a $LOGFILE
        else
            echo 'PermitRootLogin no' | sudo tee -a /etc/ssh/sshd_config > /dev/null
        fi
        sudo systemctl restart sshd | tee -a $LOGFILE
        # 4. Проверка успешности перезапуска sshd
        if [ $? -ne 0 ]; then
            echo "Ошибка при перезапуске sshd!" | tee -a $LOGFILE
        fi
        echo "Вход по SSH под root отключён." | tee -a $LOGFILE
    else
        echo "Отключение входа под root пропущено по выбору пользователя." | tee -a $LOGFILE
    fi
fi

# Отключение входа по паролю в cloud-init конфиге
CLOUD_INIT_SSHD_CONF="/etc/ssh/sshd_config.d/50-cloud-init.conf"
echo
echo "Отключаю вход по паролю в $CLOUD_INIT_SSHD_CONF..." | tee -a $LOGFILE
if [ -f "$CLOUD_INIT_SSHD_CONF" ]; then
    if grep -q '^#\?PasswordAuthentication ' "$CLOUD_INIT_SSHD_CONF"; then
        sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' "$CLOUD_INIT_SSHD_CONF" | tee -a $LOGFILE
    else
        echo 'PasswordAuthentication no' | sudo tee -a "$CLOUD_INIT_SSHD_CONF" > /dev/null
    fi
    sudo systemctl restart sshd | tee -a $LOGFILE
    # 4. Проверка успешности перезапуска sshd
    if [ $? -ne 0 ]; then
        echo "Ошибка при перезапуске sshd!" | tee -a $LOGFILE
    fi
    echo "Вход по паролю отключён в $CLOUD_INIT_SSHD_CONF." | tee -a $LOGFILE
else
    echo "$CLOUD_INIT_SSHD_CONF не найден, пропускаю этот шаг." | tee -a $LOGFILE
fi 

echo
echo "=== Установка Docker и docker-compose ===" | tee -a $LOGFILE
if command -v docker >/dev/null 2>&1; then
    echo "Docker уже установлен. Пропускаю установку Docker и docker-compose." | tee -a $LOGFILE
else
    echo | tee -a $LOGFILE
    echo "=== Установка Docker и docker-compose ===" | tee -a $LOGFILE
    read -p "Хотите установить Docker и docker-compose? (y/n): " INSTALL_DOCKER 

    if [[ "$INSTALL_DOCKER" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
        echo
        echo "Устанавливаю Docker..." | tee -a $LOGFILE
        curl -fsSL https://get.docker.com -o get-docker.sh | tee -a $LOGFILE
        sudo sh get-docker.sh | tee -a $LOGFILE
        # 5. Очистка временных файлов после установки Docker
        rm -f get-docker.sh
        sudo usermod -aG docker "$NEW_USER" | tee -a $LOGFILE
        # Проверка и устранение блокировок dpkg/apt
        if sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
            echo "Ждём освобождения менеджера пакетов..." | tee -a $LOGFILE
            while sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
                sleep 2
            done
        fi
        if sudo test -f /var/lib/dpkg/lock-frontend || sudo test -f /var/lib/dpkg/lock; then
            echo "Обнаружена блокировка dpkg. Попытка исправить..." | tee -a $LOGFILE
            sudo dpkg --configure -a | tee -a $LOGFILE
            # 4. Проверка успешности dpkg --configure -a
            if [ $? -ne 0 ]; then
                echo "Ошибка при выполнении dpkg --configure -a!" | tee -a $LOGFILE
            fi
        fi
        # После установки Docker
        if command -v docker >/dev/null 2>&1; then
            echo "Docker установлен и пользователь $NEW_USER добавлен в группу docker." | tee -a $LOGFILE
        else
            echo "Ошибка: Docker не установлен! Проверьте вывод выше." | tee -a $LOGFILE
        fi

        echo
        echo "Устанавливаю docker-compose..." | tee -a $LOGFILE
        sudo apt-get install -y docker-compose | tee -a $LOGFILE
        # 4. Проверка успешности установки docker-compose
        if [ $? -ne 0 ]; then
            echo "Ошибка при установке docker-compose!" | tee -a $LOGFILE
        fi
        # Установка docker-compose
        if command -v docker-compose >/dev/null 2>&1; then
            echo "docker-compose установлен." | tee -a $LOGFILE
        else
            echo "Ошибка: docker-compose не установлен! Проверьте вывод выше." | tee -a $LOGFILE
        fi
    else
        echo "Docker и docker-compose не будут установлены." | tee -a $LOGFILE
    fi
fi 

echo
echo "=== Swap-файл (виртуальная память) ==="
echo "Swap-файл — это область на диске, которую система использует как резервную память, если заканчивается оперативная RAM."
echo "Это помогает избежать сбоев при нехватке памяти, особенно на VPS с 512МБ-2ГБ RAM. Swap медленнее RAM, но повышает стабильность."
echo "Рекомендуется, если у вас мало оперативной памяти."

# Проверка наличия swap
if sudo swapon --show | grep -q '^'; then
    echo "Swap уже настроен. Пропускаю создание." | tee -a $LOGFILE
else
    # Получаем объём RAM в мегабайтах
    RAM_MB=$(free -m | awk '/^Mem:/ { print $2 }')
    if [ "$RAM_MB" -le 2048 ]; then
        read -p "У вас $RAM_MB МБ RAM. Создать swap-файл (рекомендуется)? (y/n): " CREATE_SWAP
        if [[ "$CREATE_SWAP" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
            echo "Создаю swap-файл 1ГБ..." | tee -a $LOGFILE
            sudo fallocate -l 1G /swapfile | tee -a $LOGFILE
            sudo chmod 600 /swapfile | tee -a $LOGFILE
            sudo mkswap /swapfile | tee -a $LOGFILE
            sudo swapon /swapfile | tee -a $LOGFILE
            # 12. Проверка наличия swap-файла в /etc/fstab перед добавлением
            if ! grep -q '^/swapfile ' /etc/fstab; then
                echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
            else
                echo "Строка для swap уже есть в /etc/fstab, пропускаю добавление." | tee -a $LOGFILE
            fi
            echo "Swap-файл создан и активирован." | tee -a $LOGFILE
        else
            echo "Swap-файл не будет создан." | tee -a $LOGFILE
        fi
    else
        echo "У вас достаточно RAM ($RAM_MB МБ). Swap не требуется." | tee -a $LOGFILE
    fi
fi 

echo
echo "=== Установка и настройка автоматических обновлений (unattended-upgrades) ===" | tee -a $LOGFILE
if dpkg -s unattended-upgrades >/dev/null 2>&1; then
    echo "unattended-upgrades уже установлен. Пропускаю установку." | tee -a $LOGFILE
else
    echo | tee -a $LOGFILE
    echo "=== Установка и настройка автоматических обновлений (unattended-upgrades) ===" | tee -a $LOGFILE
    read -p "Хотите установить автоматические обновления (unattended-upgrades)? (y/n): " INSTALL_UNATTENDED

    if [[ "$INSTALL_UNATTENDED" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
        echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | sudo debconf-set-selections
        sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" install -y unattended-upgrades | tee -a $LOGFILE
        # sudo dpkg-reconfigure --priority=low unattended-upgrades | tee -a $LOGFILE  # УБРАНО для non-interactive
        sudo systemctl enable unattended-upgrades | tee -a $LOGFILE
        sudo systemctl start unattended-upgrades | tee -a $LOGFILE
        echo "Справка:"
        echo "Основной конфиг: /etc/apt/apt.conf.d/50unattended-upgrades"
        echo "Параметры автозапуска: /etc/apt/apt.conf.d/20auto-upgrades"
        echo "Проверить работу: sudo unattended-upgrades --dry-run --debug"
        echo "Оставляю только обновления безопасности в /etc/apt/apt.conf.d/50unattended-upgrades..." | tee -a $LOGFILE
        sudo sed -i \
            -e 's|^// *\("\${distro_id}:\${distro_codename}-security";\)|\1|' \
            -e 's|^ *\("\${distro_id}:\${distro_codename}-updates";\)|// \1|' \
            -e 's|^ *\("\${distro_id}:\${distro_codename}-proposed";\)|// \1|' \
            -e 's|^ *\("\${distro_id}:\${distro_codename}-proposed-updates";\)|// \1|' \
            -e 's|^ *\("\${distro_id}:\${distro_codename}-backports";\)|// \1|' \
            /etc/apt/apt.conf.d/50unattended-upgrades | tee -a $LOGFILE
        echo "Только security-обновления будут устанавливаться автоматически." | tee -a $LOGFILE
        sudo sed -i 's|^\s*"\?origin=Debian,codename=\${distro_codename},label=Debian";|// "origin=Debian,codename=${distro_codename},label=Debian";|' /etc/apt/apt.conf.d/50unattended-upgrades
    else
        echo "unattended-upgrades не будет установлен." | tee -a $LOGFILE
    fi
fi 

echo
echo "=== Установка и настройка фаервола (ufw) ===" | tee -a $LOGFILE
if dpkg -s ufw >/dev/null 2>&1; then
    echo "ufw уже установлен. Пропускаю установку." | tee -a $LOGFILE
else
    echo | tee -a $LOGFILE
    echo "=== Установка и настройка фаервола (ufw) ===" | tee -a $LOGFILE
    read -p "Хотите установить и настроить фаервол (ufw)? (y/n): " INSTALL_UFW

    if [[ "$INSTALL_UFW" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
        echo
        echo "Устанавливаю ufw..." | tee -a $LOGFILE
        sudo apt-get install -y ufw | tee -a $LOGFILE
        echo "Разрешаю порт SSH ($NEW_SSH_PORT) в ufw..." | tee -a $LOGFILE
        sudo ufw allow "$NEW_SSH_PORT"/tcp | tee -a $LOGFILE
        sudo ufw --force enable | tee -a $LOGFILE
        echo "ufw установлен и настроен. SSH-порт $NEW_SSH_PORT разрешён." | tee -a $LOGFILE
        echo "=== Справка по работе с ufw ==="
        echo "Добавить порт: sudo ufw allow <порт>/tcp"
        echo "Заблокировать порт: sudo ufw deny <порт>/tcp"
        echo "Посмотреть открытые порты: sudo ufw status verbose"
        echo "Посмотреть используемые порты в системе: sudo ss -tulnp" 
    else
        echo "ufw не будет установлен." | tee -a $LOGFILE
    fi
fi 


echo
echo "=== Очистка системы ===" | tee -a $LOGFILE
echo "Удаляю неиспользуемые пакеты и очищаю кэш apt..." | tee -a $LOGFILE
sudo apt autoremove -y | tee -a $LOGFILE
sudo apt clean | tee -a $LOGFILE
echo "Система очищена." | tee -a $LOGFILE 

# 10. Финальный чек-лист/резюме

# Получение информации для резюме
CREATED_USER_MSG="Пользователь не создавался (используется root)"
if [ "$NEW_USER" != "root" ]; then
  CREATED_USER_MSG="Создан пользователь: $NEW_USER (в группе sudo)"
fi

OPEN_PORTS=$(sudo ss -tulnp | grep LISTEN | awk '{print $5}' | awk -F: '{print $NF}' | sort -u | tr '\n' ',' | sed 's/,$//')

UFW_STATUS=$(sudo ufw status | head -n 1)

echo
echo "=== Итоговая информация ===" | tee -a $LOGFILE
echo "$CREATED_USER_MSG" | tee -a $LOGFILE
if [ -n "$NEW_SSH_PORT" ]; then
  echo "SSH-порт: $NEW_SSH_PORT" | tee -a $LOGFILE
fi
if command -v docker >/dev/null 2>&1; then
  echo "Docker установлен" | tee -a $LOGFILE
fi
if command -v docker-compose >/dev/null 2>&1; then
  echo "docker-compose установлен" | tee -a $LOGFILE
fi
if sudo swapon --show | grep -q '^'; then
  echo "Swap активен" | tee -a $LOGFILE
fi
if dpkg -s ufw >/dev/null 2>&1; then
  echo "UFW: $UFW_STATUS" | tee -a $LOGFILE
fi
if [ -n "$OPEN_PORTS" ]; then
  echo "Открытые порты: $OPEN_PORTS" | tee -a $LOGFILE
fi

LOG_PATH=$(realpath $LOGFILE 2>/dev/null || echo "$LOGFILE")
echo "Лог-файл: $LOG_PATH" | tee -a $LOGFILE

echo
echo "Установка и настройка завершена!" | tee -a $LOGFILE

