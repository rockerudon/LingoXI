addon.name      = 'LingoXI'
addon.author    = 'rockerudon'
addon.version   = '1.0'
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

local COPAS_BUDGET  = 0.001
local MAX_INFLIGHT  = 10
local MAX_QUEUE     = 100
local CONNECT_TIMEOUT = 5
local SEND_TIMEOUT    = 5
local RECEIVE_TIMEOUT = 8
local DEDUPE_WINDOW   = 8
local SCROLL_FOLLOW_THRESHOLD = 32
local FANCY_WINDOW_COLOR = {0.0, 0.0, 0.0, 0.50}
local FANCY_LOG_COLOR    = {0.0, 0.0, 0.0, 0.0}
local FANCY_PANEL_COLOR  = {0.02, 0.02, 0.02, 0.72}

local CHAT_FILTER_DEFS = {
  { key = 'npc',       label = 'NPC / story', modes = {142, 144, 150, 151, 152} },
  { key = 'local',     label = 'Local / say', modes = {0, 1, 9} },
  { key = 'shout',     label = 'Shout / yell', modes = {2, 3, 10, 11} },
  { key = 'tell',      label = 'Tell', modes = {4, 12} },
  { key = 'party',     label = 'Party', modes = {5, 13, 210} },
  { key = 'linkshell', label = 'Linkshell', modes = {6, 14, 205, 213, 214, 217} },
  { key = 'unity',     label = 'Unity', modes = {211, 212} },
  { key = 'emote',     label = 'Emote / examine', modes = {7, 15, 208} },
  { key = 'system',    label = 'System / item', modes = {81, 85, 89, 90, 121, 127, 128, 131, 132, 133, 135, 136, 138, 139, 140, 141, 146, 148, 157, 161, 190, 200, 202, 204, 206, 209} },
  { key = 'combat',    label = 'Combat', ranges = { {20, 80}, {100, 122}, {162, 191} }, modes = {129} },
  { key = 'other',     label = 'Other', fallback = true },
}

local CHAT_FILTER_BY_MODE = {}
for _, def in ipairs(CHAT_FILTER_DEFS) do
  for _, mode in ipairs(def.modes or {}) do
    CHAT_FILTER_BY_MODE[mode] = def.key
  end
  for _, range in ipairs(def.ranges or {}) do
    for mode = range[1], range[2] do
      CHAT_FILTER_BY_MODE[mode] = def.key
    end
  end
end

local NAME_COLORS = {
  {0.58, 0.82, 1.00, 1},
  {0.82, 0.75, 1.00, 1},
  {0.80, 1.00, 0.70, 1},
  {1.00, 0.86, 0.60, 1},
  {0.90, 0.90, 0.90, 1},
  {1.00, 0.70, 0.85, 1},
}

local tradutor = {
  is_open       = { true },
  messages      = {},
  cache         = {},
  queue         = {},
  inflight      = 0,
  tick          = 0,
  max_messages  = 200,
  config_width  = 260,
  last_detected_lang = nil,  -- Track last detected language
  last_translation_time = -10,  -- Track when last translation finished (start with old time)
  is_translating = false,     -- Track if currently translating
  recent_inputs = {},
  follow_bottom = true,
  scroll_to_bottom = false,
  settings      = {
    window_color   = {0.0, 0.0, 0.0, 0.50},
    window_alpha   = 0.50,
    text_bg_color  = {0.0, 0.0, 0.0, 0.0},
    text_bg_alpha  = 0.0,
    source_lang    = 'en',
    target_lang    = 'pt',
    copas_budget   = 0.001,
    copas_interval = 1,
    font_scale     = 1.0,
    auto_detect    = true,
    show_lang_status = false,
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
    window_pos     = {100, 100},
    window_size    = {700, 400},
  },
  settings_open = { false },
  history_open  = { false },
  add_mode      = { 0 },
  user_palette  = {
    ["0"] = {1, 1, 1, 1},
    ["1"] = {1, 0.99999463558197, 0.99998998641968, 1},
    ["4"] = {1, 0.52549022436142, 1, 1},
    ["5"] = {0.45882353186607, 0.99607843160629, 1, 1},
    ["6"] = {0.55294120311737, 1, 0.83137255907059, 1},
    ["11"] = {1, 0.61568629741669, 0.70980393886566, 1},
    ["12"] = {1, 0.54509806632996, 1, 1},
    ["13"] = {0.45882353186607, 0.99607843160629, 1, 1},
    ["14"] = {0.55294120311737, 1, 0.83137255907059, 1},
    ["123"] = {0.8918918967247, 0.30303663015366, 0.57292926311493, 1},
    ["205"] = {0.55294120311737, 1, 0.83137255907059, 1},
    ["212"] = {1, 0.99607843160629, 0.74509805440903, 1},
    ["213"] = {0.14624109864235, 0.84169882535934, 0.39386612176895, 1},
    ["214"] = {0.14509804546833, 0.84313726425171, 0.39215686917305, 1},
    ["217"] = {0.14509804546833, 0.84313726425171, 0.39215686917305, 1},
  },
}

