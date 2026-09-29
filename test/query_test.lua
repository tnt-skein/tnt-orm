--- Выборка модели запросом `tnt-sql`: условие по индексу, граница,
--- условия областей и мягкого удаления, продолжение после записи,
--- порядок с пустыми значениями и страница — текстом и параметрами
--- дословно. Что серверы понимают их так же, проверяет `orm_live_test.lua`.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, loaded = helper.group('tnt.orm.query')

--- Модель с индексом по необязательному полю, мягким удалением и областями.
---@return any
local function posts()
    local model = loaded.model

    return model.define({
        space = 'posts',
        fields = {
            { 'id', 'unsigned', primary = true },
            { 'rank', 'integer' },
            { 'tag', 'string', optional = true },
            { 'score', 'number', optional = true },
            model.deleted_at(),
        },
        indexes = {
            rank = { parts = { 'rank' }, unique = false },
            tag = { parts = { 'tag' }, unique = false },
        },
        scopes = {
            tagged = { { 'tag', '~=', nil } },
            untagged = { { 'tag', '=', nil } },
            low = function(score)
                return { { 'score', '<', score }, { 'rank', '<=', 5 } }
            end,
            other = { { 'tag', '~=', 'x' }, { 'rank', '~=', 3 }, { 'rank', '>', 1 }, { 'rank', '>=', 2 } },
        },
    })
end

--- Привязывает модель к двойнику драйвера и отдаёт его.
---@param model any
---@param dialect string|nil
---@return TntOrmFakeDb
local function bound(model, dialect)
    local db = helper.fake_db(dialect or 'postgres')

    loaded.model.bind({ model }, loaded.model.settings({ source = 'sql' }), { sql = loaded.orm.gateway(db) }).attach()

    return db
end

