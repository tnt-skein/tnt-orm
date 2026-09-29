--- Шлюз `sql`: данные модели в таблице PostgreSQL либо MySQL.
---
--- Тот же договор, что у шлюзов спейсов (`TntModelGateway`), поверх
--- драйвера SQL (`tnt-postgres`, `tnt-mysql`): запрос собирает
--- `tnt-sql`, выполняет драйвер, отказ драйвера становится отказом модели
--- того же рода (`tnt.orm.refusal`). Модель не знает, что под ней база:
--- `User.find(7)` одинаков на спейсе и на таблице.
---
--- Отметки времени и признак мягкого удаления ставит этот шлюз — как
--- шлюз `local` у спейса. Замена, удаление и восстановление читают
--- прежнюю строку `select … for update` и пишут на том же соединении
--- в одной транзакции: отметка создания переходит от прежней строки,
--- и чужая запись между чтением и записью её не перетрёт. Вставка —
--- один оператор: занятый ключ база отвергнет сама.
---
--- Транзакция модели (`model.atomic`) — транзакция драйвера на одном
--- соединении. Пока она идёт, действия модели в том же файбере идут её
--- соединением, а не пулом; файбер, порождённый телом, идёт мимо неё.
--- Соединение драйвер закрывает сам: шлюз его не держит, и `close`
--- ничего не закрывает — драйвер принадлежит приложению.

local fiber = require('fiber')

local sql = require('tnt.sql')

local check = require('tnt.model.check')
local stamps = require('tnt.model.stamp')

local columns = require('tnt.orm.columns')
local ddl = require('tnt.orm.ddl')
local query = require('tnt.orm.query')
local refusal = require('tnt.orm.refusal')
local world = require('tnt.orm.world')

--- Отказ без места вызова: ошибка программиста читается текстом целиком.
local fail = require('tnt.must.fail').raise

local Module = {}

--- Имя шлюза.
Module.KIND = 'sql'

--- Удаляется ли запись из таблицы, а не помечается.
---
--- Мягко удаляется запись модели с признаком удаления, если способ
--- не `force`; восстановление — всегда правкой: у модели без признака
--- `stamps.marked` отвечает «нечего», и строка не трогается.
---@param shape TntModelShape
---@param mode string|nil
---@return boolean
local function erased(shape, mode)
    return mode ~= stamps.RESTORE and (mode == stamps.FORCE or shape.stamps[stamps.DELETED] == nil)
end

--- Значения списком с их числом: пустое в середине не теряется.
---@param ... any
---@return table
local function packed(...)
    return { n = select('#', ...), ... }
end

--- Час записи — стенные часы: отметка уезжает на другие узлы.
---@return number
local function now()
    return world.current().clock().realtime()
end

---@class TntOrmSession Транзакция модели, пока она идёт
---@field conn table|nil Соединение транзакции драйвера
---@field first TntOrmFailure|TntModelFailure|nil Первый отказ оператора: он помечает транзакцию

