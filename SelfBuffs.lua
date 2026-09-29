-- SelfBuffs: player buffs/debuffs for WoW: Forever.
-- Uses Blizzard's CustomAuraContainerTemplate (same approach as Forever Unit
-- Frames, MIT): the client reads auras and fills our icons from secure code,
-- so it keeps updating in combat. This addon never reads an aura itself.
local ADDON = ...
local TEMPLATE = "CustomAuraContainerTemplate"

local defaults = {
  hideBlizz = true,
  scale = 1,
  size = 30,         -- icon size
  spacing = 5,       -- between icons in a row
  rowSpacing = 5,    -- between rows
  perRow = 8,
  growX = "LEFT",    -- LEFT or RIGHT
  growY = "DOWN",    -- DOWN or UP
  sort = "default",  -- default | time | name | added
  reverse = false,
  cdText = true,     -- countdown numbers on the swipe
  cdTextSize = 0,    -- 0 = auto (45% of icon size)
  cdHideAbove = 0,   -- seconds; hide the numbers while more than this remains (0 = never)
  cdStyler = "selfbuffs", -- who styles the numbers when tullaCTC is loaded: "selfbuffs" | "tullactc"
  buffs   = { "TOPRIGHT", "UIParent", "TOPRIGHT", -205, -13 },
  debuffs = { "TOPRIGHT", "UIParent", "TOPRIGHT", -205, -160 },
}

local SORTS = { default = "Default", time = "ExpirationOnly", name = "NameOnly", added = "AuraInstanceIDOnly" }
local SORT_ORDER = { "default", "time", "name", "added" }
local SORT_LABEL = { default = "Blizzard default", time = "Time left", name = "Name", added = "Order gained" }

local GROUPS = {
  { key = "buffs",   filter = "HELPFUL", max = 32, label = "SelfBuffs: Buffs",   debuff = false },
  { key = "debuffs", filter = "HARMFUL", max = 16, label = "SelfBuffs: Debuffs", debuff = true  },
}

local DB
local function Msg(t) print("|cff33ff99SelfBuffs|r: " .. t) end

---------------------------------------------------------------------------
-- Deferral: containers and their buttons are changed out of combat only
---------------------------------------------------------------------------
local pending = {}
local function OutOfCombat(key, fn)
  if InCombatLockdown() then
    pending[key] = fn
    return false
  end
  fn()
  return true
end

---------------------------------------------------------------------------
-- Settings -> container
---------------------------------------------------------------------------
local function SortArgs()
  local method = AuraContainerSortMethod and AuraContainerSortMethod[SORTS[DB.sort] or "Default"]
  local dir = AuraContainerSortDirection and
    (DB.reverse and AuraContainerSortDirection.Reverse or AuraContainerSortDirection.Normal)
  return method, dir
end

local function Corner()
  local v = DB.growY == "UP" and "BOTTOM" or "TOP"
  local h = DB.growX == "RIGHT" and "LEFT" or "RIGHT"
  return v .. h
end

local function Layout()
  return { elementWidth = DB.size, elementHeight = DB.size,
    elementSpacing = DB.spacing, lineSpacing = DB.rowSpacing }
end

local function RowLength()
  return DB.perRow * DB.size + (DB.perRow - 1) * DB.spacing
end

---------------------------------------------------------------------------
-- Buttons: the container makes them; regions are added in initializeFrame.
-- Never SetScript on these; resize only out of combat, guarded.
---------------------------------------------------------------------------
local buttons = {}   -- every container button made so far
local staleButtons = false

local function HasTullaCTC()
  return type(tullaCTC) == "table" and type(tullaCTC.RegisterRule) == "function"
end

-- True when SelfBuffs (not tullaCTC) styles the countdown numbers.
local function WeStyle()
  return not HasTullaCTC() or DB.cdStyler ~= "tullactc"
end

-- With tullaCTC loaded, point our rule at its built-in "none" theme when we
-- style the text ourselves, so its hooks leave our cooldowns alone.
local function SyncTullaRule()
  if not HasTullaCTC() then return end
  pcall(function()
    local rule = tullaCTC.db.profile.rules.selfbuffs
    local want = WeStyle() and "none" or "default"
    if WeStyle() or rule.theme == "none" then rule.theme = want end
    if tullaCTC.Refresh then tullaCTC:Refresh() end
  end)
end

