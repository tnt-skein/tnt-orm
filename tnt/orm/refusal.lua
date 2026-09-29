--- Отказ базы — отказом модели: тот же род, что у спейса.
---
--- Обработчик выбирает код ответа по роду отказа модели и не обязан
--- знать, где лежат данные. Поэтому отказ драйвера (`TntStorageFailure`)
--- переводится в род модели по коду сервера, а сам он остаётся в поле
--- `cause` — тому, кому нужны `server_code` и `retriable`:
---
---   * занятое значение уникального индекса — `conflict`, как у спейса;
---     текст называет занятый индекс, а первичный — ключом: ключ свободен,
---     а занят `login` — и «с таким ключом» послало бы искать не то;
---   * база только для чтения (реплика PostgreSQL, `read_only` MySQL) —
---     `readonly`;
---   * значение, которого столбец не держит (за пределом `bigint`,
---     длиннее столбца, отвергнуто проверкой), и значение, которое
---     не ушло вовсе (строка с нулевым байтом у PostgreSQL), — `invalid`:
---     ответ «поправьте запись», а не «повторите позже»;
---   * всё прочее — сеть, срок, пул, закрытый драйвер, конфликт
---     сериализации, таблицы нет — `unavailable`: запись не легла
---     по причине, которой вход не поправит.

local failure = require('tnt.model.failure')

local check = require('tnt.model.check')
local shapes = require('tnt.model.shape')
local sql = require('tnt.sql')

local ddl = require('tnt.orm.ddl')

local Module = {}

--- Коды занятого значения уникального индекса — SQLSTATE PostgreSQL,
--- errno MySQL — и диалект, по правилам которого база назвала индекс.
---@type table<any, string>
local TAKEN = { ['23505'] = sql.POSTGRES, [1062] = sql.MYSQL }

--- Чем назван отказ без формы модели — отказ фиксации транзакции модели:
--- таблиц в ней бывает несколько, и ни одна его не называет.
local TRANSACTION = 'в транзакции'

--- Чем зовётся занятый первичный индекс — так же, как у шлюза спейса.
local KEY = 'ключом'

--- Чем зовётся занятое, когда индекс не узнан: база назвала индекс,
--- которого модель не знает (его завели мимо объявления), не назвала
--- никакого (отказ поднял триггер) либо форма модели неизвестна. Ключом
--- такое не назвать: занят мог быть и он, и любой другой уникальный индекс.
local UNNAMED = 'значением уникального индекса'

--- Коды базы только для чтения.
---@type table<any, boolean>
local READONLY = { ['25006'] = true, [1290] = true, [1792] = true }

--- Коды значения, которого столбец не держит; у PostgreSQL ещё весь
--- класс `22` — «исключение данных».
---@type table<any, boolean>
local UNFIT = {
    ['23502'] = true,
    ['23514'] = true,
    [1048] = true,
    [1264] = true,
    [1366] = true,
    [1406] = true,
    [3819] = true,
}

--- Класс SQLSTATE «исключение данных» — образцом начала кода: срез
--- `sub(1, 2)` неотличим от `sub(0, 2)`, и проверка его не держала бы.
local DATA_EXCEPTION = '^22'

--- Отвергла ли база значение, а не оператор.
---@param err table TntStorageFailure рода rejected
---@return boolean
local function unfit(err)
    local code = err.server_code

    return not err.sent or UNFIT[code] == true or (type(code) == 'string' and code:find(DATA_EXCEPTION) ~= nil)
end

--- Назвала ли база в отказе о занятом значении индекс с этим именем.
---
--- PostgreSQL зовёт ограничение в первой строке отказа, а значения строки
--- кладёт во вторую (`DETAIL`), поэтому первая строка чужих слов не несёт.
--- Кавычки у имени свои в каждом языке сервера, и имя ищется целым словом
--- (`users_login` — не часть `users_login_mail`), а не между кавычками.
--- В образце поиска имя ничего лишнего не значит: в нём только буквы,
--- цифры и `_` — так имена таблиц и индексов проверяет форма модели.
---
--- MySQL во всех языках сервера пишет сначала значение, затем ключ, оба
--- в одинарных кавычках. Ключ — последнее в кавычках: значение само
--- бывает с кавычкой, с именем другого индекса и с переводом строки,
--- но идёт раньше. Поэтому и текст берётся целиком, а не первой строкой.
--- С 8.0.19 ключ идёт с именем таблицы — `accounts.login`, прежде — без
--- него; узнаются оба вида.
---@param dialect string postgres либо mysql
---@param err table TntStorageFailure
---@param space string Таблица
---@param name string Имя индекса в базе
---@return boolean
local function named(dialect, err, space, name)
    if dialect == sql.POSTGRES then
        return err.reason:find('%f[%w_]' .. name .. '%f[^%w_]') ~= nil
    end

    local key = err.message:match(".*'([^']*)'")

    return key == name or key == space .. '.' .. name
end

--- Чем зовётся занятое: именем индекса, ключом либо без имени.
---
--- Индекс узнаётся по имени, которое дала ему схема (`ddl.index_name`).
---@param shape TntModelShape|nil
---@param dialect string postgres либо mysql
---@param err table TntStorageFailure
---@return string
local function taken(shape, dialect, err)
    if shape == nil then
        return UNNAMED
    end

    for _, index in ipairs(shape.indexes) do
        if named(dialect, err, shape.space, ddl.index_name(shape, index, dialect)) then
            return index.name == shapes.PRIMARY_INDEX and KEY or index.name
        end
    end

    return UNNAMED
end

---@class TntOrmFailure: TntModelFailure Отказ модели из отказа базы
---@field cause table Отказ драйвера `TntStorageFailure`: `server_code`, `retriable`

--- Отказ модели по отказу драйвера; отказ модели — как есть.
---
--- Отказ модели приходит сюда из транзакции драйвера: тело отменило её
--- отказом, уже переведённым, и второй перевод спутал бы роды.
---
--- Форма нужна тексту: имя таблицы и имя занятого индекса. Без неё —
--- отказ фиксации транзакции модели — текст зовёт место «в транзакции».
---@param shape TntModelShape|nil Форма модели, чей оператор отказан; пусто — фиксация
---@param err table TntStorageFailure либо TntModelFailure
---@return TntOrmFailure|TntModelFailure
function Module.of(shape, err)
    if failure.is(err) then
        return err
    end

    local space = shape and shape.space or TRANSACTION
    local dialect = err.kind == 'rejected' and TAKEN[err.server_code]
    local refused

    if dialect then
        refused = failure.new(
            failure.CONFLICT,
            ('запись %s с таким %s уже есть'):format(space, taken(shape, dialect, err))
        )
    elseif err.kind == 'rejected' and READONLY[err.server_code] then
        refused = failure.new(failure.READONLY, ('база только для чтения: %s'):format(err.reason))
    elseif err.kind == 'rejected' and unfit(err) then
        refused = failure.invalid(space, { [check.WHOLE] = err.reason })
    else
        refused = failure.new(
            failure.UNAVAILABLE,
            ('база не выполнила запрос (%s): %s'):format(space, err.message)
        )
    end

    local traced = refused --[[@as TntOrmFailure]]

    traced.cause = err

    return traced
end

return Module
