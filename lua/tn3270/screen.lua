local bit = require('bit')
local ebcdic = require('tn3270.ebcdic')

local Screen = {}
Screen.__index = Screen

function Screen.new(rows, cols)
    local self = setmetatable({}, Screen)
    self.rows = rows
    self.cols = cols
    self.size = rows * cols
    self.buffer = {}
    self.attrs = {}
    self.cursor = 0
    self.locked = true
    self:clear()
    return self
end

function Screen:clear()
    for i = 1, self.size do
        self.buffer[i] = 0x00
        self.attrs[i] = nil
    end
    self.cursor = 0
end

function Screen:put(pos, byte)
    pos = pos % self.size
    self.buffer[pos + 1] = byte
    self.attrs[pos + 1] = nil
end

function Screen:set_attr(pos, attr)
    self.attrs[(pos % self.size) + 1] = attr
end

function Screen:next_field(from)
    for i = 1, self.size do
        local pos = (from + i) % self.size + 1 -- 1-indexed for attrs table
        if self.attrs[pos] then
            if bit.band(self.attrs[pos], 0x20) == 0 then
                return (from + i + 1) % self.size
            end
        end
    end
    return from
end

function Screen:prev_field(from)
    for i = 1, self.size do
        local pos = (from - i) % self.size + 1
        if self.attrs[pos] then
            if bit.band(self.attrs[pos], 0x20) == 0 then
                local data_start = (from - i + 1) % self.size
                if data_start ~= from then
                    return data_start
                end
            end
        end
    end
    return from
end

function Screen:field_attr_at(pos)
    for i = 0, self.size - 1 do
        local check = (pos - i) % self.size + 1
        if self.attrs[check] then
            return (pos - i) % self.size
        end
    end
    return nil
end

function Screen:is_protected(pos)
    local attr_pos = self:field_attr_at(pos)
    if attr_pos == nil then return true end
    return bit.band(self.attrs[attr_pos + 1], 0x20) ~= 0
end

--- Set MDT bit on field attribute at attr_pos (0-indexed).
function Screen:set_mdt(attr_pos)
    if self.attrs[attr_pos + 1] then
        self.attrs[attr_pos + 1] = bit.bor(self.attrs[attr_pos + 1], 0x01)
    end
end

--- Find end of field: last data position before the next attribute.
function Screen:field_end(attr_pos)
    for i = 1, self.size - 1 do
        local check = (attr_pos + i) % self.size + 1
        if self.attrs[check] then
            return (attr_pos + i - 1) % self.size
        end
    end
    return attr_pos
end

--- Collect all modified fields as {start=0-indexed, data={ebcdic bytes}}.
function Screen:modified_fields()
    local fields = {}
    for i = 1, self.size do
        if self.attrs[i] and bit.band(self.attrs[i], 0x01) ~= 0
                         and bit.band(self.attrs[i], 0x20) == 0 then
            local attr_pos = i - 1
            local data_start = (attr_pos + 1) % self.size
            local data = {}
            local pos = data_start
            while true do
                data[#data + 1] = self.buffer[pos + 1]
                pos = (pos + 1) % self.size
                if self.attrs[pos + 1] then break end
            end
            -- Strip trailing nulls (but not spaces; 0x40 is real data)
            while #data > 0 and data[#data] == 0x00 do
                data[#data] = nil
            end
            if #data > 0 then
                fields[#fields + 1] = { start = data_start, data = data }
            end
        end
    end
    return fields
end

--- Sync vim buffer lines back into the screen model for unprotected fields.
function Screen:sync_from_lines(lines)
    for i = 1, self.size do
        if self.attrs[i] then
            self.attrs[i] = bit.band(self.attrs[i], 0xFE)
        end
    end
    for row = 0, self.rows - 1 do
        local line = lines[row + 1] or ''
        for col = 0, self.cols - 1 do
            local pos = row * self.cols + col
            if not self.attrs[pos + 1] and not self:is_protected(pos) then
                local char = line:sub(col + 1, col + 1)
                local displayed
                if self.buffer[pos + 1] == 0x00 then
                    displayed = ' '
                else
                    displayed = ebcdic.decode(self.buffer[pos + 1])
                end
                if char ~= displayed then
                    local new_byte
                    if char == '' or char == ' ' then
                        new_byte = 0x40
                    else
                        new_byte = ebcdic.encode(char)
                    end
                    if new_byte ~= self.buffer[pos + 1] then
                        self.buffer[pos + 1] = new_byte
                        local attr_pos = self:field_attr_at(pos)
                        if attr_pos then self:set_mdt(attr_pos) end
                    end
                end
            end
        end
    end
end

function Screen:to_lines()
    local lines = {}
    for row = 0, self.rows - 1 do
        local line = {}
        for col = 0, self.cols - 1 do
            local pos = row * self.cols + col + 1
            if self.attrs[pos] then
                line[#line + 1] = ' '
            elseif self.buffer[pos] == 0x00 then
                line[#line + 1] = ' '
            else
                line[#line + 1] = ebcdic.decode(self.buffer[pos])
            end
        end
        lines[#lines + 1] = table.concat(line)
    end
    return lines
end

return Screen
