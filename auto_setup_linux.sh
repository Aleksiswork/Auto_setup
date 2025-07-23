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

# 2. Проверка наличия SSH-ключа для рута
if [ ! -f /root/.ssh/authorized_keys ] || [ ! -s /root/.ssh/authorized_keys ]; then
    echo "Добавьте ssh ключ на сервер и мы продолжим"
    exit 1
fi

# === Функции для каждого этапа ===

update_system_and_install_packages() {
    echo "Обновление системы..." | tee -a $LOGFILE
    sudo apt update | tee -a $LOGFILE
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" upgrade -y | tee -a $LOGFILE
    PACKAGES=(curl wget git htop mc)
    for pkg in "${PACKAGES[@]}"; do
        if dpkg -s "$pkg" &> /dev/null; then
            echo "$pkg уже установлен." | tee -a $LOGFILE
        else
            echo "Устанавливаю $pkg..." | tee -a $LOGFILE
            sudo apt install -y "$pkg" | tee -a $LOGFILE
            if [ $? -ne 0 ]; then
                echo "Ошибка при установке $pkg!" | tee -a $LOGFILE
            fi
        fi
    done
}

create_new_user() {
    echo
    echo "=== Создание нового пользователя ===" | tee -a $LOGFILE
    read -p "Введите имя нового пользователя: " NEW_USER
    if id "$NEW_USER" &>/dev/null; then
        echo "Пользователь $NEW_USER уже существует." | tee -a $LOGFILE
    else
        sudo adduser "$NEW_USER" | tee -a $LOGFILE
        sudo usermod -aG sudo "$NEW_USER" | tee -a $LOGFILE
        echo "Пользователь $NEW_USER создан и добавлен в группу sudo." | tee -a $LOGFILE
    fi
    echo "Копирую SSH-ключи для пользователя $NEW_USER..." | tee -a $LOGFILE
    USER_HOME="/home/$NEW_USER"
    sudo mkdir -p "$USER_HOME/.ssh" | tee -a $LOGFILE
    sudo cp /root/.ssh/authorized_keys "$USER_HOME/.ssh/authorized_keys" | tee -a $LOGFILE
    sudo chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh" | tee -a $LOGFILE
    sudo chmod 700 "$USER_HOME/.ssh" | tee -a $LOGFILE
    sudo chmod 600 "$USER_HOME/.ssh/authorized_keys" | tee -a $LOGFILE
    echo "SSH-ключи скопированы для пользователя $NEW_USER." | tee -a $LOGFILE
}

