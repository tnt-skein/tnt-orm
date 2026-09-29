--- Живые проверки шлюза `sql` против PostgreSQL и MySQL стенда
--- (`make postgres-up`, `make mysql-up`).
---
--- Двойник драйвера показывает, какие тексты шлюз собирает; здесь —
--- что серверы понимают их так, как думает модель: схема из объявления
--- и её повтор, занятый ключ и занятый уникальный индекс — каждый своим
--- именем в тексте отказа, отметка создания, переходящая при замене,
--- страницы курсором и по номеру в порядке индекса с пустыми значениями,
--- ключи за 2^53, мягкое удаление, транзакция и отказы родами модели.
--- Один и тот же набор идёт на обоих серверах: модель одна.
---
--- Без рока (`make deps-pg`, `make deps-mysql`), на роке `mysql`,
--- собранном не по заплатам дерева, или без поднятого стенда проверки
--- пропускаются, а не падают: гейты от докера не зависят.

local t = require('luatest')
local json = require('json')
local uuid = require('uuid')

local helper = dofile('test/helper.lua')

--- Окружение стенда — через `tnt-env`, как у соседей.
local env = helper.stand_env()

--- Пароль стенда: с кавычкой и обратной чертой нарочно.
local PASSWORD = "app'se\\cret"

--- Модули драйверов: оба фасада и то, на чём они стоят.
local DRIVERS = helper.drivers()

--- Стенды: рок, модуль фасада и порт.
local STANDS = {
    postgres = { rock = 'pg', module = 'tnt.postgres', port = env.int('STAND_POSTGRES_PORT', 15432) },
    mysql = { rock = 'mysql', module = 'tnt.mysql', port = env.int('STAND_MYSQL_PORT', 13306) },
}

--- Таблица проверок: своя, чтобы не задеть таблицы проверок драйверов,
--- и своя у каждого прогона. Стенд один на машину, а проверки идут разом
--- из нескольких рабочих копий дерева: общую таблицу соседний прогон
--- сносил бы и заводил заново посреди этого.
local SPACE = 'orm_live_users_' .. uuid.str():sub(1, 8)

--- Объявление модели: все роды полей, отметки, мягкое удаление, область,
--- индекс по необязательному полю.
---@param model any
---@return table
local function spec_of(model)
    return {
        space = SPACE,
        fields = {
            { 'id', 'unsigned', primary = true },
            { 'name', 'string', min = 1, max = 64, trim = true },
            { 'age', 'unsigned', max = 150 },
            { 'email', 'string', optional = true, max = 100 },
            { 'score', 'number', optional = true },
            { 'active', 'boolean', default = true },
            { 'token', 'uuid', optional = true },
            model.created_at(),
            model.updated_at(),
            model.deleted_at(),
        },
        indexes = {
            age = { parts = { 'age' }, unique = false },
            email = { parts = { 'email' }, unique = true },
            named = { parts = { 'name', 'email' }, unique = false },
        },
        scopes = { active = { { 'active', '=', true } } },
    }
end

--- Ключи записей страницы по порядку.
---@param rows table[]
---@return any[]
local function ids(rows)
    local found = {}

    for position, row in ipairs(rows) do
        found[position] = row.id
    end

    return found
end

