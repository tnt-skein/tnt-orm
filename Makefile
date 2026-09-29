# Проверки пакета: форматирование, линт, тесты, покрытие, мутанты.

LUATEST  := .rocks/bin/luatest
LUACHECK := .rocks/bin/luacheck
COVERAGE_MIN ?= 100

# luatest держит узлы в VARDIR и стирает этот каталог на старте. Умолчание —
# общий /tmp/t, а в окружении может стоять VARDIR другого проекта: прогон
# уносил бы чужие узлы и писал бы в чужой журнал. Правило то же, что
# у tnt-mutants, — проверки и мутационный прогон делят один каталог.
# Приставка держит значение непустым: пустой VARDIR luatest понял бы как
# текущий каталог и стёр бы репозиторий.
VARDIR := /tmp/t-$(shell printf '%s' "$$(pwd)" | cksum | cut -d' ' -f1)
export VARDIR

.PHONY: help
help: ## Список целей
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN { FS = ":.*?## " } { printf "  %-12s %s\n", $$1, $$2 }'

# cluacov считает исполняемые строки по байткоду: без него luacov относит
# попадание в выражение на несколько строк к последней из них, и первая
# строка константы числится непокрытой.
#
# cluacov собирается из C против своих копий заголовков LuaJIT, и копию
# он выбирает по LUAJIT_VERSION_NUM: Tarantool объявляет 20100, и берутся
# заголовки 2.1.0-beta3. В них GC64 на x86_64 включается только макросом
# LUAJIT_ENABLE_GC64 (на arm64 — всегда), а Tarantool собран с GC64. Без
# флага раскладка объектов у рока и у машины расходится, и cluacov падает
# segfault в l_deepactivelines — гейт покрытия и его проверка падают вместе
# с ним. На arm64 флаг ничего не меняет. Аргумент CFLAGS= заменяет значение
# luarocks целиком, поэтому -fPIC повторён: без него разделяемая библиотека
# не соберётся.
CLUACOV_CFLAGS := CFLAGS="-O2 -fPIC -DLUAJIT_ENABLE_GC64"

# Собранный cluacov проверяется сразу: подсказка нужна и тогда, когда
# рок роняет процесс, а не отвечает ошибкой. Скобки держат `||` на этой
# проверке — иначе подсказка печаталась бы и на отказе предыдущего шага.
CLUACOV_CHECK := { tarantool -e "local lines = require('cluacov.deepactivelines').get(loadstring('local a = 1\nreturn a')) \
	os.exit((lines[1] and lines[2]) and 0 or 1)" || \
	{ echo 'cluacov собран не под LuaJIT этого Tarantool: см. CLUACOV_CFLAGS в Makefile' >&2; false; }; }

# Зависимости пакета — tnt-model, tnt-sql, tnt-must, tnt-external
# и tnt-clock — с сервера роков tnt-skein, по rockspec. Драйверы
# tnt-postgres и tnt-mysql пакету не зависимости — драйвер приходит
# аргументом, — а живым проверкам нужны; tnt-env им же читает порты
# стенда. Поэтому все три ставятся здесь же.
.PHONY: deps
deps: ## Поставить зависимости пакета и инструменты проверок в .rocks
	tt rocks install --server=https://luarocks.org luatest
	tt rocks install --server=https://luarocks.org luacheck 1.2.0
	tt rocks install --server=https://luarocks.org luacov 0.17.0
	tt rocks install --server=https://luarocks.org cluacov 1.0.0 $(CLUACOV_CFLAGS) && \
	$(CLUACOV_CHECK)
	tt rocks install --server=https://tnt-skein.github.io/rocks --only-deps tnt-orm-scm-1.rockspec
	tt rocks install --server=https://tnt-skein.github.io/rocks tnt-postgres
	tt rocks install --server=https://tnt-skein.github.io/rocks tnt-mysql
	tt rocks install --server=https://tnt-skein.github.io/rocks tnt-env

# Роки pg и mysql — форки с починками: официальные tarantool/pg
# и tarantool/mysql на закреплённых коммитах и заплаты из rocks/pg/
# и rocks/mysql/ (шапки tools/deps_pg.sh и tools/deps_mysql.sh). В `deps`
# не входят нарочно: роки собираются из C и требуют CMake, компилятор,
# libpq и заголовки OpenSSL, а гейты от них не зависят — без роков живые
# проверки пропускаются.
.PHONY: deps-pg
deps-pg: ## Поставить рок pg (форк с починками) для живых проверок
	tools/deps_pg.sh

.PHONY: deps-mysql
deps-mysql: ## Поставить рок mysql (форк с починками) для живых проверок
	tools/deps_mysql.sh

.PHONY: fmt
fmt: ## Отформатировать код
	stylua .

.PHONY: fmt-check
fmt-check: ## Проверить форматирование, ничего не меняя
	stylua --check .

.PHONY: lint
lint: ## Линт
	$(LUACHECK) . --formatter plain --codes

.PHONY: test
test: ## Прогон проверок
	$(LUATEST) test/

.PHONY: coverage
coverage: ## Проверки с покрытием и порогом
	mkdir -p var && rm -f var/luacov.stats.out
	$(LUATEST) test/ --coverage
	tarantool tools/coverage_gate.lua $(COVERAGE_MIN)

# Мутационное тестирование — утилитой tnt-mutants (github.com/tnt-skein/tnt-mutants).
.PHONY: mutants
mutants: ## Мутационное тестирование изменённых модулей
	tnt-mutants

.PHONY: mutants-all
mutants-all: ## Мутационное тестирование всех модулей
	tnt-mutants $(shell find tnt -name '*.lua' | sort)

.PHONY: check
check: fmt-check lint test coverage ## Все проверки, кроме мутантов

.PHONY: clean
clean: ## Убрать рабочие каталоги
	rm -rf var

# Стенд живых проверок — PostgreSQL 16 и MySQL 8.4 в докере, один
# на машину: учётка app с паролем в кавычке и обратной черте. Без него
# живые проверки пропускаются: гейты не должны зависеть от докера.
.PHONY: postgres-up
postgres-up: ## Поднять PostgreSQL 16 для живых проверок
	test/stand/postgres.sh

.PHONY: postgres-down
postgres-down: ## Погасить PostgreSQL
	test/stand/postgres.sh stop

.PHONY: mysql-up
mysql-up: ## Поднять MySQL 8.4 для живых проверок
	test/stand/mysql.sh

.PHONY: mysql-down
mysql-down: ## Погасить MySQL
	test/stand/mysql.sh stop
