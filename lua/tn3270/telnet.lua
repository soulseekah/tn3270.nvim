local Telnet = {}
Telnet.__index = Telnet

local IAC  = 0xFF
local WILL = 0xFB
local WONT = 0xFC
local DO   = 0xFD
local DONT = 0xFE
local SB   = 0xFA
local SE   = 0xF0
local EOR  = 0xEF

local STATE_DATA   = 1
local STATE_IAC    = 2
local STATE_OPTION = 3
local STATE_SB     = 4
local STATE_SB_IAC = 5

function Telnet.new(callbacks)
    local self = setmetatable({}, Telnet)
    self.state = STATE_DATA
    self.command = nil
    self.subneg_option = nil
    self.subneg_buf = {}
    self.callbacks = callbacks or {}
    return self
end

function Telnet:feed(bytes)
    for i = 1, #bytes do
        local byte = string.byte(bytes, i)
        self:process(byte)
    end
end

function Telnet:process(byte)
    if self.state == STATE_DATA then
        if byte == IAC then
            self.state = STATE_IAC
        else
            self:emit('on_data', string.char(byte))
        end

    elseif self.state == STATE_IAC then
        if byte == IAC then
            self:emit('on_data', string.char(IAC))
            self.state = STATE_DATA
        elseif byte == DO or byte == DONT or byte == WILL or byte == WONT then
            self.command = byte
            self.state = STATE_OPTION
        elseif byte == SB then
            self.state = STATE_SB
            self.subneg_option = nil
            self.subneg_buf = {}
        elseif byte == EOR then
            self:emit('on_eor')
            self.state = STATE_DATA
        else
            self.state = STATE_DATA
        end

    elseif self.state == STATE_OPTION then
        if self.command == DO then
            self:emit('on_do', byte)
        elseif self.command == DONT then
            self:emit('on_dont', byte)
        elseif self.command == WILL then
            self:emit('on_will', byte)
        elseif self.command == WONT then
            self:emit('on_wont', byte)
        end
        self.command = nil
        self.state = STATE_DATA

    elseif self.state == STATE_SB then
        if byte == IAC then
            self.state = STATE_SB_IAC
        elseif self.subneg_option == nil then
            self.subneg_option = byte
        else
            self.subneg_buf[#self.subneg_buf + 1] = byte
        end

    elseif self.state == STATE_SB_IAC then
        if byte == SE then
            self:emit('on_subneg', self.subneg_option, self.subneg_buf)
            self.subneg_option = nil
            self.subneg_buf = {}
            self.state = STATE_DATA
        elseif byte == IAC then
            self.subneg_buf[#self.subneg_buf + 1] = IAC
            self.state = STATE_SB
        else
            self.state = STATE_SB
        end
    end
end

function Telnet:emit(event, ...)
    if self.callbacks[event] then
        self.callbacks[event](...)
    end
end

return Telnet