for dialect, stand in pairs(STANDS) do
    local g = t.group('tnt.orm.live.' .. dialect)

    --- Почему живые проверки не идут; идут — пусто.
    ---@return string|nil
    local function unavailable()
        local unusable = helper.unusable_rock(stand.rock)

        if unusable ~= nil then
            return unusable
        end

        helper.load(DRIVERS)

        local probe = helper.module(stand.module).new({
            port = stand.port,
            user = 'app',
            password = PASSWORD,
            db = 'app',
            timeout = 0.5,
            pool = { wait_timeout = 0.5 },
        })
        local rows = probe:query('select 1 as one')

        probe:close()
        helper.unload(DRIVERS)

        if rows == nil then
            return ('нет стенда %s (make %s-up)'):format(dialect, dialect)
        end

        return nil
    end

    local UNAVAILABLE = unavailable()

    g.before_each(function()
        t.skip_if(UNAVAILABLE ~= nil, UNAVAILABLE)

        local loaded = helper.load(DRIVERS)

        g.model = loaded.model
        g.db = helper.module(stand.module).new({
            port = stand.port,
            user = 'app',
            password = PASSWORD,
            db = 'app',
            timeout = 3,
        })
        assert(g.db:execute('drop table if exists ' .. SPACE))

        g.User = g.model.define(spec_of(g.model))
        g.binding = g.model.bind({ g.User }, g.model.settings({ source = 'sql' }), { sql = loaded.orm.gateway(g.db) })
        g.binding.attach()

        -- Шаг схемы дважды: второй подъём на соседнем узле таблицу не трогает.
        g.User.migration()(nil)
        g.User.migration()(nil)
    end)

    g.after_each(function()
        if g.db ~= nil then
            g.binding.close()
            g.db:execute('drop table if exists ' .. SPACE)
            g.db:close()
            g.db = nil
            helper.unload(DRIVERS)
        end
    end)

    g.test_records_round_trip_with_their_kinds_and_stamps = function()
        local User = g.User
        local token = '6ba7b810-9dad-11d1-80b4-00c04fd430c8'
        local created =
            User.create({ id = 1, name = '  Мария ', age = 46, score = 0.1 + 0.2, token = token:upper() })

        t.assert_equals(created.name, 'Мария')

        local found = User.find(1)

        t.assert_equals(found:to_table(), {
            id = 1,
            name = 'Мария',
            age = 46,
            score = 0.1 + 0.2,
            active = true,
            token = token,
            created_at = helper.NOW,
            updated_at = helper.NOW,
        })
        t.assert_equals(User.find(2), nil)

        -- Замена берёт отметку создания у прежней строки, даже когда
        -- запись сохранили, не читая.
        helper.now = helper.NOW + 42

        local replaced = assert(User.validate({ id = 1, name = 'Мария', age = 47, active = false }))

        assert(replaced:save())
        t.assert_equals(User.find(1):to_table(), {
            id = 1,
            name = 'Мария',
            age = 47,
            active = false,
            created_at = helper.NOW,
            updated_at = helper.NOW + 42,
        })

        local taken, err = User.create({ id = 1, name = 'Иван', age = 30 })

        t.assert_equals(taken, nil)
        t.assert_equals(err.kind, 'conflict')
        t.assert_equals(tostring(err), ('запись %s с таким ключом уже есть'):format(SPACE))
    end

    g.test_keys_beyond_2_53_keep_their_digits = function()
        local User = g.User

        assert(User.create({ id = 9007199254740993ULL, name = 'большой', age = 1 }))
        assert(User.create({ id = 9007199254740992ULL, name = 'сосед', age = 1 }))

        t.assert_equals(User.find(9007199254740993ULL).name, 'большой')
        t.assert_equals(tostring(User.where('id', '>', 2 ^ 53):first().id):gsub('U?LL$', ''), '9007199254740993')
    end

    g.test_pages_follow_the_index_with_empty_values_first = function()
        local User = g.User

        for id, email in ipairs({ 'c@x', false, 'a@x', false, 'b@x' }) do
            assert(User.create({ id = id, name = 'n', age = 30, email = email or nil }))
        end

        -- Пустое значение меньше любого: по возрастанию — первым.
        t.assert_equals(ids(User.where('email', '>=', 'a'):all()), { 3, 5, 1 })
        t.assert_equals(ids(User.where('email', '<', 'c'):all()), { 5, 3, 4, 2 })

        local first = User.where('email', '<', 'z'):limit(2):all()
        local second = User.where('email', '<', 'z'):limit(2):after(first[2]):all()

        t.assert_equals(ids(first), { 1, 5 })
        t.assert_equals(ids(second), { 3, 4 })
        t.assert_equals(ids(User.where('email', '<', 'z'):limit(10):offset(3):all()), { 4, 2 })

        -- Страница, кончившаяся записью без почты, продолжается от места
        -- NULL — и с курсором из JSON, где почта `null`.
        t.assert_equals(ids(User.where('email', '<', 'z'):limit(2):after(second[2]):all()), { 2 })
        t.assert_equals(ids(User.where('email', '<=', 'z'):after(json.decode('{"email": null, "id": 4}')):all()), { 2 })

        -- В составном индексе по возрастанию записи без почты — первыми.
        local named = User.where('name', '=', 'n'):limit(1):all()

        t.assert_equals(ids(named), { 2 })
        t.assert_equals(ids(User.where('name', '=', 'n'):limit(2):after(named[1]):all()), { 4, 3 })
        t.assert_equals(ids(User.where('name', '=', 'n'):after(User.find(4)):all()), { 3, 5, 1 })

        local page = User.where('age', '=', 30):limit(2):all()

        t.assert_equals(ids(page), { 1, 2 })
        t.assert_equals(ids(User.where('age', '=', 30):limit(2):after(page[2]):all()), { 3, 4 })
        t.assert_equals(User.where('age', 'between', { 29, 31 }):count(), 5)
        t.assert_equals(User.where('age', '>', 30):count(), 0)
    end

    g.test_soft_delete_and_scopes_narrow_the_selection = function()
        local User = g.User

        assert(User.create({ id = 1, name = 'a', age = 20 }))
        assert(User.create({ id = 2, name = 'b', age = 21, active = false }))
        assert(User.create({ id = 3, name = 'c', age = 22 }))

        t.assert_equals(User.delete(1), true)
        t.assert_equals(User.delete(1), false)
        t.assert_equals(User.find(1), nil)
        t.assert_equals(ids(User.scan():all()), { 2, 3 })
        t.assert_equals(User.scan():count(), 2)
        t.assert_equals(ids(User.scan():scope('active'):all()), { 3 })
        t.assert_equals(ids(User.scan():only_deleted():all()), { 1 })
        t.assert_equals(User.where('id', '=', 1):with_deleted():first().deleted_at, helper.NOW)
        t.assert_equals(User.restore(1), true)
        t.assert_equals(User.find(1).deleted_at, nil)
        t.assert_equals(User.force_delete(1), true)
        t.assert_equals(User.where('id', '=', 1):with_deleted():first(), nil)
    end

    g.test_atomic_commits_the_body_and_rolls_back_on_a_throw = function()
        local User = g.User
        local model = g.model

        t.assert_equals({
            model.atomic(function(age)
                assert(User.create({ id = 1, name = 'a', age = age }))
                assert(User.create({ id = 2, name = 'b', age = age }))

                return 'готово', User.where('age', '=', age):count()
            end, 40),
        }, { 'готово', 2 })

        t.assert_error_msg_contains('передумали', model.atomic, function()
            assert(User.create({ id = 3, name = 'c', age = 1 }))
            error('передумали')
        end)
        t.assert_equals(User.find(3), nil)

        -- Отказ оператора помечает транзакцию: фиксации не будет.
        local done, err = model.atomic(function()
            assert(User.create({ id = 4, name = 'd', age = 1 }))
            User.create({ id = 1, name = 'дубль', age = 1 })
        end)

        t.assert_equals(done, nil)
        t.assert_equals(err.kind, 'conflict')
        t.assert_equals(tostring(err), ('запись %s с таким ключом уже есть'):format(SPACE))
        t.assert_equals(User.find(4), nil)
    end

    g.test_a_conflict_names_the_taken_unique_index = function()
        local User = g.User

        assert(User.create({ id = 1, name = 'a', age = 20, email = 'a@x' }))
        assert(User.create({ id = 3, name = 'c', age = 20, email = 'c@x' }))

        local _, keyed = User.create({ id = 1, name = 'b', age = 20, email = 'b@x' })
        local _, created = User.create({ id = 2, name = 'b', age = 20, email = 'a@x' })

        -- Замена легшей записи — правка строки под замком.
        local third = User.find(3)

        third.email = 'a@x'

        local _, saved = third:save()

        -- Фиксация транзакции модели отдаёт тот же отказ, что получил
        -- оператор: с именем индекса, а не «в транзакции».
        local seen = nil
        local done, committed = g.model.atomic(function()
            local _, refused = User.create({ id = 4, name = 'd', age = 20, email = 'a@x' })

            seen = refused
        end)

        local named = ('запись %s с таким email уже есть'):format(SPACE)

        t.assert_equals({ tostring(keyed), tostring(created), tostring(saved), tostring(committed) }, {
            ('запись %s с таким ключом уже есть'):format(SPACE),
            named,
            named,
            named,
        })
        t.assert_equals(done, nil)
        t.assert_is(committed, seen)
        t.assert_equals(User.find(3).email, 'c@x')
        t.assert_equals(User.find(4), nil)
    end

    g.test_refusals_of_the_base_come_as_kinds_of_the_model = function()
        local User = g.User

        -- Значение, которого столбец не держит: у PostgreSQL беззнаковое —
        -- bigint, у MySQL число за пределом double не пройдёт модель,
        -- поэтому у него — строка длиннее столбца, пришедшая мимо модели.
        local _, unfit

        if dialect == 'postgres' then
            _, unfit = User.create({ id = 9223372036854775808ULL, name = 'за краем', age = 1 })
        else
            local sql = helper.module('tnt.sql')

            _, unfit = g.db:execute(sql.table(SPACE, { 'id', 'name', 'age', 'active' })
                :insert({
                    id = 1,
                    name = string.rep('x', 65),
                    age = 1,
                    active = true,
                })
                :build(g.db.dialect))
            unfit = helper.module('tnt.orm.refusal').of(User._shape, unfit)
        end

        t.assert_equals(unfit.kind, 'invalid')
        t.assert_equals(unfit.cause.kind, 'rejected')

        assert(g.db:execute('drop table ' .. SPACE))

        local found, missing = User.find(1)

        t.assert_equals(found, nil)
        t.assert_equals(missing.kind, 'unavailable')
        t.assert_str_contains(tostring(missing), ('база не выполнила запрос (%s)'):format(SPACE))
    end
end
