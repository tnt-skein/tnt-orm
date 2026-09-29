--- Выборка модели — запросом `tnt-sql`: условие по индексу, условия
--- областей, продолжение после записи, порядок и страница.
---
--- Выборку модель описывает словами индекса TREE (`TntModelQuerySpec`):
--- итератор, ключ, верхняя граница, `after`. Здесь то же описание
--- становится условиями и порядком запроса, и страница выходит той же,
--- что у спейса:
---
---   * порядок — части индекса, затем первичный ключ, как упорядочивает
---     сам индекс TREE; `<` и `<=` идут по убыванию;
---   * пустое значение меньше любого, как NULL в индексе TREE: оно идёт
---     первым по возрастанию и подходит под «меньше» и «не равно». SQL
---     пустое значение сравнением не видит, и у необязательного поля
---     к такому условию дописывается `or … is null`, а в порядок —
---     выражение `… is null`;
---   * `after` — строго после записи в этом порядке: лексикографическое
---     сравнение частей, развёрнутое в «или», и ведущая граница по первой
---     части — с неё сервер начинает обход индекса, а не с начала таблицы.
---     Пустая часть курсора — место NULL, и сравнение с ней пишется
---     проверкой на пустоту.
---
--- Значения условий уходят параметрами через `tnt.orm.columns`: у PostgreSQL
--- пустое — с приведением к типу столбца, `uuid` — cdata, а целое — с `int8`
--- от кодирования значений, иначе сравнение шло бы мимо индекса.

local sql = require('tnt.sql')

local order = require('tnt.model.order')
local shapes = require('tnt.model.shape')

local columns = require('tnt.orm.columns')

local Module = {}

--- Знак сравнения по итератору box; у `ALL` условия нет.
---@type table<string, string>
local SIGNS = { EQ = '=', GT = '>', GE = '>=', LT = '<', LE = '<=' }

--- Знак сравнения по знаку условия области.
---@type table<string, string>
local FILTERS = { ['='] = '=', ['~='] = '<>', ['<'] = '<', ['<='] = '<=', ['>'] = '>', ['>='] = '>=' }

--- Знаки, под которые подходит и пустое значение: оно меньше любого.
---@type table<string, boolean>
local BELOW = { ['<'] = true, ['<='] = true, ['<>'] = true }

--- Сравнение поля со значением в порядке индекса TREE.
---@param target table Запрос либо группа условий
---@param dialect string
---@param field TntModelField
---@param sign string Знак SQL
---@param value any
local function compared(target, dialect, field, sign, value)
    local param = columns.param(dialect, field, value)

    if field.optional and BELOW[sign] then
        target:where(function(group)
            group:where(field.name, sign, param):or_where(field.name, 'is null')
        end)
    else
        target:where(field.name, sign, param)
    end
end

--- Условие по индексу, верхняя граница и условия областей.
---@param query table Запрос `tnt-sql`
---@param shape TntModelShape
---@param spec TntModelQuerySpec
---@param dialect string
---@return TntModelIndex index Индекс выборки
local function narrowed(query, shape, spec, dialect)
    local index = assert(shapes.index_of(shape, spec.index))
    local part = shape.by_name[index.parts[1]] --[[@as TntModelField]]
    local sign = SIGNS[spec.iterator]

    if sign ~= nil then
        compared(query, dialect, part, sign, spec.key[1])
    end

    if spec.to ~= nil then
        compared(query, dialect, part, '<=', spec.to)
    end

    for _, condition in ipairs(spec.filter or {}) do
        local field = shape.by_name[condition.field]

        -- Пустое значение условия бывает только при «=» и «~=»: так
        -- область говорит «значения нет» и «значение есть».
        if condition.value == nil then
            query:where(field.name, condition.op == '=' and 'is null' or 'is not null')
        else
            compared(query, dialect, field, FILTERS[condition.op], condition.value)
        end
    end

    return index
end

