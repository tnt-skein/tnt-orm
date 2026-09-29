--- Шлюз `sql` через модель: чтение, вставка, замена под замком строки,
--- удаление всех трёх способов, выборка с приведением значений, счёт,
--- транзакция модели и шаг схемы — на двойнике драйвера, обращениями
--- дословно; `conflict` с именем занятого индекса у `create` и `save`
--- и тот же отказ оператора у фиксации транзакции модели.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, loaded = helper.group('tnt.orm.gateway')

--- Модель пользователей с отметками и мягким удалением.
---@return any
local function users()
    local model = loaded.model

    return model.define({
        space = 'users',
        fields = {
            { 'id', 'unsigned', primary = true },
            { 'name', 'string', max = 20 },
            { 'active', 'boolean', default = true },
            { 'score', 'number', optional = true },
            model.created_at(),
            model.updated_at(),
            model.deleted_at(),
        },
    })
end

--- Модель без отметок: удаление у неё окончательное.
---@return any
local function plain()
    return loaded.model.define({
        space = 'plain',
        fields = { { 'id', 'integer', primary = true }, { 'token', 'uuid', optional = true } },
    })
end

--- Модель учётных записей: ключ и уникальный индекс по логину.
---@return any
local function accounts()
    return loaded.model.define({
        space = 'accounts',
        fields = { { 'id', 'unsigned', primary = true }, { 'login', 'string', max = 20 } },
        indexes = { login = { parts = { 'login' }, unique = true } },
    })
end

--- Привязывает модели к двойнику драйвера.
---@param list any[]
---@param db TntOrmFakeDb
---@return any binding
local function bind(list, db)
    local binding = loaded.model.bind(list, loaded.model.settings({ source = 'sql' }), {
        sql = loaded.orm.gateway(db),
    })

    binding.attach()

    return binding
end

--- Обращения двойника: оператор — текстом и параметрами, отметки — строкой.
---@param db TntOrmFakeDb
---@return table[]
local function journal(db)
    local shown = {}

    for _, call in ipairs(db.calls) do
        if type(call) == 'table' then
            table.insert(shown, { call.op, call.sql, helper.shown(call.params or { n = 0 }), call.tx })
        else
            table.insert(shown, call)
        end
    end

    return shown
end

--- Шло ли каждое обращение соединением транзакции; отметки — как есть.
---@param db TntOrmFakeDb
---@return any[]
local function links(db)
    local shown = {}

    for position, call in ipairs(db.calls) do
        if type(call) == 'table' then
            shown[position] = call.tx
        else
            shown[position] = call
        end
    end

    return shown
end

--- Отказ драйвера рода rejected с кодом сервера.
---@param code any
---@param opts table|nil
---@param message string|nil Текст сервера; пусто — безымянный отказ
---@return table
local function rejected(code, opts, message)
    local given = { server_code = code }

    for key, value in pairs(opts or {}) do
        given[key] = value
    end

    return loaded.failure.new(
        'rejected',
        message or 'ERROR:  отказ\nDETAIL:  значения строки',
        given
    )
end

--- Отказ PostgreSQL о занятом значении индекса с этим именем.
---@param constraint string
---@return table
local function postgres_taken(constraint)
    return rejected(
        '23505',
        nil,
        ('ERROR:  duplicate key value violates unique constraint "%s"\nDETAIL:  Key (id)=(1) already exists.\n'):format(
            constraint
        )
    )
end

--- Отказ MySQL о занятом значении ключа с этим именем.
---@param key string
---@return table
local function mysql_taken(key)
    return rejected(1062, nil, ("Duplicate entry 'a' for key '%s'"):format(key))
end

--- Выборка строки по ключу под замком.
local LOCKED = 'select "id", "name", "active", "score", "created_at", "updated_at", "deleted_at" from "users"'
    .. ' where "id" = $1::int8 for update'

g.test_find_reads_by_key_and_converts_the_row = function()
    local User = users()
    local db = helper.fake_db('postgres', function()
        return { { id = 7, name = 'Мария', active = true, score = '0.30000000000000004' } }
    end)

    bind({ User }, db)

    t.assert_equals(User.find(7):to_table(), { id = 7, name = 'Мария', active = true, score = 0.1 + 0.2 })
    t.assert_equals(journal(db), {
        {
            'query',
            'select "id", "name", "active", "score", "created_at", "updated_at", "deleted_at" from "users"'
                .. ' where "id" = $1::int8',
            { '7' },
            false,
        },
    })
end