--- Текст и параметры единственного оператора двойника.
---@param db TntOrmFakeDb
---@return table
local function sent(db)
    local calls = helper.statements(db)

    t.assert_equals(#calls, 1)

    return { calls[1].sql, helper.shown(calls[1].params) }
end

--- Начало всякой выборки постов.
local SELECT = 'select "id", "rank", "tag", "score", "deleted_at" from "posts" where '

g.test_each_sign_of_where_becomes_its_comparison = function()
    local Post = posts()
    local cases = {
        { '=', '"rank" = $1::int8' },
        { '>', '"rank" > $1::int8' },
        { '>=', '"rank" >= $1::int8' },
        { '<', '"rank" < $1::int8' },
        { '<=', '"rank" <= $1::int8' },
    }

    for _, case in ipairs(cases) do
        local db = bound(Post)
        local descending = case[1]:sub(1, 1) == '<'
        local direction = descending and 'desc' or 'asc'

        Post.where('rank', case[1], 7):with_deleted():all()
        t.assert_equals(sent(db), {
            ('%s%s order by "rank" %s, "id" %s limit 100'):format(SELECT, case[2], direction, direction),
            { '7' },
        }, case[1])
    end
end

g.test_an_optional_field_takes_empty_values_below_any = function()
    local Post = posts()
    local db = bound(Post)

    Post.where('tag', '<', 'm'):with_deleted():limit(5):all()
    t.assert_equals(sent(db), {
        SELECT .. '("tag" < $1 or "tag" is null) order by "tag" is null asc, "tag" desc, "id" desc limit 5',
        { 'm' },
    })

    db = bound(Post)
    Post.where('tag', '>=', 'm'):with_deleted():all()
    t.assert_equals(sent(db), {
        SELECT .. '"tag" >= $1 order by "tag" is null desc, "tag" asc, "id" asc limit 100',
        { 'm' },
    })
end

g.test_between_bounds_the_first_part_from_both_sides = function()
    local Post = posts()
    local db = bound(Post)

    Post.where('rank', 'between', { 2, 9 }):with_deleted():offset(4):all()
    t.assert_equals(sent(db), {
        SELECT .. '"rank" >= $1::int8 and "rank" <= $2::int8 order by "rank" asc, "id" asc limit 100 offset 4',
        { '2', '9' },
    })
end

g.test_scan_has_no_condition_and_deleted_records_are_hidden = function()
    local Post = posts()
    local db = bound(Post)

    Post.scan():all()
    t.assert_equals(sent(db), {
        SELECT .. '"deleted_at" is null order by "id" asc limit 100',
        {},
    })

    db = bound(Post)
    Post.scan():only_deleted():all()
    t.assert_equals(sent(db)[1], SELECT .. '"deleted_at" is not null order by "id" asc limit 100')
end

g.test_scopes_become_conditions_of_the_query = function()
    local Post = posts()
    local db = bound(Post)

    Post.scan():scope('tagged'):scope('untagged'):scope('low', 1.5):scope('other'):with_deleted():all()
    t.assert_equals(sent(db), {
        SELECT
            .. '"tag" is not null and "tag" is null'
            .. ' and ("score" < $1 or "score" is null) and "rank" <= $2::int8'
            .. ' and ("tag" <> $3 or "tag" is null) and "rank" <> $4::int8 and "rank" > $5::int8'
            .. ' and "rank" >= $6::int8'
            .. ' order by "id" asc limit 100',
        { '1.5', '5', 'x', '3', '1', '2' },
    })
end

g.test_after_continues_strictly_behind_the_record = function()
    local Post = posts()
    local db = bound(Post)

    Post.where('rank', '>=', 1):with_deleted():after({ rank = 4, id = 10 }):all()
    t.assert_equals(sent(db), {
        SELECT
            .. '"rank" >= $1::int8 and "rank" >= $2::int8'
            .. ' and (("rank" > $3::int8) or ("rank" = $4::int8 and "id" > $5::int8))'
            .. ' order by "rank" asc, "id" asc limit 100',
        { '1', '4', '4', '4', '10' },
    })

    -- По убыванию пустое значение идёт последним — после любой записи.
    db = bound(Post)
    Post.where('tag', '<=', 'z'):with_deleted():after({ tag = 'k', id = 3 }):all()
    t.assert_equals(sent(db), {
        SELECT
            .. '("tag" <= $1 or "tag" is null) and ("tag" <= $2 or "tag" is null)'
            .. ' and ((("tag" < $3 or "tag" is null)) or ("tag" = $4 and "id" < $5::int8))'
            .. ' order by "tag" is null asc, "tag" desc, "id" desc limit 100',
        { 'z', 'k', 'k', 'k', '3' },
    })
end

-- Запись без значения необязательного поля стоит на месте NULL, и курсор
-- от неё несёт пустую часть. Сравнение с пустым параметром SQL не видит,
-- поэтому оно пишется проверкой на пустоту: равно пустому и не больше
-- его — `is null`, больше — `is not null`, не меньше — любое, и условия
-- нет. «Строго меньше пустого» не бывает — по убыванию такой ветки нет.
g.test_after_an_empty_part_is_the_null_place = function()
    local Post = posts()
    local db = bound(Post)

    Post.where('tag', '<=', 'z'):with_deleted():after({ id = 3 }):all()
    t.assert_equals(sent(db), {
        SELECT
            .. '("tag" <= $1 or "tag" is null) and "tag" is null'
            .. ' and (("tag" is null and "id" < $2::int8))'
            .. ' order by "tag" is null asc, "tag" desc, "id" desc limit 100',
        { 'z', '3' },
    })

    db = bound(Post)
    Post.where('tag', '>=', 'a'):with_deleted():after({ id = 3 }):all()
    t.assert_equals(sent(db), {
        SELECT
            .. '"tag" >= $1 and (("tag" is not null) or ("tag" is null and "id" > $2::int8))'
            .. ' order by "tag" is null desc, "tag" asc, "id" asc limit 100',
        { 'a', '3' },
    })

    -- Пустая часть в середине составного индекса: по возрастанию записи
    -- без метки идут внутри рода первыми, по убыванию — последними.
    local Note = loaded.model.define({
        space = 'notes',
        fields = {
            { 'id', 'unsigned', primary = true },
            { 'kind', 'string' },
            { 'tag', 'string', optional = true },
        },
        indexes = { sorted = { parts = { 'kind', 'tag' }, unique = false } },
    })

    db = bound(Note)
    Note.where('kind', '=', 'x'):after({ kind = 'x', id = 3 }):all()
    t.assert_equals(sent(db), {
        'select "id", "kind", "tag" from "notes" where "kind" = $1 and "kind" >= $2'
            .. ' and (("kind" > $3) or ("kind" = $4 and "tag" is not null)'
            .. ' or ("kind" = $5 and "tag" is null and "id" > $6::int8))'
            .. ' order by "kind" asc, "tag" is null desc, "tag" asc, "id" asc limit 100',
        { 'x', 'x', 'x', 'x', 'x', '3' },
    })

    db = bound(Note)
    Note.where('kind', '<=', 'x'):after({ kind = 'x', id = 3 }):all()
    t.assert_equals(sent(db), {
        'select "id", "kind", "tag" from "notes" where "kind" <= $1 and "kind" <= $2'
            .. ' and (("kind" < $3) or ("kind" = $4 and "tag" is null and "id" < $5::int8))'
            .. ' order by "kind" desc, "tag" is null asc, "tag" desc, "id" desc limit 100',
        { 'x', 'x', 'x', 'x', '3' },
    })
end

g.test_count_has_neither_page_nor_order = function()
    local Post = posts()
    local db = helper.fake_db('mysql', function()
        return { { n = 3 } }
    end)

    loaded.model.bind({ Post }, loaded.model.settings({ source = 'sql' }), { sql = loaded.orm.gateway(db) }).attach()

    t.assert_equals(Post.where('rank', '>', 2):limit(5):offset(1):count(), 3)
    t.assert_equals(sent(db), {
        'select count(*) as n from `posts` where `rank` > ? and `deleted_at` is null',
        { '2' },
    })
end
