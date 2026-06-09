addon.name      = 'LingoXI'
addon.author    = 'rockerudon'
addon.version   = '1.1'
addon.desc      = 'Translate chat via Copas async HTTP.'
addon.link      = 'https://ashitaxi.com/'

local function prepend_paths()
  local install = AshitaCore:GetInstallPath()
  local dir = string.format('%s/addons/LingoXI', install)
  local dir_lower = string.format('%s/addons/lingoxi', install)
  package.path = table.concat({
    string.format('%s/?.lua', dir),
    string.format('%s/libs/?.lua', dir),
    string.format('%s/libs/?/init.lua', dir),
    string.format('%s/?.lua', dir_lower),
    string.format('%s/libs/?.lua', dir_lower),
    string.format('%s/libs/?/init.lua', dir_lower),
    package.path,
  }, ';')
  return dir
end

require('common')

local addon_dir = prepend_paths()

local imgui      = require('imgui')
local chat       = require('chat')
local copas      = require('copas')
local socket     = require('socket')
local url_mod    = require('socket.url')
local json       = require('json')
local ffi_ok, ffi = pcall(require, 'ffi')
local ffi_ready = false

if ffi_ok then
  ffi_ready = pcall(ffi.cdef, [[
    int MultiByteToWideChar(uint32_t CodePage, uint32_t dwFlags, char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int32_t cchWideChar);
    int WideCharToMultiByte(uint32_t CodePage, uint32_t dwFlags, wchar_t* lpWideCharStr, int32_t cchWideChar, char* lpMultiByteStr, int32_t cbMultiByte, const char* lpDefaultChar, bool* lpUsedDefaultChar);
  ]])
end

local MAX_INFLIGHT  = 3
local MAX_QUEUE     = 300
local MAX_RETRIES   = 2
local CONNECT_TIMEOUT = 5
local SEND_TIMEOUT    = 5
local RECEIVE_TIMEOUT = 8
-- Drops only the near-instant duplicate the game sometimes delivers for the
-- same line (e.g. routed to multiple chat windows). Kept small so the user can
-- intentionally repeat the same message without it being swallowed.
local DEDUPE_WINDOW   = 0.3
local SCROLL_FOLLOW_THRESHOLD = 32
local FANCY_WINDOW_COLOR = {0.0, 0.0, 0.0, 0.50}
local FANCY_LOG_COLOR    = {0.0, 0.0, 0.0, 0.0}

-- Static window theme colors (pushed every frame after the dynamic WindowBg).
-- WindowBg is pushed separately because it uses the user's configurable color.
local THEME_COLORS = {
  { ImGuiCol_Button,             {0, 0, 0, 0.30} },
  { ImGuiCol_ButtonHovered,      {1, 1, 1, 0.15} },
  { ImGuiCol_ButtonActive,       {1, 1, 1, 0.30} },
  { ImGuiCol_Border,             {0, 0, 0, 0} },
  { ImGuiCol_FrameBg,            {0.18, 0.18, 0.18, 0.82} },
  { ImGuiCol_FrameBgHovered,     {0.28, 0.28, 0.28, 0.88} },
  { ImGuiCol_FrameBgActive,      {0.36, 0.36, 0.36, 0.95} },
  { ImGuiCol_ScrollbarBg,        {0.05, 0.05, 0.05, 0.35} },
  { ImGuiCol_ScrollbarGrab,      {0.42, 0.42, 0.42, 0.72} },
  { ImGuiCol_ScrollbarGrabHovered, {0.56, 0.56, 0.56, 0.86} },
  { ImGuiCol_ScrollbarGrabActive,  {0.70, 0.70, 0.70, 0.96} },
  { ImGuiCol_CheckMark,          {0.82, 0.82, 0.82, 1.00} },
  { ImGuiCol_SliderGrab,         {0.58, 0.58, 0.58, 0.92} },
  { ImGuiCol_SliderGrabActive,   {0.78, 0.78, 0.78, 1.00} },
  { ImGuiCol_Header,             {0.24, 0.24, 0.24, 0.82} },
  { ImGuiCol_HeaderHovered,      {0.34, 0.34, 0.34, 0.90} },
  { ImGuiCol_HeaderActive,       {0.44, 0.44, 0.44, 0.96} },
  { ImGuiCol_ResizeGrip,         {0.50, 0.50, 0.50, 0.55} },
  { ImGuiCol_ResizeGripHovered,  {0.68, 0.68, 0.68, 0.78} },
  { ImGuiCol_ResizeGripActive,   {0.86, 0.86, 0.86, 0.95} },
  { ImGuiCol_TextSelectedBg,     {0.55, 0.55, 0.55, 0.45} },
}
-- Total style colors pushed each frame = 1 (WindowBg) + #THEME_COLORS.
local THEME_PUSH_COUNT = 1 + #THEME_COLORS

local CONFIG_THEME_COLORS = {
  { ImGuiCol_WindowBg,            {0.10, 0.10, 0.10, 0.94} },
  { ImGuiCol_ChildBg,             {0.12, 0.12, 0.12, 0.60} },
  { ImGuiCol_PopupBg,             {0.10, 0.10, 0.10, 0.96} },
  { ImGuiCol_Border,              {0.30, 0.30, 0.30, 0.50} },
  { ImGuiCol_FrameBg,             {0.18, 0.18, 0.18, 0.82} },
  { ImGuiCol_FrameBgHovered,      {0.28, 0.28, 0.28, 0.88} },
  { ImGuiCol_FrameBgActive,       {0.36, 0.36, 0.36, 0.95} },
  { ImGuiCol_TitleBg,             {0.08, 0.08, 0.08, 1.00} },
  { ImGuiCol_TitleBgActive,       {0.14, 0.14, 0.14, 1.00} },
  { ImGuiCol_Button,              {0.24, 0.24, 0.24, 0.82} },
  { ImGuiCol_ButtonHovered,       {0.34, 0.34, 0.34, 0.90} },
  { ImGuiCol_ButtonActive,        {0.44, 0.44, 0.44, 0.96} },
  { ImGuiCol_Header,              {0.24, 0.24, 0.24, 0.82} },
  { ImGuiCol_HeaderHovered,       {0.34, 0.34, 0.34, 0.90} },
  { ImGuiCol_HeaderActive,        {0.44, 0.44, 0.44, 0.96} },
  { ImGuiCol_ScrollbarBg,         {0.05, 0.05, 0.05, 0.35} },
  { ImGuiCol_ScrollbarGrab,       {0.42, 0.42, 0.42, 0.72} },
  { ImGuiCol_ScrollbarGrabHovered,{0.56, 0.56, 0.56, 0.86} },
  { ImGuiCol_ScrollbarGrabActive, {0.70, 0.70, 0.70, 0.96} },
  { ImGuiCol_CheckMark,           {0.82, 0.82, 0.82, 1.00} },
  { ImGuiCol_SliderGrab,          {0.58, 0.58, 0.58, 0.92} },
  { ImGuiCol_SliderGrabActive,    {0.78, 0.78, 0.78, 1.00} },
  { ImGuiCol_TextSelectedBg,      {0.55, 0.55, 0.55, 0.45} },
}

