--- Шлюз моделей `tnt-model` для SQL-хранилищ: та же модель поверх
--- PostgreSQL и MySQL.
---
---     local orm = require('tnt.orm')
---     local postgres = require('tnt.postgres')
---
---     local db = postgres.new({ host = 'db', user = 'app', password = secret, db = 'app' })
---     local binding = model.bind({ User }, model.settings({ source = 'sql' }), { sql = orm.gateway(db) })
---
---     binding.attach()
---     User.create({ id = 1, name = 'Мария', age = 46 })     -- insert в таблицу users
---     User.where('age', '>=', 18):limit(50):all()          -- select … order by … limit 50
---
--- Второй системы объявления здесь нет: модель объявляется `model.define`,
--- как и для спейса, — форма, проверка входа, хуки, отметки, области.
--- Пакет даёт ей шлюз `sql` (`orm.gateway`): запрос собирает `tnt-sql`,
--- выполняет драйвер SQL, отказ базы становится отказом модели того
--- же рода. Схему таблицы шлюз выводит из объявления: шаг
--- `Model.migration()` на модели, привязанной к шлюзу `sql`, создаёт
--- таблицу и индексы в базе вместо спейса (`orm.statements` показывает
--- их текст).
---
--- Источник выбирает раздел `models` настроек привязки: `source = 'sql'`,
--- и шлюз приходит `model.bind` третьим аргументом; код моделей при этом
--- не меняется.
---
--- Части: `gateway` — шлюз, `query` — выборка модели запросом `tnt-sql`,
--- `columns` — значения по пути в базу и обратно, `ddl` — схема таблицы,
--- `refusal` — отказ базы отказом модели, `world` — часы отметок.

local must = require('tnt.must')

local ddl = require('tnt.orm.ddl')
local gateway = require('tnt.orm.gateway')
local world = require('tnt.orm.world')

local Module = {}

--- Имя шлюза: так его называет `binding.status()` и `Model.bound()`.
Module.KIND = gateway.KIND

--- Диалекты, которые шлюз знает.
Module.DIALECTS = { 'postgres', 'mysql' }

--- Подмена внешних зависимостей — для проверок.
Module._set_source = world._set_source

--- Шлюз модели над драйвером SQL.
---
--- Драйвер — `tnt-postgres` либо `tnt-mysql`: `query`, `execute`,
--- `transaction` и диалект. Иное — ошибка программиста на строке
--- вызывающего.
---@param db table Драйвер SQL
---@return TntModelGateway
function Module.gateway(db)
    local caller = must.at(2)

    caller.table(db, 'драйвер')
    caller.callable(db.transaction, 'драйвер.transaction')
    caller.one_of((db.dialect or {}).name, 'диалект драйвера', Module.DIALECTS)

    return gateway.new(db)
end

--- Операторы схемы таблицы модели под диалект — текст, который выполнит
--- шаг миграции на шлюзе `sql`.
---@param model TntModel
---@param dialect string postgres либо mysql
---@return string[]
function Module.statements(model, dialect)
    must.at(2).one_of(dialect, 'диалект', Module.DIALECTS)

    return ddl.statements(model._shape, dialect)
end

return Module
