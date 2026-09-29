rockspec_format = '3.0'

package = 'tnt-orm'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-orm.git',
    branch = 'main',
}

description = {
    summary = 'Шлюз моделей tnt-model для PostgreSQL и MySQL: та же модель поверх SQL',
    detailed = [[
        Второй системы объявления моделей здесь нет: модель объявляется
        model.define из tnt-model, как и для спейса, а этот пакет даёт ей
        шлюз sql — find, create, save, delete, where…:all()/count()/first(),
        after и offset поверх драйверов tnt-postgres и tnt-mysql. Запрос
        собирает tnt-sql: значения уходят параметрами, имена — по белому
        списку формы. Отказ базы становится отказом модели того же рода:
        занятый ключ — conflict, база только для чтения — readonly,
        значение не по столбцу — invalid, прочее — unavailable.

        Страница та же, что у спейса: порядок индекса и первичного ключа,
        пустое значение меньше любого, продолжение после записи. Отметки
        времени и мягкое удаление ставит шлюз: замена читает прежнюю
        строку под замком в той же транзакции. model.atomic — транзакция
        драйвера на одном соединении.

        Схема таблицы выводится из объявления: шаг Model.migration()
        модели, привязанной к шлюзу sql, создаёт таблицу и индексы в базе
        (create table if not exists) — источник данных меняется
        настройкой, а не кодом моделей и миграций.

        Зависит от tnt-model (форма записи, отказы, отметки), tnt-sql
        (сборка запросов), tnt-must (проверки аргументов), tnt-external
        и tnt-clock (часы отметок). Драйвер приходит аргументом.
        Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-orm',
    issues_url = 'https://github.com/tnt-skein/tnt-orm/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'orm', 'model', 'sql', 'postgresql', 'mysql' },
}

dependencies = {
    'lua >= 5.1',
    -- Форма записи, отказы модели и отметки времени — шлюз служит ей.
    'tnt-model',
    -- Запросы собираются построителем: значения параметрами, имена по белому списку.
    'tnt-sql',
    -- Проверки аргументов на строке вызывающего и бросок без места.
    'tnt-must',
    -- Подмена часов отметок в проверках.
    'tnt-external',
    -- Стенные часы: отметки времени записи.
    'tnt-clock',
    -- Не объявлены tnt-postgres и tnt-mysql: драйвер приходит аргументом,
    -- и какой из них ставить, решает приложение.
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.orm'] = 'tnt/orm.lua',
        ['tnt.orm.columns'] = 'tnt/orm/columns.lua',
        ['tnt.orm.ddl'] = 'tnt/orm/ddl.lua',
        ['tnt.orm.gateway'] = 'tnt/orm/gateway.lua',
        ['tnt.orm.query'] = 'tnt/orm/query.lua',
        ['tnt.orm.refusal'] = 'tnt/orm/refusal.lua',
        ['tnt.orm.world'] = 'tnt/orm/world.lua',
    },
}