g.test_find_of_a_missing_row_is_empty_and_a_refusal_is_a_pair = function()
    local User = users()
    local answer = { {} } --[[@as any[] ]]
    local db = helper.fake_db('mysql', function()
        return unpack(answer)
    end)

    bind({ User }, db)

    t.assert_equals(User.find(7), nil)

    answer = { nil, loaded.failure.new('timeout', 'ответа нет за 5 с') }

    local found, err = User.find(7)

    t.assert_equals(found, nil)
    t.assert_equals(err.kind, 'unavailable')
    t.assert_equals(
        tostring(err),
        'база не выполнила запрос (users): ответа нет за 5 с'
    )
    t.assert_equals(err.cause.kind, 'timeout')
end

g.test_mysql_boolean_comes_as_a_number_and_turns_into_logic = function()
    local User = users()
    local db = helper.fake_db('mysql', function()
        return { { id = 1, name = 'a', active = 0 }, { id = 2, name = 'b', active = 1 } }
    end)

    bind({ User }, db)

    local rows = User.scan():with_deleted():all()

    t.assert_equals({ rows[1].active, rows[2].active }, { false, true })
end

g.test_create_inserts_one_statement_with_stamps = function()
    local User = users()
    local db = helper.fake_db('postgres')

    bind({ User }, db)

    t.assert_equals(User.create({ id = 1, name = 'a', score = 2 }):to_table(), {
        id = 1,
        name = 'a',
        active = true,
        score = 2,
        created_at = helper.NOW,
        updated_at = helper.NOW,
    })
    t.assert_equals(journal(db), {
        {
            'execute',
            'insert into "users" ("active", "created_at", "deleted_at", "id", "name", "score", "updated_at")'
                .. ' values ($1, $2, $3::double precision, $4::int8, $5, $6::int8, $7)',
            { 'true', tostring(helper.NOW), 'NULL', '1', 'a', '2', tostring(helper.NOW) },
            false,
        },
    })
end

g.test_create_on_a_taken_key_is_a_conflict = function()
    local User = users()
    local db = helper.fake_db('postgres', function()
        return nil, postgres_taken('users_pkey')
    end)

    bind({ User }, db)

    local created, err = User.create({ id = 1, name = 'a' })

    t.assert_equals(created, nil)
    t.assert_equals(err.kind, 'conflict')
    t.assert_equals(tostring(err), 'запись users с таким ключом уже есть')
end

--- Отказы о занятом логине и о занятом ключе на каждом сервере.
local TAKEN = {
    postgres = { 'accounts_login', 'accounts_pkey' },
    mysql = { 'accounts.login', 'accounts.PRIMARY' },
}

for dialect, names in pairs(TAKEN) do
    g['test_a_conflict_names_the_taken_unique_index_on_' .. dialect] = function()
        local Account = accounts()
        local taken = dialect == 'postgres' and postgres_taken or mysql_taken
        local answer = nil
        local db = helper.fake_db(dialect, function(call)
            if call.op == 'query' then
                return {}
            end

            return nil, answer
        end)

        bind({ Account }, db)

        -- Вставка — одним оператором, замена — под замком строки: отказ
        -- оператора внутри своей транзакции и отказ её фиксации называют
        -- один индекс.
        answer = taken(names[1])

        local _, created = Account.create({ id = 1, login = 'a' })
        local _, saved = assert(Account.validate({ id = 2, login = 'a' })):save()

        answer = taken(names[2])

        local _, keyed = Account.create({ id = 1, login = 'b' })

        t.assert_equals({ tostring(created), tostring(saved), tostring(keyed) }, {
            'запись accounts с таким login уже есть',
            'запись accounts с таким login уже есть',
            'запись accounts с таким ключом уже есть',
        })
        t.assert_equals({ created.kind, saved.kind, keyed.kind }, { 'conflict', 'conflict', 'conflict' })
    end
end

g.test_save_of_a_new_key_inserts_under_the_lock = function()
    local User = users()
    local db = helper.fake_db('postgres', function(call)
        return call.op == 'query' and {} or { affected = 1 }
    end)

    bind({ User }, db)

    local saved = assert(User.validate({ id = 3, name = 'c' })):save()

    t.assert_equals(saved.created_at, helper.NOW)
    t.assert_equals(journal(db), {
        'begin',
        { 'query', LOCKED, { '3' }, true },
        {
            'execute',
            'insert into "users" ("active", "created_at", "deleted_at", "id", "name", "score", "updated_at")'
                .. ' values ($1, $2, $3::double precision, $4::int8, $5, $6::double precision, $7)',
            { 'true', tostring(helper.NOW), 'NULL', '3', 'c', 'NULL', tostring(helper.NOW) },
            true,
        },
        'commit',
    })