setup_ssh() {
    echo
    echo "=== Настройка SSH ===" | tee -a $LOGFILE
    read -p "Введите новый порт для SSH (например, 2222): " NEW_SSH_PORT 
    if [ -z "$NEW_SSH_PORT" ]; then
        CURRENT_PORT=$(grep -E '^Port ' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
        if [ -n "$CURRENT_PORT" ]; then
            NEW_SSH_PORT="$CURRENT_PORT"
            echo "Порт не введён. Использую текущий порт из конфига: $NEW_SSH_PORT" | tee -a $LOGFILE
        else
            NEW_SSH_PORT=22
            echo "Порт не введён и не найден в конфиге. Использую порт по умолчанию: 22" | tee -a $LOGFILE
        fi
    fi
    echo "Изменяю порт SSH на $NEW_SSH_PORT..." | tee -a $LOGFILE
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak | tee -a $LOGFILE
    if [ $? -ne 0 ]; then
        echo "Ошибка при создании резервной копии sshd_config!" | tee -a $LOGFILE
    fi
    if grep -q '^#\?Port ' /etc/ssh/sshd_config; then
        sudo sed -i "s/^#\?Port .*/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config | tee -a $LOGFILE
    else
        echo "Port $NEW_SSH_PORT" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi
    sudo systemctl restart sshd | tee -a $LOGFILE
    if [ $? -ne 0 ]; then
        echo "Ошибка при перезапуске sshd!" | tee -a $LOGFILE
    fi
    echo "Порт SSH изменён и служба перезапущена." | tee -a $LOGFILE 
}

disable_root_login() {
    OTHER_USERS=$(awk -F: '($3>=1000)&&($1!="root")&&(($7=="/bin/bash")||($7=="/bin/sh")) {print $1}' /etc/passwd)
    if [ -z "$OTHER_USERS" ]; then
        echo "Нет других пользователей кроме root с shell /bin/bash или /bin/sh. Отключение входа под root пропущено." | tee -a $LOGFILE
    else
        echo "Обнаружены пользователи: $OTHER_USERS" | tee -a $LOGFILE
        read -p "Отключить вход по SSH под root? (y/n): " DISABLE_ROOT_LOGIN
        if [[ "$DISABLE_ROOT_LOGIN" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
            echo "Отключаю вход по SSH под root..." | tee -a $LOGFILE
            if grep -q '^#\?PermitRootLogin ' /etc/ssh/sshd_config; then
                sudo sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config | tee -a $LOGFILE
            else
                echo 'PermitRootLogin no' | sudo tee -a /etc/ssh/sshd_config > /dev/null
            fi
            sudo systemctl restart sshd | tee -a $LOGFILE
            if [ $? -ne 0 ]; then
                echo "Ошибка при перезапуске sshd!" | tee -a $LOGFILE
            fi
            echo "Вход по SSH под root отключён." | tee -a $LOGFILE
        else
            echo "Отключение входа под root пропущено по выбору пользователя." | tee -a $LOGFILE
        fi
    fi
}

disable_password_auth() {
    CLOUD_INIT_SSHD_CONF="/etc/ssh/sshd_config.d/50-cloud-init.conf"
    echo "Отключаю вход по паролю в $CLOUD_INIT_SSHD_CONF..." | tee -a $LOGFILE
    if [ -f "$CLOUD_INIT_SSHD_CONF" ]; then
        if grep -q '^#\?PasswordAuthentication ' "$CLOUD_INIT_SSHD_CONF"; then
            sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' "$CLOUD_INIT_SSHD_CONF" | tee -a $LOGFILE
        else
            echo 'PasswordAuthentication no' | sudo tee -a "$CLOUD_INIT_SSHD_CONF" > /dev/null
        fi
        sudo systemctl restart sshd | tee -a $LOGFILE
        if [ $? -ne 0 ]; then
            echo "Ошибка при перезапуске sshd!" | tee -a $LOGFILE
        fi
        echo "Вход по паролю отключён в $CLOUD_INIT_SSHD_CONF." | tee -a $LOGFILE
    else
        echo "$CLOUD_INIT_SSHD_CONF не найден, пропускаю этот шаг." | tee -a $LOGFILE
    fi
}

install_docker() {
    echo "=== Установка Docker и docker-compose ===" | tee -a $LOGFILE
    if command -v docker >/dev/null 2>&1; then
        echo "Docker уже установлен. Пропускаю установку Docker и docker-compose." | tee -a $LOGFILE
    else
        read -p "Хотите установить Docker и docker-compose? (y/n): " INSTALL_DOCKER 
        if [[ "$INSTALL_DOCKER" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
            echo "Устанавливаю Docker..." | tee -a $LOGFILE
            curl -fsSL https://get.docker.com -o get-docker.sh | tee -a $LOGFILE
            sudo sh get-docker.sh | tee -a $LOGFILE
            rm -f get-docker.sh
            sudo usermod -aG docker "$NEW_USER" | tee -a $LOGFILE
            if sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
                echo "Ждём освобождения менеджера пакетов..." | tee -a $LOGFILE
                while sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
                    sleep 2
                done
            fi
            if sudo test -f /var/lib/dpkg/lock-frontend || sudo test -f /var/lib/dpkg/lock; then
                echo "Обнаружена блокировка dpkg. Попытка исправить..." | tee -a $LOGFILE
                sudo dpkg --configure -a | tee -a $LOGFILE
                if [ $? -ne 0 ]; then
                    echo "Ошибка при выполнении dpkg --configure -a!" | tee -a $LOGFILE
                fi
            fi
            if command -v docker >/dev/null 2>&1; then
                echo "Docker установлен и пользователь $NEW_USER добавлен в группу docker." | tee -a $LOGFILE
            else
                echo "Ошибка: Docker не установлен! Проверьте вывод выше." | tee -a $LOGFILE
            fi
            echo "Устанавливаю docker-compose..." | tee -a $LOGFILE
            sudo apt-get install -y docker-compose | tee -a $LOGFILE
            if [ $? -ne 0 ]; then
                echo "Ошибка при установке docker-compose!" | tee -a $LOGFILE
            fi
            if command -v docker-compose >/dev/null 2>&1; then
                echo "docker-compose установлен." | tee -a $LOGFILE
            else
                echo "Ошибка: docker-compose не установлен! Проверьте вывод выше." | tee -a $LOGFILE
            fi
        else
            echo "Docker и docker-compose не будут установлены." | tee -a $LOGFILE
        fi
    fi
}

create_swap() {
    echo "=== Swap-файл (виртуальная память) ==="
    if sudo swapon --show | grep -q '^'; then
        echo "Swap уже настроен. Пропускаю создание." | tee -a $LOGFILE
    else
        RAM_MB=$(free -m | awk '/^Mem:/ { print $2 }')
        if [ "$RAM_MB" -le 2048 ]; then
            read -p "У вас $RAM_MB МБ RAM. Создать swap-файл (рекомендуется)? (y/n): " CREATE_SWAP
            if [[ "$CREATE_SWAP" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
                echo "Создаю swap-файл 1ГБ..." | tee -a $LOGFILE
                sudo fallocate -l 1G /swapfile | tee -a $LOGFILE
                sudo chmod 600 /swapfile | tee -a $LOGFILE
                sudo mkswap /swapfile | tee -a $LOGFILE
                sudo swapon /swapfile | tee -a $LOGFILE
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
}

install_unattended_upgrades() {
    echo "=== Установка и настройка автоматических обновлений (unattended-upgrades) ===" | tee -a $LOGFILE
    if dpkg -s unattended-upgrades >/dev/null 2>&1; then
        echo "unattended-upgrades уже установлен. Пропускаю установку." | tee -a $LOGFILE
    else
        read -p "Хотите установить автоматические обновления (unattended-upgrades)? (y/n): " INSTALL_UNATTENDED
        if [[ "$INSTALL_UNATTENDED" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
            echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | sudo debconf-set-selections
            sudo DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" install -y unattended-upgrades | tee -a $LOGFILE
            sudo systemctl enable unattended-upgrades | tee -a $LOGFILE
            sudo systemctl start unattended-upgrades | tee -a $LOGFILE
            echo "Справка:"
            echo "Основной конфиг: /etc/apt/apt.conf.d/50unattended-upgrades"
            echo "Параметры автозапуска: /etc/apt/apt.conf.d/20auto-upgrades"
            echo "Проверить работу: sudo unattended-upgrades --dry-run --debug"
            sudo sed -i \
                -e 's|^// *\("\${distro_id}:\${distro_codename}-security";\)|\1|' \
                -e 's|^ *\("\${distro_id}:\${distro_codename}-updates";\)|// \1|' \
                -e 's|^ *\("\${distro_id}:\${distro_codename}-proposed";\)|// \1|' \
                -e 's|^ *\("\${distro_id}:\${distro_codename}-proposed-updates";\)|// \1|' \
                -e 's|^ *\("\${distro_id}:\${distro_codename}-backports";\)|// \1|' \
                /etc/apt/apt.conf.d/50unattended-upgrades | tee -a $LOGFILE
            echo "Только security-обновления будут устанавливаться автоматически." | tee -a $LOGFILE
            sudo sed -i 's|^\s*"?origin=Debian,codename=\${distro_codename},label=Debian";|// "origin=Debian,codename=${distro_codename},label=Debian";|' /etc/apt/apt.conf.d/50unattended-upgrades
        else
            echo "unattended-upgrades не будет установлен." | tee -a $LOGFILE
        fi
    fi
}

install_ufw() {
    echo "=== Установка и настройка фаервола (ufw) ===" | tee -a $LOGFILE
    if dpkg -s ufw >/dev/null 2>&1; then
        echo "ufw уже установлен. Пропускаю установку." | tee -a $LOGFILE
    else
        read -p "Хотите установить и настроить фаервол (ufw)? (y/n): " INSTALL_UFW
        if [[ "$INSTALL_UFW" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
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
}

clean_system() {
    echo "=== Очистка системы ===" | tee -a $LOGFILE
    echo "Удаляю неиспользуемые пакеты и очищаю кэш apt..." | tee -a $LOGFILE
    sudo apt autoremove -y | tee -a $LOGFILE
    sudo apt clean | tee -a $LOGFILE
    echo "Система очищена." | tee -a $LOGFILE 
}

final_summary() {
    CREATED_USER_MSG="Пользователь не создавался (используется root)"
    if [ "$NEW_USER" != "root" ] && [ -n "$NEW_USER" ]; then
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
}

# === Меню выбора этапа ===
while true; do
    echo
    echo "Выберите действие:"
    echo "0. Выполнить все шаги по порядку (с подтверждением)"
    echo "1. Выполнить все шаги по порядку (без подтверждения)"
    echo "2. Обновление системы и установка базовых пакетов"
    echo "3. Настройка SSH"
    echo "4. Создание нового пользователя"
    echo "5. Отключение входа под root (при наличии других пользователей)"
    echo "6. Отключение входа по паролю"
    echo "7. Установка Docker и docker-compose"
    echo "8. Создание swap-файла"
    echo "9. Установка автоматических обновлений"
    echo "10. Установка и настройка ufw (фаервола)"
    echo "11. Очистка системы"
    echo "q. Выйти"
    read -p "Ваш выбор: " MENU_CHOICE

    case $MENU_CHOICE in
        0)
            read -p "Вы уверены, что хотите выполнить все шаги по порядку? (y/n): " CONFIRM
            if [[ "$CONFIRM" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
                update_system_and_install_packages
                setup_ssh
                create_new_user
                disable_root_login
                disable_password_auth
                install_docker
                create_swap
                install_unattended_upgrades
                install_ufw
                clean_system
                final_summary
            else
                echo "Отмена выполнения всех шагов."
            fi
            ;;
        1)
            update_system_and_install_packages
            setup_ssh
            create_new_user
            disable_root_login
            disable_password_auth
            install_docker
            create_swap
            install_unattended_upgrades
            install_ufw
            clean_system
            final_summary
            ;;
        2)
            update_system_and_install_packages
            final_summary
            ;;
        3)
            setup_ssh
            final_summary
            ;;
        4)
            create_new_user
            final_summary
            ;;
        5)
            disable_root_login
            final_summary
            ;;
        6)
            disable_password_auth
            final_summary
            ;;
        7)
            install_docker
            final_summary
            ;;
        8)
            create_swap
            final_summary
            ;;
        9)
            install_unattended_upgrades
            final_summary
            ;;
        10)
            install_ufw
            final_summary
            ;;
        11)
            clean_system
            final_summary
            ;;
        q|Q)
            echo "Выход."
            exit 0
            ;;
        *)
            echo "Некорректный выбор. Попробуйте снова."
            ;;
    esac
    echo
    read -p "Нажмите Enter для возврата в меню или q для выхода: " RET
    if [[ "$RET" =~ ^[qQ]$ ]]; then
        echo "Выход."
        exit 0
    fi

done

