-- Minimal class helper: metatable + __index, single inheritance via `base`.
local function Class(name, base)
    local cls = {__name = name, __index = nil}
    cls.__index = cls
    if base then setmetatable(cls, {__index = base}) end
    function cls.new(...)
        local self = setmetatable({}, cls)
        if self.init then self:init(...) end
        return self
    end
    return cls
end

return Class
