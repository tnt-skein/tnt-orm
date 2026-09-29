#!/usr/bin/env bash
# Поднимает PostgreSQL для живых проверок шлюза sql.
#
# Настоящий сервер, а не двойник рока: двойник показывает, что фасад
# правильно разговаривает сам с собой, а сервер — что его понимает
# PostgreSQL. Разница вылезает на отказах: SQLSTATE конфликта, срок
# statement_timeout, сеанс, убитый посреди запроса, пароль с кавычкой
# в строке соединения.
#
# Один сервер, TLS включён (`ssl=on`): открытый текст и шифрование идут
# на тот же порт, а какой из них выбрать, решает `sslmode` клиента.
# Сертификаты выпускаются здесь же на год корнем из того же каталога.
# Учёток две: `app` владеет базой, `reader` войти может, а таблиц
# не видит — отказ прав настоящий. Пароль `app` с кавычкой и обратной
# чертой: рок вставляет значения в строку соединения без экранирования,
# и такой пароль ломает вход, если фасад его не экранирует.
#
# Каталог сертификатов — `POSTGRES_TLS_DIR`, по умолчанию общий на машину
# `/tmp/tnt-stand/<контейнер>`: контейнер один на машину и переживает
# рабочую копию, которая его подняла. Имя контейнера —
# `STAND_POSTGRES_CONTAINER`.
#
#   test/stand/postgres.sh          # поднять
#   test/stand/postgres.sh stop     # погасить
set -euo pipefail

# Относительный каталог отсчитывается от места запуска: оттуда его
# читает и живая проверка. Ниже сценарий переходит в свой каталог, и без
# этого стенд лёг бы в одно место, а проверка искала бы его в другом.
case "${POSTGRES_TLS_DIR:-}" in
    '' | /*) ;;
    *) POSTGRES_TLS_DIR="${PWD}/${POSTGRES_TLS_DIR}" ;;
esac

cd "$(dirname "$0")"

IMAGE='postgres:16-alpine'
CONTAINER="${STAND_POSTGRES_CONTAINER:-tnt-stand-postgres}"
PORT="${STAND_POSTGRES_PORT:-15432}"
DIR="${POSTGRES_TLS_DIR:-/tmp/tnt-stand/${CONTAINER}}"

# Пароли стенда: локальный сервер для проверок, а не развёртывание.
PASSWORD="app'se\\cret"
READER_PASSWORD='reader-secret'

if ! command -v docker > /dev/null 2>&1; then
    echo 'docker не найден: PostgreSQL поднять нечем' >&2
    exit 1
fi

if [ "${1:-up}" = 'stop' ]; then
    docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true
    echo 'PostgreSQL остановлен'
    exit 0
fi

if ! command -v openssl > /dev/null 2>&1; then
    echo 'openssl не найден: сертификаты выпустить нечем' >&2
    exit 1
fi

# Повторный запуск безвреден: контейнер с тем же именем сносится
# и поднимается заново. Данные живут внутри контейнера и уходят с ним.
# Сносится до выпуска сертификатов: каталог смонтирован в него, и проверки
# соседних копий иначе брали бы новый корень, пока отвечает старый сервер.
docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true

mkdir -p "${DIR}"
DIR="$(cd "${DIR}" && pwd)"

# Сертификаты выпускаются заново на каждый подъём: вчерашний каталог дал
# бы отказ рукопожатия, неотличимый от того, ради которого проверка
# написана. Срок — год, а не сутки: контейнер общий на машину и живёт
# дольше задачи, которая его подняла, и сертификат на сутки назавтра
# ронял бы проверки TLS во всех копиях.
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj '/CN=tnt-postgres-live-ca' \
    -keyout "${DIR}/ca.key" -out "${DIR}/ca.pem" 2> /dev/null
printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n' > "${DIR}/server.ext"
openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' \
    -keyout "${DIR}/server.key" -out "${DIR}/server.csr" 2> /dev/null
openssl x509 -req -in "${DIR}/server.csr" -days 365 \
    -CA "${DIR}/ca.pem" -CAkey "${DIR}/ca.key" -CAcreateserial \
    -extfile "${DIR}/server.ext" -out "${DIR}/server.pem" 2> /dev/null

# Ключ сервера PostgreSQL принимает только своим и с правами 0600,
# а смонтированный каталог принадлежит пользователю машины. Поэтому
# вход образа обёрнут: ключ копируется внутрь с нужным владельцем,
# затем управление уходит обычному входу образа.
docker run -d \
    --name "${CONTAINER}" \
    -p "127.0.0.1:${PORT}:5432" \
    -v "${DIR}:/certs:ro" \
    -e POSTGRES_USER=app \
    -e POSTGRES_PASSWORD="${PASSWORD}" \
    -e POSTGRES_DB=app \
    --entrypoint sh \
    "${IMAGE}" \
    -c 'install -o postgres -m 600 /certs/server.key /tmp/server.key &&
        install -o postgres -m 644 /certs/server.pem /tmp/server.pem &&
        exec docker-entrypoint.sh postgres -c ssl=on \
            -c ssl_cert_file=/tmp/server.pem -c ssl_key_file=/tmp/server.key' > /dev/null

# Готовности ждём по настоящему запросу, а не по pg_isready: образ
# поднимает сервер дважды (сперва для начальных сценариев), и между
# подъёмами pg_isready уже отвечает. Проверки, запущенные в этот миг,
# пропустились бы — и это выглядело бы как «всё хорошо».
for _ in $(seq 1 100); do
    if docker exec "${CONTAINER}" psql -h 127.0.0.1 -U app -d app -tAc 'select 1' 2> /dev/null | grep -q '^1$'; then
        docker exec "${CONTAINER}" psql -h 127.0.0.1 -U app -d app -q \
            -c "create role reader login password '${READER_PASSWORD}'" > /dev/null
        echo "PostgreSQL поднят: 127.0.0.1:${PORT}, TLS на том же порту, сертификаты в ${DIR}"
        exit 0
    fi

    sleep 0.3
done

echo "PostgreSQL не ответил за 30 секунд: смотрите docker logs ${CONTAINER}" >&2
exit 1