--- Заводит шлюз над драйвером SQL.
---@param db table Драйвер `tnt-postgres` либо `tnt-mysql`
---@return TntModelGateway
function Module.new(db)
    local dialect = db.dialect.name

    local gateway = { kind = Module.KIND }

    --- Объявления таблиц `tnt-sql` по формам — белый список столбцов
    --- собирается один раз на модель. Слабые ключи: форму держит модель.
    ---@type table<TntModelShape, table>
    local tables = setmetatable({}, { __mode = 'k' })

    --- Транзакция модели по файберу, пока она идёт.
    ---@type table<integer, TntOrmSession>
    local sessions = {}

    ---@param shape TntModelShape
    ---@return table
    local function table_of(shape)
        if tables[shape] == nil then
            local names = {}

            for position, field in ipairs(shape.fields) do
                names[position] = field.name
            end

            tables[shape] = sql.table(shape.space, names)
        end

        return tables[shape]
    end

    --- Правка строки по ключу: все поля, кроме ключа, — ключ не меняется.
    ---@param shape TntModelShape
    ---@param values table
    ---@param key any[]
    ---@return table
    local function updated(shape, values, key)
        local primary = {}

        for _, name in ipairs(shape.primary) do
            primary[name] = true
        end

        return query.keyed(table_of(shape):update(columns.row(dialect, shape, values, primary)), shape, key, dialect)
    end

    --- Замена записи: правка прежней строки либо вставка, когда её нет.
    ---@param shape TntModelShape
    ---@param values table
    ---@param key any[]
    ---@param previous table|nil Прежняя строка
    ---@return table
    local function replacing(shape, values, key, previous)
        if previous == nil then
            return table_of(shape):insert(columns.row(dialect, shape, values))
        end

        return updated(shape, values, key)
    end

    --- Куда идёт оператор: соединение транзакции модели либо драйвер.
    ---@return table
    local function link()
        local session = sessions[fiber.id()]

        return session and session.conn or db
    end

    --- Отказ базы отказом модели.
    ---
    --- Первый отказ оператора помечает транзакцию модели, и драйвер отдаёт
    --- его же следующим операторам и фиксации. Они получают и тот же отказ
    --- модели: назвать занятый индекс может только перевод с формой той
    --- модели, чей оператор отказ получил, а перевод с чужой формой
    --- или без формы назвал бы не то.
    ---@param shape TntModelShape|nil Форма модели; пусто — фиксация
    ---@param err table TntStorageFailure
    ---@param session TntOrmSession|nil Транзакция модели; пусто — по файберу
    ---@return TntOrmFailure|TntModelFailure
    local function refused(shape, err, session)
        session = session or sessions[fiber.id()]

        if session == nil then
            return refusal.of(shape, err)
        end

        local first = session.first

        if first ~= nil and first.cause == err then
            return first
        end

        local translated = refusal.of(shape, err)

        session.first = first or translated

        return translated
    end

    --- Оператор без выборки; отказ — отказом модели.
    ---@param shape TntModelShape
    ---@param statement table Запрос `tnt-sql`
    ---@param conn table|nil Соединение; пусто — по месту
    ---@return table|nil done
    ---@return TntModelFailure|nil err
    local function executed(shape, statement, conn)
        local done, err = (conn or link()):execute(statement:build(db.dialect))

        if done == nil then
            return nil, refused(shape, err)
        end

        return done
    end

    --- Прежняя строка по ключу под замком и действие над ней — на одном
    --- соединении, в одной транзакции.
    ---
    --- Внутри транзакции модели — её соединением: своя транзакция
    --- драйвера в том же файбере была бы вложенной. Действие отвечает
    --- парой; отказ отменяет свою транзакцию.
    ---@param shape TntModelShape
    ---@param key any[]
    ---@param act fun(conn: table, previous: table|nil): any, TntModelFailure|nil
    ---@return any value
    ---@return TntModelFailure|nil err
    local function locked(shape, key, act)
        local function body(conn)
            local text, params = query.keyed(table_of(shape):select(), shape, key, dialect):build(db.dialect)

            -- `for update` — постоянные слова, а не значение: склейка
            -- с ними ничего не впускает в текст запроса. Отказ сборки
            -- проходит к драйверу как есть, и тот отдаёт его парой.
            local rows, err = conn:query(text and text .. ' for update', params)

            if rows == nil then
                return nil, refused(shape, err)
            end

            return act(conn, rows[1] and columns.record(shape, rows[1]))
        end

        local own = sessions[fiber.id()]

        if own ~= nil then
            return body(own.conn)
        end

        -- Обёртка: ответ «нечего» (`false`) драйвер принял бы за отмену
        -- транзакции. Отказ внутри — всегда отказ оператора: драйвер уже
        -- пометил им транзакцию, откатит её сам и отдаст этот отказ.
        local done, err = db:transaction(function(conn)
            return { value = body(conn) }
        end)

        if not done then
            return nil, refused(shape, err)
        end

        return done.value
    end

    function gateway.find(shape, key)
        local statement = query.keyed(table_of(shape):select(), shape, key, dialect)
        local rows, err = link():query(statement:build(db.dialect))

        if rows == nil then
            return nil, refused(shape, err)
        end

        return rows[1] and columns.record(shape, rows[1])
    end

    --- Вставка — один оператор; замена — правка прежней строки либо
    --- вставка, когда её нет, под замком.
    function gateway.put(shape, values, mode)
        if mode == 'insert' then
            stamps.written(shape, values, nil, now())

            local done, err = executed(shape, table_of(shape):insert(columns.row(dialect, shape, values)))

            return done and values, err
        end

        local key = check.key_from(shape, values)

        return locked(shape, key, function(conn, previous)
            stamps.written(shape, values, previous, now())

            local done, err = executed(shape, replacing(shape, values, key, previous), conn)

            return done and values, err
        end)
    end

    --- Окончательное удаление, мягкое удаление либо восстановление.
    function gateway.delete(shape, key, mode)
        return locked(shape, key, function(conn, previous)
            if previous == nil then
                return false
            end

            if erased(shape, mode) then
                local done, err = executed(shape, query.keyed(table_of(shape):delete(), shape, key, dialect), conn)

                return done and true, err
            end

            local marked = stamps.marked(shape, previous, mode, now())

            if marked == nil then
                return false
            end

            local done, err = executed(shape, updated(shape, marked, key), conn)

            return done and marked, err
        end)
    end

    function gateway.select(shape, spec)
        local rows, err = link():query(query.page(table_of(shape), shape, spec, dialect):build(db.dialect))

        if rows == nil then
            return nil, refused(shape, err)
        end

        for position, row in ipairs(rows) do
            rows[position] = columns.record(shape, row)
        end

        return rows
    end

    function gateway.count(shape, spec)
        local rows, err = link():query(query.count(table_of(shape), shape, spec, dialect):build(db.dialect))

        if rows == nil then
            return nil, refused(shape, err)
        end

        return rows[1].n
    end

    --- Транзакция модели: тело целиком на одном соединении.
    ---
    --- Как у `box.atomic`: исключение тела откатывает транзакцию и идёт
    --- дальше, иначе — фиксация и ответ тела как есть, даже `nil, err`.
    --- Своё у базы: фиксация бывает отказом (сеть, сериализация), а отказ
    --- оператора помечает транзакцию — следующие операторы получают тот
    --- же отказ, и фиксации не будет. Тогда ответ — пара `nil, err`, где
    --- `err` — тот же отказ модели, что получил отказанный оператор.
    function gateway.atomic(fn, ...)
        local id = fiber.id()

        if sessions[id] ~= nil then
            fail(
                'model.atomic внутри model.atomic: у базы транзакция одна на соединение, вложенной нет'
            )
        end

        local args = packed(...)
        local results = nil
        ---@type TntOrmSession
        local session = {}

        local ok, done, err = pcall(db.transaction, db, function(conn)
            session.conn = conn
            sessions[id] = session
            results = packed(fn(unpack(args, 1, args.n)))

            -- Истина, а не ответ тела: `nil` и `false` драйвер принял бы
            -- за отмену, а у `box.atomic` ответ тела фиксацию не решает.
            return true
        end)

        sessions[id] = nil

        if not ok then
            fail(done)
        end

        if not done then
            ---@cast err table
            return nil, refused(nil, err, session)
        end

        ---@cast results table
        return unpack(results, 1, results.n)
    end

    function gateway.close() end

    --- Схема таблицы модели: операторы по порядку, каждый своим вызовом.
    ---
    --- Не транзакцией драйвера: шаг `tnt-schema` идёт внутри транзакции
    --- box, а драйвер в ней транзакции не открывает. Каждый оператор
    --- переживает повтор, поэтому шаг, оборванный посередине, следующим
    --- подъёмом доделается.
    ---@param shape TntModelShape
    ---@return boolean|nil done
    ---@return TntModelFailure|nil err
    function gateway.migrate(shape)
        for _, text in ipairs(ddl.statements(shape, dialect)) do
            local done, err = db:execute(text)

            if done == nil then
                return nil, refused(shape, err)
            end
        end

        return true
    end

    return gateway --[[@as TntModelGateway]]
end

return Module