-- Countdown format, applied by the client (works in combat):
-- seconds (rounded up) under a minute, then minutes, then hours;
-- an empty format hides the text.
local formatter
local function BuildFormatter()
  formatter = nil
  if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter) then return end
  local R = Enum.NumericRuleFormatRounding
  local up = R and R.Up
  local points = {
    { threshold = 0,    format = "%d",  rounding = up, step = 1 },
    { threshold = 60,   format = "%dm", components = { { div = 60, rounding = up, step = 1 } } },
    { threshold = 3600, format = "%dh", components = { { div = 3600, rounding = up, step = 1 } } },
  }
  local cut = DB.cdHideAbove or 0
  if cut > 0 then
    for i = #points, 1, -1 do
      if points[i].threshold >= cut then table.remove(points, i) end
    end
    points[#points + 1] = { threshold = cut, format = "", rounding = up, step = 1 }
  end
  local ok, f = pcall(C_StringUtil.CreateNumericRuleFormatter)
  if ok and f and pcall(f.SetBreakpoints, f, points) then formatter = f end
end

local function CountdownSize()
  if (DB.cdTextSize or 0) > 0 then return DB.cdTextSize end
  return math.max(8, math.floor(DB.size * 0.45 + 0.5))
end

local function SizeButton(b)
  b:SetSize(DB.size, DB.size)
  if b.sbBorder then b.sbBorder:SetSize(DB.size + 3, DB.size + 2) end
  local cd = b.sbCooldown
  if cd then
    cd:SetHideCountdownNumbers(not DB.cdText)
    if WeStyle() then
      local fs = cd.GetCountdownFontString and cd:GetCountdownFontString()
      if fs then fs:SetFont(STANDARD_TEXT_FONT, CountdownSize(), "OUTLINE") end
      if formatter and cd.SetCountdownFormatter then cd:SetCountdownFormatter(formatter) end
    end
  end
end

local function InitButton(button, debuff)
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints()

  local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
  cd:SetAllPoints()
  cd:SetReverse(true)
  cd:SetDrawEdge(false)
  cd.selfBuffs = true   -- tullaCTC rule matches on this
  button.sbCooldown = cd

  local cover = CreateFrame("Frame", nil, button)
  cover:SetAllPoints()
  cover:SetFrameLevel(cd:GetFrameLevel() + 1)
  local count = cover:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  count:SetPoint("BOTTOMRIGHT", -2, 2)

  if debuff then
    local border = cover:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
    border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
    border:SetPoint("CENTER")
    button.sbBorder = border
  end
  SizeButton(button)

  button:SetIcon(icon)
  button:SetDurationCooldown(cd)
  button:SetApplicationCount(count)
  if button.sbBorder then
    pcall(button.AddDispelTypeTexture, button, button.sbBorder, {
      style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
      showWithoutDispelType = true,
    })
  end
  pcall(button.SetTooltipAnchorPoint, button, "ANCHOR_BOTTOMLEFT")
  buttons[#buttons + 1] = button
end

-- Refused while auras are secret; retried after combat.
local function RestyleButtons()
  staleButtons = false
  for _, b in ipairs(buttons) do
    if not pcall(SizeButton, b) then staleButtons = true end
  end
end

---------------------------------------------------------------------------
-- Movers + containers
---------------------------------------------------------------------------
local movers, containers = {}, {}

local function SizeMovers()
  for _, m in pairs(movers) do
    m:SetSize(RowLength(), DB.size)
    m:SetScale(DB.scale)
  end
end

local function CreateMover(g)
  local m = CreateFrame("Frame", "SelfBuffs_" .. g.key, UIParent)
  m:SetMovable(true)
  m:SetClampedToScreen(true)
  m:RegisterForDrag("LeftButton")
  m:SetScript("OnDragStart", m.StartMoving)
  m:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    DB[g.key] = { p, "UIParent", rp, x, y }
  end)
  local pt = DB[g.key]
  m:SetPoint(pt[1], UIParent, pt[3], pt[4], pt[5])

  m.bg = m:CreateTexture(nil, "BACKGROUND")
  m.bg:SetAllPoints()
  m.bg:SetColorTexture(0, 1, 0, 0.35)
  m.bg:Hide()
  m.text = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  m.text:SetPoint("BOTTOM", m, "TOP", 0, 2)
  m.text:SetText(g.label)
  m.text:Hide()
  movers[g.key] = m
end

local function Configure()
  BuildFormatter()
  SizeMovers()
  local corner = Corner()
  local method, dir = SortArgs()
  local hDir = DB.growX == "RIGHT" and AnchorUtil.FlowDirection.Right or AnchorUtil.FlowDirection.Left
  local vDir = DB.growY == "UP" and AnchorUtil.FlowDirection.Up or AnchorUtil.FlowDirection.Down

  for _, g in ipairs(GROUPS) do
    local c, m = containers[g.key], movers[g.key]
    if c then
      c:SetFlowLayoutAxis(AnchorUtil.FlowLayoutAxis.Horizontal)
      c:SetFlowLayoutAnchorPoint(corner)
      c:SetFlowLayoutGrowthDirection(hDir, vDir)
      c:SetFlowLayoutMaximumLineSize(RowLength() + 0.5)
      c:SetAuraGroupLayout("all", Layout())
      if method then pcall(c.SetAuraGroupSortMethod, c, "all", method, dir) end
      c:ClearAllPoints()
      c:SetPoint(corner, m, corner)
    end
  end
  RestyleButtons()
end

local function Build()
  local ok, err = pcall(function()
    for _, g in ipairs(GROUPS) do
      local c = CreateFrame("AuraContainer", nil, movers[g.key], TEMPLATE)
      containers[g.key] = c
      pcall(c.SetEditModePreviewEnabled, c, false)
      local method, dir = SortArgs()
      c:AddAuraGroup("all", g.filter, {
        maxFrameCount = g.max,
        layout = Layout(),
        sortMethod = method,
        sortDirection = dir,
        initializeFrame = function(button) InitButton(button, g.debuff) end,
      })
      c:SetUnit("player")
      c:Show()
    end
  end)
  if not ok then
    Msg("this client refused to create an aura container: " .. tostring(err))
    for _, c in pairs(containers) do c:Hide() end
    wipe(containers)
    return
  end
  Configure()
end

-- Any setting change goes through here.
local function Apply()
  if not OutOfCombat("config", Configure) then Msg("changes apply after combat.") end
end

---------------------------------------------------------------------------
-- Blizzard frames / movers
---------------------------------------------------------------------------
local hider = CreateFrame("Frame")
hider:Hide()
local function SetBlizzardHidden(hide)
  for _, f in ipairs({ BuffFrame, DebuffFrame }) do
    if f then f:SetParent(hide and hider or UIParent) end
  end
end

local unlocked = false
local function SetUnlocked(on)
  if on and InCombatLockdown() then Msg("not in combat.") return end
  unlocked = on
  for _, m in pairs(movers) do
    m:EnableMouse(on)
    m.bg:SetShown(on)
    m.text:SetShown(on)
  end
end

local function ResetPositions()
  if InCombatLockdown() then Msg("not in combat.") return end
  for _, g in ipairs(GROUPS) do
    local pt = defaults[g.key]
    DB[g.key] = { unpack(pt) }
    movers[g.key]:ClearAllPoints()
    movers[g.key]:SetPoint(pt[1], UIParent, pt[3], pt[4], pt[5])
  end
end

---------------------------------------------------------------------------
-- Options window (plain widgets only, so it doesn't depend on
-- templates that may be missing on this client)
---------------------------------------------------------------------------
local Options
local controls = {}

local function MakeSlider(parent, label, key, minV, maxV, step, fmt, y)
  local s = CreateFrame("Slider", nil, parent)
  s:SetOrientation("HORIZONTAL")
  s:SetSize(200, 14)
  s:SetPoint("TOPLEFT", 20, y)
  s:SetMinMaxValues(minV, maxV)
  s:SetValueStep(step)
  s:SetObeyStepOnDrag(true)
  s:EnableMouseWheel(true)

  local track = s:CreateTexture(nil, "BACKGROUND")
  track:SetPoint("LEFT")
  track:SetPoint("RIGHT")
  track:SetHeight(4)
  track:SetColorTexture(1, 1, 1, 0.25)
  local thumb = s:CreateTexture(nil, "OVERLAY")
  thumb:SetSize(10, 16)
  thumb:SetColorTexture(1, 0.82, 0, 1)
  s:SetThumbTexture(thumb)

  local title = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 3)
  title:SetText(label)
  local value = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  value:SetPoint("LEFT", s, "RIGHT", 10, 0)

  s:SetScript("OnValueChanged", function(self, v)
    v = math.floor(v / step + 0.5) * step
    value:SetText(type(fmt) == "function" and fmt(v) or fmt:format(v))
    if self.syncing or DB[key] == v then return end
    DB[key] = v
    Apply()
  end)
  s:SetScript("OnMouseWheel", function(self, d) self:SetValue(self:GetValue() + d * step) end)
  s.Sync = function(self)
    self.syncing = true
    self:SetValue(DB[key])
    value:SetText(type(fmt) == "function" and fmt(DB[key]) or fmt:format(DB[key]))
    self.syncing = false
  end
  controls[#controls + 1] = s
  return s
end

local function MakeButton(parent, width, x, y, onClick, textFn)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width, 22)
  b:SetPoint("TOPLEFT", x, y)
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.2, 0.2, 0.2, 0.9)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.1)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("CENTER")
  b:SetScript("OnClick", function(self) onClick(); self:Sync() end)
  b.Sync = function(self) self.text:SetText(textFn()) end
  controls[#controls + 1] = b
  return b
end

local function MakeCheck(parent, label, x, y, get, set)
  local b = CreateFrame("CheckButton", nil, parent)
  b:SetSize(18, 18)
  b:SetPoint("TOPLEFT", x, y)
  local box = b:CreateTexture(nil, "BACKGROUND")
  box:SetAllPoints()
  box:SetColorTexture(0.2, 0.2, 0.2, 0.9)
  local tick = b:CreateTexture(nil, "ARTWORK")
  tick:SetPoint("TOPLEFT", 4, -4)
  tick:SetPoint("BOTTOMRIGHT", -4, 4)
  tick:SetColorTexture(1, 0.82, 0, 1)
  b:SetCheckedTexture(tick)
  local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  t:SetPoint("LEFT", b, "RIGHT", 6, 0)
  t:SetText(label)
  b:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
  b.Sync = function(self) self:SetChecked(get()) end
  controls[#controls + 1] = b
  return b
end

local function Label(parent, text, x, y)
  local t = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  t:SetPoint("TOPLEFT", x, y)
  t:SetText(text)
end

local function SyncOptions()
  for _, c in ipairs(controls) do c:Sync() end
end

local function CreateOptions()
  local f = CreateFrame("Frame", "SelfBuffsOptions", UIParent)
  f:SetSize(300, 590)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:Hide()
  tinsert(UISpecialFrames, "SelfBuffsOptions") -- Esc closes it

  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.05, 0.05, 0.92)
  local header = f:CreateTexture(nil, "BORDER")
  header:SetPoint("TOPLEFT")
  header:SetPoint("TOPRIGHT")
  header:SetHeight(26)
  header:SetColorTexture(0.15, 0.15, 0.15, 1)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 10, -7)
  title:SetText("SelfBuffs")

  local close = CreateFrame("Button", nil, f)
  close:SetSize(22, 22)
  close:SetPoint("TOPRIGHT", -2, -2)
  close.text = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  close.text:SetPoint("CENTER")
  close.text:SetText("x")
  close:SetScript("OnClick", function() f:Hide() end)
  f:SetScript("OnHide", function() if unlocked then SetUnlocked(false) end end)

  local y = -50
  MakeSlider(f, "Icon size", "size", 16, 64, 1, "%d", y);            y = y - 45
  MakeSlider(f, "Icon spacing", "spacing", 0, 20, 1, "%d", y);       y = y - 45
  MakeSlider(f, "Row spacing", "rowSpacing", 0, 30, 1, "%d", y);     y = y - 45
  MakeSlider(f, "Icons per row", "perRow", 1, 20, 1, "%d", y);       y = y - 45
  MakeSlider(f, "Scale", "scale", 0.5, 2, 0.05, "%.2f", y);          y = y - 35

  Label(f, "Grow", 20, y)
  MakeButton(f, 80, 110, y + 4, function()
    DB.growX = DB.growX == "LEFT" and "RIGHT" or "LEFT"; Apply()
  end, function() return DB.growX == "LEFT" and "Left" or "Right" end)
  MakeButton(f, 80, 195, y + 4, function()
    DB.growY = DB.growY == "DOWN" and "UP" or "DOWN"; Apply()
  end, function() return DB.growY == "DOWN" and "Rows down" or "Rows up" end)
  y = y - 30

  Label(f, "Sort", 20, y)
  MakeButton(f, 165, 110, y + 4, function()
    local i = 1
    for n, k in ipairs(SORT_ORDER) do if k == DB.sort then i = n end end
    DB.sort = SORT_ORDER[i % #SORT_ORDER + 1]; Apply()
  end, function() return SORT_LABEL[DB.sort] end)
  y = y - 30

  MakeCheck(f, "Reverse sort", 20, y, function() return DB.reverse end,
    function(v) DB.reverse = v; Apply() end)
  y = y - 26
  MakeCheck(f, "Cooldown text", 20, y, function() return DB.cdText end,
    function(v) DB.cdText = v; Apply() end)
  if HasTullaCTC() then
    MakeCheck(f, "Styled by tullaCTC", 150, y, function() return DB.cdStyler == "tullactc" end,
      function(v) DB.cdStyler = v and "tullactc" or "selfbuffs"; SyncTullaRule(); Apply(); SyncOptions() end)
  end
  y = y - 40
  local sizeSlider = MakeSlider(f, "Cooldown text size", "cdTextSize", 0, 32, 1,
    function(v) return v == 0 and "Auto" or tostring(v) end, y)
  y = y - 45
  local hideSlider = MakeSlider(f, "Hide text above", "cdHideAbove", 0, 600, 5, function(v)
    if v == 0 then return "Never" end
    if v >= 60 and v % 60 == 0 then return (v / 60) .. "m" end
    return v .. "s"
  end, y)
  y = y - 30
  -- greyed out while tullaCTC styles the text
  for _, sl in ipairs({ sizeSlider, hideSlider }) do
    local base = sl.Sync
    sl.Sync = function(self)
      base(self)
      local on = WeStyle()
      self:EnableMouse(on)
      self:EnableMouseWheel(on)
      self:SetAlpha(on and 1 or 0.4)
    end
  end
  MakeCheck(f, "Hide Blizzard buff frames", 20, y, function() return DB.hideBlizz end, function(v)
    DB.hideBlizz = v
    if not OutOfCombat("blizz", function() SetBlizzardHidden(DB.hideBlizz) end) then
      Msg("changes apply after combat.")
    end
  end)
  y = y - 36

  MakeButton(f, 125, 20, y, function() SetUnlocked(not unlocked) end,
    function() return unlocked and "Lock frames" or "Unlock frames" end)
  MakeButton(f, 125, 155, y, function() ResetPositions() end, function() return "Reset position" end)
  y = y - 30
  MakeButton(f, 260, 20, y, function()
    for _, k in ipairs({ "size", "spacing", "rowSpacing", "perRow", "scale", "growX", "growY", "sort", "reverse", "cdText", "cdTextSize", "cdHideAbove" }) do
      DB[k] = defaults[k]
    end
    Apply()
    SyncOptions()
  end, function() return "Reset all settings" end)

  Options = f
end

local function ToggleOptions()
  if not Options then CreateOptions() end
  if Options:IsShown() then Options:Hide() else SyncOptions(); Options:Show() end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    SelfBuffsDB = SelfBuffsDB or {}
    DB = SelfBuffsDB
    for k, v in pairs(defaults) do
      if DB[k] == nil then DB[k] = type(v) == "table" and { unpack(v) } or v end
    end
    if not SORTS[DB.sort] then DB.sort = defaults.sort end
    if HasTullaCTC() then
      pcall(tullaCTC.RegisterRule, tullaCTC, {
        id = "selfbuffs",
        displayName = "SelfBuffs",
        priority = 50,
        enabled = true,
        match = function(cooldown) return cooldown.selfBuffs == true end,
      })
      SyncTullaRule()
    end
    for _, g in ipairs(GROUPS) do CreateMover(g) end
    SizeMovers()
    OutOfCombat("build", Build)
    if DB.hideBlizz then OutOfCombat("blizz", function() SetBlizzardHidden(true) end) end
  elseif event == "PLAYER_REGEN_DISABLED" then
    if unlocked then SetUnlocked(false) end
    if Options and Options:IsShown() then SyncOptions() end
  elseif event == "PLAYER_REGEN_ENABLED" then
    local run = pending
    pending = {}
    if run.build then run.build() end
    for k, fn in pairs(run) do if k ~= "build" then fn() end end
    if staleButtons and not run.config then RestyleButtons() end
  end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_SELFBUFFS1 = "/selfbuffs"
SLASH_SELFBUFFS2 = "/sb"
SlashCmdList.SELFBUFFS = function(msg)
  local cmd = strsplit(" ", (msg or ""):lower(), 2)
  if cmd == "unlock" then SetUnlocked(true)
  elseif cmd == "lock" then SetUnlocked(false)
  elseif cmd == "reset" then ResetPositions()
  else ToggleOptions() end
end
