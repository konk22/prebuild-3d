#!/bin/bash
# =============================================================================
# Рефакторинг скрипта установки Prind на OrangePi (Debian-based)
# Цель: чистый, читаемый код, цветные информативные сообщения, обработка ошибок
# =============================================================================

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

MIRROR="http://192.168.11.102:5000"
FILE="/etc/docker/daemon.json"
TMP="/tmp/daemon.json.$$"

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[ГОТОВО]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $*"; }
log_error()       { echo -e "${RED}[ОШИБКА]${NC} $*"; exit 1; }

# =============================================================================
# 1. Установка системных пакетов и Docker
# =============================================================================
log_info "Обновление пакетов и установка зависимостей..."

cp /etc/apt/sources.list /etc/apt/sources.list.backup

cat > "/etc/apt/sources.list" <<EOF
# Основные репозитории
deb http://mirror.yandex.ru/debian/ trixie main contrib non-free non-free-firmware
deb-src http://mirror.yandex.ru/debian/ trixie main contrib non-free non-free-firmware

# Обновления безопасности
deb http://mirror.yandex.ru/debian-security/ trixie-security main contrib non-free non-free-firmware
deb-src http://mirror.yandex.ru/debian-security/ trixie-security main contrib non-free non-free-firmware

# Обновления (updates)
deb http://mirror.yandex.ru/debian/ trixie-updates main contrib non-free non-free-firmware
deb-src http://mirror.yandex.ru/debian/ trixie-updates main contrib non-free non-free-firmware

# Backports (если нужны)
# deb http://mirror.yandex.ru/debian/ trixie-backports main contrib non-free non-free-firmware
# deb-src http://mirror.yandex.ru/debian/ trixie-backports main contrib non-free non-free-firmware
EOF

cat > "/etc/apt/apt.conf.d/02proxy" <<EOF
Acquire::http::Proxy "http://192.168.11.102:3142";
Acquire::https::Proxy "http://192.168.11.102:3142";
EOF



apt update
apt install -y ca-certificates curl git xinit feh plymouth imagemagick

log_info "Добавление официального репозитория Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $( . /etc/os-release && echo "$VERSION_CODENAME" )
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
log_success "Docker установлен"

systemctl disable NetworkManager-wait-online.service
systemctl disable cloud-init-main.service cloud-init-network.service cloud-config.service cloud-final.service
systemctl disable e2scrub_reap.service
systemctl disable ModemManager.service bluetooth.service


sudo mkdir -p /etc/docker

if [ -f "$FILE" ]; then
    # Проверяем, есть ли уже такой MIRROR
    if ! grep -q "\"$MIRROR\"" "$FILE"; then
        # Добавляем MIRROR в массив registry-mirrors или создаём массив, если его нет
        sudo sed '
            /"registry-mirrors"/ {
                :a
                /]/! {N;ba}        # читаем до конца массива ]
                s/]/,"'"$MIRROR"'"]/   # вставляем новый элемент перед ]
            }
        ' "$FILE" > "$TMP"

        # Если массива registry-mirrors вообще не было — добавим ключ
        if ! grep -q '"registry-mirrors"' "$TMP"; then
            sudo sed -i '1s|{|{"registry-mirrors":["'"$MIRROR"'"],|' "$TMP"
        fi
    else
        # Дубликата нет — просто копируем файл
        cp "$FILE" "$TMP"
    fi
else
    # Файла нет — создаём новый
    echo "{\"registry-mirrors\": [\"$MIRROR\"]}" | sudo tee "$FILE" > /dev/null
    sudo systemctl restart docker
    echo "Docker registry mirror $MIRROR добавлен и Docker перезапущен"
fi

sudo mv "$TMP" "$FILE"
sudo systemctl restart docker

# =============================================================================
# 2. Клонирование Prind от пользователя pi
# =============================================================================
log_info "Клонирование репозитория Prind..."
sudo -u pi bash -c '
    cd /home/pi
    rm -rf prind
    git clone https://github.com/konk22/prind.git
    cd prind
    chmod -R o+r img/
    chmod o+rx img
'
log_success "Prind склонирован"

# =============================================================================
# 3. Создание темы
# =============================================================================
log_info "Создание темы для plymouth"
mkdir /usr/share/plymouth/themes/simple-image

cat > /usr/share/plymouth/themes/simple-image/simple-image.plymouth <<EOF
[Plymouth Theme]
Name=Arch Linux Simple Image
Description=This is a plymouth theme which simply displays an image
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/simple-image
ScriptFile=/usr/share/plymouth/themes/simple-image/simple-image.script
EOF

cat > /usr/share/plymouth/themes/simple-image/simple-image.script <<EOF
image = Image("img.png");

pos_x = Window.GetWidth()/2 - image.GetWidth()/2;
pos_y = Window.GetHeight()/2 - image.GetHeight()/2;

sprite = Sprite(image);
sprite.SetX(pos_x);
sprite.SetY(pos_y);

fun refresh_callback () {
  sprite.SetOpacity(1);
  spr.SetZ(15);
}

Plymouth.SetRefreshFunction (refresh_callback);
EOF

# =============================================================================
# 3.1. Загрузка и установка кастомного splash-экрана
# =============================================================================
THEME_DIR="/usr/share/plymouth/themes/simple-image"
LOCK_DIR="/home/pi/prind/img"
CUSTOM_URL="https://raw.githubusercontent.com/deflord/3def/refs/heads/main/%D0%9E%D0%B1%D1%80%D0%B0%D0%B7%D1%8B%20%D0%B4%D0%BB%D1%8F%20OrangePi/watermark800x450.png"

