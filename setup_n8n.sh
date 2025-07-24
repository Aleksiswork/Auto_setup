#!/bin/bash

# =============================================
# Скрипт установки n8n с поддержкой Redis/Postgres и Traefik
# Требования: запуск от root, установленные docker и docker compose
# =============================================

set -e
LOGFILE="setup_n8n.log"

# Проверка прав
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт с root-правами (sudo)!" | tee -a $LOGFILE
  exit 1
fi

# Проверка наличия docker
if ! command -v docker &> /dev/null; then
  echo "Docker не установлен! Установите Docker и повторите запуск." | tee -a $LOGFILE
  exit 1
fi
if ! docker compose version &> /dev/null; then
  echo "Docker Compose не установлен или не интегрирован с docker! Установите docker compose plugin." | tee -a $LOGFILE
  exit 1
fi

# Меню выбора этапов установки
while true; do
  echo
  echo "Выберите действие:"
  echo "1. Установка N8N (без Postgres и Redis)"
  echo "2. Установка Redis"
  echo "3. Установка Postgres"
  echo "0. Выполнить все пункты"
  echo "q. Выйти"
  read -p "Ваш выбор: " MENU_CHOICE

  INSTALL_N8N=0
  INSTALL_REDIS=0
  INSTALL_POSTGRES=0

  case $MENU_CHOICE in
    1)
      INSTALL_N8N=1
      ;;
    2)
      INSTALL_REDIS=1
      ;;
    3)
      INSTALL_POSTGRES=1
      ;;
    0)
      INSTALL_N8N=1
      INSTALL_REDIS=1
      INSTALL_POSTGRES=1
      ;;
    q|Q)
      echo "Выход." | tee -a $LOGFILE
      exit 0
      ;;
    *)
      echo "Некорректный выбор. Попробуйте снова." | tee -a $LOGFILE
      continue
      ;;
  esac
  break
done

# Проверка docker/docker compose только если выбран пункт 1, 2, 3 или 0
if [ "$INSTALL_N8N" = "1" ] || [ "$INSTALL_REDIS" = "1" ] || [ "$INSTALL_POSTGRES" = "1" ]; then
  if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите скрипт с root-правами (sudo)!" | tee -a $LOGFILE
    exit 1
  fi
  if ! command -v docker &> /dev/null; then
    echo "Docker не установлен! Установите Docker и повторите запуск." | tee -a $LOGFILE
    exit 1
  fi
  if ! docker compose version &> /dev/null; then
    echo "Docker Compose не установлен или не интегрирован с docker! Установите docker compose plugin." | tee -a $LOGFILE
    exit 1
  fi
fi

# Получаем список пользователей с shell bash/sh
USER_LIST=($(awk -F: '($7=="/bin/bash"||$7=="/bin/sh"){print $1}' /etc/passwd))