end

g.test_save_of_an_existing_row_keeps_its_creation_stamp = function()
    local User = users()
    local db = helper.fake_db('postgres', function(call)
        if call.op == 'query' then
            return { { id = 3, name = 'c', active = true, created_at = '100.5', updated_at = '100.5' } }
        end

        return { affected = 1 }
    end)

    bind({ User }, db)

    local saved = assert(User.validate({ id = 3, name = 'd' })):save()

    t.assert_equals(saved:to_table(), {
        id = 3,
        name = 'd',
        active = true,
        created_at = 100.5,
        updated_at = helper.NOW,
    })
    t.assert_equals(journal(db)[3], {
        'execute',
        'update "users" set "active" = $1, "created_at" = $2, "deleted_at" = $3::double precision,'
            .. ' "name" = $4, "score" = $5::double precision, "updated_at" = $6 where "id" = $7::int8',
        { 'true', '100.5', 'NULL', 'd', 'NULL', tostring(helper.NOW), '3' },
        true,
    })
    t.assert_equals(journal(db)[4], 'commit')
end

g.test_a_refused_write_under_the_lock_rolls_back = function()
    local User = users()
    local db = helper.fake_db('postgres', function(call)
        if call.op == 'query' then
            return {}
        end

        return nil, rejected('22003')
    end)

    bind({ User }, db)

    local saved, err = assert(User.validate({ id = 3, name = 'c' })):save()

    t.assert_equals(saved, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(err.fields, { ['$'] = 'ERROR:  отказ' })
    t.assert_equals(journal(db)[4], 'rollback')
end

g.test_a_refused_lock_is_a_pair = function()
    local User = users()
    local db = helper.fake_db('mysql', function()
        return nil, loaded.failure.new('busy', 'пул занят')
    end)

    bind({ User }, db)

    local removed, err = User.delete(3)

    t.assert_equals(removed, nil)
    t.assert_equals(err.kind, 'unavailable')
    t.assert_equals(db.calls[#db.calls], 'rollback')
end

g.test_a_string_with_a_zero_byte_never_leaves_for_postgres = function()
    local User = users()
    local db = helper.fake_db('postgres')

    bind({ User }, db)

    local created, err = User.create({ id = 1, name = 'a\0b' })

    t.assert_equals(created, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(err.cause.sent, false)
    t.assert_equals(db.calls, {})

    local saved, refused = assert(User.validate({ id = 1, name = 'a\0b' })):save()

    t.assert_equals(saved, nil)
    t.assert_equals(refused.kind, 'invalid')
end

g.test_soft_delete_marks_and_restore_clears = function()
    local User = users()
    local row = { id = 3, name = 'c', active = true, created_at = '100.5' }
    local db = helper.fake_db('postgres', function(call)
        return call.op == 'query' and { row } or { affected = 1 }
    end)

    bind({ User }, db)

    t.assert_equals(User.delete(3), true)
    t.assert_equals(journal(db)[3], {
        'execute',
        'update "users" set "active" = $1, "created_at" = $2, "deleted_at" = $3, "name" = $4,'
            .. ' "score" = $5::double precision, "updated_at" = $6 where "id" = $7::int8',
        { 'true', '100.5', tostring(helper.NOW), 'c', 'NULL', tostring(helper.NOW), '3' },
        true,
    })

    -- Удалённую не удаляют второй раз, живую не восстанавливают.
    row.deleted_at = '200.5'
    t.assert_equals(User.delete(3), false)
    t.assert_equals(User.restore(3), true)

    row.deleted_at = nil
    t.assert_equals(User.restore(3), false)
    t.assert_equals(User.delete(99), true)
end

g.test_delete_of_a_missing_row_answers_false_without_a_write = function()
    local User = users()
    local db = helper.fake_db('postgres')

    bind({ User }, db)

    t.assert_equals(User.delete(3), false)
    t.assert_equals(journal(db), { 'begin', { 'query', LOCKED, { '3' }, true }, 'commit' })
end

g.test_force_delete_and_a_model_without_mark_erase_the_row = function()
    local User = users()
    local Plain = plain()
    local db = helper.fake_db('postgres', function(call)
        return call.op == 'query' and { { id = 3 } } or { affected = 1 }
    end)

    bind({ User, Plain }, db)

    t.assert_equals(User.force_delete(3), true)
    t.assert_equals(journal(db)[3], { 'execute', 'delete from "users" where "id" = $1::int8', { '3' }, true })
    t.assert_equals(Plain.delete(4), true)
    t.assert_equals(journal(db)[7], { 'execute', 'delete from "plain" where "id" = $1::int8', { '4' }, true })
end

g.test_a_refused_erase_is_a_pair = function()
    local Plain = plain()
    local db = helper.fake_db('postgres', function(call)
        if call.op == 'query' then
            return { { id = 3 } }
        end

        return nil, rejected('25006')
    end)

    bind({ Plain }, db)

    local removed, err = Plain.delete(3)

    t.assert_equals(removed, nil)
    t.assert_equals(err.kind, 'readonly')
    t.assert_equals(tostring(err), 'база только для чтения: ERROR:  отказ')
end

g.test_refusals_inside_atomic_come_back_to_the_body_as_pairs = function()
    local User = users()
    local Plain = plain()
    local answers = {}
    local db = helper.fake_db('postgres', function()
        local answer = table.remove(answers, 1)

        return answer[1], answer[2]
    end)

    bind({ User, Plain }, db)

    local seen = {}

    local done, err = loaded.model.atomic(function()
        -- Замок не взят.
        answers = { { nil, loaded.failure.new('timeout', 'ответа нет') } }
        table.insert(seen, { User.delete(1) })

        -- Строка есть, пометка отвергнута.
        answers = { { { { id = 1, name = 'a' } } }, { nil, rejected('25006') } }
        table.insert(seen, { User.delete(1) })

        -- Строка есть, удаление отвергнуто.
        answers = { { { { id = 2 } } }, { nil, rejected('25006') } }
        table.insert(seen, { Plain.delete(2) })
    end)

    t.assert_equals(done, nil)
    t.assert_equals(err.kind, 'unavailable')

    local shown = {}

    for position, pair in ipairs(seen) do
        shown[position] = { pair[1], pair[2].kind }
    end

    t.assert_equals(shown, { { nil, 'unavailable' }, { nil, 'readonly' }, { nil, 'readonly' } })

    -- Фиксацию сорвал первый отказ, и ответ — он же, как его получил
    -- оператор: следующие отказы его не подменяют.
    t.assert_is(err, seen[1][2])
    t.assert_equals(tostring(err), 'база не выполнила запрос (users): ответа нет')
end

g.test_the_refusal_that_marked_atomic_comes_to_later_statements_and_the_commit = function()
    local Account = accounts()
    local Plain = plain()
    local taken = postgres_taken('accounts_login')
    local db = helper.fake_db('postgres', function()
        -- Как у драйвера: отказ, пометивший транзакцию, — и следующим.
        return nil, taken
    end)

    bind({ Account, Plain }, db)

    local seen = {}
    local done, err = loaded.model.atomic(function()
        table.insert(seen, select(2, Account.create({ id = 1, login = 'a' })))
        table.insert(seen, select(2, Plain.create({ id = 2 })))

        return 'готово'
    end)

    t.assert_equals(done, nil)
    t.assert_equals(tostring(err), 'запись accounts с таким login уже есть')
    t.assert_is(seen[1], err)
    t.assert_is(seen[2], err)
end

g.test_a_commit_refused_on_its_own_is_named_by_the_transaction = function()
    local User = users()
    local db = helper.fake_db('mysql')
    local commit = loaded.failure.new('broken', 'соединение оборвалось')

    bind({ User }, db)

    -- Фиксация отказала сама, ни один оператор отказа не видел.
    db.transaction = function(_, fn)
        fn(db)

        return nil, commit
    end

    local done, err = loaded.model.atomic(function()
        assert(User.create({ id = 1, name = 'a' }))
    end)

    t.assert_equals(done, nil)
    t.assert_equals(err.kind, 'unavailable')
    t.assert_equals(
        tostring(err),
        'база не выполнила запрос (в транзакции): соединение оборвалось'
    )
    t.assert_is(err.cause, commit)
end

g.test_uuid_and_integers_leave_for_postgres_with_their_types = function()
    local Plain = plain()
    local db = helper.fake_db('postgres')

    bind({ Plain }, db)

    assert(Plain.create({ id = -5, token = '6BA7B810-9DAD-11D1-80B4-00C04FD430C8' }))
    t.assert_equals(journal(db), {
        {
            'execute',
            'insert into "plain" ("id", "token") values ($1::int8, $2::uuid)',
            { '-5', '6ba7b810-9dad-11d1-80b4-00c04fd430c8' },
            false,
        },
    })
end

g.test_select_and_count_refusals_are_pairs = function()
    local User = users()
    local db = helper.fake_db('postgres', function()
        return nil, rejected('42P01')
    end)

    bind({ User }, db)

    local rows, err = User.scan():all()

    t.assert_equals(rows, nil)
    t.assert_equals(err.kind, 'unavailable')

    local counted, refused = User.scan():count()

    t.assert_equals(counted, nil)
    t.assert_equals(refused.kind, 'unavailable')
end

g.test_atomic_runs_the_body_on_one_connection = function()
    local User = users()
    local db = helper.fake_db('postgres', function(call)
        return call.op == 'query' and { { id = 1, name = 'a' } } or { affected = 1 }
    end)

    bind({ User }, db)

    t.assert_equals({
        loaded.model.atomic(function(first, second)
            return User.find(1).name, User.delete(1), first, nil, second
        end, 'x', 'y'),
    }, { 'a', true, 'x', nil, 'y' })

    t.assert_equals(links(db), { 'begin', true, true, true, 'commit' })

    -- После транзакции действия снова идут драйвером.
    User.find(1)
    t.assert_equals(links(db)[6], false)
end

g.test_atomic_inside_atomic_is_the_mistake_of_the_caller = function()
    local User = users()
    local db = helper.fake_db('postgres')

    bind({ User }, db)

    t.assert_error_msg_equals(
        'model.atomic внутри model.atomic: у базы транзакция одна на соединение, вложенной нет',
        loaded.model.atomic,
        function()
            loaded.model.atomic(function() end)
        end
    )

    -- Брошенное изнутри отпустило соединение: следующая транзакция своя.
    loaded.model.atomic(function()
        User.find(1)
    end)
    t.assert_equals(links(db), { 'begin', 'drop', 'begin', true, 'commit' })
end

g.test_a_throw_in_atomic_goes_on_and_frees_the_fiber = function()
    local User = users()
    local db = helper.fake_db('postgres')

    bind({ User }, db)

    local boom = setmetatable({}, {
        __tostring = function()
            return 'бросок'
        end,
    })
    local ok, err = pcall(loaded.model.atomic, function()
        error(boom)
    end)

    t.assert_equals(ok, false)
    t.assert_is(err, boom)
    t.assert_equals(db.calls, { 'begin', 'drop' })

    User.find(1)
    t.assert_equals(links(db), { 'begin', 'drop', false })
end

g.test_a_refused_statement_in_atomic_cancels_the_commit = function()
    local User = users()
    local db = helper.fake_db('mysql', function(call)
        if call.op == 'execute' then
            return nil, mysql_taken('users.PRIMARY')
        end

        return {}
    end)

    bind({ User }, db)

    local done, err = loaded.model.atomic(function()
        User.create({ id = 1, name = 'a' })

        return 'готово'
    end)

    t.assert_equals(done, nil)
    t.assert_equals(err.kind, 'conflict')
    t.assert_equals(tostring(err), 'запись users с таким ключом уже есть')
    t.assert_equals(db.calls[#db.calls], 'rollback')
end

g.test_migration_step_creates_the_table_instead_of_the_space = function()
    local User = users()
    local db = helper.fake_db('mysql')
    local binding = bind({ User }, db)

    User.migration()(nil)
    t.assert_equals(journal(db), {
        {
            'execute',
            'create table if not exists `users` (`id` bigint unsigned not null,'
                .. ' `name` varchar(20) character set utf8mb4 collate utf8mb4_0900_bin not null,'
                .. ' `active` boolean not null, `score` double, `created_at` double, `updated_at` double,'
                .. ' `deleted_at` double, primary key (`id`))',
            {},
            false,
        },
    })

    -- Шлюз драйвер не закрывает: он принадлежит приложению.
    binding.close()
    t.assert_equals(#db.calls, 1)
end

g.test_a_refused_migration_breaks_the_step = function()
    local model = loaded.model
    local Tagged = model.define({
        space = 'tagged',
        fields = { { 'id', 'integer', primary = true }, { 'tag', 'string' } },
        indexes = { tag = { parts = { 'tag' }, unique = false } },
    })
    local db = helper.fake_db('postgres', function(call)
        if call.sql:find('^create index') then
            return nil, rejected('42501')
        end

        return { affected = 0 }
    end)

    bind({ Tagged }, db)

    local ok, err = pcall(Tagged.migration(), nil)

    t.assert_equals(ok, false)
    t.assert_equals(err.kind, 'unavailable')
    t.assert_equals(#helper.statements(db), 2)
end