-- Chat categories. Each entry drives BOTH the on/off filter and the color used
-- to render that category's translated messages. `color` is the default; the
-- user can override it per category in the config window. `desc` explains what
-- the category covers. `modes`/`ranges` map FFXI chat mode ids to the category.
local CHAT_FILTER_DEFS = {
  { key = 'npc',       label = 'NPC / story',     color = {1.00, 0.95, 0.78, 1}, desc = 'NPC dialogue and story messages.',            modes = {142, 144, 150, 151, 152} },
  { key = 'local',     label = 'Local / say',     color = {1.00, 1.00, 1.00, 1}, desc = 'Say and nearby local chat.',                  modes = {0, 1, 9} },
  { key = 'shout',     label = 'Shout / yell',    color = {1.00, 0.66, 0.30, 1}, desc = 'Shout and yell channels.',                    modes = {2, 3, 10, 11} },
  { key = 'tell',      label = 'Tell',            color = {1.00, 0.55, 1.00, 1}, desc = 'Private tells (/tell).',                      modes = {4, 12} },
  { key = 'party',     label = 'Party',           color = {0.46, 1.00, 1.00, 1}, desc = 'Party and alliance chat.',                    modes = {5, 13, 210} },
  { key = 'linkshell', label = 'Linkshell',       color = {0.55, 1.00, 0.60, 1}, desc = 'Linkshell 1 and 2 chat.',                     modes = {6, 14, 205, 213, 214, 217} },
  { key = 'unity',     label = 'Unity',           color = {1.00, 0.98, 0.62, 1}, desc = 'Unity concord chat.',                         modes = {211, 212} },
  { key = 'emote',     label = 'Emote / examine', color = {0.82, 0.75, 1.00, 1}, desc = 'Emotes and examine messages.',                modes = {7, 15, 208} },
  { key = 'system',    label = 'System / item',   color = {0.70, 1.00, 0.70, 1}, desc = 'System notices and item messages.',           modes = {81, 85, 89, 90, 121, 127, 128, 131, 132, 133, 135, 136, 138, 139, 140, 141, 146, 148, 157, 161, 190, 200, 202, 204, 206, 209} },
  { key = 'combat',    label = 'Combat',          color = {0.85, 0.85, 0.85, 1}, desc = 'Combat log (damage, actions, etc.).',         ranges = { {20, 80}, {100, 122}, {162, 191} }, modes = {129} },
  { key = 'other',     label = 'Other',           color = {1.00, 1.00, 1.00, 1}, desc = 'Anything not covered by the categories above.' },
}

-- XIClient's default chat color table. The in-game chat can use the user's
-- actual client color settings via color2(message mode), but ImGui cannot read
-- those resolved colors. This table keeps the main window visually aligned with
-- the stock client palette when "client colors" is enabled.
local CLIENT_PRIMARY_COLORS = {
  [0x42] = 0x60808080, [0x4A] = 0x60808080, [0x4B] = 0x80A0A0A0,
  [0x41] = 0xFF101010, [0x43] = 0x60404040, [0x44] = 0x60A02C34,
  [0x4C] = 0x30FF2020, [0x4D] = 0x60A08080, [0x48] = 0xA0701090,
  [0x45] = 0x60808010, [0x4E] = 0x60686840, [0x46] = 0x60405080,
  [0x52] = 0x5020C0A0, [0x47] = 0x603050F0, [0x49] = 0x50A040A0,
  [0x4F] = 0x4000C000, [0x53] = 0x5010C040, [0x50] = 0x4070F070,
  [0x6F] = 0x80802060, [0x51] = 0xFF5020FF, [0x54] = 0x60808080,
  [0x55] = 0x60A07060, [0x6C] = 0x60A06050, [0x56] = 0x50A040A0,
  [0x57] = 0x5020C0A0, [0x58] = 0x5050FF60, [0x59] = 0x606050A0,
  [0x5A] = 0x50A0D0D0, [0x5B] = 0x60808080, [0x5C] = 0x606090C0,
  [0x5D] = 0x70A0302C, [0x5E] = 0x60808080, [0x5F] = 0x60808080,
  [0x60] = 0x60808050, [0x61] = 0x60808080, [0x62] = 0x5090C0F0,
  [0x63] = 0x58C08080, [0x64] = 0x60808080, [0x65] = 0x60808080,
  [0x66] = 0x60A08040, [0x67] = 0x60707070, [0x68] = 0x60808010,
  [0x69] = 0x50C060D0, [0x6A] = 0x50F0F050, [0x6B] = 0x50F0F050,
  [0x70] = 0x80FF80A0, [0x71] = 0x80FF80A0,
}

local MSG_KIND_PRIMARY_COLOR = {
  [0x01] = 0x54, [0x02] = 0x55, [0x03] = 0x6C, [0x04] = 0x56,
  [0x05] = 0x57, [0x06] = 0x58, [0x07] = 0x59, [0x08] = 0x69,
  [0x09] = 0x54, [0x0A] = 0x55, [0x0B] = 0x6C, [0x0C] = 0x56,
  [0x0D] = 0x57, [0x0E] = 0x58, [0x0F] = 0x59, [0x10] = 0x69,
  [0x11] = 0x5A, [0x12] = 0x5A, [0x14] = 0x63, [0x15] = 0x67,
  [0x16] = 0x62, [0x17] = 0x62, [0x18] = 0x62, [0x19] = 0x63,
  [0x1A] = 0x67, [0x1B] = 0x62, [0x1C] = 0x5D, [0x1D] = 0x61,
  [0x1E] = 0x5C, [0x1F] = 0x5C, [0x20] = 0x63, [0x21] = 0x67,
  [0x22] = 0x62, [0x23] = 0x62, [0x24] = 0x45, [0x25] = 0x4E,
  [0x26] = 0x44, [0x27] = 0x4C, [0x28] = 0x63, [0x29] = 0x67,
  [0x2A] = 0x62, [0x2B] = 0x62, [0x2C] = 0x42, [0x32] = 0x68,
  [0x33] = 0x68, [0x34] = 0x68, [0x35] = 0x4E, [0x36] = 0x42,
  [0x37] = 0x68, [0x38] = 0x5E, [0x39] = 0x5F, [0x3A] = 0x68,
  [0x3B] = 0x60, [0x3C] = 0x64, [0x3D] = 0x65, [0x3E] = 0x68,
  [0x3F] = 0x66, [0x40] = 0x64, [0x41] = 0x65, [0x42] = 0x68,
  [0x43] = 0x66, [0x44] = 0x66, [0x45] = 0x66, [0x46] = 0x61,
  [0x47] = 0x67, [0x48] = 0x67, [0x50] = 0x68, [0x51] = 0x5E,
  [0x52] = 0x5F, [0x53] = 0x68, [0x54] = 0x61, [0x55] = 0x68,
  [0x56] = 0x64, [0x57] = 0x65, [0x58] = 0x68, [0x59] = 0x67,
  [0x5A] = 0x68, [0x5B] = 0x64, [0x5C] = 0x65, [0x5D] = 0x68,
}

local CHAT_FILTER_BY_MODE = {}
local CHAT_FILTER_DEF_BY_KEY = {}
for _, def in ipairs(CHAT_FILTER_DEFS) do
  CHAT_FILTER_DEF_BY_KEY[def.key] = def
  for _, mode in ipairs(def.modes or {}) do
    CHAT_FILTER_BY_MODE[mode] = def.key
  end
  for _, range in ipairs(def.ranges or {}) do
    for mode = range[1], range[2] do
      CHAT_FILTER_BY_MODE[mode] = def.key
    end
  end
end

local tradutor = {
  messages      = {},
  cache         = {},
  queue         = {},
  inflight      = 0,
  tick          = 0,
  max_messages  = 200,
  recent_inputs = {},
  follow_bottom = true,
  scroll_to_bottom = false,
  native_outbox = {},
  settings      = {
    window_color   = {0.0, 0.0, 0.0, 0.50},
    window_alpha   = 0.50,
    text_bg_color  = {0.0, 0.0, 0.0, 0.0},
    text_bg_alpha  = 0.0,
    source_lang    = 'en',
    target_lang    = 'pt',
    copas_interval = 1,
    auto_detect    = true,
    show_main_window = true,
    use_client_colors = true,
    native_chat_output = false,
    native_chat_prefix = false,
    chat_filters   = {
      npc = true,
      ['local'] = true,
      shout = true,
      tell = true,
      party = true,
      linkshell = true,
      unity = true,
      emote = true,
      system = true,
      combat = true,
      other = true,
    },
    -- Per-category render color override. Empty means "use the category's
    -- default color from CHAT_FILTER_DEFS"; the user can change any of them in
    -- the config window. Keyed by category key (e.g. 'linkshell').
    chat_colors    = {},
    window_pos     = {100, 100},
    window_size    = {700, 400},
  },
  settings_open = { false },
}