if [ "$INSTALL_N8N" = "1" ]; then
  # Проверка портов 80, 443, 5678 только при установке N8N
  for PORT in 80 443 5678; do
    if lsof -i :$PORT -sTCP:LISTEN -t >/dev/null ; then
      echo "Порт $PORT уже занят! Освободите порт и повторите запуск." | tee -a $LOGFILE
      exit 1
    fi
  done

  if [ ${#USER_LIST[@]} -eq 0 ]; then
    echo "В системе не найдено пользователей с shell /bin/bash или /bin/sh." | tee -a $LOGFILE
    exit 1
  fi

  while true; do
    echo "Выберите пользователя, в папку которого будет установлена n8n:"
    for i in "${!USER_LIST[@]}"; do
      idx=$((i+1))
      echo "$idx. ${USER_LIST[$i]}"
    done
    read -p "Введите номер пользователя: " USER_NUM
    if ! [[ "$USER_NUM" =~ ^[0-9]+$ ]] || [ "$USER_NUM" -lt 1 ] || [ "$USER_NUM" -gt ${#USER_LIST[@]} ]; then
      echo "Некорректный выбор! Попробуйте снова." | tee -a $LOGFILE
    else
      break
    fi
  done

  INSTALL_USER="${USER_LIST[$((USER_NUM-1))]}"
  echo "Выбран пользователь: $INSTALL_USER" | tee -a $LOGFILE

  USER_HOME=$(eval echo "~$INSTALL_USER")
  if [ ! -d "$USER_HOME" ]; then
    echo "Домашняя папка пользователя $INSTALL_USER не найдена! Проверьте корректность пользователя." | tee -a $LOGFILE
    exit 1
  fi
  cd "$USER_HOME" || { echo "Не удалось перейти в домашнюю папку!" | tee -a $LOGFILE; exit 1; }
  echo "Перешёл в папку: $USER_HOME" | tee -a $LOGFILE

  # Создание папки n8n-compose и переход в неё
  if [ -d n8n-compose ]; then
    read -p "Папка n8n-compose уже существует. Перезаписать содержимое? (y/n): " OVERWRITE
    [[ "$OVERWRITE" =~ ^[yY]$ ]] || exit 1
    rm -rf n8n-compose
  fi
  mkdir -p n8n-compose || { echo "Ошибка при создании папки n8n-compose" | tee -a $LOGFILE; exit 1; }
  cd n8n-compose || { echo "Не удалось перейти в папку n8n-compose" | tee -a $LOGFILE; exit 1; }
  echo "Создана и выбрана папка: $(pwd)" | tee -a $LOGFILE

  cd "$USER_HOME"
  sudo chown -R "$INSTALL_USER:$INSTALL_USER" n8n-compose
  cd n8n-compose

  # Проверка существования .env
  if [ -f .env ]; then
    read -p ".env уже существует. Перезаписать? (y/n): " OVERWRITE
    [[ "$OVERWRITE" =~ ^[yY]$ ]] || exit 1
  fi

  # Ввод домена с повтором при ошибке
  while true; do
    read -p "Введите домен, который будет использоваться для n8n (например, n8n.example.com): " DOMAIN
    if [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      break
    else
      echo "Некорректный домен, попробуйте снова." | tee -a $LOGFILE
    fi
  done

  echo "Ваш домен: $DOMAIN" | tee -a $LOGFILE

  # Ввод email с повтором при ошибке
  while true; do
    read -p "Введите email для SSL-сертификата: " SSL_EMAIL
    if [[ "$SSL_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
      break
    else
      echo "Некорректный email, попробуйте снова." | tee -a $LOGFILE
    fi
  done

  # Разделение домена на SUBDOMAIN и DOMAIN_NAME
  IFS='.' read -ra DOMAIN_PARTS <<< "$DOMAIN"
  PARTS_COUNT=${#DOMAIN_PARTS[@]}
  if [ $PARTS_COUNT -lt 2 ]; then
    echo "Домен должен содержать хотя бы одну точку!" | tee -a $LOGFILE
    exit 1
  fi
  DOMAIN_NAME="${DOMAIN_PARTS[$((PARTS_COUNT-1))]}"
  SUBDOMAIN="${DOMAIN_PARTS[0]}"
  if [ $PARTS_COUNT -gt 2 ]; then
    for ((i=1; i<PARTS_COUNT-1; i++)); do
      SUBDOMAIN+=".${DOMAIN_PARTS[$i]}"
    done
  fi

  cat > .env <<EOF
  ######################################
  DOMAIN_NAME=$DOMAIN_NAME
  SUBDOMAIN=$SUBDOMAIN
  GENERIC_TIMEZONE=Europe/Moscow
  SSL_EMAIL=$SSL_EMAIL
  ######################################
EOF

  sudo chown "$INSTALL_USER:$INSTALL_USER" .env
  ENV_PATH="$(pwd)/.env"

  mkdir -p local-files
  sudo chown "$INSTALL_USER:$INSTALL_USER" local-files

  echo "=========================================" | tee -a $LOGFILE
  echo "Файл .env создан по пути: $ENV_PATH" | tee -a $LOGFILE
  echo "Для редактирования используйте команду:" | tee -a $LOGFILE
  echo "sudo -u $INSTALL_USER nano $ENV_PATH" | tee -a $LOGFILE
  echo "=========================================" | tee -a $LOGFILE

  # Проверка существования docker-compose.yml
  if [ -f docker-compose.yml ]; then
    read -p "docker-compose.yml уже существует. Перезаписать? (y/n): " OVERWRITE
    [[ "$OVERWRITE" =~ ^[yY]$ ]] || exit 1
  fi

  sudo -u "$INSTALL_USER" touch docker-compose.yml
  sudo chown "$INSTALL_USER:$INSTALL_USER" docker-compose.yml
  cat > docker-compose.yml <<'EOF'
  #######################
  services:
    traefik:
      image: "traefik"
      restart: always
      command:
        - "--api=true"
        - "--api.insecure=true"
        - "--providers.docker=true"
        - "--providers.docker.exposedbydefault=false"
        - "--entrypoints.web.address=:80"
        - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
        - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
        - "--entrypoints.websecure.address=:443"
        - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"
        - "--certificatesresolvers.mytlschallenge.acme.email=${SSL_EMAIL}"
        - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
      ports:
        - "80:80"
        - "443:443"
      volumes:
        - traefik_data:/letsencrypt
        - /var/run/docker.sock:/var/run/docker.sock:ro

    n8n:
      image: docker.n8n.io/n8nio/n8n
      restart: always
      ports:
        - "127.0.0.1:5678:5678"
      labels:
        - traefik.enable=true
        - traefik.http.routers.n8n.rule=Host(`$SUBDOMAIN.$DOMAIN_NAME`)
        - traefik.http.routers.n8n.tls=true
        - traefik.http.routers.n8n.entrypoints=web,websecure
        - traefik.http.routers.n8n.tls.certresolver=mytlschallenge
        - traefik.http.middlewares.n8n.headers.SSLRedirect=true
        - traefik.http.middlewares.n8n.headers.STSSeconds=315360000
        - traefik.http.middlewares.n8n.headers.browserXSSFilter=true
        - traefik.http.middlewares.n8n.headers.contentTypeNosniff=true
        - traefik.http.middlewares.n8n.headers.forceSTSHeader=true
        - traefik.http.middlewares.n8n.headers.SSLHost=${DOMAIN_NAME}
        - traefik.http.middlewares.n8n.headers.STSIncludeSubdomains=true
        - traefik.http.middlewares.n8n.headers.STSPreload=true
        - traefik.http.routers.n8n.middlewares=n8n@docker
      environment:
        - N8N_HOST=$SUBDOMAIN.$DOMAIN_NAME
        - N8N_PORT=5678
        - N8N_PROTOCOL=https
        - NODE_ENV=production
        - WEBHOOK_URL=https://$SUBDOMAIN.$DOMAIN_NAME/
        - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      volumes:
        - n8n_data:/home/node/.n8n
        - ./local-files:/files

  volumes:
    n8n_data:
    traefik_data:
#######################
EOF

  # Всегда перезапускаем контейнеры после формирования docker-compose.yml
  sudo docker compose down || { echo "Ошибка при остановке контейнеров" | tee -a $LOGFILE; exit 1; }
  sudo docker compose up -d || { echo "Ошибка при запуске контейнеров" | tee -a $LOGFILE; exit 1; }

  echo
  echo "=========================================" | tee -a $LOGFILE
  echo "Установка завершена! Все должно работать." | tee -a $LOGFILE
  echo "Текущие запущенные контейнеры:" | tee -a $LOGFILE
  sudo docker ps | tee -a $LOGFILE
  echo "=========================================" | tee -a $LOGFILE
fi

# Добавляем блок Postgres только если выбран пункт 3 или 0
if [ "$INSTALL_POSTGRES" = "1" ]; then
  cat >> n8n-compose/.env <<EOF
DB_TYPE=postgresdb
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=n8n
DB_POSTGRESDB_SCHEMA=public
######################################
EOF
fi

# Пункт 2: установка Redis
if [ "$INSTALL_REDIS" = "1" ] && [ "$INSTALL_N8N" = "0" ]; then
  if [ ! -f docker-compose.yml ]; then
    echo "Файл docker-compose.yml не найден. Сначала выполните установку N8N (пункт 1), чтобы создать базовую структуру." | tee -a $LOGFILE
    exit 1
  fi
  # Опрос о необходимости Redis и Postgres

  REDIS_BLOCK="  redis:\n    image: redis:7-alpine\n    restart: always\n    ports:\n      - \"6379:6379\"\n    volumes:\n      - redis_data:/data\n"
  POSTGRES_BLOCK="  postgres:\n    image: postgres:15-alpine\n    restart: always\n    environment:\n      - POSTGRES_USER=n8n\n      - POSTGRES_PASSWORD=n8n\n      - POSTGRES_DB=n8n\n    ports:\n      - \"5432:5432\"\n    volumes:\n      - postgres_data:/var/lib/postgresql/data\n"

  NEED_RESTART=0
  TMPFILE=""
  trap '[ -n "$TMPFILE" ] && rm -f "$TMPFILE"' EXIT

  if [[ "$INSTALL_REDIS" =~ ^([yY][eE][sS]?|[yY])$ ]] || [[ "$INSTALL_POSTGRES" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
    TMPFILE=$(mktemp)
    INSERTED=0
    while IFS= read -r line; do
      echo "$line" >> "$TMPFILE"
      if [[ $line =~ ^services: ]]; then
        if [[ "$INSTALL_REDIS" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
          echo -e "$REDIS_BLOCK" >> "$TMPFILE"
          NEED_RESTART=1
        fi
        if [[ "$INSTALL_POSTGRES" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
          echo -e "$POSTGRES_BLOCK" >> "$TMPFILE"
          NEED_RESTART=1
        fi
        INSERTED=1
      fi
    done < docker-compose.yml
    mv "$TMPFILE" docker-compose.yml
  fi

  if [[ "$INSTALL_REDIS" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
    if ! grep -q 'redis_data:' docker-compose.yml; then
      sed -i '/^volumes:/a \  redis_data:' docker-compose.yml
    fi
  fi
  if [[ "$INSTALL_POSTGRES" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
    if ! grep -q 'postgres_data:' docker-compose.yml; then
      sed -i '/^volumes:/a \  postgres_data:' docker-compose.yml
    fi
  fi

  # Всегда перезапускаем контейнеры после формирования docker-compose.yml
  sudo docker compose down || { echo "Ошибка при остановке контейнеров" | tee -a $LOGFILE; exit 1; }
  sudo docker compose up -d || { echo "Ошибка при запуске контейнеров" | tee -a $LOGFILE; exit 1; }
  echo "Redis успешно добавлен и запущен." | tee -a $LOGFILE
fi

# Пункт 3: установка Postgres
if [ "$INSTALL_POSTGRES" = "1" ] && [ "$INSTALL_N8N" = "0" ]; then
  if [ ! -f docker-compose.yml ]; then
    echo "Файл docker-compose.yml не найден. Сначала выполните установку N8N (пункт 1), чтобы создать базовую структуру." | tee -a $LOGFILE
    exit 1
  fi
  # Опрос о необходимости Redis и Postgres

  REDIS_BLOCK="  redis:\n    image: redis:7-alpine\n    restart: always\n    ports:\n      - \"6379:6379\"\n    volumes:\n      - redis_data:/data\n"
  POSTGRES_BLOCK="  postgres:\n    image: postgres:15-alpine\n    restart: always\n    environment:\n      - POSTGRES_USER=n8n\n      - POSTGRES_PASSWORD=n8n\n      - POSTGRES_DB=n8n\n    ports:\n      - \"5432:5432\"\n    volumes:\n      - postgres_data:/var/lib/postgresql/data\n"

  NEED_RESTART=0
  TMPFILE=""
  trap '[ -n "$TMPFILE" ] && rm -f "$TMPFILE"' EXIT

  if [[ "$INSTALL_REDIS" =~ ^([yY][eE][sS]?|[yY])$ ]] || [[ "$INSTALL_POSTGRES" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
    TMPFILE=$(mktemp)
    INSERTED=0
    while IFS= read -r line; do
      echo "$line" >> "$TMPFILE"
      if [[ $line =~ ^services: ]]; then
        if [[ "$INSTALL_REDIS" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
          echo -e "$REDIS_BLOCK" >> "$TMPFILE"
          NEED_RESTART=1
        fi
        if [[ "$INSTALL_POSTGRES" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
          echo -e "$POSTGRES_BLOCK" >> "$TMPFILE"
          NEED_RESTART=1
        fi
        INSERTED=1
      fi
    done < docker-compose.yml
    mv "$TMPFILE" docker-compose.yml
  fi

  if [[ "$INSTALL_REDIS" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
    if ! grep -q 'redis_data:' docker-compose.yml; then
      sed -i '/^volumes:/a \  redis_data:' docker-compose.yml
    fi
  fi
  if [[ "$INSTALL_POSTGRES" =~ ^([yY][eE][sS]?|[yY])$ ]]; then
    if ! grep -q 'postgres_data:' docker-compose.yml; then
      sed -i '/^volumes:/a \  postgres_data:' docker-compose.yml
    fi
  fi

  # Всегда перезапускаем контейнеры после формирования docker-compose.yml
  sudo docker compose down || { echo "Ошибка при остановке контейнеров" | tee -a $LOGFILE; exit 1; }
  sudo docker compose up -d || { echo "Ошибка при запуске контейнеров" | tee -a $LOGFILE; exit 1; }
  echo "Postgres успешно добавлен и запущен." | tee -a $LOGFILE
fi
