#!/usr/bin/env bash
# Ставит рок pg — форк с починками — в дерево .rocks проекта.
#
# Форк — это официальный tarantool/pg на закреплённом коммите master
# и заплаты из rocks/pg/ поверх него: SQLSTATE у отказа, число затронутых
# строк, отмена входа без ошибки Lua и сборка на CMake 4. Выпуск 2.0.2
# на rocks.tarantool.org этого не умеет, а в master нет ни одной из трёх
# починок, поэтому ни метка, ни master сами по себе не годятся.
#
# Форк лежит в репозитории рецептом — коммит и заплаты, — а не копией
# рока и не отдельным репозиторием: рок собирается с чистого клона из одних
# и тех же исходников, а `make deps` его не подменяет.
#
# Коммит закреплён: заплаты написаны против него, и master, ушедший
# вперёд, либо не примет их, либо молча поменяет поведение, которое
# проверки tnt-postgres сверили. Подъём — отдельная правка со сверкой
# живыми проверками заново.
#
# Рок собирается из C и требует libpq на машине: на macOS её путь
# берётся у brew, на Linux — пакет libpq-dev (или postgresql-devel).
# В `make deps` цель не входит нарочно: без рока гейты проходят,
# а живые проверки пропускаются.
#
# Запуск: tools/deps_pg.sh (или make deps-pg)

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rocks_tree="${project_root}/.rocks"
patches="${project_root}/rocks/pg"
source_dir="${project_root}/var/rocks/pg"

UPSTREAM='https://github.com/tarantool/pg.git'
COMMIT='a88dcf157c6cdecd2fc461a5fa6e52428854975a'

echo "[1/3] исходники ${UPSTREAM} на ${COMMIT:0:7}"
rm -rf "${source_dir}"
mkdir -p "$(dirname "${source_dir}")"
git clone --quiet "${UPSTREAM}" "${source_dir}"
git -C "${source_dir}" checkout --quiet "${COMMIT}"

echo "[2/3] заплаты из rocks/pg"
for patch in "${patches}"/*.patch; do
    echo "  $(basename "${patch}")"
    git -C "${source_dir}" apply "${patch}"
done

# CMake находит libpq сам, если она в системных путях; brew кладёт её
# в свой префикс, и без подсказки сборка кончается «Could NOT find
# PostgreSQL (missing: PostgreSQL_LIBRARY)».
if command -v brew > /dev/null 2>&1 && libpq="$(brew --prefix libpq 2> /dev/null)"; then
    export CMAKE_PREFIX_PATH="${libpq}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
    export PKG_CONFIG_PATH="${libpq}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
fi

echo "[3/3] сборка в ${rocks_tree}"
# Сборка идёт из каталога исходников: там нет luarocks.lock, и чужое
# закреплённое проекта в дерево не поедет.
(
    cd "${source_dir}"
    tt rocks make --tree "${rocks_tree}" pg-scm-1.rockspec
)

echo 'Рок pg (форк) поставлен'
