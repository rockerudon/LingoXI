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
-- Drops only the near-instant duplicate the game sometimes delivers for the
-- same line (e.g. routed to multiple chat windows). Kept small so the user can
-- intentionally repeat the same message without it being swallowed.
local DEDUPE_WINDOW   = 0.3
local SCROLL_FOLLOW_THRESHOLD = 32
local FANCY_WINDOW_COLOR = {0.0, 0.0, 0.0, 0.50}
local FANCY_LOG_COLOR    = {0.0, 0.0, 0.0, 0.0}
local FANCY_PANEL_COLOR  = {0.02, 0.02, 0.02, 0.72}

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
  { key = 'other',     label = 'Other',           color = {1.00, 1.00, 1.00, 1}, desc = 'Anything not covered by the categories above.', fallback = true },
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
    -- Per-category render color override. Empty means "use the category's
    -- default color from CHAT_FILTER_DEFS"; the user can change any of them in
    -- the config window. Keyed by category key (e.g. 'linkshell').
    chat_colors    = {},
    window_pos     = {100, 100},
    window_size    = {700, 400},
  },
  settings_open = { false },
  history_open  = { false },
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
  local key = chat_filter_key(e.mode_modified or e.mode)
  return category_color(key)
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

  if imgui.CollapsingHeader('Chat categories', ImGuiTreeNodeFlags_DefaultOpen) then
    imgui.TextDisabled('Toggle which message types are translated, and pick each one\'s color.')
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
    local text = m.text or ''
    if m.name then
      text = m.name .. ': ' .. text
    end

    local segs = build_segments(text, m.color or {1,1,1,1})
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

  -- Show a cached result if we have one. The cache may hold a value equal to
  -- the original (text that was already in the target language); we still
  -- display it so nothing is dropped.
  local cached = tradutor.cache[key]
  if cached ~= nil then
    append_message({
      text  = cached,
      color = color,
      name  = name,
      orig  = key,
    })
    return
  end

  if #tradutor.queue < MAX_QUEUE then
    table.insert(tradutor.queue, {
      orig  = key,
      send  = content,
      color = color,
      name  = name,
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

      -- Use the translation when we got one; otherwise (no result, or text
      -- already in the target language) fall back to the original so messages
      -- are never silently dropped. Cache the displayed text either way to
      -- avoid re-requesting the same line.
      local display = (tr ~= nil) and tr or job.orig
      tradutor.cache[job.orig] = display
      append_message({
        text  = display,
        color = job.color,
        name  = job.name,
        orig  = job.orig,
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

  if tradutor.settings_open[1] then
    imgui.SetNextWindowSize({300, 420}, ImGuiCond_FirstUseEver)
    local config_flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoSavedSettings)
    if imgui.Begin('LingoXI Config', true, config_flags) then
      imgui.Text('Config')
      imgui.SameLine()
      local close_w = 24
      local cur_x = imgui.GetCursorPosX()
      local avail_w = imgui.GetContentRegionAvail()
      imgui.SetCursorPosX(cur_x + math.max(0, avail_w - close_w))
      if imgui.Button('X##close_config', {close_w, 0}) then
        tradutor.settings_open[1] = false
      end
      imgui.Separator()
      draw_config_contents()
    end
    imgui.End()
  end

  imgui.PopStyleColor(THEME_PUSH_COUNT)
end)

ashita.events.register('load', 'load_cb', function()
  load_ini()
  load_cache()
end)

ashita.events.register('unload', 'unload_cb', function()
  save_ini()
  save_cache()
end)
