--- Фасад и перевод отказов: аргументы `orm.gateway`, род модели по коду
--- сервера каждого перечня, имя занятого индекса в тексте `conflict`
--- по отказу каждого сервера, целое у PostgreSQL — с `int8` и точными
--- цифрами по обе стороны 2^53.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, loaded = helper.group('tnt.orm')

g.test_the_gateway_is_named_sql = function()
    local gateway = loaded.orm.gateway(helper.fake_db('mysql'))

    t.assert_equals({ loaded.orm.KIND, gateway.kind }, { 'sql', 'sql' })
end

g.test_a_wrong_driver_is_the_mistake_of_the_caller = function()
    local orm = loaded.orm
    local wrong = helper.wrong

    helper.assert_blamed({
        {
            function()
                orm.gateway(wrong('db'))
            end,
            'драйвер — таблица, а не строка',
        },
        {
            function()
                orm.gateway({ dialect = { name = 'postgres' } })
            end,
            'драйвер.transaction — функция или вызываемая таблица, а не nil',
        },
        {
            function()
                orm.gateway({ transaction = function() end })
            end,
            'диалект драйвера — одно из «postgres», «mysql», а не nil',
        },
        {
            function()
                orm.gateway({ transaction = function() end, dialect = { name = 'tarantool' } })
            end,
            'диалект драйвера — одно из «postgres», «mysql», а не «tarantool»',
        },
    })
end

--- Форма модели пользователей: ключ и два уникальных индекса, имя
--- одного — начало имени другого.
---@param space string|nil Имя таблицы; пусто — users
---@return TntModelShape
local function users(space)
    return loaded.model.define({
        space = space or 'users',
        fields = { { 'id', 'unsigned', primary = true }, { 'login', 'string' }, { 'mail', 'string' } },
        indexes = {
            login = { parts = { 'login' }, unique = true },
            login_mail = { parts = { 'login', 'mail' }, unique = true },
        },
    })._shape
end

--- Род отказа модели по отказу драйвера.
---@param kind string Род отказа драйвера
---@param opts table|nil Настройки отказа драйвера
---@return table
local function refused(kind, opts)
    local refusal = helper.module('tnt.orm.refusal')
    local err = refusal.of(users(), loaded.failure.new(kind, 'ERROR:  отказ\nDETAIL:  (id)=(1)', opts))

    return { err.kind, tostring(err) }
end

