# tnt-orm

Шлюз моделей [tnt-model](https://github.com/tnt-skein/tnt-model) для
PostgreSQL и MySQL: та же модель — объявление, проверка входа, хуки,
отметки времени, мягкое удаление, области — поверх таблицы в базе.
Запрос собирает [tnt-sql](https://github.com/tnt-skein/tnt-sql),
выполняет драйвер [tnt-postgres](https://github.com/tnt-skein/tnt-postgres)
либо [tnt-mysql](https://github.com/tnt-skein/tnt-mysql), отказ базы
становится отказом модели того же рода.

```lua
local model = require('tnt.model')
local orm = require('tnt.orm')

local binding = model.bind({ User }, model.settings({ source = 'sql' }), { sql = orm.gateway(db) })

binding.attach()
User.migration()(box)                                -- create table if not exists "users" …
User.create({ id = 1, name = 'Мария', age = 46 })    -- insert into "users" …
User.where('age', '>=', 18):limit(50):all()          -- select … order by "age" asc, "id" asc limit 50
```

Зависимости: [tnt-model](https://github.com/tnt-skein/tnt-model),
[tnt-sql](https://github.com/tnt-skein/tnt-sql),
[tnt-must](https://github.com/tnt-skein/tnt-must),
[tnt-external](https://github.com/tnt-skein/tnt-external),
[tnt-clock](https://github.com/tnt-skein/tnt-clock). Драйвер приходит
аргументом, и какой из двух ставить, решает приложение.

## Зачем

- **Второй системы моделей нет.** Модель объявляется `model.define`, как
  и для спейса; пакет даёт ей шлюз `sql` с тем же договором: `find`,
  `create`, `save`, `delete`, `where…:all()/count()/first()`, `after`,
  `offset`, `model.atomic`, отказы `conflict`, `readonly`, `invalid`,
  `unavailable`.
- **Схема из объявления.** Шаг `Model.migration()` модели на шлюзе `sql`
  создаёт таблицу и индексы в базе; шаги миграций приложения те же.
- **Источник выбирает настройка.** Раздел `models` привязки говорит
  `source = 'sql'`, шлюз приходит в `model.bind`, код моделей не меняется.
- **Страница та же, что у спейса**: порядок индекса и первичного ключа,
  пустое значение меньше любого, продолжение после записи.

## Установка

```sh
tt rocks install tnt-orm --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-orm.git
cd tnt-orm && tt rocks make
```

Драйвер ставится отдельно: `tnt-postgres` либо `tnt-mysql` с того же
сервера роков.

## Как пользоваться

| Вызов | Что делает |
|---|---|
| `orm.gateway(db)` | шлюз `sql` над драйвером `tnt-postgres` либо `tnt-mysql`; иной драйвер — исключение на строке вызывающего |
| `orm.statements(Model, dialect)` | операторы схемы таблицы модели под `postgres` либо `mysql` — то, что выполнит шаг миграции |
| `orm.KIND`, `orm.DIALECTS` | имя шлюза (`sql`) и диалекты, которые он знает |

Остальное — договор модели: `find`, `create`, `save`, `delete`,
`force_delete`, `restore`, выборки, `model.atomic` — транзакция драйвера
на одном соединении.

```lua
model.atomic(function()
    assert(User.create({ id = 1, name = 'a', age = 20 }))
    assert(User.create({ id = 2, name = 'b', age = 21 }))

    return 'готово'
end)
--> 'готово'

local _, err = User.create({ id = 1, name = 'дубль', age = 30 })
err.kind                  --> 'conflict' — занятый ключ, как у спейса
err.cause.server_code     --> '23505' — отказ драйвера целиком
```

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov и зависимости пакета в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
```

67 проверок, из них 14 живых; покрытие строк — 100 %, убитых мутантов —
100 % (371 мутант в семи модулях). Живые проверки идут на PostgreSQL 16
и MySQL 8.4 с форками роков и без них пропускаются:

```sh
make deps-pg deps-mysql      # форки роков pg и mysql в .rocks
make postgres-up mysql-up    # стенд в докере
make test
```

## Документ

Полное описание с обоснованием решений и отличиями от спейсов:
[docs/orm.md](docs/orm.md).

## Лицензия

MIT.
