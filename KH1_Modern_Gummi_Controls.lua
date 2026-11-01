LUAGUI_NAME = "KH1 Modern Gummi Controls"
LUAGUI_AUTH = "Mariano"
LUAGUI_DESC = "Gummi ship flight: inverted up/down and a reticle that stays where you leave it."

local MOD_VERSION = "1.1.1"

-- ============================ SETTINGS ============================
-- Players change these in KH1_Modern_Gummi_Controls_Config.lua in the game
-- folder (next to the game's .exe), not here. The mod creates that file on
-- first launch with every setting below at its default, and updates never
-- touch it. Numbers must be above `min` and at most `max`; each setting
-- becomes a global of the same name.
local SETTINGS = {
    { name = "InvertY", default = true,
      help = "Flight: flip up/down from the game's default." },
    { name = "HoldReticle", default = true,
      help = "Flight: the stick moves the reticle, which stays where you leave it.\n"
          .. "false = it snaps back to the center, like vanilla." },
    { name = "ReticleSpeed", default = 4.0, min = 0, max = 20,
      help = "HoldReticle: how fast the reticle moves at full tilt, in half-screens\n"
          .. "per second (above 0, up to 20)." },
    { name = "DebugLog", default = false,
      help = "Log state changes to KH1_Modern_Gummi_Controls_log.txt in the game folder." },
}
local CONFIG_FILE = "KH1_Modern_Gummi_Controls_Config.lua"   -- relative to the game folder
-- ==================================================================

-- Steam Global only: every address below was found or verified on it.
local FINGERPRINT_ADDR = 0x3B2271
local FINGERPRINT      = 0x7265737563697065

-- The controller-read function (once per frame, before the game logic)
-- converts XInput's left stick to floats, negating Y with
-- `xorps xmm2, [sign mask]`, then stores them at LEFT_X / LEFT_Y. Lua runs
-- after the game logic, so writing those floats does nothing: the code is
-- patched instead, only while flying, and restored afterwards.
--
-- InvertY: NOP the negation.
local LEFT_Y_NEGATE = 0x113CA5
local NEGATE_BYTES  = { 0x0F, 0x57, 0x15, 0xA4, 0xBF, 0x31, 0x00 }
local NOP_BYTES     = { 0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00 }   -- 7-byte NOP

-- HoldReticle: jump over the two stores to a small code cave that stores
-- the real stick at REAL_X / REAL_Y instead. The game's floats then keep
-- what this script writes: a "virtual stick" that the real stick moves and
-- that stays put on release. The reticle follows the stick position, so it
-- stays put too.
local LEFT_STORE       = 0x113CC8
local LEFT_STORE_BYTES = { 0xF3, 0x0F, 0x11, 0x47, 0x28,    -- movss [rdi+28], xmm0
                           0xF3, 0x0F, 0x11, 0x4F, 0x2C }   -- movss [rdi+2C], xmm1
local LEFT_STORE_NEXT  = 0x113CD2
local LEFT_X = 0x22C9310   -- right-positive
local LEFT_Y = 0x22C9314   -- up-negative
-- Unused tails of the .nep code section and the .data section (past their
-- contents, inside their last page).
local CAVE      = 0x3AF800
local CAVE_SIZE = 21
local REAL_X    = 0x2F13F00
local REAL_Y    = REAL_X + 4

-- The gummi code ignores each axis up to ~0.48 (meant for a physical
-- stick's deadzone). The virtual stick skips that band so the reticle
-- doesn't stall on the center lines; below RETICLE_CENTER it is centered.
local GAME_AXIS_DEADZONE = 0.47
local RETICLE_CENTER     = 0.02
local FRAME_RATE         = 60

-- Game state, found by memory scans comparing gummi flight with being on
-- foot and with the pause menu.
local GAME_STATE       = 0x233FBC0   -- 7 in gummi mode (world map and flight), 5 on foot
local GAME_STATE_GUMMI = 7
-- While flying a route this alternates 17 / 0 every frame; it stays 0 on the
-- world map, in menus and in the pause menu. So flight is "nonzero in this
-- frame or the last". Found by a scan labeling level flight, braking, the
-- world map and the pause menu; it has five copies 0x30 apart.
local FLIGHT_FLAG = 0x23E7CC0
-- The flag also alternates in the gummi garage. This one tells them apart:
-- 2 while flying a route (pause menu included), 4 on the world map and in
-- the garage, 79 on foot. Found by a second scan that labeled the garage.
local GUMMI_MODE        = 0x2382B64
local GUMMI_MODE_FLIGHT = 2
local PAUSE_MENU       = 0x232DFA0   -- 1 in the gummi pause menu

local LOG_FILE = "KH1_Modern_Gummi_Controls_log.txt"

local active
local inverted, holding   -- current patch states
local caveReady           -- nil = not checked yet
local vx, vy              -- virtual stick
local wasFlying
local keepReticle         -- flight stopped for the pause menu: resume where it was
local lastFlag            -- FLIGHT_FLAG last frame
local lastRaw             -- DebugLog: last logged game-state values

local function log(msg)
    ConsolePrint("KH1 Modern Gummi Controls - " .. msg)
    if not DebugLog then return end
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("%H:%M:%S "), msg, "\n")
        f:close()
    end
end

-- A setting's value as it is written in the config file.
local function luaValue(v)
    if math.type(v) == "float" and v == math.floor(v) then
        return string.format("%.1f", v)
    end
    return tostring(v)
end

local function writeDefaultConfig()
    local lines = {
        "-- KH1 Modern Gummi Controls settings",
        "-- Change a value, save, then restart the game. Delete a line to use its",
        "-- default, or delete this file to have the mod recreate it.",
        "",
    }
    for _, s in ipairs(SETTINGS) do
        for line in s.help:gmatch("[^\n]+") do lines[#lines + 1] = "-- " .. line end
        lines[#lines + 1] = s.name .. " = " .. luaValue(s.default)
        lines[#lines + 1] = ""
    end
    local f = io.open(CONFIG_FILE, "w")
    if not f then
        log("could not create " .. CONFIG_FILE .. " in the game folder. Using the defaults.")
        return
    end
    f:write(table.concat(lines, "\n"))
    f:close()
    log("created " .. CONFIG_FILE .. " in the game folder with the default settings")
end

-- The config file's assignments as a table, e.g. { ReticleSpeed = 2.5 }. A
-- missing file is created with the defaults; a broken one is reported.
local function readConfig()
    local f = io.open(CONFIG_FILE, "r")
    if not f then
        writeDefaultConfig()
        return {}
    end
    local text = f:read("a"):gsub("^\239\187\191", "")   -- tolerate a UTF-8 BOM
    f:close()
    local cfg = {}
    local chunk, err = load(text, "=" .. CONFIG_FILE, "t", cfg)
    local ok = chunk ~= nil
    if ok then ok, err = pcall(chunk) end
    if not ok then
        log("error in " .. CONFIG_FILE .. ", using the defaults: " .. tostring(err))
        return {}
    end
    return cfg
end

-- Set every setting from the config file, or its default when the file
-- leaves it out or the value is invalid (reported). Unknown names are
-- reported too, since they are usually typos.
local function loadSettings()
    DebugLog = false   -- log() reads it before it is loaded
    local cfg = readConfig()
    local known, changed = {}, 0
    for _, s in ipairs(SETTINGS) do
        known[s.name] = true
        local v = cfg[s.name]
        if v == nil then v = s.default end
        local ok = type(v) == type(s.default)
        if ok and s.max then ok = v > s.min and v <= s.max end
        if not ok then
            log(string.format("%s = %s is not valid (%s). Using %s.", s.name, tostring(v),
                s.max and string.format("a number above %g, up to %g", s.min, s.max)
                    or "true or false",
                luaValue(s.default)))
            v = s.default
        end
        if v ~= s.default then changed = changed + 1 end
        _ENV[s.name] = v
    end
    for name in pairs(cfg) do
        if not known[name] then
            log("unknown setting " .. tostring(name) .. " in " .. CONFIG_FILE .. " (typo?)")
        end
    end
    if changed > 0 then
        log(string.format("%d setting(s) changed from the defaults", changed))
    end
end

local function bytesAre(addr, bytes)
    for i, b in ipairs(bytes) do
        if ReadByte(addr + i - 1) ~= b then return false end
    end
    return true
end

-- One WriteArray call, so an instruction is never left half-written.
local function writeBytes(addr, bytes)
    WriteArray(addr, bytes)
end

-- Little-endian bytes of a rel32/disp32 measured from `from` (the end of
-- the instruction).
local function rel32(from, to)
    local d = (to - from) & 0xFFFFFFFF
    return d & 0xFF, (d >> 8) & 0xFF, (d >> 16) & 0xFF, (d >> 24) & 0xFF
end

local function caveBytes()
    local a1, a2, a3, a4 = rel32(CAVE + 8, REAL_X)
    local b1, b2, b3, b4 = rel32(CAVE + 16, REAL_Y)
    local j1, j2, j3, j4 = rel32(CAVE + 21, LEFT_STORE_NEXT)
    return {
        0xF3, 0x0F, 0x11, 0x05, a1, a2, a3, a4,   -- movss [REAL_X], xmm0
        0xF3, 0x0F, 0x11, 0x0D, b1, b2, b3, b4,   -- movss [REAL_Y], xmm1
        0xE9, j1, j2, j3, j4,                     -- jmp back after the stores
    }
end

local function jumpToCaveBytes()
    local j1, j2, j3, j4 = rel32(LEFT_STORE + 5, CAVE)
    return { 0xE9, j1, j2, j3, j4, 0x0F, 0x1F, 0x44, 0x00, 0x00 }   -- jmp cave; 5-byte NOP
end

-- Write the cave once, and only into memory that is still unused (all zero).
local function prepareCave()
    if caveReady ~= nil then return caveReady end
    local want = caveBytes()
    if bytesAre(CAVE, want) then
        caveReady = true
    else
        local zeros = {}
        for i = 1, CAVE_SIZE do zeros[i] = 0 end
        caveReady = bytesAre(CAVE, zeros)
        if caveReady then
            writeBytes(CAVE, want)
        else
            log("HoldReticle unavailable: the code cave spot is in use (another mod?)")
        end
    end
    return caveReady
end

local function setInverted(on)
    if on == inverted then return end
    writeBytes(LEFT_Y_NEGATE, on and NOP_BYTES or NEGATE_BYTES)
    inverted = on
    log(on and "up/down inverted" or "up/down normal")
end

local function setHolding(on)
    if on and not prepareCave() then on = false end
    if on == holding then return end
    writeBytes(LEFT_STORE, on and jumpToCaveBytes() or LEFT_STORE_BYTES)
    holding = on
    log(on and "reticle hold on" or "reticle hold off")
end

-- Map a virtual axis past the gummi code's deadzone (see GAME_AXIS_DEADZONE).
local function pastDeadzone(v)
    local a = math.abs(v)
    if a < RETICLE_CENTER then return 0 end
    local w = GAME_AXIS_DEADZONE + (1 - GAME_AXIS_DEADZONE) * a
    return v < 0 and -w or w
end

-- Move the virtual stick by the real one and write it where the game reads
-- the left stick. Kept inside the unit circle like a real stick.
local function updateVirtualStick()
    local sx, sy = ReadFloat(REAL_X), ReadFloat(REAL_Y)
    if sx ~= sx or sy ~= sy then return end
    if InvertY then sy = -sy end
    local step = ReticleSpeed / FRAME_RATE
    vx, vy = vx + sx * step, vy + sy * step
    local len = math.sqrt(vx * vx + vy * vy)
    if len > 1 then vx, vy = vx / len, vy / len end

    local wx, wy = pastDeadzone(vx), pastDeadzone(vy)
    local wlen = math.sqrt(wx * wx + wy * wy)
    if wlen > 1 then wx, wy = wx / wlen, wy / wlen end
    WriteFloat(LEFT_X, wx)
    WriteFloat(LEFT_Y, wy)
end

function _OnInit()
    active = ReadLong(FINGERPRINT_ADDR) == FINGERPRINT
    inverted, holding, caveReady = false, false, nil
    vx, vy, wasFlying, lastRaw = 0, 0, false, nil
    keepReticle, lastFlag = false, 0
    if not active then
        ConsolePrint(string.format("KH1 Modern Gummi Controls v%s - NOT running: only "
            .. "the Steam Global version is supported. Nothing will be written.", MOD_VERSION))
        return
    end

    -- Undo this mod's own patches left over from a script reload, then only
    -- run if the code is exactly what this mod expects.
    if bytesAre(LEFT_Y_NEGATE, NOP_BYTES) then writeBytes(LEFT_Y_NEGATE, NEGATE_BYTES) end
    if bytesAre(LEFT_STORE, jumpToCaveBytes()) then writeBytes(LEFT_STORE, LEFT_STORE_BYTES) end
    if not bytesAre(LEFT_Y_NEGATE, NEGATE_BYTES) or not bytesAre(LEFT_STORE, LEFT_STORE_BYTES) then
        active = false
        ConsolePrint(string.format("KH1 Modern Gummi Controls v%s - NOT running: the "
            .. "controller code is not what was expected (another mod?).", MOD_VERSION))
        return
    end

    loadSettings()
    ConsolePrint(string.format("KH1 Modern Gummi Controls v%s - installed (Steam GL)",
        MOD_VERSION))
end

function _OnFrame()
    if not active then return end

    local state, flag, mode, pauseFlag = ReadInt(GAME_STATE), ReadInt(FLIGHT_FLAG),
        ReadInt(GUMMI_MODE), ReadInt(PAUSE_MENU)
    local inFlight = (flag ~= 0 or lastFlag ~= 0) and mode == GUMMI_MODE_FLIGHT
    lastFlag = flag
    if DebugLog then
        local raw = string.format("state=%d mode=%d flight=%s pause=%d", state, mode,
            inFlight and "yes" or "no", pauseFlag)
        if raw ~= lastRaw then
            log(raw)
            lastRaw = raw
        end
    end

    -- The flag also drops in the pause menu, so both patches step aside
    -- there and the stick drives the menu. The reticle resumes where it was
    -- after a pause; a new flight starts centered.
    local flying = state == GAME_STATE_GUMMI and inFlight and pauseFlag == 0
    if not flying then
        -- Only a pause during flight keeps the reticle; leaving the pause
        -- menu for anything but flight forgets it.
        keepReticle = pauseFlag ~= 0 and (keepReticle or wasFlying)
    end
    if flying ~= wasFlying then
        log(flying and "flight control on" or "flight control off")
        if flying then
            if not keepReticle then vx, vy = 0, 0 end
            keepReticle = false
        end
    end
    wasFlying = flying
    local control = flying

    setHolding(HoldReticle and control)
    if holding then
        setInverted(false)   -- the virtual stick applies InvertY itself
        updateVirtualStick()
    else
        setInverted(InvertY and control)
    end
end