local ini_file = string.format('%s/LingoXI.ini', addon_dir)
local cache_file = string.format('%s/cache.json', addon_dir)

-- ============================================================================
-- Cache Functions (JSON file based)
-- ============================================================================
local function load_cache()
  local f = io.open(cache_file, 'r')
  if not f then return end
  
  local ok, data = pcall(json.decode, f:read('*a'))
  f:close()
  
  if ok and type(data) == 'table' then
    tradutor.cache = data.cache or data or {}
  end
end

local function save_cache()
  local f = io.open(cache_file, 'w')
  if not f then return end
  
  f:write(json.encode(tradutor.cache))
  f:close()
end

local function clear_cache()
  tradutor.cache = {}
  save_cache()
end

local function copy_color(c)
  return {c[1], c[2], c[3], c[4]}
end

local function color_near(c, r, g, b, a)
  if not c then return false end
  local alpha = c[4] or a
  return math.abs((c[1] or 0) - r) < 0.02
    and math.abs((c[2] or 0) - g) < 0.02
    and math.abs((c[3] or 0) - b) < 0.02
    and math.abs(alpha - a) < 0.05
end

local function migrate_fancy_theme()
  if color_near(tradutor.settings.window_color, 0.17, 0.17, 0.17, 0.90) then
    tradutor.settings.window_color = copy_color(FANCY_WINDOW_COLOR)
    tradutor.settings.window_alpha = FANCY_WINDOW_COLOR[4]
  end

  if color_near(tradutor.settings.window_color, 0.0, 0.0, 0.0, 0.45) then
    tradutor.settings.window_color = copy_color(FANCY_WINDOW_COLOR)
    tradutor.settings.window_alpha = FANCY_WINDOW_COLOR[4]
  end

  if color_near(tradutor.settings.text_bg_color, 0.22, 0.24, 0.27, 1.00)
      or color_near(tradutor.settings.text_bg_color, 0.0, 0.0, 0.0, 0.18) then
    tradutor.settings.text_bg_color = copy_color(FANCY_LOG_COLOR)
    tradutor.settings.text_bg_alpha = FANCY_LOG_COLOR[4]
  end
end

local function norm_lang(v, fallback)
  if not v then return fallback end
  local s = tostring(v):lower():gsub('%s+', '')
  if s == '' then return fallback end
  return s
end

local function decode_unicode(str)
  return str:gsub('\\u(%x%x%x%x)', function(h)
    local n = tonumber(h,16)
    if n < 0x80 then return string.char(n)
    elseif n < 0x800 then
      return string.char(
        0xC0 + math.floor(n/0x40),
        0x80 + (n % 0x40)
      )
    else
      return string.char(
        0xE0 + math.floor(n/0x1000),
        0x80 + (math.floor(n/0x40)%0x40),
        0x80 + (n % 0x40)
      )
    end
  end)
end

local function utf8_from_codepoint(n)
  if n < 0x80 then
    return string.char(n)
  elseif n < 0x800 then
    return string.char(
      0xC0 + math.floor(n / 0x40),
      0x80 + (n % 0x40)
    )
  end
  return string.char(
    0xE0 + math.floor(n / 0x1000),
    0x80 + (math.floor(n / 0x40) % 0x40),
    0x80 + (n % 0x40)
  )
end

local shiftjis_cache = {}
local function shiftjis_to_utf8(raw)
  if not ffi_ready or not ffi or not raw or raw == '' then
    return nil
  end

  local cached = shiftjis_cache[raw]
  if cached ~= nil then
    return cached
  end

  local ok, converted = pcall(function()
    local source_length = #raw
    local cbuffer = ffi.new('char[?]', source_length + 1)
    ffi.copy(cbuffer, raw, source_length)

    local wchar_length = ffi.C.MultiByteToWideChar(932, 0, cbuffer, source_length, nil, 0)
    if wchar_length <= 0 then
      return nil
    end

    local wbuffer = ffi.new('wchar_t[?]', wchar_length + 1)
    if ffi.C.MultiByteToWideChar(932, 0, cbuffer, source_length, wbuffer, wchar_length) <= 0 then
      return nil
    end

    local utf8_length = ffi.C.WideCharToMultiByte(65001, 0, wbuffer, wchar_length, nil, 0, nil, nil)
    if utf8_length <= 0 then
      return nil
    end

    local outbuffer = ffi.new('char[?]', utf8_length + 1)
    if ffi.C.WideCharToMultiByte(65001, 0, wbuffer, wchar_length, outbuffer, utf8_length, nil, nil) <= 0 then
      return nil
    end

    local converted = ffi.string(outbuffer, utf8_length)
    return converted
  end)

  if not ok then
    return nil
  end

  shiftjis_cache[raw] = converted
  return converted
end

local FFXI_CHAT_UTF8_PAIRS = {
  ['\129\99'] = utf8_from_codepoint(0x22EF),
  ['\129\121'] = utf8_from_codepoint(0x3010),
  ['\129\122'] = utf8_from_codepoint(0x3011),
  ['\129\126'] = utf8_from_codepoint(0x2715),
  ['\129\153'] = utf8_from_codepoint(0x2606),
  ['\129\154'] = utf8_from_codepoint(0x2605),
  ['\129\156'] = utf8_from_codepoint(0x0A66),
  ['\129\158'] = utf8_from_codepoint(0x25C7),
  ['\129\159'] = utf8_from_codepoint(0x25C6),
  ['\129\166'] = utf8_from_codepoint(0x25D9),
  ['\129\168'] = utf8_from_codepoint(0x2192),
  ['\129\169'] = utf8_from_codepoint(0x2190),
  ['\129\170'] = utf8_from_codepoint(0x2191),
  ['\129\171'] = utf8_from_codepoint(0x2193),
  ['\129\172'] = utf8_from_codepoint(0x2014),
  ['\129\195'] = utf8_from_codepoint(0x21D2),
  ['\129\244'] = utf8_from_codepoint(0x266A),
  ['\131\182'] = utf8_from_codepoint(0x03A9),
  ['\133\64'] = utf8_from_codepoint(0x20AC),
  ['\133\99'] = utf8_from_codepoint(0x00A3),
  ['\133\112'] = utf8_from_codepoint(0x00B0),
  ['\135\64'] = '(1)',
  ['\135\65'] = '(2)',
  ['\135\66'] = '(3)',
  ['\135\67'] = '(4)',
  ['\135\68'] = '(5)',
  ['\135\69'] = '(6)',
  ['\135\70'] = '(7)',
  ['\135\71'] = '(8)',
  ['\135\72'] = '(9)',
  ['\135\73'] = '(10)',
  ['\135\74'] = '(11)',
  ['\135\75'] = '(12)',
  ['\135\178'] = '"',
  ['\135\179'] = '"',
  ['\136\105'] = utf8_from_codepoint(0x00E9),
  ['\239\31'] = '[fire]',
  ['\239\32'] = '[ice]',
  ['\239\33'] = '[wind]',
  ['\239\34'] = '[earth]',
  ['\239\35'] = '[lightning]',
  ['\239\36'] = '[water]',
  ['\239\37'] = '[light]',
  ['\239\38'] = '[dark]',
}

local FFXI_CHAT_SJIS_LEAD = {}
for b = 0x81, 0x9F do FFXI_CHAT_SJIS_LEAD[b] = true end
for b = 0xE0, 0xEF do FFXI_CHAT_SJIS_LEAD[b] = true end