--- Проверка на пустоту вместо сравнения с пустым значением курсора.
---
--- Пустое меньше любого, как NULL в индексе TREE: равно пустому
--- и не больше его только пустое, больше — любое непустое. Под «не
--- меньше пустого» подходит всё, и условия нет вовсе; «строго меньше
--- пустого» не бывает, и такой ветки `continued` не ставит.
---@type table<string, string>
local EMPTY = { ['='] = 'is null', ['<='] = 'is null', ['>'] = 'is not null' }

--- Сравнение поля с частью курсора: пустая часть — место NULL.
---
--- Сравнение с пустым параметром SQL не видит — `"email" > null`
--- не истинно никогда, — и страница после записи без значения вышла бы
--- неверной: без записей дальше либо с уже отданными.
---@param target table Запрос либо группа условий
---@param dialect string
---@param field TntModelField
---@param sign string Знак SQL
---@param value any Часть курсора; пусто — NULL
local function placed(target, dialect, field, sign, value)
    if value ~= nil then
        compared(target, dialect, field, sign, value)
    elseif EMPTY[sign] ~= nil then
        target:where(field.name, EMPTY[sign])
    end
end

--- Строго после записи `after` в порядке выборки.
---
--- Часть курсора бывает пустой только у необязательного поля: модель
--- берёт `after` с каждым обязательным полем индекса и ключа, а пустоту
--- необязательного считает местом NULL (`placed`). По убыванию ветка
--- «строго меньше пустого» выпадает: меньше пустого нет ничего.
---@param query table
---@param shape TntModelShape
---@param names string[] Порядок: части индекса, затем первичный ключ
---@param spec TntModelQuerySpec
---@param dialect string
local function continued(query, shape, names, spec, dialect)
    local descending = order.descending(spec.iterator)
    local cursor = spec.after --[[@as table]]

    placed(query, dialect, shape.by_name[names[1]], descending and '<=' or '>=', cursor[names[1]])

    query:where(function(any)
        for position, name in ipairs(names) do
            if not descending or cursor[name] ~= nil then
                any:or_where(function(step)
                    for before = 1, position - 1 do
                        placed(step, dialect, shape.by_name[names[before]], '=', cursor[names[before]])
                    end

                    placed(step, dialect, shape.by_name[name], descending and '<' or '>', cursor[name])
                end)
            end
        end
    end)
end

--- Порядок выборки: части индекса, затем первичный ключ; пустое — первым
--- по возрастанию и последним по убыванию.
---@param query table
---@param shape TntModelShape
---@param names string[]
---@param spec TntModelQuerySpec
local function ordered(query, shape, names, spec)
    local descending = order.descending(spec.iterator)

    for _, name in ipairs(names) do
        if shape.by_name[name].optional then
            query:order_by(sql.raw('? is null', sql.column(name)), descending and 'asc' or 'desc')
        end

        query:order_by(name, descending and 'desc' or 'asc')
    end
end

--- Страница выборки.
---@param from table Объявление таблицы `tnt-sql`
---@param shape TntModelShape
---@param spec TntModelQuerySpec
---@param dialect string
---@return table query Выборка `tnt-sql`, ещё не собранная
function Module.page(from, shape, spec, dialect)
    local query = from:select()
    local names = order.names_of(shape, narrowed(query, shape, spec, dialect))

    if spec.after ~= nil then
        continued(query, shape, names, spec, dialect)
    end

    ordered(query, shape, names, spec)
    query:limit(spec.limit)

    if spec.offset ~= nil then
        query:offset(spec.offset)
    end

    return query
end

--- Счёт записей выборки: без страницы, смещения и `after`.
---@param from table
---@param shape TntModelShape
---@param spec TntModelQuerySpec
---@param dialect string
---@return table query
function Module.count(from, shape, spec, dialect)
    local query = from:select(sql.raw('count(*) as n'))

    narrowed(query, shape, spec, dialect)

    return query
end

--- Запрос по первичному ключу: каждая часть — на равенство.
---@param query table Выборка, правка либо удаление `tnt-sql`
---@param shape TntModelShape
---@param key any[] Части ключа по порядку первичного индекса
---@param dialect string
---@return table query
function Module.keyed(query, shape, key, dialect)
    for position, name in ipairs(shape.primary) do
        query:where(name, '=', columns.param(dialect, shape.by_name[name], key[position]))
    end

    return query
end

return Module
