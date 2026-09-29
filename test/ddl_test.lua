--- Схема таблицы из объявления: тексты `create table` и индексов под оба
--- диалекта — дословно, имя индекса PostgreSQL, усечённое, как его
--- усекает сервер, и отказ фасада на незнакомом диалекте.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, loaded = helper.group('tnt.orm.ddl')

--- Модель со всеми родами полей и двумя индексами сверх первичного.
---@return any
local function everything()
    local model = loaded.model

    return model.define({
        space = 'items',
        fields = {
            { 'id', 'unsigned', primary = true },
            { 'part', 'integer', primary = true },
            { 'code', 'string', max = 16383 },
            { 'note', 'string', optional = true, max = 16384 },
            { 'text', 'string', optional = true },
            { 'price', 'number' },
            { 'ready', 'boolean', default = false },
            { 'token', 'uuid', optional = true },
            model.created_at(),
        },
        indexes = {
            by_code = { parts = { 'code' }, unique = true },
            by_price = { parts = { 'price', 'ready' }, unique = false },
        },
    })
end

g.test_postgres_creates_the_table_then_each_index = function()
    t.assert_equals(loaded.orm.statements(everything(), 'postgres'), {
        'create table if not exists "items" ('
            .. '"id" bigint check ("id" >= 0) not null, '
            .. '"part" bigint not null, '
            .. '"code" text collate "C" not null, '
            .. '"note" text collate "C", '
            .. '"text" text collate "C", '
            .. '"price" double precision not null, '
            .. '"ready" boolean not null, '
            .. '"token" uuid, '
            .. '"created_at" double precision, '
            .. 'primary key ("id", "part"))',
        'create unique index if not exists "items_by_code" on "items" ("code")',
        'create index if not exists "items_by_price" on "items" ("price", "ready")',
    })
end

g.test_mysql_keeps_indexes_inside_the_table = function()
    t.assert_equals(loaded.orm.statements(everything(), 'mysql'), {
        'create table if not exists `items` ('
            .. '`id` bigint unsigned not null, '
            .. '`part` bigint not null, '
            .. '`code` varchar(16383) character set utf8mb4 collate utf8mb4_0900_bin not null, '
            .. '`note` longtext character set utf8mb4 collate utf8mb4_0900_bin, '
            .. '`text` longtext character set utf8mb4 collate utf8mb4_0900_bin, '
            .. '`price` double not null, '
            .. '`ready` boolean not null, '
            .. '`token` char(36), '
            .. '`created_at` double, '
            .. 'primary key (`id`, `part`), '
            .. 'unique index `by_code` (`code`), '
            .. 'index `by_price` (`price`, `ready`))',
    })
end

g.test_a_model_without_secondary_indexes_is_one_statement = function()
    local plain = loaded.model.define({ space = 'plain', fields = { { 'id', 'integer', primary = true } } })

    t.assert_equals(loaded.orm.statements(plain, 'postgres'), {
        'create table if not exists "plain" ("id" bigint not null, primary key ("id"))',
    })
end

g.test_postgres_gets_the_index_name_cut_to_63_bytes = function()
    local space = ('t'):rep(60)
    local long = loaded.model.define({
        space = space,
        fields = { { 'id', 'integer', primary = true }, { 'code', 'string' } },
        indexes = { by_code = { parts = { 'code' }, unique = true } },
    })

    -- Длиннее сервер усёк бы имя сам: в тексте оно то, что он сохранит.
    t.assert_equals(
        loaded.orm.statements(long, 'postgres')[2],
        ('create unique index if not exists "%s_by" on "%s" ("code")'):format(space, space)
    )
end

g.test_an_unknown_dialect_is_the_mistake_of_the_caller = function()
    local plain = loaded.model.define({ space = 'plain', fields = { { 'id', 'integer', primary = true } } })

    helper.assert_blamed({
        {
            function()
                loaded.orm.statements(plain, 'tarantool')
            end,
            'диалект — одно из «postgres», «mysql», а не «tarantool»',
        },
    })
end