g.test_codes_of_the_server_choose_the_kind_of_the_model = function()
    -- Индекса отказ не называет: текст — без имени, а не «ключом».
    local taken = {
        'conflict',
        'запись users с таким значением уникального индекса уже есть',
    }
    local readonly = { 'readonly', 'база только для чтения: ERROR:  отказ' }
    local unfit = { 'invalid', 'запись users не прошла проверку: $ — ERROR:  отказ' }
    local unavailable = {
        'unavailable',
        'база не выполнила запрос (users): ERROR:  отказ\nDETAIL:  (id)=(1)',
    }
    local cases = {
        { '23505', taken },
        { 1062, taken },
        { '25006', readonly },
        { 1290, readonly },
        { 1792, readonly },
        { '23502', unfit },
        { '23514', unfit },
        { '22003', unfit },
        { '22P02', unfit },
        { 1048, unfit },
        { 1264, unfit },
        { 1366, unfit },
        { 1406, unfit },
        { 3819, unfit },
        { '42P01', unavailable },
        { '42201', unavailable },
        { 22003, unavailable },
        { 1146, unavailable },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(refused('rejected', { server_code = case[1] }), case[2], tostring(case[1]))
    end
end

g.test_a_value_that_never_left_is_invalid = function()
    t.assert_equals(refused('rejected', { sent = false }), {
        'invalid',
        'запись users не прошла проверку: $ — ERROR:  отказ',
    })
end

g.test_other_kinds_of_the_driver_are_unavailable_whatever_the_code = function()
    for _, kind in ipairs({ 'conflict', 'timeout', 'broken', 'unreachable', 'busy', 'closed', 'denied', 'overflow' }) do
        t.assert_equals(refused(kind, { server_code = '23505' })[1], 'unavailable', kind)
    end
end

g.test_a_failure_of_the_model_passes_as_it_is = function()
    local own = loaded.model.failure.new('refused', 'хук отказал')

    t.assert_is(helper.module('tnt.orm.refusal').of(users(), own), own)
end

--- Текст `conflict` по тексту отказа сервера.
---@param code string|integer SQLSTATE либо errno
---@param message string Текст отказа, как его отдаёт драйвер
---@param shape TntModelShape|nil Форма модели; пусто — пользователи
---@return string
local function conflict(code, message, shape)
    local err = helper
        .module('tnt.orm.refusal')
        .of(shape or users(), loaded.failure.new('rejected', message, { server_code = code }))

    t.assert_equals(err.kind, 'conflict', message)

    return tostring(err)
end

--- Отказ PostgreSQL о занятом значении: имя в первой строке, значения —
--- во второй.
---@param constraint string Имя ограничения с кавычками языка сервера
---@param detail string|nil Вторая строка
---@return string
local function postgres_taken(constraint, detail)
    return ('ERROR:  duplicate key value violates unique constraint %s\nDETAIL:  %s\n'):format(
        constraint,
        detail or 'Key (id)=(1) already exists.'
    )
end

g.test_postgres_names_the_taken_index_by_the_first_line = function()
    local key = 'запись users с таким ключом уже есть'
    local login = 'запись users с таким login уже есть'
    local unnamed =
        'запись users с таким значением уникального индекса уже есть'

    local cases = {
        { postgres_taken('"users_pkey"'), key },
        { postgres_taken('"users_login"', 'Key (login)=(users_pkey) already exists.'), login },
        { postgres_taken('"users_login_mail"'), 'запись users с таким login_mail уже есть' },
        -- Кавычки у имени свои в каждом языке сервера.
        {
            'ОШИБКА:  повторяющееся значение ключа нарушает ограничение уникальности «users_login»',
            login,
        },
        { 'FEHLER:  doppelter Schlüsselwert verletzt Unique-Constraint »users_pkey«', key },
        -- Значения строки во второй строке индекс не называют.
        { postgres_taken('"users_extra"', 'Key (login)=(users_login) already exists.'), unnamed },
        { postgres_taken('"users"'), unnamed },
        { 'ERROR:  значение занято триггером', unnamed },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(conflict('23505', case[1]), case[2], case[1])
    end
end

g.test_postgres_names_the_index_it_cut_to_63_bytes = function()
    -- Имя длиннее 63 байт сервер усекает: у индекса — целиком, у ключа —
    -- таблицу, чтобы с `_pkey` уложиться в те же 63.
    local space = 'u' .. ('x'):rep(58)
    local shape = users(space)
    local cut = (space .. '_login'):sub(1, 63)

    t.assert_equals(#cut, 63)
    t.assert_equals(
        conflict('23505', postgres_taken('"' .. cut .. '"'), shape),
        ('запись %s с таким login уже есть'):format(space)
    )
    t.assert_equals(
        conflict('23505', postgres_taken('"' .. space:sub(1, 58) .. '_pkey"'), shape),
        ('запись %s с таким ключом уже есть'):format(space)
    )

    -- Имя таблицы, которое с `_pkey` укладывается в 63 байта, не режется.
    local fits = ('y'):rep(58)

    t.assert_equals(
        conflict('23505', postgres_taken('"' .. fits .. '_pkey"'), users(fits)),
        ('запись %s с таким ключом уже есть'):format(fits)
    )
end

g.test_mysql_names_the_key_quoted_last = function()
    local key = 'запись users с таким ключом уже есть'
    local login = 'запись users с таким login уже есть'
    local unnamed =
        'запись users с таким значением уникального индекса уже есть'

    local cases = {
        { "Duplicate entry '1' for key 'users.PRIMARY'", key },
        { "Duplicate entry 'a' for key 'users.login'", login },
        {
            "Duplicate entry 'a-b' for key 'users.login_mail'",
            'запись users с таким login_mail уже есть',
        },
        -- Без имени таблицы ключ пишут серверы до 8.0.19.
        { "Duplicate entry '1' for key 'PRIMARY'", key },
        { "Duplicate entry 'a' for key 'login'", login },
        -- Значение идёт раньше ключа и само бывает с кавычкой, с именем
        -- индекса и с переводом строки.
        { "Duplicate entry 'x' for key 'users.login'' for key 'users.PRIMARY'", key },
        { "Duplicate entry 'a\nb' for key 'users.login'", login },
        { "'a' は索引 'users.login' で重複しています。", login },
        { "Duplicate entry 'login' for key 'users.extra'", unnamed },
        { "Duplicate entry 'a' for key 'other.login'", unnamed },
        { 'Duplicate entry', unnamed },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(conflict(1062, case[1]), case[2], case[1])
    end
end

g.test_a_conflict_without_a_shape_names_no_index = function()
    local err = helper.module('tnt.orm.refusal').of(
        nil,
        loaded.failure.new('rejected', "Duplicate entry '1' for key 'users.PRIMARY'", { server_code = 1062 })
    )

    t.assert_equals(
        tostring(err),
        'запись в транзакции с таким значением уникального индекса уже есть'
    )
end

g.test_an_integer_leaves_for_postgres_with_int8_and_exact_digits = function()
    local Plain = loaded.model.define({ space = 'plain', fields = { { 'id', 'integer', primary = true } } })
    local db = helper.fake_db('postgres')

    loaded.model.bind({ Plain }, loaded.model.settings({ source = 'sql' }), { sql = loaded.orm.gateway(db) }).attach()

    for _, id in ipairs({ 2 ^ 53 - 1, -(2 ^ 53 - 1), 2 ^ 53, -2 ^ 53 }) do
        assert(Plain.create({ id = id }))
    end

    local sent = {}

    for position, call in ipairs(helper.statements(db)) do
        sent[position] = { call.sql:match('values %((.-)%)'), helper.shown(call.params)[1] }
    end

    -- Шлюз отдаёт целое числом, а приведение ставит кодирование значений:
    -- целое у PostgreSQL уходит int8, а цифры — точными, без %.14g рока,
    -- и у ±(2^53 − 1), и у ±2^53.
    t.assert_equals(sent, {
        { '$1::int8', '9007199254740991' },
        { '$1::int8', '-9007199254740991' },
        { '$1::int8', '9007199254740992' },
        { '$1::int8', '-9007199254740992' },
    })
end

g.test_mysql_takes_values_as_they_are = function()
    local Plain = loaded.model.define({
        space = 'plain',
        fields = { { 'id', 'integer', primary = true }, { 'token', 'uuid', optional = true } },
    })
    local db = helper.fake_db('mysql', function(call)
        return call.op == 'query' and { { id = 5, token = '6ba7b810-9dad-11d1-80b4-00c04fd430c8' } } or { affected = 1 }
    end)

    loaded.model.bind({ Plain }, loaded.model.settings({ source = 'sql' }), { sql = loaded.orm.gateway(db) }).attach()

    assert(Plain.create({ id = 5, token = '6ba7b810-9dad-11d1-80b4-00c04fd430c8' }))
    assert(Plain.create({ id = 6 }))
    t.assert_equals(Plain.find(5):to_table(), { id = 5, token = '6ba7b810-9dad-11d1-80b4-00c04fd430c8' })

    local calls = helper.statements(db)

    t.assert_equals(calls[1].params[1], 5)
    t.assert_equals(calls[1].params[2], '6ba7b810-9dad-11d1-80b4-00c04fd430c8')
    t.assert_is(calls[2].params[2], box.NULL)
end

g.test_stamps_take_the_wall_clock_without_a_replacement = function()
    local clock = require('clock')
    local model = loaded.model
    local Stamped = model.define({ space = 's', fields = { { 'id', 'integer', primary = true }, model.created_at() } })
    local db = helper.fake_db('mysql')

    loaded.orm._set_source(nil)
    model.bind({ Stamped }, model.settings({ source = 'sql' }), { sql = loaded.orm.gateway(db) }).attach()

    local before = clock.realtime()
    local created = assert(Stamped.create({ id = 1 }))

    t.assert_ge(created.created_at, before)
    t.assert_le(created.created_at, clock.realtime())
end