local palette_dirty = false

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

local function vec2x(v)
  if not v then return 0 end
  local t = type(v)
  if t == 'number' then return v end
  if t == 'table' then return v.x or v[1] or v[0] or 0 end
  if t == 'userdata' then
    local ok, val = pcall(function() return v.x end)
    if ok and val then return val end
  end
  return 0
end

local function vec2y(v)
  if not v then return 0 end
  local t = type(v)
  if t == 'number' then return v end
  if t == 'table' then return v.y or v[2] or v[0] or 0 end
  if t == 'userdata' then
    local ok, val = pcall(function() return v.y end)
    if ok and val then return val end
  end
  return 0
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

local function get_cursor_screen_xy()
  local pos, y = imgui.GetCursorScreenPos()
  return vec2x(pos), y or vec2y(pos)
end

local function draw_settings_tool_button(size)
  local x, y = get_cursor_screen_xy()
  imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {4, 4})
  imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0)
  imgui.PushStyleColor(ImGuiCol_Button,        {0, 0, 0, 0})
  imgui.PushStyleColor(ImGuiCol_ButtonHovered, {1, 1, 1, 0.15})
  imgui.PushStyleColor(ImGuiCol_ButtonActive,  {1, 1, 1, 0.30})
  local clicked = imgui.Button('##lingoxi_settings', {size, size})
  local hovered = imgui.IsItemHovered()
  local draw = imgui.GetWindowDrawList()
  local color = imgui.GetColorU32(hovered and {1, 1, 1, 0.95} or {0.85, 0.85, 0.85, 0.72})
  local x1 = x + (size * 0.32)
  local y1 = y + (size * 0.70)
  local x2 = x + (size * 0.68)
  local y2 = y + (size * 0.34)
  local jaw = size * 0.12

  draw:AddLine({x1, y1}, {x2, y2}, color, 2.0)
  draw:AddLine({x1 - 2, y1 + 2}, {x1 + 4, y1 - 4}, color, 1.4)
  draw:AddLine({x2, y2}, {x2 - jaw, y2 - jaw}, color, 1.7)
  draw:AddLine({x2, y2}, {x2 + jaw, y2 + jaw * 0.25}, color, 1.7)

  if hovered then
    imgui.SetTooltip('Config')
  end

  imgui.PopStyleColor(3)
  imgui.PopStyleVar(2)
  return clicked
end

local function norm_lang(v, fallback)
  if not v then return fallback end
  local s = tostring(v):lower():gsub('%s+', '')
  if s == '' then return fallback end
  return s
end

