--- Значения полей модели по пути в базу и обратно.
---
--- Рок отдаёт выборку без типов столбцов, и привести её к роду поля может
--- только тот, кто знает схему, — шлюз: форма записи у него в руках.
--- Туда же и путь в базу: какое значение Lua отдать построителю, чтобы
--- сервер получил его своим типом.
---
--- Что сверено запуском на PostgreSQL 16 и MySQL 8.4 с форками роков:
---
---   * PostgreSQL принимает NULL-параметр типом `text`, и в столбец
---     `boolean`, `double precision`, `uuid` либо `bigint` такой NULL
---     не ложится: «column "b" is of type boolean but expression is
---     of type text». Поэтому пустое значение уходит с приведением
---     к типу столбца: `$1::boolean`;
---   * число Lua рок `pg` шлёт типом `numeric`, и сравнение столбца `bigint`
---     с `numeric` идёт мимо индекса. Приведение `$1::int8` целому ставит
---     кодирование значений `tnt-storage`, которым `tnt-sql` собирает
---     запрос, — и числу, и `int64`, с точными цифрами, — поэтому целое
---     уходит как есть;
---   * строку рок `pg` шлёт типом `text`, а столбец `uuid` её не примет —
---     значение `uuid` уходит cdata, с приведением `$1::uuid`;
---   * `double precision` PostgreSQL отдаёт строкой, `boolean` MySQL —
---     числом `tinyint(1)`: их шлюз приводит к роду поля. Целые оба рока
---     отдают числом до 2^53 и cdata дальше — как и `box`, поэтому они
---     остаются как есть.

local uuid = require('uuid')

local sql = require('tnt.sql')

local Module = {}

--- Типы столбцов PostgreSQL по родам поля — без ограничений и сортировки,
--- ими же приводится пустое значение.
---@type table<string, string>
Module.POSTGRES = {
    unsigned = 'bigint',
    integer = 'bigint',
    number = 'double precision',
    string = 'text',
    boolean = 'boolean',
    uuid = 'uuid',
}

--- Значение поля для параметра запроса.
---
--- MySQL значения Lua принимает как есть: `int64` и `uint64` уходят
--- строкой и сравниваются со столбцом `bigint` точно (сверено на ключах
--- 2^53 и 2^53 + 1), а пустое значение — это `box.NULL`: пустота
--- в середине строки иначе стёрла бы столбец из запроса.
---@param dialect string postgres либо mysql
---@param field TntModelField
---@param value any
---@return any
function Module.param(dialect, field, value)
    if dialect ~= sql.POSTGRES then
        return value == nil and box.NULL or value
    end

    if value == nil then
        return sql.raw('?::' .. Module.POSTGRES[field.type], box.NULL)
    end

    if field.type == 'uuid' then
        return uuid.fromstr(value)
    end

    return value
end

--- Значение столбца из выборки — родом поля.
---@param field TntModelField
---@param value any
---@return any
function Module.value(field, value)
    if field.type == 'boolean' and type(value) == 'number' then
        return value ~= 0
    end

    if field.type == 'number' and type(value) == 'string' then
        return tonumber(value)
    end

    return value
end

--- Значения записи из строки выборки: по полям формы, пустое — без ключа.
---@param shape TntModelShape
---@param row table
---@return table
function Module.record(shape, row)
    local values = {}

    for _, field in ipairs(shape.fields) do
        values[field.name] = Module.value(field, row[field.name])
    end

    return values
end

--- Строка для вставки либо правки: каждое поле формы, кроме названных.
---
--- Пустое значение уходит явно: правка, пропустившая столбец, оставила бы
--- в нём прежнее значение, а у записи его уже нет.
---@param dialect string
---@param shape TntModelShape
---@param values table
---@param skipped table<string, boolean>|nil Поля, которых в строке быть не должно
---@return table
function Module.row(dialect, shape, values, skipped)
    local row = {}

    for _, field in ipairs(shape.fields) do
        if not (skipped or {})[field.name] then
            row[field.name] = Module.param(dialect, field, values[field.name])
        end
    end

    return row
end

return Module
