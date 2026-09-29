--- Схема таблицы из формы записи: `create table` и индексы.
---
--- Текст собирается здесь, а не построителем: `tnt-sql` схемы не знает.
--- Склейки значений в нём нет — только имена и типы, а имена прошли
--- проверку формы при объявлении модели (латиница, цифры и `_`, не с цифры)
--- и кавычку диалекта закрыть не могут.
---
--- Каждый оператор переживает повтор (`if not exists`): версия схемы
--- живёт на узле Tarantool (`tnt-schema`), а таблица — в общей базе,
--- и шаг идёт на каждом узле, который её разделяет. Шаг создаёт таблицу
--- по нынешнему объявлению, как и спейс: таблицу, которая уже есть, он
--- не трогает, и правки формы после выпуска — отдельными шагами.
---
--- Типы выбраны так, чтобы база держала то же, что спейс:
---
---   * строка сравнивается побайтно, с учётом регистра: у PostgreSQL
---     `collate "C"`, у MySQL `utf8mb4_0900_bin` — иначе уникальный
---     индекс счёл бы «Мария» и «мария» одной записью, а у MySQL ещё
---     и «a» с «a » (сортировка по умолчанию добивает строки пробелами);
---   * беззнаковое у PostgreSQL — `bigint` с проверкой `>= 0`: беззнаковых
---     целых у него нет, и предел у поля там 2^63 − 1;
---   * строка MySQL — `varchar` длиной `max` знаков: без длины столбец
---     не войдёт в индекс; без `max` — `longtext`.

local columns = require('tnt.orm.columns')

local shapes = require('tnt.model.shape')
local sql = require('tnt.sql')

local Module = {}

--- Самое длинное имя, которое держит PostgreSQL (NAMEDATALEN − 1 байт):
--- длиннее он усекает молча, и в отказе приходит усечённое.
local POSTGRES_LONGEST = 63

--- Хвост имени первичного ключа PostgreSQL: имя ему даёт сервер.
local POSTGRES_PRIMARY = '_pkey'

--- Имя первичного ключа MySQL — одно на все таблицы.
local MYSQL_PRIMARY = 'PRIMARY'

--- Типы столбцов MySQL по родам поля; строка — ниже, по длине.
---@type table<string, string>
local MYSQL = {
    unsigned = 'bigint unsigned',
    integer = 'bigint',
    number = 'double',
    boolean = 'boolean',
    uuid = 'char(36)',
}

--- Самая длинная строка MySQL, которая ещё `varchar`: 65 535 байт строки
--- на четыре байта знака utf8mb4.
local LONGEST_VARCHAR = 16383

--- Кавычки имён по диалекту.
---@type table<string, string>
local QUOTES = { [sql.POSTGRES] = '"', [sql.MYSQL] = '`' }

--- Имена в кавычках диалекта через запятую.
---@param quote string
---@param names string[]
---@return string
local function listed(quote, names)
    local quoted = {}

    for position, name in ipairs(names) do
        quoted[position] = quote .. name .. quote
    end

    return table.concat(quoted, ', ')
end

--- Тип столбца PostgreSQL.
---@param field TntModelField
---@param name string Имя столбца в кавычках
---@return string
local function postgres_type(field, name)
    local base = columns.POSTGRES[field.type]

    if field.type == 'string' then
        return base .. ' collate "C"'
    end

    if field.type == 'unsigned' then
        return ('%s check (%s >= 0)'):format(base, name)
    end

    return base
end

--- Тип столбца MySQL.
---@param field TntModelField
---@return string
local function mysql_type(field)
    if field.type ~= 'string' then
        return MYSQL[field.type]
    end

    local stored = 'longtext'

    if field.max ~= nil and field.max <= LONGEST_VARCHAR then
        stored = ('varchar(%d)'):format(field.max)
    end

    return stored .. ' character set utf8mb4 collate utf8mb4_0900_bin'
end

--- Первые `longest` байт имени — так его усекает PostgreSQL.
---
--- Точностью формата, а не срезом: `sub(1, n)` неотличим от `sub(0, n)`,
--- и проверка начала среза не держала бы.
---@param name string
---@param longest integer
---@return string
local function cut(name, longest)
    return ('%.' .. longest .. 's'):format(name)
end

--- Имя индекса формы в базе — то, которым база зовёт его и в отказе.
---
--- Одно правило на схему и на разбор отказа: по нему отказ о занятом
--- значении узнаёт индекс модели (`tnt.orm.refusal`), и разойдись они —
--- отказ перестал бы его называть.
---
--- У PostgreSQL имя индекса общее на схему базы и начинается именем
--- таблицы; имя длиннее 63 байт сервер усекает, и оно здесь усечено так
--- же. Первичному ключу имя даёт сервер: таблица, урезанная так, чтобы
--- вместе с `_pkey` уложиться в те же 63 байта. У MySQL имя индекса живёт
--- внутри таблицы, а первичный зовётся `PRIMARY`.
---@param shape TntModelShape
---@param index TntModelIndex
---@param dialect string postgres либо mysql
---@return string
function Module.index_name(shape, index, dialect)
    local primary = index.name == shapes.PRIMARY_INDEX

    if dialect == sql.MYSQL then
        return primary and MYSQL_PRIMARY or index.name
    end

    if primary then
        return cut(shape.space, POSTGRES_LONGEST - #POSTGRES_PRIMARY) .. POSTGRES_PRIMARY
    end

    return cut(shape.space .. '_' .. index.name, POSTGRES_LONGEST)
end

--- Операторы схемы таблицы модели по порядку.
---
--- У MySQL индексы — часть `create table`: `create index` у него нет
--- `if not exists`. У PostgreSQL индекс — отдельный оператор. Имя
--- индекса — по `index_name`.
---@param shape TntModelShape
---@param dialect string postgres либо mysql
---@return string[]
function Module.statements(shape, dialect)
    local quote = QUOTES[dialect]
    local parts = {}

    for _, field in ipairs(shape.fields) do
        local name = quote .. field.name .. quote
        local kind = dialect == sql.POSTGRES and postgres_type(field, name) or mysql_type(field)

        table.insert(parts, ('%s %s%s'):format(name, kind, field.optional and '' or ' not null'))
    end

    table.insert(parts, ('primary key (%s)'):format(listed(quote, shape.primary)))

    local table_name = quote .. shape.space .. quote
    local statements = { '' }

    -- Первый индекс формы — первичный: он уже стал `primary key`.
    for position = 2, #shape.indexes do
        local index = shape.indexes[position]
        local unique = index.unique and 'unique ' or ''
        local parts_of = listed(quote, index.parts)
        local name = quote .. Module.index_name(shape, index, dialect) .. quote

        if dialect == sql.POSTGRES then
            table.insert(
                statements,
                ('create %sindex if not exists %s on %s (%s)'):format(unique, name, table_name, parts_of)
            )
        else
            table.insert(parts, ('%sindex %s (%s)'):format(unique, name, parts_of))
        end
    end

    statements[1] = ('create table if not exists %s (%s)'):format(table_name, table.concat(parts, ', '))

    return statements
end

return Module