local function name_color(name)
  if not name or #NAME_COLORS == 0 then return {1,1,1,1} end
  local sum = 0
  for i = 1, #name do
    sum = (sum + string.byte(name, i)) % 1024
  end
  local idx = (sum % #NAME_COLORS) + 1
  return NAME_COLORS[idx]
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

local function clean_str(s)
  if not s then return '' end
  s = AshitaCore:GetChatManager():ParseAutoTranslate(s, true)
  s = s:strip_colors()
  s = s:strip_translate(true)
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
  return (s:gsub('([^%w%-_%.~ ])', function(c)
    return string.format('%%%02X', string.byte(c))
  end):gsub(' ', '%%20'))
end

local ESC1 = string.char(0x1E)
local ESC2 = string.char(0x1F)

local function extract_color_tag(msg)
  if not msg or #msg < 2 then return nil end
  local pos = msg:find(ESC1, 1, true)
  local table_id = 1
  if not pos then
    pos = msg:find(ESC2, 1, true)
    table_id = 2
  end
  if pos and (pos + 1) <= #msg then
    local code = msg:byte(pos + 1)
    return table_id, code
  end
  return nil
end

local function argb_to_rgba(argb)
  if not argb then return nil end
  local a = bit.rshift(argb, 24)
  local r = bit.band(bit.rshift(argb, 16), 0xFF)
  local g = bit.band(bit.rshift(argb, 8), 0xFF)
  local b = bit.band(argb, 0xFF)
  local inv = 1 / 255
  return { r * inv, g * inv, b * inv, a * inv }
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

local function sorted_keys(tbl)
  local t = {}
  for k in pairs(tbl or {}) do table.insert(t, k) end
  table.sort(t, function(a,b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na < nb end
    return tostring(a) < tostring(b)
  end)
  return t
end

local function cm_color(table_id, code)
  local cm = AshitaCore and AshitaCore:GetChatManager()
  if not cm then return nil end
  local candidates = {
    function() return cm:GetColor(table_id, code) end,
    function() return cm:GetColor(table_id - 1, code) end,
    function() return cm:GetTypeColor(code) end,
  }
  for _, fn in ipairs(candidates) do
    local ok, v = pcall(fn)
    if ok and type(v) == 'number' and v ~= 0 then
      local c = argb_to_rgba(v)
      if c then return c end
    end
  end
  return nil
end

local function get_chat_color(e)
  local modes_to_try = {
    norm_mode(e.mode_modified),
    norm_mode(e.mode),
    e.mode_modified,
    e.mode,
  }

  for _, m in ipairs(modes_to_try) do
    if m and tradutor.user_palette[tostring(m)] then
      return norm_color(tradutor.user_palette[tostring(m)])
    end
  end

  if e.color and type(e.color) == 'table' and #e.color >= 3 then
    return norm_color({ e.color[1], e.color[2], e.color[3], e.color[4] })
  end
  if e.rgba and type(e.rgba) == 'table' and #e.rgba >= 3 then
    return norm_color({ e.rgba[1], e.rgba[2], e.rgba[3], e.rgba[4] })
  end

  local cm = AshitaCore and AshitaCore:GetChatManager()
  if cm and cm.GetTypeColor then
    for _, m in ipairs(modes_to_try) do
      if m then
        local argb = cm:GetTypeColor(m)
        local col = argb_to_rgba(argb)
        if col then return norm_color(col) end
      end
    end
  end

  local table_id, code = extract_color_tag(e.message_modified) or extract_color_tag(e.message)
  if table_id and code then
    local c = cm_color(table_id, code)
    if c then return norm_color(c) end
  end

  if chat.getModeColor then
    for _, m in ipairs(modes_to_try) do
      if m then
        local c = chat.getModeColor(m)
        if c and #c >= 3 then return norm_color({ c[1], c[2], c[3], c[4] }) end
      end
    end
  end

  local m = modes_to_try[1] or modes_to_try[2] or 0
  local m8 = bit.band(m, 0xFF)
  local fallback = {
    [0x00] = {1.00, 1.00, 1.00, 1},
    [0x01] = {1.00, 0.65, 0.35, 1},
    [0x02] = {1.00, 1.00, 0.40, 1},
    [0x03] = {1.00, 0.55, 0.85, 1},
    [0x04] = {0.45, 0.80, 1.00, 1},
    [0x05] = {0.45, 1.00, 0.45, 1},
    [0x06] = {0.70, 0.90, 0.40, 1},
    [0x09] = {1.00, 1.00, 1.00, 1},
    [0x0D] = {0.45, 0.80, 1.00, 1},
    [0x0E] = {0.45, 0.80, 1.00, 1},
    [0x17] = {0.45, 1.00, 0.45, 1},
    [0x19] = {1.00, 0.55, 0.85, 1},
  }
  return norm_color(fallback[m] or fallback[m8] or {1,1,1,1})
end

local function detect_modes()
  local cm = AshitaCore and AshitaCore:GetChatManager()
  if not cm or not cm.GetTypeColor then return 0 end
  local added = 0
  for m = 0, 255 do
    local argb = cm:GetTypeColor(m)
    if argb and type(argb) == 'number' and argb ~= 0 then
      local key = tostring(bit.band(m, 0xFF))
      if not tradutor.user_palette[key] then
        local col = argb_to_rgba(argb)
        if col then
          tradutor.user_palette[key] = norm_color(col)
          added = added + 1
        end
      end
    end
  end
  if added > 0 then
    palette_dirty = true
  end
  return added
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
          end
        elseif section == 'Language' then
          if key == 'source' then tradutor.settings.source_lang = value
          elseif key == 'target' then tradutor.settings.target_lang = value
          elseif key == 'auto_detect' then tradutor.settings.auto_detect = (value:lower() == 'true' or value == '1')
          elseif key == 'show_lang_status' then tradutor.settings.show_lang_status = (value:lower() == 'true' or value == '1')
          end
        elseif section == 'Filters' then
          if tradutor.settings.chat_filters[key] ~= nil then
            tradutor.settings.chat_filters[key] = (value:lower() == 'true' or value == '1')
          end
        elseif section == 'Performance' then
          if key == 'copas_budget_ms' then
            tradutor.settings.copas_budget = (tonumber(value) or 1.0) / 1000
          elseif key == 'frame_interval' then
            local interval = tonumber(value)
            if interval == nil or interval < 1 or interval == 17 then
              interval = 1
            end
            tradutor.settings.copas_interval = math.max(1, interval)
          end
        elseif section == 'ChannelColors' then
          local r, g, b, a = value:match('([%d%.]+),%s*([%d%.]+),%s*([%d%.]+),%s*([%d%.]+)')
          if r and g and b and a then
            tradutor.user_palette[key] = {tonumber(r), tonumber(g), tonumber(b), tonumber(a)}
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
  
  f:write('[Language]\n')
  f:write(string.format('source = %s\n', tradutor.settings.source_lang))
  f:write(string.format('target = %s\n', tradutor.settings.target_lang))
  f:write(string.format('auto_detect = %s\n', tradutor.settings.auto_detect and 'true' or 'false'))
  f:write(string.format('show_lang_status = %s\n\n', tradutor.settings.show_lang_status and 'true' or 'false'))

  f:write('[Filters]\n')
  for _, def in ipairs(CHAT_FILTER_DEFS) do
    f:write(string.format('%s = %s\n', def.key, tradutor.settings.chat_filters[def.key] and 'true' or 'false'))
  end
  f:write('\n')
  
  f:write('[Performance]\n')
  f:write(string.format('copas_budget_ms = %.2f\n', tradutor.settings.copas_budget * 1000))
  f:write(string.format('frame_interval = %d\n\n', tradutor.settings.copas_interval))
  
  f:write('[ChannelColors]\n')
  f:write('# Format: mode_id = r, g, b, a (values from 0.0 to 1.0)\n')
  local modes = sorted_keys(tradutor.user_palette)
  for _, key in ipairs(modes) do
    local col = tradutor.user_palette[key]
    if col then
      f:write(string.format('%s = %.3f, %.3f, %.3f, %.3f\n', key, col[1], col[2], col[3], col[4] or 1.0))
    end
  end
  
  f:close()
  palette_dirty = false
end

local function draw_config_contents()
  if imgui.CollapsingHeader('Appearance', ImGuiTreeNodeFlags_DefaultOpen) then
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

    local budget_ms = {(tradutor.settings.copas_budget or COPAS_BUDGET) * 1000}
    imgui.PushItemWidth(110)
    if imgui.SliderFloat('Copas budget (ms)', budget_ms, 0.01, 5.0, '%.2f') then
      tradutor.settings.copas_budget = math.max(0.00001, budget_ms[1] / 1000)
      save_ini()
    end
    local interval = {tradutor.settings.copas_interval or 1}
    if imgui.SliderInt('Frame interval', interval, 1, 60) then
      tradutor.settings.copas_interval = math.max(1, interval[1])
      save_ini()
    end
    imgui.PopItemWidth()
  end

  if imgui.CollapsingHeader('Chat filters', ImGuiTreeNodeFlags_DefaultOpen) then
    if imgui.Button('All on', {90, 0}) then
      chat_filter_all(true)
      save_ini()
    end
    imgui.SameLine()
    if imgui.Button('All off', {90, 0}) then
      chat_filter_all(false)
      save_ini()
    end

    for _, def in ipairs(CHAT_FILTER_DEFS) do
      local enabled = {tradutor.settings.chat_filters[def.key] ~= false}
      if imgui.Checkbox(def.label, enabled) then
        tradutor.settings.chat_filters[def.key] = enabled[1]
        save_ini()
      end
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

  if imgui.CollapsingHeader('Channel colors') then
    imgui.Text('Manual per mode id')
    local modes = sorted_keys(tradutor.user_palette)
    for _, key in ipairs(modes) do
      local col = tradutor.user_palette[key]
      if col then
        local c = { col[1], col[2], col[3], col[4] or 1 }
        imgui.PushID(key)
        if imgui.ColorEdit4(string.format('Mode %s', key), c, ImGuiColorEditFlags_NoInputs) then
          tradutor.user_palette[key] = { c[1], c[2], c[3], c[4] }
          palette_dirty = true
        end
        imgui.PopID()
      end
    end
    imgui.PushItemWidth(80)
    imgui.InputInt('##addmode', tradutor.add_mode)
    imgui.PopItemWidth()
    imgui.SameLine()
    if imgui.Button('Add') and tradutor.add_mode[1] >= 0 then
      tradutor.user_palette[tostring(tradutor.add_mode[1])] = {1,1,1,1}
      palette_dirty = true
    end

    if palette_dirty then
      if imgui.Button('Save##pal') then
        save_ini()
      end
      imgui.SameLine()
      if imgui.Button('Reset##pal') then
        tradutor.user_palette = {}
        palette_dirty = false
        save_ini()
      end
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

local function extract_detected_language(body, data)
  -- Try to extract detected language from response
  -- Google Translate API returns detected language in data[3] or data[9]
  if type(data) == 'table' then
    if type(data[3]) == 'string' and #data[3] > 0 then
      return data[3]
    end
    if type(data[9]) == 'table' and type(data[9][1]) == 'table' and type(data[9][1][1]) == 'string' then
      return data[9][1][1]
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
  local name, body = msg:match('^%s*([%w%-_%\'%.]+)%s*[:>]%s*(.+)$')
  if name and body then return name, body end
  return nil, msg
end

local pump_queue

local function build_segments(text, base_color)
  local txt = text or ''
  return { { text = txt, color = base_color } }
end

local function render_segments(segments, fallback_color)
  if not segments or #segments == 0 then
    imgui.PushStyleColor(ImGuiCol_Text, fallback_color or {1,1,1,1})
    imgui.TextWrapped("")
    imgui.PopStyleColor()
    return
  end
  imgui.PushTextWrapPos()
  local first = true
  for _, seg in ipairs(segments) do
    if not first then imgui.SameLine(0, 0) end
    imgui.PushStyleColor(ImGuiCol_Text, seg.color or fallback_color or {1,1,1,1})
    imgui.Text(seg.text or "")
    imgui.PopStyleColor()
    first = false
  end
  imgui.PopTextWrapPos()
end

local function draw_message(m)
  imgui.BeginGroup()
    if m.name then
      local name_col = m.color or name_color(m.name)
      imgui.PushStyleColor(ImGuiCol_Text, name_col)
      imgui.Text(m.name .. ':')
      imgui.PopStyleColor()
      imgui.SameLine()
    end

    local segs = build_segments(m.text or '', m.color or {1,1,1,1})
    render_segments(segs, m.color or {1,1,1,1})
    
    -- Tooltip with original text and click to copy
    if imgui.IsItemHovered() then
      if m.orig and m.orig ~= m.text then
        imgui.SetTooltip('Original: ' .. m.orig .. '\n(Click to copy)')
      end
      
      if imgui.IsMouseClicked(0) then
        imgui.SetClipboardText(m.text or '')
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

local function translate_async(content, color, name)
  local key = content or ''

  -- Mark as translating and update language status immediately
  tradutor.is_translating = true
  if tradutor.settings.auto_detect then
    -- Will be updated when translation completes
    tradutor.last_detected_lang = nil
  else
    tradutor.last_detected_lang = tradutor.settings.source_lang:upper()
  end

  -- Check cache
  local cached = tradutor.cache[key]
  if cached and cached ~= key then
    append_message({
      text    = cached,
      color   = color,
      name    = name,
      orig    = key,
    })
    return
  elseif cached == key then
    tradutor.cache[key] = nil
  end

  if #tradutor.queue < MAX_QUEUE then
    table.insert(tradutor.queue, {
      orig   = key,
      send   = content,
      color  = color,
      name   = name,
    })
    pump_queue()
  else
    tradutor.is_translating = false
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
      local detected_lang = nil

      local body, code = http_get('translate.googleapis.com', path)
      if code == 200 and type(body) == 'string' then
        local ok, data = pcall(json.decode, body)
        local parsed = ok and extract_translation(body, data) or extract_translation(body, nil)
        if parsed and #parsed > 0 then
          tr = parsed
          -- Extract detected language if auto-detect is enabled
          if tradutor.settings.auto_detect and ok then
            detected_lang = extract_detected_language(body, data)
          end
        end
      end

      if tr ~= nil and tr ~= job.orig then
        tradutor.cache[job.orig] = tr
        append_message({
          text = tr,
          color = job.color,
          name = job.name,
          orig = job.orig,
        })
      end
      
      -- Update last detected language
      if detected_lang then
        tradutor.last_detected_lang = detected_lang:upper()
      elseif not tradutor.settings.auto_detect then
        tradutor.last_detected_lang = tradutor.settings.source_lang:upper()
      end

      -- Mark translation as complete and record time
      tradutor.last_translation_time = socket.gettime and socket.gettime() or os.clock()
      if tradutor.inflight <= 1 and #tradutor.queue == 0 then
        tradutor.is_translating = false
        -- Save cache when all translations are done
        save_cache()
      end

      tradutor.inflight = tradutor.inflight - 1
      pump_queue()
    end)
  end
end

ashita.events.register('command', 'lingoxi_command_cb', function(e)
  local args = e.command:args()
  if (#args == 0 or args[1]:lower() ~= '/lingoxi') then
    return
  end

  e.blocked = true

  if (#args >= 2 and args[2]:lower() == 'config') then
    tradutor.settings_open[1] = true
    return
  end

  print(chat.header(addon.name):append(chat.message('Use /lingoxi config')))
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

  local raw     = clean_str(e.message or '')
  local mod     = clean_str(e.message_modified or '')
  local is_auto = (raw ~= mod)
  local display = is_auto and mod or raw

  local name, body = split_name(display)
  if not name then
    name, body = split_name(raw)
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

  translate_async(content, color, name)
end)

ashita.events.register('d3d_present', 'present_cb', function()
  tradutor.tick = tradutor.tick + 1
  local interval = math.max(1, tradutor.settings.copas_interval or 1)
  if tradutor.tick % interval == 0 then
    copas.step(0)
  end

  imgui.SetNextWindowBgAlpha(tradutor.settings.window_alpha)
  tradutor.settings.window_color[4] = tradutor.settings.window_alpha
  imgui.PushStyleColor(ImGuiCol_WindowBg, tradutor.settings.window_color)
  imgui.PushStyleColor(ImGuiCol_Button,        {0, 0, 0, 0.30})
  imgui.PushStyleColor(ImGuiCol_ButtonHovered, {1, 1, 1, 0.15})
  imgui.PushStyleColor(ImGuiCol_ButtonActive,  {1, 1, 1, 0.30})
  imgui.PushStyleColor(ImGuiCol_Border,        {0, 0, 0, 0})
  imgui.PushStyleColor(ImGuiCol_FrameBg,              {0.18, 0.18, 0.18, 0.82})
  imgui.PushStyleColor(ImGuiCol_FrameBgHovered,       {0.28, 0.28, 0.28, 0.88})
  imgui.PushStyleColor(ImGuiCol_FrameBgActive,        {0.36, 0.36, 0.36, 0.95})
  imgui.PushStyleColor(ImGuiCol_ScrollbarBg,          {0.05, 0.05, 0.05, 0.35})
  imgui.PushStyleColor(ImGuiCol_ScrollbarGrab,        {0.42, 0.42, 0.42, 0.72})
  imgui.PushStyleColor(ImGuiCol_ScrollbarGrabHovered, {0.56, 0.56, 0.56, 0.86})
  imgui.PushStyleColor(ImGuiCol_ScrollbarGrabActive,  {0.70, 0.70, 0.70, 0.96})
  imgui.PushStyleColor(ImGuiCol_CheckMark,            {0.82, 0.82, 0.82, 1.00})
  imgui.PushStyleColor(ImGuiCol_SliderGrab,           {0.58, 0.58, 0.58, 0.92})
  imgui.PushStyleColor(ImGuiCol_SliderGrabActive,     {0.78, 0.78, 0.78, 1.00})
  imgui.PushStyleColor(ImGuiCol_Header,               {0.24, 0.24, 0.24, 0.82})
  imgui.PushStyleColor(ImGuiCol_HeaderHovered,        {0.34, 0.34, 0.34, 0.90})
  imgui.PushStyleColor(ImGuiCol_HeaderActive,         {0.44, 0.44, 0.44, 0.96})
  imgui.PushStyleColor(ImGuiCol_ResizeGrip,           {0.50, 0.50, 0.50, 0.55})
  imgui.PushStyleColor(ImGuiCol_ResizeGripHovered,    {0.68, 0.68, 0.68, 0.78})
  imgui.PushStyleColor(ImGuiCol_ResizeGripActive,     {0.86, 0.86, 0.86, 0.95})
  imgui.PushStyleColor(ImGuiCol_TextSelectedBg,       {0.55, 0.55, 0.55, 0.45})
  
  -- Set window position and size from settings
  imgui.SetNextWindowPos(tradutor.settings.window_pos, ImGuiCond_FirstUseEver)
  imgui.SetNextWindowSize(tradutor.settings.window_size, ImGuiCond_FirstUseEver)
  
  local window_flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoSavedSettings)
  if imgui.Begin('LingoXI', true, window_flags) then
    -- Save current window position and size
    local pos = imgui.GetWindowPos()
    local size = imgui.GetWindowSize()
    tradutor.settings.window_pos = {vec2x(pos), vec2y(pos)}
    tradutor.settings.window_size = {vec2x(size), vec2y(size)}
    -- Toolbar with language status (left) and settings icon (right)
    local now = socket.gettime and socket.gettime() or os.clock()
    local show_status = false and tradutor.settings.show_lang_status and 
                       (tradutor.is_translating or (now - tradutor.last_translation_time) < 3)
    
    if show_status and tradutor.last_detected_lang then
      local lang_names = {
        EN = 'English',
        PT = 'Portuguese',
        ES = 'Spanish',
        FR = 'French',
        DE = 'German',
        IT = 'Italian',
        JA = 'Japanese',
        ZH = 'Chinese',
        KO = 'Korean',
        RU = 'Russian',
        AR = 'Arabic',
        NL = 'Dutch',
        PL = 'Polish',
        TR = 'Turkish',
        SV = 'Swedish',
        DA = 'Danish',
        NO = 'Norwegian',
        FI = 'Finnish',
      }
      
      local src_code = tradutor.last_detected_lang
      local tgt_code = tradutor.settings.target_lang:upper()
      local src_name = lang_names[src_code] or src_code
      local tgt_name = lang_names[tgt_code] or tgt_code
      
      local lang_text = string.format('%s → %s', src_name, tgt_name)
      imgui.TextColored({0.7, 0.7, 0.7, 1}, lang_text)
      imgui.SameLine()
    end
    
    if false then
    local total_w = 24
    local cur_x = imgui.GetCursorPosX()
    local avail = imgui.GetContentRegionAvail()
    imgui.SetCursorPosX(cur_x + math.max(0, vec2x(avail) - total_w))
    if draw_settings_tool_button(total_w) then
      tradutor.settings_open[1] = not tradutor.settings_open[1]
    end
    imgui.Spacing()
    end

    -- Calculate widths
    local sett_w = 0
    local content_avail = imgui.GetContentRegionAvail()
    local msg_w = math.max(100, vec2x(content_avail))

    -- Messages panel
    tradutor.settings.text_bg_color[4] = tradutor.settings.text_bg_alpha
    imgui.PushStyleColor(ImGuiCol_ChildBg, tradutor.settings.text_bg_color)
    imgui.BeginChild('scroll', {msg_w, 0}, false)
      local scroll_y = imgui.GetScrollY()
      local scroll_max = imgui.GetScrollMaxY()
      tradutor.follow_bottom = scroll_max <= 0 or scroll_y >= (scroll_max - SCROLL_FOLLOW_THRESHOLD)
      if false and #tradutor.messages == 0 then
        imgui.TextColored({1,0,0,1}, 'Waiting for translations…')
      else
        for _, m in ipairs(tradutor.messages) do
          draw_message(m)
        end

        if tradutor.scroll_to_bottom then
          imgui.SetScrollHereY(1.0)
          tradutor.scroll_to_bottom = false
          tradutor.follow_bottom = true
        end
      end
    imgui.EndChild()
    imgui.PopStyleColor()

    -- Settings panel (right)
    if false and tradutor.settings_open[1] then
      imgui.SameLine()
      imgui.PushStyleColor(ImGuiCol_ChildBg, FANCY_PANEL_COLOR)
      imgui.BeginChild('config_panel', {sett_w, 0}, false)
        if imgui.CollapsingHeader('Appearance', ImGuiTreeNodeFlags_DefaultOpen) then
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
          
          local budget_ms = {(tradutor.settings.copas_budget or COPAS_BUDGET) * 1000}
          imgui.PushItemWidth(110)
          if imgui.SliderFloat('Copas budget (ms)', budget_ms, 0.01, 5.0, '%.2f') then
            tradutor.settings.copas_budget = math.max(0.00001, budget_ms[1] / 1000)
            save_ini()
          end
          local interval = {tradutor.settings.copas_interval or 1}
          if imgui.SliderInt('Frame interval', interval, 1, 60) then
            tradutor.settings.copas_interval = math.max(1, interval[1])
            save_ini()
          end
          imgui.PopItemWidth()
        end
        
        if imgui.CollapsingHeader('Cache', ImGuiTreeNodeFlags_DefaultOpen) then
          local cache_count = 0
          for _ in pairs(tradutor.cache) do cache_count = cache_count + 1 end
          imgui.Text(string.format('Cached: %d', cache_count))
          
          if imgui.Button('Clear Cache', {-1, 0}) then
            clear_cache()
          end
        end
        
        if imgui.CollapsingHeader('Channel colors') then
          imgui.Text('Manual per mode id')
          local modes = sorted_keys(tradutor.user_palette)
          for _, key in ipairs(modes) do
            local col = tradutor.user_palette[key]
            if col then
              local c = { col[1], col[2], col[3], col[4] or 1 }
              imgui.PushID(key)
              if imgui.ColorEdit4(string.format('Mode %s', key), c, ImGuiColorEditFlags_NoInputs) then
                tradutor.user_palette[key] = { c[1], c[2], c[3], c[4] }
                palette_dirty = true
              end
              imgui.PopID()
            end
          end
          imgui.PushItemWidth(80)
          imgui.InputInt('##addmode', tradutor.add_mode)
          imgui.PopItemWidth()
          imgui.SameLine()
          if imgui.Button('Add') and tradutor.add_mode[1] >= 0 then
            tradutor.user_palette[tostring(tradutor.add_mode[1])] = {1,1,1,1}
            palette_dirty = true
          end

          if palette_dirty then
            if imgui.Button('Save##pal') then
              save_ini()
            end
            imgui.SameLine()
            if imgui.Button('Reset##pal') then
              tradutor.user_palette = {}
              palette_dirty = false
              save_ini()
            end
          end
        end
      imgui.EndChild()
      imgui.PopStyleColor()
    end
  end

  imgui.End()

  if tradutor.settings_open[1] then
    imgui.SetNextWindowSize({300, 420}, ImGuiCond_FirstUseEver)
    local config_flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoSavedSettings)
    if imgui.Begin('LingoXI Config', true, config_flags) then
      imgui.Text('Config')
      imgui.SameLine()
      local close_w = 24
      local cur_x = imgui.GetCursorPosX()
      local avail = imgui.GetContentRegionAvail()
      imgui.SetCursorPosX(cur_x + math.max(0, vec2x(avail) - close_w))
      if imgui.Button('X##close_config', {close_w, 0}) then
        tradutor.settings_open[1] = false
      end
      imgui.Separator()
      draw_config_contents()
    end
    imgui.End()
  end

  imgui.PopStyleColor(22)
end)

ashita.events.register('load', 'load_cb', function()
  load_ini()
  load_cache()
end)

ashita.events.register('unload', 'unload_cb', function()
  if palette_dirty then
    save_ini()
  else
    save_ini()
  end
  save_cache()
end)