local function ffxi_chat_to_utf8(s)
  local out = {}
  local i = 1
  while i <= #s do
    local b1 = string.byte(s, i)
    local b2 = (i < #s) and string.byte(s, i + 1) or nil
    local b3 = (i + 1 < #s) and string.byte(s, i + 2) or nil
    local b4 = (i + 2 < #s) and string.byte(s, i + 3) or nil

    if b1 == 0x85 and b2 and b2 >= 0xA0 and b2 <= 0xD9 then
      out[#out + 1] = utf8_from_codepoint(0x00C1 + (b2 - 0xA0))
      i = i + 2
    elseif b1 >= 0xC2 and b1 <= 0xDF and b2 and b2 >= 0x80 and b2 <= 0xBF then
      out[#out + 1] = string.char(b1, b2)
      i = i + 2
    elseif b1 >= 0xE0 and b1 <= 0xEF
        and b2 and b2 >= 0x80 and b2 <= 0xBF
        and b3 and b3 >= 0x80 and b3 <= 0xBF then
      out[#out + 1] = string.char(b1, b2, b3)
      i = i + 3
    elseif b1 >= 0xF0 and b1 <= 0xF4
        and b2 and b2 >= 0x80 and b2 <= 0xBF
        and b3 and b3 >= 0x80 and b3 <= 0xBF
        and b4 and b4 >= 0x80 and b4 <= 0xBF then
      out[#out + 1] = string.char(b1, b2, b3, b4)
      i = i + 4
    elseif b2 then
      local pair = string.char(b1, b2)
      local mapped = FFXI_CHAT_UTF8_PAIRS[pair]
      if mapped then
        out[#out + 1] = mapped
        i = i + 2
      elseif FFXI_CHAT_SJIS_LEAD[b1] then
        out[#out + 1] = shiftjis_to_utf8(pair) or '?'
        i = i + 2
      else
        out[#out + 1] = string.char(b1)
        i = i + 1
      end
    else
      out[#out + 1] = string.char(b1)
      i = i + 1
    end
  end
  return table.concat(out)
end

local function clean_str(s)
  if not s then return '' end
  s = AshitaCore:GetChatManager():ParseAutoTranslate(s, true)
  s = s:strip_colors()
  s = s:gsub(string.char(0xEF, 0x27), utf8_from_codepoint(0x276E))
  s = s:gsub(string.char(0xEF, 0x28), utf8_from_codepoint(0x276F))
  s = s:strip_translate(false)
  s = ffxi_chat_to_utf8(s)
  while true do
    local hasN = s:endswith('\n')
    local hasR = s:endswith('\r')
    if not hasN and not hasR then break end
    if hasN then s = s:trimend('\n') end
    if hasR then s = s:trimend('\r') end
  end
  return s:gsub(string.char(0x07), '\n')
end

local function urlencode(s)
  if url_mod and url_mod.escape then
    return url_mod.escape(s)
  end
  return (s:gsub('([^A-Za-z0-9%-_%.~ ])', function(c)
    return string.format('%%%02X', string.byte(c))
  end):gsub(' ', '%%20'))
end

local function norm_mode(mode) return mode and bit.band(mode, 0xFF) or 0 end

local function chat_filter_key(mode)
  local m = norm_mode(mode)
  return CHAT_FILTER_BY_MODE[m] or 'other'
end

local function chat_filter_all(value)
  for _, def in ipairs(CHAT_FILTER_DEFS) do
    tradutor.settings.chat_filters[def.key] = value
  end
end

local function chat_filter_allowed(e)
  local key = chat_filter_key(e.mode_modified or e.mode)
  return tradutor.settings.chat_filters[key] ~= false
end

local function norm_color(c)
  if not c or type(c) ~= 'table' then return {1,1,1,1} end
  local r = tonumber(c[1]) or 1
  local g = tonumber(c[2]) or 1
  local b = tonumber(c[3]) or 1
  local a = tonumber(c[4]) or 1
  local function clamp(x) return math.max(0, math.min(1, x)) end
  return { clamp(r), clamp(g), clamp(b), clamp(a > 0 and a or 1) }
end

local function client_argb_to_rgba(argb)
  if not argb or argb == 0 then
    return nil
  end

  return {
    bit.rshift(bit.band(argb, 0x00FF0000), 16) / 255,
    bit.rshift(bit.band(argb, 0x0000FF00), 8) / 255,
    bit.band(argb, 0x000000FF) / 255,
    1.0,
  }
end

local function client_color_from_mode(mode)
  local color_id = MSG_KIND_PRIMARY_COLOR[norm_mode(mode)]
  return client_argb_to_rgba(color_id and CLIENT_PRIMARY_COLORS[color_id])
end

local function nearest_client_color_code(color)
  local c = norm_color(color)
  local best_code = 0x54
  local best_dist = math.huge

  for code, argb in pairs(CLIENT_PRIMARY_COLORS) do
    local candidate = client_argb_to_rgba(argb)
    if candidate then
      local dr = c[1] - candidate[1]
      local dg = c[2] - candidate[2]
      local db = c[3] - candidate[3]
      local dist = dr * dr + dg * dg + db * db
      if dist < best_dist then
        best_code = code
        best_dist = dist
      end
    end
  end

  return best_code
end

-- Returns the render color for a chat category key: the user's override if set,
-- otherwise the category's default color from CHAT_FILTER_DEFS.
local function category_color(key)
  local override = tradutor.settings.chat_colors[key]
  if override then
    return norm_color(override)
  end
  local def = CHAT_FILTER_DEF_BY_KEY[key]
  if def and def.color then
    return norm_color(def.color)
  end
  return {1, 1, 1, 1}
end

-- Color a chat message by its category. This is simple and predictable: every
-- message in a category renders in that category's (configurable) color.
local function get_chat_color(e)
  if tradutor.settings.use_client_colors then
    local mode = norm_mode(e.mode_modified or e.mode)
    local key = chat_filter_key(mode)
    local color = client_color_from_mode(mode)
    if key == 'local' or not color then
      return category_color(key)
    end
    return color
  end

  local key = chat_filter_key(e.mode_modified or e.mode)
  return category_color(key)
end

local function native_color_from_message(s)
  if not s or s == '' then
    return nil
  end

  for i = 1, #s - 1 do
    local marker = string.byte(s, i)
    if marker == 0x1E or marker == 0x1F then
      local code = string.byte(s, i + 1)
      if code and code ~= 1 then
        return { table = (marker == 0x1F) and 2 or 1, code = code }
      end
    end
  end
  return nil
end

local function native_color_from_event(e)
  local mode = norm_mode(e.mode_modified or e.mode)
  if tradutor.settings.use_client_colors and mode > 0 then
    return { table = 2, code = mode }
  end

  if tradutor.settings.use_client_colors then
    return native_color_from_message(e.message_modified or '')
      or native_color_from_message(e.message or '')
  end

  return { table = 1, code = nearest_client_color_code(category_color(chat_filter_key(mode))) }
end

local function load_ini()
  local f = io.open(ini_file, 'r')
  if not f then return end
  
  local section = nil
  for line in f:lines() do
    line = line:gsub('^%s+', ''):gsub('%s+$', '') -- trim
    
    -- Skip comments and empty lines
    if line:match('^[#;]') or line == '' then
      -- skip
    -- Section header
    elseif line:match('^%[(.+)%]$') then
      section = line:match('^%[(.+)%]$')
    -- Key = value
    elseif line:match('=') then
      local key, value = line:match('^([^=]+)%s*=%s*(.+)$')
      if key and value then
        key = key:gsub('%s+$', '')
        value = value:gsub('^%s+', '')
        
        if section == 'Window' then
          if key == 'pos_x' then tradutor.settings.window_pos[1] = tonumber(value) or 100
          elseif key == 'pos_y' then tradutor.settings.window_pos[2] = tonumber(value) or 100
          elseif key == 'width' then tradutor.settings.window_size[1] = tonumber(value) or 700
          elseif key == 'height' then tradutor.settings.window_size[2] = tonumber(value) or 400
          end
        elseif section == 'Appearance' then
          if key == 'window_color' then
            local r, g, b = value:match('([%d%.]+),%s*([%d%.]+),%s*([%d%.]+)')
            if r and g and b then
              tradutor.settings.window_color = {tonumber(r), tonumber(g), tonumber(b), tradutor.settings.window_alpha}
            end
          elseif key == 'window_alpha' then
            tradutor.settings.window_alpha = tonumber(value) or 0.9
            tradutor.settings.window_color[4] = tradutor.settings.window_alpha
          elseif key == 'log_color' then
            local r, g, b = value:match('([%d%.]+),%s*([%d%.]+),%s*([%d%.]+)')
            if r and g and b then
              tradutor.settings.text_bg_color = {tonumber(r), tonumber(g), tonumber(b), tradutor.settings.text_bg_alpha}
            end
          elseif key == 'log_alpha' then
            tradutor.settings.text_bg_alpha = tonumber(value) or 1.0
            tradutor.settings.text_bg_color[4] = tradutor.settings.text_bg_alpha
          elseif key == 'show_main_window' then
            tradutor.settings.show_main_window = (value:lower() == 'true' or value == '1')
          end
        elseif section == 'Language' then
          if key == 'source' then tradutor.settings.source_lang = value
          elseif key == 'target' then tradutor.settings.target_lang = value
          elseif key == 'auto_detect' then tradutor.settings.auto_detect = (value:lower() == 'true' or value == '1')
          elseif key == 'use_client_colors' then tradutor.settings.use_client_colors = (value:lower() == 'true' or value == '1')
          elseif key == 'native_chat_output' then tradutor.settings.native_chat_output = (value:lower() == 'true' or value == '1')
          elseif key == 'native_chat_prefix' then tradutor.settings.native_chat_prefix = (value:lower() == 'true' or value == '1')
          end
        elseif section == 'Filters' then
          if tradutor.settings.chat_filters[key] ~= nil then
            tradutor.settings.chat_filters[key] = (value:lower() == 'true' or value == '1')
          end
        elseif section == 'Performance' then
          if key == 'frame_interval' then
            local interval = tonumber(value)
            if interval == nil or interval < 1 or interval == 17 then
              interval = 1
            end
            tradutor.settings.copas_interval = math.max(1, interval)
          end
        elseif section == 'ChatColors' then
          -- Per-category color override: key = category key, value = r,g,b[,a].
          if CHAT_FILTER_DEF_BY_KEY[key] ~= nil then
            local r, g, b, a = value:match('([%d%.]+),%s*([%d%.]+),%s*([%d%.]+),%s*([%d%.]+)')
            if not r then
              r, g, b = value:match('([%d%.]+),%s*([%d%.]+),%s*([%d%.]+)')
            end
            if r and g and b then
              tradutor.settings.chat_colors[key] = { tonumber(r), tonumber(g), tonumber(b), tonumber(a) or 1.0 }
            end
          end
        end
      end
    end
  end
  
  f:close()
  migrate_fancy_theme()
end

local function save_ini()
  local f = io.open(ini_file, 'w')
  if not f then return end
  
  f:write('# LingoXI Configuration File\n')
  f:write('# Edit values manually if needed\n\n')
  
  f:write('[Window]\n')
  f:write(string.format('pos_x = %d\n', math.floor(tradutor.settings.window_pos[1])))
  f:write(string.format('pos_y = %d\n', math.floor(tradutor.settings.window_pos[2])))
  f:write(string.format('width = %d\n', math.floor(tradutor.settings.window_size[1])))
  f:write(string.format('height = %d\n\n', math.floor(tradutor.settings.window_size[2])))
  
  f:write('[Appearance]\n')
  f:write(string.format('window_color = %.3f, %.3f, %.3f\n', 
    tradutor.settings.window_color[1], 
    tradutor.settings.window_color[2], 
    tradutor.settings.window_color[3]))
  f:write(string.format('window_alpha = %.2f\n', tradutor.settings.window_alpha))
  f:write(string.format('log_color = %.3f, %.3f, %.3f\n', 
    tradutor.settings.text_bg_color[1], 
    tradutor.settings.text_bg_color[2], 
    tradutor.settings.text_bg_color[3]))
  f:write(string.format('log_alpha = %.2f\n\n', tradutor.settings.text_bg_alpha))
  f:write(string.format('show_main_window = %s\n\n', tradutor.settings.show_main_window and 'true' or 'false'))
  
  f:write('[Language]\n')
  f:write(string.format('source = %s\n', tradutor.settings.source_lang))
  f:write(string.format('target = %s\n', tradutor.settings.target_lang))
  f:write(string.format('auto_detect = %s\n', tradutor.settings.auto_detect and 'true' or 'false'))
  f:write(string.format('use_client_colors = %s\n', tradutor.settings.use_client_colors and 'true' or 'false'))
  f:write(string.format('native_chat_output = %s\n', tradutor.settings.native_chat_output and 'true' or 'false'))
  f:write(string.format('native_chat_prefix = %s\n\n', tradutor.settings.native_chat_prefix and 'true' or 'false'))

  f:write('[Filters]\n')
  for _, def in ipairs(CHAT_FILTER_DEFS) do
    f:write(string.format('%s = %s\n', def.key, tradutor.settings.chat_filters[def.key] and 'true' or 'false'))
  end
  f:write('\n')
  
  f:write('[Performance]\n')
  f:write(string.format('frame_interval = %d\n\n', tradutor.settings.copas_interval))
  
  f:write('[ChatColors]\n')
  f:write('# Format: category = r, g, b, a (values from 0.0 to 1.0)\n')
  f:write('# Categories: ')
  local names = {}
  for _, def in ipairs(CHAT_FILTER_DEFS) do names[#names + 1] = def.key end
  f:write(table.concat(names, ', ') .. '\n')
  for _, def in ipairs(CHAT_FILTER_DEFS) do
    local col = tradutor.settings.chat_colors[def.key]
    if col then
      f:write(string.format('%s = %.3f, %.3f, %.3f, %.3f\n', def.key, col[1], col[2], col[3], col[4] or 1.0))
    end
  end
  
  f:close()
end

local function draw_config_contents()
  if imgui.CollapsingHeader('Appearance', ImGuiTreeNodeFlags_DefaultOpen) then
    local show_main = {tradutor.settings.show_main_window}
    if imgui.Checkbox('Show main translation window', show_main) then
      tradutor.settings.show_main_window = show_main[1]
      save_ini()
    end

    imgui.ColorEdit3('Window', tradutor.settings.window_color, ImGuiColorEditFlags_NoInputs)
    imgui.PushItemWidth(150)
    local wa = {tradutor.settings.window_alpha}
    if imgui.SliderFloat('Win Alpha', wa, 0.0, 1.0, '%.2f') then
      tradutor.settings.window_alpha = wa[1]
      save_ini()
    end
    imgui.PopItemWidth()
  end

  if imgui.CollapsingHeader('Language', ImGuiTreeNodeFlags_DefaultOpen) then
    local native_chat = {tradutor.settings.native_chat_output}
    if imgui.Checkbox('Print translations in game chat', native_chat) then
      tradutor.settings.native_chat_output = native_chat[1]
      save_ini()
    end
    if imgui.IsItemHovered() then
      imgui.SetTooltip('Original messages stay visible; translated lines are printed below them when ready.')
    end
    local native_prefix = {tradutor.settings.native_chat_prefix}
    if imgui.Checkbox('Show LingoXI prefix in game chat', native_prefix) then
      tradutor.settings.native_chat_prefix = native_prefix[1]
      save_ini()
    end
    local auto = {tradutor.settings.auto_detect}
    if imgui.Checkbox('Auto-detect language', auto) then
      tradutor.settings.auto_detect = auto[1]
      save_ini()
    end
    local src = {tradutor.settings.source_lang}
    local tgt = {tradutor.settings.target_lang}
    imgui.PushItemWidth(100)
    if imgui.InputText('Source', src, 16) then
      tradutor.settings.source_lang = src[1]
      save_ini()
    end
    if imgui.InputText('Target', tgt, 16) then
      tradutor.settings.target_lang = tgt[1]
      save_ini()
    end
    imgui.PopItemWidth()

    imgui.PushItemWidth(110)
    local interval = {tradutor.settings.copas_interval or 1}
    if imgui.SliderInt('Frame interval', interval, 1, 60) then
      tradutor.settings.copas_interval = math.max(1, interval[1])
      save_ini()
    end
    imgui.PopItemWidth()
  end

  if imgui.CollapsingHeader('Chat categories', ImGuiTreeNodeFlags_DefaultOpen) then
    local client_colors = {tradutor.settings.use_client_colors}
    if imgui.Checkbox('Use client chat colors', client_colors) then
      tradutor.settings.use_client_colors = client_colors[1]
      save_ini()
    end
    if imgui.IsItemHovered() then
      imgui.SetTooltip('Uses the game message type colors for the main window and printed chat. Turn this off to use LingoXI category color swatches.')
    end

    if imgui.Button('All on', {90, 0}) then
      chat_filter_all(true)
      save_ini()
    end
    imgui.SameLine()
    if imgui.Button('All off', {90, 0}) then
      chat_filter_all(false)
      save_ini()
    end
    imgui.SameLine()
    if imgui.Button('Reset colors', {110, 0}) then
      tradutor.settings.chat_colors = {}
      save_ini()
    end

    imgui.Separator()

    for _, def in ipairs(CHAT_FILTER_DEFS) do
      imgui.PushID(def.key)

      -- On/off toggle for the category.
      local enabled = { tradutor.settings.chat_filters[def.key] ~= false }
      if imgui.Checkbox('##on', enabled) then
        tradutor.settings.chat_filters[def.key] = enabled[1]
        save_ini()
      end
      if imgui.IsItemHovered() then imgui.SetTooltip(def.desc) end

      -- Color swatch (no '#' input row; just the editable swatch).
      imgui.SameLine()
      local c = category_color(def.key)
      local cc = { c[1], c[2], c[3], c[4] }
      if imgui.ColorEdit4('##col', cc, ImGuiColorEditFlags_NoInputs) then
        tradutor.settings.chat_colors[def.key] = { cc[1], cc[2], cc[3], cc[4] }
        save_ini()
      end
      if imgui.IsItemHovered() then imgui.SetTooltip('Color for ' .. def.label .. ' messages.') end

      -- Label, colored to match the category so it doubles as a legend.
      imgui.SameLine()
      imgui.TextColored(c, def.label)
      if imgui.IsItemHovered() then imgui.SetTooltip(def.desc) end

      imgui.PopID()
    end
  end

  if imgui.CollapsingHeader('Cache', ImGuiTreeNodeFlags_DefaultOpen) then
    local cache_count = 0
    for _ in pairs(tradutor.cache) do cache_count = cache_count + 1 end
    imgui.Text(string.format('Cached: %d', cache_count))

    if imgui.Button('Clear Cache', {-1, 0}) then
      clear_cache()
    end
  end
end

local function extract_translation(body, data)
  if type(data) == 'table' and type(data[1]) == 'table' then
    local parts = {}
    for _, seg in ipairs(data[1]) do
      if type(seg) == 'table' and seg[1] then
        table.insert(parts, seg[1])
      end
    end
    if #parts > 0 then
      return table.concat(parts)
    end
  end

  if body then
    local txt = body:match('%[%[%["(.-)"')
    if txt then
      txt = txt:gsub('\\"','"'):gsub('\\\\','\\')
      return decode_unicode(txt)
    end
  end
  return nil
end

local function http_get(host, path)
  local tcp, err = socket.tcp()
  if not tcp then return nil, err end
  tcp:settimeout(0)

  local s = copas.wrap(tcp)
  if type(s.settimeouts) == 'function' then
    s:settimeouts(CONNECT_TIMEOUT, SEND_TIMEOUT, RECEIVE_TIMEOUT)
  elseif type(s.settimeout) == 'function' then
    s:settimeout(RECEIVE_TIMEOUT)
  end
  local ok, cerr = s:connect(host, 80)
  if not ok then return nil, cerr end

  local req = table.concat({
    'GET ' .. path .. ' HTTP/1.1',
    'Host: ' .. host,
    'User-Agent: LingoXI-copas',
    'Accept: application/json',
    'Accept-Encoding: identity',
    'Connection: close',
    '\r\n',
  }, '\r\n')
  s:send(req)

  local status = s:receive('*l')
  if not status then return nil, 'no status' end
  local code = tonumber(status:match('^HTTP/%d%.%d%s+(%d%d%d)')) or 0

  local headers = {}
  while true do
    local line = s:receive('*l')
    if not line then break end
    if line == '' then break end
    local k, v = line:match('^(.-):%s*(.*)$')
    if k and v then headers[string.lower(k)] = v end
  end

  local body = {}
  if headers['transfer-encoding'] == 'chunked' then
    while true do
      local size_line = s:receive('*l')
      if not size_line then break end
      local size = tonumber(size_line, 16)
      if not size or size == 0 then
        s:receive('*l')
        break
      end
      local chunk = s:receive(size)
      if chunk and #chunk > 0 then
        body[#body + 1] = chunk
      end
      s:receive('*l')
    end
  else
    local len = tonumber(headers['content-length'])
    if len and len > 0 then
      local data = s:receive(len)
      if data and #data > 0 then
        body[#body + 1] = data
      end
    else
      while true do
        local chunk, rerr, partial = s:receive(1024)
        chunk = chunk or partial
        if chunk and #chunk > 0 then
          body[#body + 1] = chunk
        end
        if rerr == 'closed' then break end
        if rerr and rerr ~= 'timeout' then break end
      end
    end
  end

  return table.concat(body), code
end

local function split_name(msg)
  if not msg then return nil, nil end

  local function accept(prefix, sep, body)
    if not prefix or not body then
      return nil, nil
    end

    prefix = tostring(prefix):trimex()
    sep = tostring(sep or ' ')
    body = tostring(body):trimex()
    if prefix == '' or body == '' or #prefix > 64 then
      return nil, nil
    end

    return prefix, body, sep
  end

  -- Lua's %w is locale-dependent here, so use delimiter-based patterns.
  -- This keeps accented names/text from being missed or folded into the body.
  local name, body, sep = accept(msg:match('^%s*(%[[^%]]+%]%s*<[^>]+>)(%s+)(.+)$'))
  if name and body then return name, body, sep end

  name, body, sep = accept(msg:match('^%s*(<[^>]+>)(%s+)(.+)$'))
  if name and body then return name, body, sep end

  name, body, sep = accept(msg:match('^%s*({[^}]+})(%s+)(.+)$'))
  if name and body then return name, body, sep end

  name, sep, body = msg:match('^%s*(.-)(%s+:%s+)(.+)$')
  name, body, sep = accept(name, sep, body)
  if name and body then return name, body, sep end

  name, sep, body = msg:match('^%s*([^:>]+)(%s*[:>]%s*)(.+)$')
  name, body, sep = accept(name, sep, body)
  if name and body then return name, body, sep end

  return nil, msg
end

local pump_queue

local function compose_display_text(name, text, sep)
  text = tostring(text or '')
  if name and name ~= '' then
    return tostring(name) .. tostring(sep or ' ') .. text
  end
  return text
end

local AUTO_TRANSLATE_OPEN = utf8_from_codepoint(0x276E)
local AUTO_TRANSLATE_CLOSE = utf8_from_codepoint(0x276F)

local function escape_pattern(s)
  return tostring(s or ''):gsub('([%(%)%.%%%+%-%*%?%[%]%^%$])', '%%%1')
end

local function protect_autotranslate(text)
  local tokens = {}
  local index = 0
  local open_pat = escape_pattern(AUTO_TRANSLATE_OPEN)
  local close_pat = escape_pattern(AUTO_TRANSLATE_CLOSE)

  local function token_for(body)
    index = index + 1
    local token = string.format('LXATOKEN%03d', index)
    tokens[token] = AUTO_TRANSLATE_OPEN .. tostring(body or ''):trimex() .. AUTO_TRANSLATE_CLOSE
    return token .. ' '
  end

  local protected = tostring(text or ''):gsub(open_pat .. '(.-)' .. close_pat .. '%s*', token_for)
  protected = protected:gsub('%[([^%]]+)%]%s*', token_for)
  return protected, tokens
end

local function restore_autotranslate(text, tokens)
  local out = tostring(text or '')
  for token, value in pairs(tokens or {}) do
    local replacement = tostring(value or '') .. ' '
    out = out:gsub('%(%s*' .. token .. '%s*%)', replacement)
    out = out:gsub('%[%s*' .. token .. '%s*%]', replacement)
    out = out:gsub(token, replacement)
  end
  return out
end

local function window_text(text)
  return tostring(text or '')
    :gsub(AUTO_TRANSLATE_OPEN, '[')
    :gsub(AUTO_TRANSLATE_CLOSE, ']')
end

local function cleanup_autotranslate_artifacts(text)
  local out = tostring(text or '')
  local close_pat = escape_pattern(AUTO_TRANSLATE_CLOSE)

  out = out:gsub('(' .. close_pat .. ')%s*%(', '%1 ')
  out = out:gsub('(' .. close_pat .. ')%s*(.)', function(term, next_char)
    if next_char:match('[%.,%!%?:;%)]') then
      return term .. next_char
    end
    return term .. ' ' .. next_char
  end)
  return out
end

local function draw_message(m)
  imgui.BeginGroup()
    local text = window_text(cleanup_autotranslate_artifacts(compose_display_text(m.name, m.text, m.sep)))
    imgui.PushStyleColor(ImGuiCol_Text, m.color or {1,1,1,1})
    imgui.TextWrapped(text)
    imgui.PopStyleColor()
    
    -- Tooltip with original text and click to copy
    if imgui.IsItemHovered() then
      if m.orig and m.orig ~= m.text then
        imgui.SetTooltip('Original: ' .. window_text(cleanup_autotranslate_artifacts(m.orig)) .. '\n(Click to copy)')
      end
      
      if imgui.IsMouseClicked(0) then
        imgui.SetClipboardText(window_text(m.text or ''))
      end
    end
  imgui.EndGroup()
end

local function append_message(message)
  table.insert(tradutor.messages, message)
  if tradutor.follow_bottom then
    tradutor.scroll_to_bottom = true
  end
  while #tradutor.messages > tradutor.max_messages do
    table.remove(tradutor.messages, 1)
  end
end

local function native_chat_encode_accents(text)
  local out = tostring(text or '')
  local at_open = '\1LX_AT_OPEN\1'
  local at_close = '\1LX_AT_CLOSE\1'
  out = out:gsub(AUTO_TRANSLATE_OPEN, at_open)
  out = out:gsub(AUTO_TRANSLATE_CLOSE, at_close)
  out = out:gsub(utf8_from_codepoint(0x22EF), '...')
  out = out:gsub(utf8_from_codepoint(0x3010), '[')
  out = out:gsub(utf8_from_codepoint(0x3011), ']')
  out = out:gsub(utf8_from_codepoint(0x2715), 'x')
  out = out:gsub(utf8_from_codepoint(0x2606), '*')
  out = out:gsub(utf8_from_codepoint(0x2605), '*')
  out = out:gsub(utf8_from_codepoint(0x0A66), 'O')
  out = out:gsub(utf8_from_codepoint(0x25C7), '<>')
  out = out:gsub(utf8_from_codepoint(0x25C6), '<>')
  out = out:gsub(utf8_from_codepoint(0x25D9), '*')
  out = out:gsub(utf8_from_codepoint(0x2192), '->')
  out = out:gsub(utf8_from_codepoint(0x2190), '<-')
  out = out:gsub(utf8_from_codepoint(0x2191), '^')
  out = out:gsub(utf8_from_codepoint(0x2193), 'v')
  out = out:gsub(utf8_from_codepoint(0x2018), "'")
  out = out:gsub(utf8_from_codepoint(0x2019), "'")
  out = out:gsub(utf8_from_codepoint(0x201C), '"')
  out = out:gsub(utf8_from_codepoint(0x201D), '"')
  out = out:gsub(utf8_from_codepoint(0x2013), '-')
  out = out:gsub(utf8_from_codepoint(0x2014), '-')
  out = out:gsub(utf8_from_codepoint(0x2026), '...')
  out = out:gsub(utf8_from_codepoint(0x266A), '~')
  out = out:gsub(utf8_from_codepoint(0x03A9), 'Omega')
  out = out:gsub(utf8_from_codepoint(0x20AC), 'EUR')
  out = out:gsub(utf8_from_codepoint(0x00A3), 'GBP')
  out = out:gsub(utf8_from_codepoint(0x00B0), 'deg')
  local latin = {}
  for codepoint = 0x00C0, 0x00FF do
    local ch = utf8_from_codepoint(codepoint)
    local token = string.format('\2LX_LAT_%02X\2', codepoint)
    out = out:gsub(ch, token)
    latin[token] = string.char(0x85, 0x9F + (codepoint - 0x00C0))
  end
  out = out:gsub('[\194-\244][\128-\191]*', '?')
  for token, ch in pairs(latin) do
    out = out:gsub(token, ch)
  end
  out = out:gsub(at_open, string.char(0xEF, 0x27))
  out = out:gsub(at_close, string.char(0xEF, 0x28))
  return out
end

local function native_chat_text(text)
  return native_chat_encode_accents(text)
end

local function queue_native_translation(message)
  if not tradutor.settings.native_chat_output then
    return
  end

  local text = tostring(message and message.text or ''):trimex()
  if text == '' then
    return
  end

  text = compose_display_text(message.name, text, message.sep):trimex()
  text = cleanup_autotranslate_artifacts(text):trimex()

  table.insert(tradutor.native_outbox, {
    text = text,
    native_color = message.native_color,
  })
end

local function flush_native_translations()
  if #tradutor.native_outbox == 0 then
    return
  end

  local pending = tradutor.native_outbox
  tradutor.native_outbox = {}
  for _, item in ipairs(pending) do
    local text = native_chat_text(item.text or '')
    if tradutor.settings.native_chat_prefix then
      text = string.format('[%s] %s', addon.name, text:trimex())
    end

    if item.native_color and item.native_color.table == 2 and item.native_color.code then
      AshitaCore:GetChatManager():AddChatMessage(item.native_color.code, false, text:trimex())
    else
      local code = (item.native_color and item.native_color.code) or 0x54
      AshitaCore:GetChatManager():AddChatMessage(code, false, text:trimex())
    end
  end
end

local function publish_translation(message)
  append_message(message)
  queue_native_translation(message)
end

local function translate_async(content, color, name, native_color, sep)
  local key = content or ''
  local cache_key = key
  if key:find(AUTO_TRANSLATE_OPEN, 1, true) or key:match('%[[^%]]+%]') then
    cache_key = 'AT9:' .. key
  end

  -- Show a cached result if we have one. The cache may hold a value equal to
  -- the original (text that was already in the target language); we still
  -- display it so nothing is dropped.
  local cached = tradutor.cache[cache_key]
  if cached ~= nil then
      publish_translation({
        text  = cleanup_autotranslate_artifacts(tostring(cached or ''):trimex()),
        color = color,
        name  = name,
        sep   = sep,
        orig  = key,
        native_color = native_color,
      })
    return
  end

  if #tradutor.queue < MAX_QUEUE then
    local send_text, autotranslate_tokens = protect_autotranslate(content)
    table.insert(tradutor.queue, {
      orig  = key,
      cache_key = cache_key,
      send  = send_text,
      autotranslate_tokens = autotranslate_tokens,
      color = color,
      name  = name,
      sep   = sep,
      native_color = native_color,
      retries = 0,
    })
    pump_queue()
  end
end

pump_queue = function()
  while tradutor.inflight < MAX_INFLIGHT and #tradutor.queue > 0 do
    local job = table.remove(tradutor.queue, 1)
    tradutor.inflight = tradutor.inflight + 1

    copas.addthread(function()
      local src = tradutor.settings.auto_detect and 'auto' or norm_lang(tradutor.settings.source_lang, 'en')
      local tgt = norm_lang(tradutor.settings.target_lang, 'pt')
      local send_text = job.send or ''
      local path = '/translate_a/single?client=gtx&sl=' .. src .. '&tl=' .. tgt .. '&dt=t&q='
                 .. urlencode(send_text)
      local tr = nil

      local body, code = http_get('translate.googleapis.com', path)
      if code == 200 and type(body) == 'string' then
        local ok, data = pcall(json.decode, body)
        local parsed = ok and extract_translation(body, data) or extract_translation(body, nil)
        if parsed and #parsed > 0 then
          tr = parsed
        end
      end

      if tr == nil and (job.retries or 0) < MAX_RETRIES then
        job.retries = (job.retries or 0) + 1
        table.insert(tradutor.queue, job)
        tradutor.inflight = tradutor.inflight - 1
        pump_queue()
        return
      end

      -- Use the translation when we got one; otherwise (no result, or text
      -- already in the target language) fall back to the original so messages
      -- are never silently dropped. Cache the displayed text either way to
      -- avoid re-requesting the same line.
      local display = (tr ~= nil)
        and restore_autotranslate(tr, job.autotranslate_tokens)
        or restore_autotranslate(job.send or job.orig, job.autotranslate_tokens)
      display = cleanup_autotranslate_artifacts(display)
      display = tostring(display or ''):trimex()
      tradutor.cache[job.cache_key or job.orig] = display
      publish_translation({
        text  = display,
        color = job.color,
        name  = job.name,
        sep   = job.sep,
        orig  = job.orig,
        native_color = job.native_color,
      })

      if tradutor.inflight <= 1 and #tradutor.queue == 0 then
        -- Save cache once all in-flight translations are done.
        save_cache()
      end

      tradutor.inflight = tradutor.inflight - 1
      pump_queue()
    end)
  end
end

ashita.events.register('command', 'lingoxi_command_cb', function(e)
  local args = e.command:args()
  local cmd = (#args > 0) and args[1]:lower() or ''
  if (cmd ~= '/lingoxi' and cmd ~= '/lingo') then
    return
  end

  e.blocked = true

  if (#args >= 2 and args[2]:lower() == 'config') then
    tradutor.settings_open[1] = true
    return
  end

  if (#args >= 2 and args[2]:lower() == 'hide') then
    tradutor.settings.show_main_window = false
    save_ini()
    print(chat.header(addon.name):append(chat.message('Main translation window hidden. Use /lingo show to restore it.')))
    return
  end

  if (#args >= 2 and args[2]:lower() == 'show') then
    tradutor.settings.show_main_window = true
    save_ini()
    print(chat.header(addon.name):append(chat.message('Main translation window shown.')))
    return
  end

  print(chat.header(addon.name):append(chat.message('Use /lingo config, /lingo hide, or /lingo show.')))
end)

ashita.events.register('text_in', 'text_in_cb', function(e)
  if e.injected then
    return
  end

  if not chat_filter_allowed(e) then
    return
  end

  if (not e.message_modified or #e.message_modified == 0) and (not e.message or #e.message == 0) then
    return
  end

  local native_color = native_color_from_event(e)
  local raw     = clean_str(e.message or '')
  local mod     = clean_str(e.message_modified or '')
  local is_auto = (raw ~= mod)
  local display = is_auto and mod or raw

  local name, body, sep = split_name(display)
  if not name then
    name, body, sep = split_name(raw)
  end
  local content = body or display
  if content == '' then
    return
  end

  local dedupe_text = tostring(content):gsub('%s+', ' '):trimex()
  local input_key = table.concat({ name or '', dedupe_text }, '\31')
  local now = socket.gettime and socket.gettime() or os.clock()

  for key, seen_at in pairs(tradutor.recent_inputs) do
    if now - seen_at > DEDUPE_WINDOW then
      tradutor.recent_inputs[key] = nil
    end
  end

  if tradutor.recent_inputs[input_key] ~= nil then
    return
  end
  tradutor.recent_inputs[input_key] = now

  local color = get_chat_color(e)

  translate_async(content, color, name, native_color, sep)
end)

ashita.events.register('d3d_present', 'present_cb', function()
  tradutor.tick = tradutor.tick + 1
  local interval = math.max(1, tradutor.settings.copas_interval or 1)
  if tradutor.tick % interval == 0 then
    copas.step(0)
  end
  flush_native_translations()

  if tradutor.settings.show_main_window then
    imgui.SetNextWindowBgAlpha(tradutor.settings.window_alpha)
    tradutor.settings.window_color[4] = tradutor.settings.window_alpha
    imgui.PushStyleColor(ImGuiCol_WindowBg, tradutor.settings.window_color)
    for _, c in ipairs(THEME_COLORS) do
      imgui.PushStyleColor(c[1], c[2])
    end

    -- Set window position and size from settings
    imgui.SetNextWindowPos(tradutor.settings.window_pos, ImGuiCond_FirstUseEver)
    imgui.SetNextWindowSize(tradutor.settings.window_size, ImGuiCond_FirstUseEver)
    
    local window_flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoSavedSettings)
    if imgui.Begin('LingoXI', true, window_flags) then
      -- Persist the live window position and size (this binding returns two
      -- numbers, so capture both; saving only the first duplicated x into y).
      local pos_x, pos_y = imgui.GetWindowPos()
      local size_w, size_h = imgui.GetWindowSize()
      if math.abs((tradutor.settings.window_pos[1] or 0) - pos_x) >= 1 or
         math.abs((tradutor.settings.window_pos[2] or 0) - pos_y) >= 1 or
         math.abs((tradutor.settings.window_size[1] or 0) - size_w) >= 1 or
         math.abs((tradutor.settings.window_size[2] or 0) - size_h) >= 1 then
        tradutor.settings.window_pos = {pos_x, pos_y}
        tradutor.settings.window_size = {size_w, size_h}
      end
      -- Calculate widths
      local avail_w = imgui.GetContentRegionAvail()
      local msg_w = math.max(100, avail_w)

      -- Messages panel
      tradutor.settings.text_bg_color[4] = tradutor.settings.text_bg_alpha
      imgui.PushStyleColor(ImGuiCol_ChildBg, tradutor.settings.text_bg_color)
      imgui.BeginChild('scroll', {msg_w, 0}, false)
        local scroll_y = imgui.GetScrollY()
        local scroll_max = imgui.GetScrollMaxY()
        tradutor.follow_bottom = scroll_max <= 0 or scroll_y >= (scroll_max - SCROLL_FOLLOW_THRESHOLD)
        for _, m in ipairs(tradutor.messages) do
          draw_message(m)
        end

        if tradutor.scroll_to_bottom then
          imgui.SetScrollHereY(1.0)
          tradutor.scroll_to_bottom = false
          tradutor.follow_bottom = true
        end
      imgui.EndChild()
      imgui.PopStyleColor()
    end

    imgui.End()
    imgui.PopStyleColor(THEME_PUSH_COUNT)
  end

  if tradutor.settings_open[1] then
    imgui.SetNextWindowSize({300, 420}, ImGuiCond_FirstUseEver)
    for _, c in ipairs(CONFIG_THEME_COLORS) do
      imgui.PushStyleColor(c[1], c[2])
    end
    local config_open = { tradutor.settings_open[1] }
    local config_flags = bit.bor(ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoSavedSettings)
    if imgui.Begin('LingoXI Config', config_open, config_flags) then
      draw_config_contents()
    end
    imgui.End()
    tradutor.settings_open[1] = config_open[1]
    imgui.PopStyleColor(#CONFIG_THEME_COLORS)
  end
end)

ashita.events.register('load', 'load_cb', function()
  load_ini()
  load_cache()
end)

ashita.events.register('unload', 'unload_cb', function()
  save_ini()
  save_cache()
end)
