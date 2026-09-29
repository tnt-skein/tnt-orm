--- Внешние зависимости шлюза: часы отметок времени.
---
--- Через внешнюю зависимость затем, что проверка ставит свой час и сверяет
--- отметку точным значением: по настоящим часам отличить «отметку
--- создания взяли у прежней строки» от «поставили заново» можно было бы
--- только паузой между записями.

local external = require('tnt.external')

---@class TntOrmWorld
---@field current fun(): table Действующие средства
---@field _set_source fun(replacement: table|nil) Подмена средств — для проверок
local Module = {}

Module.current = external.install(Module, {
    --- Стенные часы `tnt-clock`: отметка уезжает на другие узлы
    --- и переживает перезапуск, а монотонные часы чужого процесса
    --- со своими несравнимы.
    clock = function()
        return require('tnt.clock')
    end,
})

return Module
