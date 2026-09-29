--- Общие средства проверок шлюза `sql`.
---
--- Двойник здесь — драйвер SQL целиком, а не рок: шлюз говорит
--- с драйвером (`query`, `execute`, `transaction`, диалект), и всё, что
--- он решает, — по тому, что драйвер вернул. Двойник повторяет договор
--- драйвера SQL над роком из `tnt-storage`: отказ сборки проходит
--- насквозь, тело транзакции ничего не вернуло — фиксация и `true`,
--- `nil` или `false` — откат и пара, исключение тела — откат и исключение
--- дальше, первый отказ оператора помечает транзакцию. Что тексты
--- принимают настоящие серверы, проверяет `orm_live_test.lua`.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.model`, `tnt.sql`, `tnt.must`, `tnt.external`,
--- `tnt.clock` — и драйверы живых проверок `tnt.postgres`, `tnt.mysql`
--- берутся из `.rocks` обычным `require`: проверяется этот пакет, а не они.
---
--- Исходники грузятся заново на каждую проверку: у шлюза подменённые
--- часы. Фасад моделей из `.rocks` тоже берётся заново: у него привязка
--- процесса, и проверка, забывшая привязать свои модели, иначе шла бы
--- через привязку предыдущей.
---
--- Оснастка в `test/testing/` — загрузчик исходников — грузится так же,
--- файлом, и один раз на процесс: второй экземпляр загрузчика не знал бы,
--- что вытеснил первый, и не вернул бы вытесненное на место.
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в репозитории, где пакет живёт рядом со своими зависимостями.

local fio = require('fio')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    unload_sources = package.loaded['tnt.testing.sources'].unload,
}

local helper = {}

--- Модули пакета в порядке зависимостей.
helper.MODULES = {
    { name = 'tnt.orm.world', path = 'tnt/orm/world.lua' },
    { name = 'tnt.orm.columns', path = 'tnt/orm/columns.lua' },
    { name = 'tnt.orm.ddl', path = 'tnt/orm/ddl.lua' },
    { name = 'tnt.orm.query', path = 'tnt/orm/query.lua' },
    { name = 'tnt.orm.refusal', path = 'tnt/orm/refusal.lua' },
    { name = 'tnt.orm.gateway', path = 'tnt/orm/gateway.lua' },
    { name = 'tnt.orm', path = 'tnt/orm.lua' },
}

--- Час, который ставят подменённые часы; проверка вправе его сдвинуть.
helper.NOW = 1790000000.25

--- Час подменённых часов сейчас.
helper.now = helper.NOW

---@class TntOrmLoaded
---@field orm any Фасад `tnt.orm`
---@field model any Фасад `tnt.model` той же загрузки
---@field failure any Отказы драйвера `tnt.storage.failure`
---@field sql any Построитель запросов

--- Забывает фасад моделей и его части: следующий `require` возьмёт их
--- из `.rocks` заново, с пустой привязкой процесса.
local function forget_models()
    for name in pairs(package.loaded) do
        if name == 'tnt.model' or name:find('^tnt%.model%.') ~= nil then
            package.loaded[name] = nil
        end
    end
end

--- Грузит исходники заново и ставит часы отметок.
---
--- Драйверы живых проверок приходят из `.rocks`, и грузить для них
--- нечего: аргумент — для файла проверок, общего с репозиторием, где
--- драйверы грузятся исходниками.
---@param _ any Модули драйверов — здесь не нужны
---@return TntOrmLoaded
function helper.load(_)
    forget_models()

    local orm = testing.load_sources(helper.MODULES, 'tnt.orm')

    helper.now = helper.NOW

    orm._set_source({
        clock = function()
            return {
                realtime = function()
                    return helper.now
                end,
            }
        end,
    })

    return {
        orm = orm,
        model = require('tnt.model'),
        failure = require('tnt.storage.failure'),
        sql = require('tnt.sql'),
    }
end

--- Убирает исходники: следующая проверка грузит их заново.
---@param _ any Модули драйверов — здесь не нужны
function helper.unload(_)
    testing.unload_sources(helper.MODULES)
    forget_models()
end

--- Группа проверок со свежими исходниками на каждую проверку.
---
--- Загрузка — одна таблица на всю группу, её поля переписываются перед
--- каждой проверкой: проверки берут её один раз, при объявлении.
---@param name string
---@return table g
---@return TntOrmLoaded loaded
function helper.group(name)
    local g = t.group(name)
    local loaded = {}

    g.before_each(function()
        for key, value in pairs(helper.load(nil)) do
            loaded[key] = value
        end
    end)
    g.after_each(helper.unload)

    return g, loaded
end

--- Модуль той же загрузки: свой — из исходников, чужой — из `.rocks`.
---@param name string
---@return any
function helper.module(name)
    return package.loaded[name] or require(name)
end

--- Модули драйверов живым проверкам: здесь они приходят из `.rocks`
--- (`make deps`), и грузить исходниками нечего.
---@return nil
function helper.drivers()
    return nil
end

--- Почему рок драйвера нельзя взять живым проверкам; можно — пусто,
--- и рок загружен.
---
--- Рок `mysql` — форк, собранный по заплатам `rocks/mysql/`, и на роке,
--- собранном до новой заплаты, проверки падали бы на том, что она чинит:
--- без заплаты 0008 `false` столбца `boolean` время от времени читался
--- `true`. Сверка — `test/fork.lua`, та же, что у проверок `tnt-mysql`,
--- и идёт она до загрузки: такой рок в процесс проверок не попадает
--- вовсе. У рока `pg` отпечатка сборки нет, и его только пробуют загрузить.
---@param rock string Имя рока: pg либо mysql
---@return string|nil
function helper.unusable_rock(rock)
    if rock == 'mysql' then
        return dofile('test/fork.lua').unusable()
    end

    if not pcall(require, rock) then
        return ('нет рока %s (make deps-%s)'):format(rock, rock)
    end

    return nil
end

--- Чтение окружения для настроек живых проверок: порты стенда.
---
--- `tnt-env` приходит из `.rocks`: сам пакет окружения не читает,
--- и его зависимостью он не объявлен — его ставит `make deps`.
---@return table
function helper.stand_env()
    return require('tnt.env')
end

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

---@class TntOrmCall Обращение к двойнику драйвера
---@field op string query либо execute
---@field sql string|nil Текст
---@field params table|nil Параметры
---@field tx boolean Шло ли соединением транзакции

---@class TntOrmFakeDb Двойник драйвера SQL
---@field dialect { name: string }
---@field calls (TntOrmCall|string)[] Обращения по порядку; `begin`, `commit`, `rollback`, `drop` — строкой
---@field query fun(self: TntOrmFakeDb, sql: string|nil, params: any): table|nil, any
---@field execute fun(self: TntOrmFakeDb, sql: string|nil, params: any): table|nil, any
---@field transaction fun(self: TntOrmFakeDb, fn: fun(tx: table): any, any): any, any

--- Значения списком с их числом: «ничего» отличается от `nil`.
---@param ... any
---@return table
local function packed(...)
    return { n = select('#', ...), ... }
end

--- Двойник драйвера: пишет обращения и отвечает тем, что скажет `respond`.
---
--- `respond(call)` отдаёт ответ оператора: записи либо `{ affected }`,
--- а отказ — парой `nil, err`. Без него выборка пуста, оператор без
--- выборки отвечает `{ affected = 1 }`.
---@param dialect string postgres либо mysql
---@param respond (fun(call: TntOrmCall): any, any)|nil
---@return TntOrmFakeDb
function helper.fake_db(dialect, respond)
    local db = { dialect = { name = dialect }, calls = {} }

    --- Оператор: запись обращения и ответ.
    ---@param op string
    ---@param tx boolean
    ---@param sql string|nil
    ---@param params any
    ---@return any value
    ---@return any err
    local function run(op, tx, sql, params)
        -- Отказ сборки драйвер отдаёт парой, ничего не отправив.
        if sql == nil then
            return nil, params
        end

        local call = { op = op, sql = sql, params = params, tx = tx }

        table.insert(db.calls, call)

        if respond ~= nil then
            return respond(call)
        end

        if op == 'query' then
            return {}
        end

        return { affected = 1 }
    end

    function db.query(_, sql, params)
        return run('query', false, sql, params)
    end

    function db.execute(_, sql, params)
        return run('execute', false, sql, params)
    end

    function db.transaction(_, fn)
        local failed = nil
        local tx = {}

        function tx.query(_, sql, params)
            local rows, err = run('query', true, sql, params)

            failed = failed or err

            return rows, err
        end

        function tx.execute(_, sql, params)
            local done, err = run('execute', true, sql, params)

            failed = failed or err

            return done, err
        end

        table.insert(db.calls, 'begin')

        -- Как у драйвера: тело ничего не вернуло — согласие, отказ
        -- оператора побеждает ответ тела, пустое и ложь — отмена.
        local results = packed(pcall(fn, tx))

        if not results[1] then
            table.insert(db.calls, 'drop')
            error(results[2], 0)
        end

        local verdict = results[2]

        if results.n == 1 then
            verdict = true
        end

        if failed == nil and verdict ~= nil and verdict ~= false then
            table.insert(db.calls, 'commit')

            return verdict
        end

        table.insert(db.calls, 'rollback')

        return nil, failed or results[3] or 'тело отменило транзакцию'
    end

    return db
end

--- Обращения двойника без отметок транзакции — только операторы.
---@param db TntOrmFakeDb
---@return TntOrmCall[]
function helper.statements(db)
    local found = {}

    for _, call in ipairs(db.calls) do
        if type(call) == 'table' then
            table.insert(found, call)
        end
    end

    return found
end

--- Параметры обращения строками: `int64` и `uuid` сверяются видом, а не
--- ссылкой на cdata.
---@param params table
---@return string[]
function helper.shown(params)
    local shown = {}

    for position = 1, params.n do
        local value = params[position]

        shown[position] = value == nil and 'NULL' or tostring(value)
    end

    return shown
end

return helper