CUSTOM_FILE="$THEME_DIR/img.png"
LOCK_FILE="$LOCK_DIR/splashscreen-1080p-dark.png"

log_info "Загрузка кастомного изображения загрузки..."
wget -q --show-progress -O "$CUSTOM_FILE" "$CUSTOM_URL"
log_success "Изображение установлено"

# =============================================================================
# 4. Отключение радужного экрана + настройка cmdline.txt для чистого Plymouth
# =============================================================================
log_info "Отключение радужного splash и настройка cmdline.txt..."

CONFIG="/boot/firmware/config.txt"
if ! grep -q "^disable_splash=1" "$CONFIG" 2>/dev/null; then
    echo "disable_splash=1" >> "$CONFIG"
    log_success "Добавлено disable_splash=1 в config.txt"
else
    log_warn "disable_splash=1 уже присутствует"
fi

CMDLINE="/boot/firmware/cmdline.txt"

# Добавляем параметры только если их ещё нет
if ! grep -q "quiet splash logo.nologo vt.global_cursor_default=0 plymouth.ignore-serial-consoles" "$CMDLINE"; then
    # Сначала пробуем заменить " quiet" в конце (если уже есть quiet)
    if grep -q " quiet$" "$CMDLINE"; then
        sed -i 's/ quiet$/ quiet splash logo.nologo vt.global_cursor_default=0 plymouth.ignore-serial-consoles/' "$CMDLINE" && \
            log_success "Обновлена строка cmdline.txt (замена quiet)"
    else
        # Если quiet нет вообще — просто добавляем в конец
        sed -i '$ s/$/ quiet splash logo.nologo vt.global_cursor_default=0 plymouth.ignore-serial-consoles/' "$CMDLINE" && \
            log_success "Добавлены параметры в конец cmdline.txt"
    fi
else
    log_warn "Параметры Plymouth уже присутствуют в cmdline.txt"
fi

# =============================================================================
# 5. Нанесение серийного номера на splash
# =============================================================================
SN="SN999"  # ← Измените здесь свой номер
IMAGE="$THEME_DIR/img.png"

if [[ -f "$IMAGE" ]]; then
    log_info "Нанесение текста $SN на изображение..."
    SN_TEXT="${SN%%[0-9]*}"        # "SN"
    NUM_TEXT="${SN#SN}"           # "999"

    FONT_SIZE=30
    BIG_SIZE=$((FONT_SIZE * 3 / 2))

    convert "$IMAGE" \
        -gravity South -font DejaVu-Sans-Bold -fill "#ff0000" -pointsize "$BIG_SIZE" -annotate -40+15 "$SN_TEXT" \
        -gravity South -font DejaVu-Sans-Bold -fill white      -pointsize "$BIG_SIZE" -annotate +40+15 "$NUM_TEXT" \
        "$IMAGE"
    log_success "Текст $SN нанесён"
    cp "$IMAGE" "$LOCK_FILE"
else
    log_error "Файл $IMAGE не найден"
fi

# =============================================================================
# 6. Настройка X11 и запуск контейнеров
# =============================================================================
log_info "Запуск setup-X11.sh..."
sudo bash /home/pi/prind/scripts/setup-X11.sh

log_info "Сборка и запуск контейнеров Prind (mainsail + klipperscreen)..."
cd /home/pi/prind
sudo docker compose --profile mainsail --profile klipperscreen up -d --build

# log_info "Ожидание статуса healthy..."
# for i in {1..10}; do
#     if sudo docker compose ps --services | while read service; do
#         sudo docker inspect --format='{{.Name}} {{.State.Health.Status}}' $(docker ps -q --filter name="$service") 2>/dev/null
#     done | grep -q healthy; then
#         log_success "Все контейнеры healthy"
#         break
#     fi
#     [[ $i -eq 10 ]] && log_error "Таймаут ожидания healthy"
#     sleep 6
# done

# sudo docker compose ps

if [ ! -f "$FILE" ]; then
    echo "Файл $FILE не существует. Нечего удалять."
fi

# Удаляем строку с нужным MIRROR внутри массива registry-mirrors
sudo sed "/registry-mirrors/ , /]/ {
    /$MIRROR/d
}" "$FILE" > "$TMP"

# Убираем пустые элементы и лишние запятые
sudo sed -i '
    s/,\s*]/]/g;      # убираем запятую перед закрывающей скобкой
    s/\[\s*\]/[]/g;   # нормализуем пустой массив
' "$TMP"

# Если массив registry-mirrors стал пустым — удаляем ключ
sudo sed -i '
    /"registry-mirrors": \[\]/d
' "$TMP"

# Если JSON стал маленьким (пустой объект или почти пустой) — удаляем файл
if [ "$(wc -c < "$TMP")" -le 10 ]; then
    sudo rm -f "$FILE"
else
    sudo mv "$TMP" "$FILE"
fi

sudo systemctl restart docker

rm /etc/apt/apt.conf.d/02proxy

# =============================================================================
# 7. Установка темы Plymouth и перезагрузка
# =============================================================================
log_info "Установка темы plymouth simple-image..."
plymouth-set-default-theme simple-image -R
log_success "Тема pix установлена"

log_info "Перезагрузка системы через 10 секунд..."
sleep 10
reboot
