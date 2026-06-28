--[[ ============================================================
    Session & AFK Tracker  -  Executor UI
    ------------------------------------------------------------
    Sidebar UI with four tabs:
      - Main   : injected-since timer, last input, AFK timer,
                 Anti-AFK toggle, Freeze toggle, Platform toggle
      - Logs   : scrolling log of every anti-AFK right-click,
                 with a Clear button to wipe all entries
      - Server : current Place ID / Job ID / server link (with copy
                 buttons), Join Server form (Place ID + Job ID only),
                 and Server Management (Rejoin, Server Hop, Smallest Server)
      - Info   : credits + freeze warning

    Platform modes (auto-detected, switchable on Main tab):
      - PC    : RightShift hides/shows the panel
      - Mobile: Hide button in the sidebar; when hidden, a small
                draggable floating button appears to reopen the panel

    Settings saved to file (survive re-execute):
      - platform (PC / Mobile)
      - antiAfkEnabled
      - panel position
      (Freeze is NEVER auto-restored - always starts OFF for safety)

    Re-execute support:
      - The script cleans up any previous instance on startup, so it's
        safe to re-execute. For auto re-execution across game hops,
        place this script in your executor's autoexec folder.

    - Mouse MOVEMENT is ignored (you can wiggle freely)
    - Built-in anti-AFK (VirtualUser Button2 on player.Idled)
    - Unload button on sidebar fully tears everything down
    - No console output
--============================================================ ]]

--// ─────────────── Config ───────────────
local AFK_THRESHOLD = 5
local TOGGLE_KEY    = Enum.KeyCode.RightShift   -- hide / show panel (PC)
local MAX_LOGS      = 100
local SETTINGS_FILE = "AfkTrackerSettings.json"

--// ─────────────── Services ───────────────
local Players     = game:GetService("Players")
local UIS         = game:GetService("UserInputService")
local Run         = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")
local player      = Players.LocalPlayer

--// ─────────────── Re-execute support ───────────────
-- If a previous instance is running, unload it first so we don't end up
-- with duplicate panels. This makes the script safe to re-execute manually
-- OR via an executor's auto-execute folder (which re-runs it on every game join).
-- To enable auto re-execution across game hops, place this script in your
-- executor's autoexec folder (Synapse: autoexec/, Krnl: autoexec/, etc.).
if getgenv and getgenv().AfkTrackerUnload then
    pcall(getgenv().AfkTrackerUnload)
    task.wait(0.2)
end

local gui = player:WaitForChild("PlayerGui")

--// ─────────────── Settings (persistent) ───────────────
local function defaultSettings()
    return {
        platform       = "PC",      -- "PC" or "Mobile"
        antiAfkEnabled = true,
        frozen         = false,
        panelPos       = { x = 16, y = 0.5, oy = -140 }, -- fallback
    }
end

local function loadSettings()
    local s = defaultSettings()
    if not isfile or not readfile then return s end
    if not isfile(SETTINGS_FILE) then return s end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(SETTINGS_FILE))
    end)
    if not ok or type(data) ~= "table" then return s end
    -- Merge with defaults so missing keys don't break things
    for k, v in pairs(data) do s[k] = v end
    -- Validate platform
    if s.platform ~= "PC" and s.platform ~= "Mobile" then
        s.platform = "PC"
    end
    return s
end

local function saveSettings(s)
    if not writefile then return end
    pcall(function()
        writefile(SETTINGS_FILE, HttpService:JSONEncode(s))
    end)
end

local settings = loadSettings()

--// ─────────────── Platform detection (only used if no saved setting) ───────────────
-- We only auto-detect on first run (when no settings file exists).
-- After that, the saved platform is respected.
local function detectPlatform()
    -- TouchEnabled + no mouse = mobile
    if UIS.TouchEnabled and not UIS.MouseEnabled then
        return "Mobile"
    end
    return "PC"
end

-- If this is a fresh install (file didn't exist), auto-detect platform
local isFreshInstall = (not isfile) or (not isfile(SETTINGS_FILE))
if isFreshInstall then
    settings.platform = detectPlatform()
    saveSettings(settings)
end

local platform = settings.platform   -- "PC" or "Mobile"

--// ─────────────── State ───────────────
local scriptStart    = tick()
local lastInput      = tick()
local afkStartTick   = nil
local antiAfkEnabled = settings.antiAfkEnabled
local frozen         = false   -- never restore frozen=true on re-exec (unsafe)
local queueOnTeleport = false  -- Queue on Teleport toggle state
local savedWalkSpeed = nil
local unloaded       = false
local panelVisible   = true

-- In-game time: use persistent per-server timestamp
local gameJoinTime
do
    local jobId = game.JobId
    if jobId == "" then jobId = "singleplayer" end
    local sessionKey = "AfkTrackerSession_" .. tostring(jobId)
    local function loadSession()
        if not isfile or not readfile then return nil end
        if not isfile(sessionKey) then return nil end
        local ok, data = pcall(function()
            return HttpService:JSONDecode(readfile(sessionKey))
        end)
        if ok and type(data) == "table" and type(data.joinTime) == "number" then
            return data.joinTime
        end
        return nil
    end
    local function saveSession(t)
        if not writefile then return end
        pcall(function()
            writefile(sessionKey, HttpService:JSONEncode({ joinTime = t }))
        end)
    end
    local existing = loadSession()
    if existing and existing < os.time() then
        -- We've been in this server before (script re-executed)
        gameJoinTime = existing
    else
        -- First time in this server - best we can do is script start
        -- Convert tick() to os.time() equivalent for consistency
        gameJoinTime = os.time()
        saveSession(gameJoinTime)
    end
end

local connections = {}
local function track(conn)
    table.insert(connections, conn)
    return conn
end

--// ─────────────── Build UI shell ───────────────
local screen = Instance.new("ScreenGui")
screen.Name           = "AfkTracker"
screen.ResetOnSpawn   = false
screen.IgnoreGuiInset = true
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent         = gui

local frame = Instance.new("Frame")
frame.Name             = "Panel"
frame.Size             = UDim2.new(0, 320, 0, 280)
-- Restore saved position if available
do
    local p = settings.panelPos
    if p and type(p.x) == "number" and type(p.y) == "number" then
        frame.Position = UDim2.new(0, p.x, p.y, p.oy or -140)
    else
        frame.Position = UDim2.new(0, 16, 0.5, -140)
    end
end
frame.BackgroundColor3 = Color3.fromRGB(18, 19, 24)
frame.BackgroundTransparency = 0.05
frame.BorderSizePixel  = 0
frame.Active           = true
frame.Parent           = screen

Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
local stroke = Instance.new("UIStroke", frame)
stroke.Color        = Color3.fromRGB(120, 160, 255)
stroke.Thickness    = 1.2
stroke.Transparency = 0.4

--// ─────────────── Sidebar ───────────────
local SIDEBAR_W = 60

local sidebar = Instance.new("Frame", frame)
sidebar.Name             = "Sidebar"
sidebar.Size             = UDim2.new(0, SIDEBAR_W, 1, 0)
sidebar.Position         = UDim2.new(0, 0, 0, 0)
sidebar.BackgroundColor3 = Color3.fromRGB(14, 15, 19)
sidebar.BorderSizePixel  = 0
Instance.new("UICorner", sidebar).CornerRadius = UDim.new(0, 10)

local sideMask = Instance.new("Frame", sidebar)
sideMask.Size             = UDim2.new(0, 6, 1, 0)
sideMask.Position         = UDim2.new(1, -6, 0, 0)
sideMask.BackgroundColor3 = Color3.fromRGB(14, 15, 19)
sideMask.BorderSizePixel  = 0

local sidebarLogo = Instance.new("TextLabel", sidebar)
sidebarLogo.Size                  = UDim2.new(1, 0, 0, 22)
sidebarLogo.Position              = UDim2.new(0, 0, 0, 6)
sidebarLogo.BackgroundTransparency= 1
sidebarLogo.Font                  = Enum.Font.GothamBold
sidebarLogo.TextSize              = 11
sidebarLogo.TextColor3            = Color3.fromRGB(120, 160, 255)
sidebarLogo.Text                  = "TRACK"

local activeTab = "Main"

local function makeTabBtn(name, text, y)
    local btn = Instance.new("TextButton")
    btn.Name             = name
    btn.Size             = UDim2.new(1, -12, 0, 28)
    btn.Position         = UDim2.new(0, 6, 0, y)
    btn.BackgroundColor3 = Color3.fromRGB(30, 32, 40)
    btn.BorderSizePixel  = 0
    btn.Font             = Enum.Font.GothamBold
    btn.TextSize         = 12
    btn.TextColor3       = Color3.fromRGB(200, 202, 210)
    btn.AutoButtonColor  = true
    btn.Text             = text
    btn.Parent           = sidebar
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    return btn
end

local mainBtn   = makeTabBtn("MainTab",   "Main",   30)
local logsBtn   = makeTabBtn("LogsTab",   "Logs",   64)
local serverBtn = makeTabBtn("ServerTab", "Server", 98)
local infoBtn   = makeTabBtn("InfoTab",   "Info",   132)

-- Hide button (always visible in sidebar, essential for mobile)
local hideBtn = Instance.new("TextButton")
hideBtn.Name             = "HideTab"
hideBtn.Size             = UDim2.new(1, -12, 0, 24)
hideBtn.Position         = UDim2.new(0, 6, 1, -58)
hideBtn.BackgroundColor3 = Color3.fromRGB(40, 42, 50)
hideBtn.BorderSizePixel  = 0
hideBtn.Font             = Enum.Font.GothamBold
hideBtn.TextSize         = 11
hideBtn.TextColor3       = Color3.fromRGB(200, 202, 210)
hideBtn.AutoButtonColor  = true
hideBtn.Text             = "Hide"
hideBtn.Visible          = (platform == "Mobile")  -- PC uses RightShift instead
hideBtn.Parent           = sidebar
Instance.new("UICorner", hideBtn).CornerRadius = UDim.new(0, 6)

local unloadBtn = Instance.new("TextButton")
unloadBtn.Name             = "UnloadTab"
unloadBtn.Size             = UDim2.new(1, -12, 0, 24)
unloadBtn.Position         = UDim2.new(0, 6, 1, -30)
unloadBtn.BackgroundColor3 = Color3.fromRGB(80, 30, 35)
unloadBtn.BorderSizePixel  = 0
unloadBtn.Font             = Enum.Font.GothamBold
unloadBtn.TextSize         = 11
unloadBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
unloadBtn.AutoButtonColor  = true
unloadBtn.Text             = "Unload"
unloadBtn.Parent           = sidebar
Instance.new("UICorner", unloadBtn).CornerRadius = UDim.new(0, 6)

local function paintTab(btn, active)
    if active then
        btn.BackgroundColor3 = Color3.fromRGB(120, 160, 255)
        btn.TextColor3       = Color3.fromRGB(255, 255, 255)
    else
        btn.BackgroundColor3 = Color3.fromRGB(30, 32, 40)
        btn.TextColor3       = Color3.fromRGB(200, 202, 210)
    end
end
paintTab(mainBtn, true)
paintTab(logsBtn, false)
paintTab(serverBtn, false)
paintTab(infoBtn, false)

--// ─────────────── Floating reopen button (shown when panel hidden) ───────────────
local floatBtn = Instance.new("TextButton")
floatBtn.Name             = "FloatBtn"
floatBtn.Size             = UDim2.new(0, 44, 0, 44)
floatBtn.Position         = UDim2.new(0, 16, 0, 100)
floatBtn.BackgroundColor3 = Color3.fromRGB(18, 19, 24)
floatBtn.BackgroundTransparency = 0.1
floatBtn.BorderSizePixel  = 0
floatBtn.AutoButtonColor  = true
floatBtn.Text             = ""
floatBtn.Visible          = false
floatBtn.Parent           = screen
Instance.new("UICorner", floatBtn).CornerRadius = UDim.new(0.5, 0)
local floatStroke = Instance.new("UIStroke", floatBtn)
floatStroke.Color        = Color3.fromRGB(120, 160, 255)
floatStroke.Thickness    = 1.5
floatStroke.Transparency = 0.3

local floatLogo = Instance.new("TextLabel", floatBtn)
floatLogo.Size                  = UDim2.new(1, 0, 1, 0)
floatLogo.BackgroundTransparency= 1
floatLogo.Font                  = Enum.Font.GothamBold
floatLogo.TextSize              = 11
floatLogo.TextColor3            = Color3.fromRGB(120, 160, 255)
floatLogo.Text                  = "T"

--// ─────────────── Hide / show logic ───────────────
local function setPanelVisible(v)
    panelVisible = v
    frame.Visible = v
    -- Floating button shows ONLY when panel is hidden
    floatBtn.Visible = (not v) and (not unloaded)
end

track(hideBtn.MouseButton1Click:Connect(function()
    setPanelVisible(false)
end))

track(floatBtn.MouseButton1Click:Connect(function()
    setPanelVisible(true)
end))

--// ─────────────── Main view ───────────────
local mainView = Instance.new("Frame", frame)
mainView.Name             = "MainView"
mainView.Size             = UDim2.new(1, -SIDEBAR_W, 1, 0)
mainView.Position         = UDim2.new(0, SIDEBAR_W, 0, 0)
mainView.BackgroundTransparency = 1
mainView.Visible          = true

local title = Instance.new("TextLabel", mainView)
title.Size                  = UDim2.new(1, -110, 0, 24)
title.Position              = UDim2.new(0, 12, 0, 6)
title.BackgroundTransparency= 1
title.Font                  = Enum.Font.GothamBold
title.TextSize              = 14
title.TextColor3            = Color3.fromRGB(255, 255, 255)
title.TextXAlignment        = Enum.TextXAlignment.Left
title.Text                  = "Session Tracker"

local accentBar = Instance.new("Frame", mainView)
accentBar.Size             = UDim2.new(0, 3, 1, -16)
accentBar.Position         = UDim2.new(0, 0, 0, 8)
accentBar.BackgroundColor3 = Color3.fromRGB(120, 160, 255)
accentBar.BorderSizePixel  = 0
Instance.new("UICorner", accentBar).CornerRadius = UDim.new(1, 0)

-- Anti-AFK toggle button (top-right of title row)
local toggleBtn = Instance.new("TextButton", mainView)
toggleBtn.Size             = UDim2.new(0, 92, 0, 20)
toggleBtn.Position         = UDim2.new(1, -100, 0, 8)
toggleBtn.BackgroundColor3 = Color3.fromRGB(30, 32, 40)
toggleBtn.BorderSizePixel  = 0
toggleBtn.Font             = Enum.Font.GothamBold
toggleBtn.TextSize         = 12
toggleBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
toggleBtn.AutoButtonColor  = true
toggleBtn.Text             = "Anti-AFK: ON"
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 6)

local function updateToggleVisual()
    if antiAfkEnabled then
        toggleBtn.Text             = "Anti-AFK: ON"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(46, 90, 60)
    else
        toggleBtn.Text             = "Anti-AFK: OFF"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(90, 46, 46)
    end
end
updateToggleVisual()

track(toggleBtn.MouseButton1Click:Connect(function()
    antiAfkEnabled = not antiAfkEnabled
    settings.antiAfkEnabled = antiAfkEnabled
    saveSettings(settings)
    updateToggleVisual()
end))

-- Freeze toggle button (directly under Anti-AFK)
local freezeBtn = Instance.new("TextButton", mainView)
freezeBtn.Size             = UDim2.new(0, 92, 0, 20)
freezeBtn.Position         = UDim2.new(1, -100, 0, 32)
freezeBtn.BackgroundColor3 = Color3.fromRGB(30, 32, 40)
freezeBtn.BorderSizePixel  = 0
freezeBtn.Font             = Enum.Font.GothamBold
freezeBtn.TextSize         = 12
freezeBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
freezeBtn.AutoButtonColor  = true
freezeBtn.Text             = "Freeze: OFF"
Instance.new("UICorner", freezeBtn).CornerRadius = UDim.new(0, 6)

local function updateFreezeVisual()
    if frozen then
        freezeBtn.Text             = "Freeze: ON"
        freezeBtn.BackgroundColor3 = Color3.fromRGB(46, 90, 60)
    else
        freezeBtn.Text             = "Freeze: OFF"
        freezeBtn.BackgroundColor3 = Color3.fromRGB(90, 46, 46)
    end
end
updateFreezeVisual()

--// ─────────────── Freeze logic ───────────────
-- Anchors HRP + Stepped CFrame lock. Does NOT touch WalkSpeed.
-- Anchoring alone prevents all movement (walking is a physics force,
-- anchored parts ignore physics). Touching WalkSpeed breaks movement
-- in games that manage speed themselves (e.g. Tower of Hell).
local lockedCFrame = nil

local function applyFreezeToCharacter(char)
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    if frozen then
        hrp.Anchored = true
        lockedCFrame = hrp.CFrame
    else
        hrp.Anchored = false
        lockedCFrame = nil
    end
end

-- Stepped hook: force-resets HRP CFrame every frame to resist drag abilities
track(Run.Stepped:Connect(function()
    if unloaded or not frozen then return end
    local char = player.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp or not lockedCFrame then return end
    if not hrp.Anchored then hrp.Anchored = true end
    hrp.CFrame = lockedCFrame
    hrp.AssemblyLinearVelocity  = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
end))

local function setFrozen(state)
    frozen = state
    -- Note: we intentionally do NOT save frozen to settings.
    -- Freeze always starts OFF on re-execute for safety.
    if player.Character then
        applyFreezeToCharacter(player.Character)
    end
    updateFreezeVisual()
end

track(freezeBtn.MouseButton1Click:Connect(function()
    setFrozen(not frozen)
end))

-- Re-apply freeze when character respawns
track(player.CharacterAdded:Connect(function(char)
    local hrp = char:WaitForChild("HumanoidRootPart", 5)
    if hrp then
        task.wait(0.1)
        if frozen and not unloaded then
            applyFreezeToCharacter(char)
        end
    end
end))

if player.Character then
    applyFreezeToCharacter(player.Character)
end

--// ─────────────── Stat lines ───────────────
local function makeLine(y)
    local lbl = Instance.new("TextLabel", mainView)
    lbl.Size                  = UDim2.new(1, -110, 0, 22)
    lbl.Position              = UDim2.new(0, 14, 0, y)
    lbl.BackgroundTransparency= 1
    lbl.Font                  = Enum.Font.Gotham
    lbl.TextSize              = 13
    lbl.TextColor3            = Color3.fromRGB(225, 226, 232)
    lbl.TextXAlignment        = Enum.TextXAlignment.Left
    lbl.Text                  = "..."
    return lbl
end

local inGameLbl    = makeLine(70)
local lastInputLbl = makeLine(98)
local afkLbl       = makeLine(126)

local hintLbl = Instance.new("TextLabel", mainView)
hintLbl.Size                  = UDim2.new(1, -24, 0, 18)
hintLbl.Position              = UDim2.new(0, 14, 1, -22)
hintLbl.BackgroundTransparency= 1
hintLbl.Font                  = Enum.Font.Gotham
hintLbl.TextSize              = 10
hintLbl.TextColor3            = Color3.fromRGB(140, 142, 150)
hintLbl.TextXAlignment        = Enum.TextXAlignment.Left
hintLbl.Text                  = (platform == "Mobile") and "Hide btn to minimize" or "RightShift to hide/show"

-- Platform toggle (under AFK for, right-aligned like Anti-AFK/Freeze)
local platLabel = Instance.new("TextLabel", mainView)
platLabel.Size                  = UDim2.new(0, 70, 0, 20)
platLabel.Position              = UDim2.new(0, 14, 0, 156)
platLabel.BackgroundTransparency= 1
platLabel.Font                  = Enum.Font.Gotham
platLabel.TextSize              = 13
platLabel.TextColor3            = Color3.fromRGB(225, 226, 232)
platLabel.TextXAlignment        = Enum.TextXAlignment.Left
platLabel.Text                  = "Platform:"

local platBtn = Instance.new("TextButton", mainView)
platBtn.Size             = UDim2.new(0, 92, 0, 20)
platBtn.Position         = UDim2.new(1, -100, 0, 156)
platBtn.BackgroundColor3 = Color3.fromRGB(30, 32, 40)
platBtn.BorderSizePixel  = 0
platBtn.Font             = Enum.Font.GothamBold
platBtn.TextSize         = 12
platBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
platBtn.AutoButtonColor  = true
platBtn.Text             = platform
Instance.new("UICorner", platBtn).CornerRadius = UDim.new(0, 6)

local function refreshPlatBtn()
    platBtn.Text             = platform
    platBtn.BackgroundColor3 = (platform == "Mobile")
        and Color3.fromRGB(46, 90, 60)
        or  Color3.fromRGB(46, 60, 90)
end
refreshPlatBtn()

track(platBtn.MouseButton1Click:Connect(function()
    platform = (platform == "PC") and "Mobile" or "PC"
    settings.platform = platform
    saveSettings(settings)
    refreshPlatBtn()
    hintLbl.Text = (platform == "Mobile")
        and "Hide btn to minimize"
        or  "RightShift to hide/show"
    hideBtn.Visible = (platform == "Mobile")
end))

-- Queue on Teleport toggle (under Platform toggle)
local queueLabel = Instance.new("TextLabel", mainView)
queueLabel.Size                  = UDim2.new(0, 130, 0, 20)
queueLabel.Position              = UDim2.new(0, 14, 0, 180)
queueLabel.BackgroundTransparency= 1
queueLabel.Font                  = Enum.Font.Gotham
queueLabel.TextSize              = 13
queueLabel.TextColor3            = Color3.fromRGB(225, 226, 232)
queueLabel.TextXAlignment        = Enum.TextXAlignment.Left
queueLabel.Text                  = "Queue on Teleport:"

local queueBtn = Instance.new("TextButton", mainView)
queueBtn.Size             = UDim2.new(0, 92, 0, 20)
queueBtn.Position         = UDim2.new(1, -100, 0, 180)
queueBtn.BackgroundColor3 = Color3.fromRGB(90, 46, 46)
queueBtn.BorderSizePixel  = 0
queueBtn.Font             = Enum.Font.GothamBold
queueBtn.TextSize         = 12
queueBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
queueBtn.AutoButtonColor  = true
queueBtn.Text             = "Queue: OFF"
Instance.new("UICorner", queueBtn).CornerRadius = UDim.new(0, 6)

local function updateQueueVisual()
    if queueOnTeleport then
        queueBtn.Text             = "Queue: ON"
        queueBtn.BackgroundColor3 = Color3.fromRGB(46, 90, 60)
    else
        queueBtn.Text             = "Queue: OFF"
        queueBtn.BackgroundColor3 = Color3.fromRGB(90, 46, 46)
    end
end
updateQueueVisual()

track(queueBtn.MouseButton1Click:Connect(function()
    queueOnTeleport = not queueOnTeleport
    updateQueueVisual()
    if queueOnTeleport then
        -- Verify a queue function exists before promising the user it'll work
        local q = queue_on_teleport or queueonteleport
        if not q and type(syn) == "table" then q = syn.queue_on_teleport end
        if not q and type(getgenv) == "function" then
            local g = getgenv()
            if g then q = g.queue_on_teleport or g.queueonteleport end
        end
        if q then
            notify("Queue on Teleport enabled", Color3.fromRGB(140, 230, 160))
        else
            notify("Queue on Teleport: not supported by this executor", Color3.fromRGB(255, 140, 140))
        end
    else
        notify("Queue on Teleport disabled", Color3.fromRGB(160, 162, 170))
    end
end))

--// ─────────────── Logs view ───────────────
local logsView = Instance.new("Frame", frame)
logsView.Name             = "LogsView"
logsView.Size             = UDim2.new(1, -SIDEBAR_W, 1, 0)
logsView.Position         = UDim2.new(0, SIDEBAR_W, 0, 0)
logsView.BackgroundTransparency = 1
logsView.Visible          = false

local logsTitle = Instance.new("TextLabel", logsView)
logsTitle.Size                  = UDim2.new(1, -110, 0, 24)
logsTitle.Position              = UDim2.new(0, 12, 0, 6)
logsTitle.BackgroundTransparency= 1
logsTitle.Font                  = Enum.Font.GothamBold
logsTitle.TextSize              = 14
logsTitle.TextColor3            = Color3.fromRGB(255, 255, 255)
logsTitle.TextXAlignment        = Enum.TextXAlignment.Left
logsTitle.Text                  = "Anti-AFK Logs"

-- Clear button (top-right of logs title row)
local clearBtn = Instance.new("TextButton", logsView)
clearBtn.Size             = UDim2.new(0, 60, 0, 20)
clearBtn.Position         = UDim2.new(1, -68, 0, 8)
clearBtn.BackgroundColor3 = Color3.fromRGB(80, 50, 30)
clearBtn.BorderSizePixel  = 0
clearBtn.Font             = Enum.Font.GothamBold
clearBtn.TextSize         = 11
clearBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
clearBtn.AutoButtonColor  = true
clearBtn.Text             = "Clear"
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

local logsAccent = Instance.new("Frame", logsView)
logsAccent.Size             = UDim2.new(0, 3, 1, -16)
logsAccent.Position         = UDim2.new(0, 0, 0, 8)
logsAccent.BackgroundColor3 = Color3.fromRGB(120, 160, 255)
logsAccent.BorderSizePixel  = 0
Instance.new("UICorner", logsAccent).CornerRadius = UDim.new(1, 0)

local scroll = Instance.new("ScrollingFrame", logsView)
scroll.Size                        = UDim2.new(1, -24, 1, -54)
scroll.Position                    = UDim2.new(0, 12, 0, 34)
scroll.BackgroundTransparency      = 1
scroll.BorderSizePixel             = 0
scroll.ScrollBarThickness          = 4
scroll.ScrollBarImageColor3        = Color3.fromRGB(120, 160, 255)
scroll.ScrollBarImageTransparency  = 0.3
scroll.CanvasSize                  = UDim2.new(0, 0, 0, 0)
scroll.ScrollingDirection          = Enum.ScrollingDirection.Y

local listLayout = Instance.new("UIListLayout", scroll)
listLayout.SortOrder         = Enum.SortOrder.LayoutOrder
listLayout.Padding           = UDim.new(0, 4)
listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

-- Auto-resize canvas when content changes
listLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    scroll.CanvasSize = UDim2.new(0, 0, 0, listLayout.AbsoluteContentSize.Y)
end)

local emptyLbl = Instance.new("TextLabel", scroll)
emptyLbl.Size                  = UDim2.new(1, -8, 0, 24)
emptyLbl.BackgroundTransparency= 1
emptyLbl.Font                  = Enum.Font.Gotham
emptyLbl.TextSize              = 12
emptyLbl.TextColor3            = Color3.fromRGB(140, 142, 150)
emptyLbl.Text                  = "No anti-AFK events yet."
emptyLbl.LayoutOrder           = 999999

--// ─────────────── Log entries ───────────────
local logEntries = {}
local logCounter  = 0

local function addLogEntry(ts)
    emptyLbl.Visible = false
    local entry = { timestamp = ts }

    local card = Instance.new("Frame")
    card.Size             = UDim2.new(1, -6, 0, 28)
    card.BackgroundColor3 = Color3.fromRGB(28, 30, 36)
    card.BorderSizePixel  = 0
    card.LayoutOrder      = logCounter
    card.Parent           = scroll
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 5)

    local dot = Instance.new("Frame", card)
    dot.Size             = UDim2.new(0, 6, 0, 6)
    dot.Position         = UDim2.new(0, 8, 0.5, -3)
    dot.BackgroundColor3 = Color3.fromRGB(120, 160, 255)
    dot.BorderSizePixel  = 0
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

    local label = Instance.new("TextLabel", card)
    label.Size                  = UDim2.new(1, -26, 1, 0)
    label.Position              = UDim2.new(0, 22, 0, 0)
    label.BackgroundTransparency= 1
    label.Font                  = Enum.Font.Gotham
    label.TextSize              = 12
    label.TextColor3            = Color3.fromRGB(225, 226, 232)
    label.TextXAlignment        = Enum.TextXAlignment.Left
    label.TextYAlignment        = Enum.TextYAlignment.Center
    label.Text                  = "Sent right click: just now"

    entry.frame = card
    entry.label = label
    table.insert(logEntries, entry)
    logCounter = logCounter - 1

    if #logEntries > MAX_LOGS then
        local oldest = table.remove(logEntries, 1)
        if oldest and oldest.frame then oldest.frame:Destroy() end
    end
    return entry
end

-- Clear all log entries
local function clearLogs()
    for _, entry in ipairs(logEntries) do
        if entry.frame then
            entry.frame:Destroy()
        end
    end
    logEntries = {}
    logCounter = 0
    emptyLbl.Visible = true
end

track(clearBtn.MouseButton1Click:Connect(function()
    clearLogs()
end))

--// ─────────────── Info view ───────────────
local infoView = Instance.new("Frame", frame)
infoView.Name             = "InfoView"
infoView.Size             = UDim2.new(1, -SIDEBAR_W, 1, 0)
infoView.Position         = UDim2.new(0, SIDEBAR_W, 0, 0)
infoView.BackgroundTransparency = 1
infoView.Visible          = false

local infoTitle = Instance.new("TextLabel", infoView)
infoTitle.Size                  = UDim2.new(1, -24, 0, 24)
infoTitle.Position              = UDim2.new(0, 12, 0, 6)
infoTitle.BackgroundTransparency= 1
infoTitle.Font                  = Enum.Font.GothamBold
infoTitle.TextSize              = 14
infoTitle.TextColor3            = Color3.fromRGB(255, 255, 255)
infoTitle.TextXAlignment        = Enum.TextXAlignment.Left
infoTitle.Text                  = "Info"

local infoAccent = Instance.new("Frame", infoView)
infoAccent.Size             = UDim2.new(0, 3, 1, -16)
infoAccent.Position         = UDim2.new(0, 0, 0, 8)
infoAccent.BackgroundColor3 = Color3.fromRGB(120, 160, 255)
infoAccent.BorderSizePixel  = 0
Instance.new("UICorner", infoAccent).CornerRadius = UDim.new(1, 0)

-- Info body content
local infoLines = {
    { text = "Session & AFK Tracker",  color = Color3.fromRGB(255, 255, 255), bold = true,  size = 13 },
    { text = "Built for executor use",  color = Color3.fromRGB(160, 162, 170), bold = false, size = 11 },
    { text = "",                        color = Color3.fromRGB(0, 0, 0),       bold = false, size = 6 },
    { text = "Creator's Discord: twin.e8", color = Color3.fromRGB(120, 160, 255), bold = true, size = 12 },
    { text = "",                        color = Color3.fromRGB(0, 0, 0),       bold = false, size = 6 },
    { text = "WARNING",                 color = Color3.fromRGB(255, 140, 140), bold = true,  size = 12 },
    { text = "Freeze anchors your character.",            color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
    { text = "May get you kicked if the game",            color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
    { text = "has an anti-cheat. Use with caution.",      color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
    { text = "",                        color = Color3.fromRGB(0, 0, 0),       bold = false, size = 6 },
    { text = "SERVER LINK",             color = Color3.fromRGB(255, 200, 100), bold = true,  size = 11 },
    { text = "The generated server link may",             color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
    { text = "not put you in the exact same",             color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
    { text = "server. Roblox's new browser flow",         color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
    { text = "can redirect you to a different",           color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
    { text = "instance.",                                 color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
    { text = "",                        color = Color3.fromRGB(0, 0, 0),       bold = false, size = 6 },
    { text = "JOIN SERVER",             color = Color3.fromRGB(255, 200, 100), bold = true,  size = 11 },
    { text = "Some games restrict way of",                color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
    { text = "joining. You may see an error like",        color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
    { text = '"attempted to teleport to a place',         color = Color3.fromRGB(200, 200, 210), bold = false, size = 11 },
    { text = 'that is restricted" if the game',           color = Color3.fromRGB(200, 200, 210), bold = false, size = 11 },
    { text = "blocks this method.",                       color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
}

-- Scrollable container for info content
local infoScroll = Instance.new("ScrollingFrame", infoView)
infoScroll.Size                        = UDim2.new(1, -24, 1, -40)
infoScroll.Position                    = UDim2.new(0, 12, 0, 34)
infoScroll.BackgroundTransparency      = 1
infoScroll.BorderSizePixel             = 0
infoScroll.ScrollBarThickness          = 4
infoScroll.ScrollBarImageColor3        = Color3.fromRGB(120, 160, 255)
infoScroll.ScrollBarImageTransparency  = 0.3
infoScroll.CanvasSize                  = UDim2.new(0, 0, 0, 0)
infoScroll.ScrollingDirection          = Enum.ScrollingDirection.Y

local infoLayout = Instance.new("UIListLayout", infoScroll)
infoLayout.SortOrder         = Enum.SortOrder.LayoutOrder
infoLayout.Padding           = UDim.new(0, 0)

-- Auto-resize canvas when content changes
infoLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    infoScroll.CanvasSize = UDim2.new(0, 0, 0, infoLayout.AbsoluteContentSize.Y)
end)

local infoY = 0
for i, line in ipairs(infoLines) do
    local lbl = Instance.new("TextLabel", infoScroll)
    lbl.Size                  = UDim2.new(1, -8, 0, line.size + 6)
    lbl.BackgroundTransparency= 1
    lbl.Font                  = line.bold and Enum.Font.GothamBold or Enum.Font.Gotham
    lbl.TextSize              = line.size
    lbl.TextColor3            = line.color
    lbl.TextXAlignment        = Enum.TextXAlignment.Left
    lbl.TextYAlignment        = Enum.TextYAlignment.Top
    lbl.TextWrapped           = true
    lbl.LayoutOrder           = i
    lbl.Text                  = line.text
    infoY = infoY + line.size + 6
end

--// ─────────────── HTTP request helper (executor-agnostic) ───────────────
local function httpRequest(options)
    local req = http_request or request
    if not req and type(syn) == "table" then req = syn.request end
    if not req and type(fluxus) == "table" then req = fluxus.request end
    if not req then
        return nil, "No HTTP function available on this executor"
    end
    local ok, result = pcall(req, options)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

-- Extract body and status from an HTTP response, handling different executor formats
local function parseResponse(resp)
    if not resp then return nil, 0, "No response" end
    -- Body can be under .Body, .body, .BodyString, or just a string
    local body = resp.Body or resp.body or resp.BodyString or (type(resp) == "string" and resp or nil)
    -- Status code can be under .StatusCode, .status, .Status, .code
    local status = resp.StatusCode or resp.status or resp.Status or resp.code or 0
    -- If body is nil but resp is a string, the whole response might be the body
    if not body and type(resp) == "string" then body = resp; status = 200 end
    return body, status, nil
end

--// ─────────────── Queue on Teleport helper ───────────────
-- Finds a supported queue-on-teleport function across executors.
-- Returns the function or nil if none is available.
local function getQueueFunction()
    local q = queue_on_teleport or queueonteleport
    if not q and type(syn) == "table" then q = syn.queue_on_teleport end
    if not q and type(getgenv) == "function" then
        local g = getgenv()
        if g then q = g.queue_on_teleport or g.queueonteleport end
    end
    return q
end

-- The loader code to re-execute after a teleport.
local QUEUE_LOADER = 'loadstring(game:HttpGet("https://raw.githubusercontent.com/dashingmonkeyNgl/SessionTracker/main/anti.lua"))()'

-- Call this before any teleport initiated by THIS script.
-- If the toggle is on, queues the loader for auto-execution in the new server.
-- Runs the queue call on a separate thread so it cannot block the teleport
-- (some executors' queue functions yield, which would freeze the button).
local function queueScript()
    if not queueOnTeleport then return true end
    local q = getQueueFunction()
    if not q then
        notify("Queue on Teleport not supported by this executor", Color3.fromRGB(255, 140, 140))
        return false
    end
    -- Run the queue call on a separate thread so it doesn't block the teleport
    task.spawn(function()
        local ok, err = pcall(q, QUEUE_LOADER)
        if ok then
            notify("Script queued for re-execution", Color3.fromRGB(140, 230, 160))
        else
            notify("Queue failed: " .. tostring(err):sub(1, 50), Color3.fromRGB(255, 140, 140))
        end
    end)
    return true
end

--// ─────────────── Notification toast ───────────────
local toast = Instance.new("TextLabel")
toast.Name = "Toast"
toast.Size = UDim2.new(1, -SIDEBAR_W - 24, 0, 26)
toast.Position = UDim2.new(0, SIDEBAR_W + 12, 1, -32)
toast.BackgroundColor3 = Color3.fromRGB(40, 42, 50)
toast.BorderSizePixel = 0
toast.Font = Enum.Font.GothamBold
toast.TextSize = 11
toast.TextColor3 = Color3.fromRGB(255, 255, 255)
toast.TextXAlignment = Enum.TextXAlignment.Center
toast.TextYAlignment = Enum.TextYAlignment.Center
toast.Visible = false
toast.ZIndex = 100
toast.Parent = frame
Instance.new("UICorner", toast).CornerRadius = UDim.new(0, 5)
local toastStroke = Instance.new("UIStroke", toast)
toastStroke.Color = Color3.fromRGB(120, 160, 255)
toastStroke.Thickness = 1
toastStroke.Transparency = 0.5

local toastTask = nil
local function notify(text, color)
    if not toast or not toast.Parent then return end
    toast.Text = text
    toast.TextColor3 = color or Color3.fromRGB(255, 255, 255)
    toast.Visible = true
    if toastTask then pcall(function() task.cancel(toastTask) end) end
    toastTask = task.delay(4, function()
        if toast and toast.Parent then toast.Visible = false end
    end)
end

--// ─────────────── Server fetch helper (with pagination) ───────────────
-- Returns: servers (table), errorMsg (string or nil)
-- Handles both API formats:
--   Old: {"servers": [...], "nextPageCursor": "..."}
--   New: {"data": [...], "nextPageCursor": "..."}
local function fetchServers(placeId, maxPages)
    local servers = {}
    local cursor = nil
    local pages = maxPages or 10
    for page = 1, pages do
        local url = "https://games.roblox.com/v1/games/" .. placeId .. "/servers/Public?limit=100"
        if cursor then url = url .. "&cursor=" .. cursor end
        local resp, err = httpRequest({
            Url = url,
            Method = "GET",
            Headers = {
                ["Accept"] = "application/json",
                ["User-Agent"] = "Roblox/WinInet",
            }
        })
        if not resp then
            return servers, "HTTP failed: " .. tostring(err):sub(1, 80)
        end
        local body, status = parseResponse(resp)
        if status ~= 200 then
            return servers, "HTTP " .. tostring(status) .. (page == 1 and " (may be rate-limited)" or "")
        end
        if not body or body == "" then
            return servers, "Empty response body"
        end
        local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
        if not ok then
            local preview = tostring(body):gsub("%s+", " "):sub(1, 60)
            return servers, "Not JSON: " .. preview
        end
        if type(data) ~= "table" then
            return servers, "JSON is not a table"
        end
        -- Handle both "servers" (old) and "data" (new) keys
        local serverList = data.servers or data.data
        if not serverList then
            if data.errors and data.errors[1] then
                return servers, "API: " .. tostring(data.errors[1].message or "unknown error")
            end
            local keys = {}
            for k in pairs(data) do table.insert(keys, tostring(k)) end
            local preview = tostring(body):gsub("%s+", " "):sub(1, 80)
            return servers, "No server list. Keys: [" .. table.concat(keys, ",") .. "]"
        end
        for _, s in ipairs(serverList) do
            table.insert(servers, s)
        end
        -- Handle both "nextPageCursor" formats
        local nextCursor = data.nextPageCursor
        if not nextCursor or nextCursor == "" or nextCursor == "null" then break end
        cursor = nextCursor
        task.wait(0.5) -- avoid rate limiting
    end
    return servers, nil
end

--// ─────────────── Server view ───────────────
local serverView = Instance.new("Frame", frame)
serverView.Name             = "ServerView"
serverView.Size             = UDim2.new(1, -SIDEBAR_W, 1, 0)
serverView.Position         = UDim2.new(0, SIDEBAR_W, 0, 0)
serverView.BackgroundTransparency = 1
serverView.Visible          = false

local serverTitle = Instance.new("TextLabel", serverView)
serverTitle.Size                  = UDim2.new(1, -24, 0, 24)
serverTitle.Position              = UDim2.new(0, 12, 0, 6)
serverTitle.BackgroundTransparency= 1
serverTitle.Font                  = Enum.Font.GothamBold
serverTitle.TextSize              = 14
serverTitle.TextColor3            = Color3.fromRGB(255, 255, 255)
serverTitle.TextXAlignment        = Enum.TextXAlignment.Left
serverTitle.Text                  = "Server"

local serverAccent = Instance.new("Frame", serverView)
serverAccent.Size             = UDim2.new(0, 3, 1, -16)
serverAccent.Position         = UDim2.new(0, 0, 0, 8)
serverAccent.BackgroundColor3 = Color3.fromRGB(120, 160, 255)
serverAccent.BorderSizePixel  = 0
Instance.new("UICorner", serverAccent).CornerRadius = UDim.new(1, 0)

-- Scrollable content container
local serverScroll = Instance.new("ScrollingFrame", serverView)
serverScroll.Size                        = UDim2.new(1, -16, 1, -36)
serverScroll.Position                    = UDim2.new(0, 8, 0, 32)
serverScroll.BackgroundTransparency      = 1
serverScroll.BorderSizePixel             = 0
serverScroll.ScrollBarThickness          = 4
serverScroll.ScrollBarImageColor3        = Color3.fromRGB(120, 160, 255)
serverScroll.ScrollBarImageTransparency  = 0.3
serverScroll.CanvasSize                  = UDim2.new(0, 0, 0, 0)
serverScroll.ScrollingDirection          = Enum.ScrollingDirection.Y

local serverContent = Instance.new("Frame", serverScroll)
serverContent.Size             = UDim2.new(1, -12, 0, 400)
serverContent.Position         = UDim2.new(0, 0, 0, 0)
serverContent.BackgroundTransparency = 1

-- Helper: build a labeled row with a value box + copy button
local function makeServerRow(y, labelText, valueText)
    local label = Instance.new("TextLabel", serverContent)
    label.Size                  = UDim2.new(1, -16, 0, 14)
    label.Position              = UDim2.new(0, 6, 0, y)
    label.BackgroundTransparency= 1
    label.Font                  = Enum.Font.GothamBold
    label.TextSize              = 10
    label.TextColor3            = Color3.fromRGB(160, 162, 170)
    label.TextXAlignment        = Enum.TextXAlignment.Left
    label.Text                  = labelText

    local valueBox = Instance.new("TextLabel", serverContent)
    valueBox.Size             = UDim2.new(1, -80, 0, 22)
    valueBox.Position         = UDim2.new(0, 6, 0, y + 16)
    valueBox.BackgroundColor3 = Color3.fromRGB(28, 30, 36)
    valueBox.BorderSizePixel  = 0
    valueBox.Font             = Enum.Font.Code
    valueBox.TextSize         = 11
    valueBox.TextColor3       = Color3.fromRGB(225, 226, 232)
    valueBox.TextXAlignment   = Enum.TextXAlignment.Left
    valueBox.TextTruncate     = Enum.TextTruncate.AtEnd
    valueBox.Text             = valueText
    local pad = Instance.new("UIPadding", valueBox)
    pad.PaddingLeft = UDim.new(0, 8)
    Instance.new("UICorner", valueBox).CornerRadius = UDim.new(0, 5)

    local copyBtn = Instance.new("TextButton", serverContent)
    copyBtn.Size             = UDim2.new(0, 60, 0, 22)
    copyBtn.Position         = UDim2.new(1, -66, 0, y + 16)
    copyBtn.BackgroundColor3 = Color3.fromRGB(40, 50, 70)
    copyBtn.BorderSizePixel  = 0
    copyBtn.Font             = Enum.Font.GothamBold
    copyBtn.TextSize         = 11
    copyBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
    copyBtn.AutoButtonColor  = true
    copyBtn.Text             = "Copy"
    Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 5)

    track(copyBtn.MouseButton1Click:Connect(function()
        if setclipboard then
            setclipboard(valueBox.Text)
            copyBtn.Text = "Copied!"
            task.delay(1.2, function()
                if copyBtn and copyBtn.Parent then copyBtn.Text = "Copy" end
            end)
        else
            copyBtn.Text = "No cb"
            task.delay(1.2, function()
                if copyBtn and copyBtn.Parent then copyBtn.Text = "Copy" end
            end)
        end
    end))

    return valueBox
end

-- Section: Current Server
local csHeader = Instance.new("TextLabel", serverContent)
csHeader.Size                  = UDim2.new(1, -16, 0, 14)
csHeader.Position              = UDim2.new(0, 6, 0, 0)
csHeader.BackgroundTransparency= 1
csHeader.Font                  = Enum.Font.GothamBold
csHeader.TextSize              = 11
csHeader.TextColor3            = Color3.fromRGB(120, 160, 255)
csHeader.TextXAlignment        = Enum.TextXAlignment.Left
csHeader.Text                  = "CURRENT SERVER"

local placeIdStr = tostring(game.PlaceId)
local jobIdStr   = (game.JobId == "") and "(none - singleplayer)" or game.JobId
local linkStr    = "https://www.roblox.com/games/start?placeId=" .. placeIdStr
                   .. (game.JobId ~= "" and ("&gameInstanceId=" .. game.JobId) or "")

makeServerRow(14, "PLACE ID",   placeIdStr)
makeServerRow(52, "JOB ID",     jobIdStr)
makeServerRow(90, "SERVER LINK", linkStr)

-- Note under server link
local linkNote = Instance.new("TextLabel", serverContent)
linkNote.Size                  = UDim2.new(1, -16, 0, 14)
linkNote.Position              = UDim2.new(0, 6, 0, 128)
linkNote.BackgroundTransparency= 1
linkNote.Font                  = Enum.Font.Gotham
linkNote.TextSize              = 9
linkNote.TextColor3            = Color3.fromRGB(180, 160, 100)
linkNote.TextXAlignment        = Enum.TextXAlignment.Left
linkNote.TextWrapped           = true
linkNote.Text                  = "Note: Roblox may redirect to another server."

-- Section: Join Server
local jsHeader = Instance.new("TextLabel", serverContent)
jsHeader.Size                  = UDim2.new(1, -16, 0, 14)
jsHeader.Position              = UDim2.new(0, 6, 0, 150)
jsHeader.BackgroundTransparency= 1
jsHeader.Font                  = Enum.Font.GothamBold
jsHeader.TextSize              = 11
jsHeader.TextColor3            = Color3.fromRGB(120, 160, 255)
jsHeader.TextXAlignment        = Enum.TextXAlignment.Left
jsHeader.Text                  = "JOIN SERVER"

-- Place ID input
local joinPlaceLabel = Instance.new("TextLabel", serverContent)
joinPlaceLabel.Size                  = UDim2.new(1, -16, 0, 12)
joinPlaceLabel.Position              = UDim2.new(0, 6, 0, 166)
joinPlaceLabel.BackgroundTransparency= 1
joinPlaceLabel.Font                  = Enum.Font.GothamBold
joinPlaceLabel.TextSize              = 10
joinPlaceLabel.TextColor3            = Color3.fromRGB(160, 162, 170)
joinPlaceLabel.TextXAlignment        = Enum.TextXAlignment.Left
joinPlaceLabel.Text                  = "PLACE ID"

local joinPlaceBox = Instance.new("TextBox", serverContent)
joinPlaceBox.Size             = UDim2.new(1, -18, 0, 20)
joinPlaceBox.Position         = UDim2.new(0, 6, 0, 178)
joinPlaceBox.BackgroundColor3 = Color3.fromRGB(28, 30, 36)
joinPlaceBox.BorderSizePixel  = 0
joinPlaceBox.Font             = Enum.Font.Code
joinPlaceBox.TextSize         = 11
joinPlaceBox.TextColor3       = Color3.fromRGB(225, 226, 232)
joinPlaceBox.PlaceholderText  = "e.g. 920587237"
joinPlaceBox.PlaceholderColor3= Color3.fromRGB(120, 122, 130)
joinPlaceBox.Text             = ""
joinPlaceBox.ClearTextOnFocus = false
joinPlaceBox.TextXAlignment   = Enum.TextXAlignment.Left
local jpPad = Instance.new("UIPadding", joinPlaceBox)
jpPad.PaddingLeft = UDim.new(0, 8)
Instance.new("UICorner", joinPlaceBox).CornerRadius = UDim.new(0, 5)

-- Job ID input
local joinJobLabel = Instance.new("TextLabel", serverContent)
joinJobLabel.Size                  = UDim2.new(1, -16, 0, 12)
joinJobLabel.Position              = UDim2.new(0, 6, 0, 202)
joinJobLabel.BackgroundTransparency= 1
joinJobLabel.Font                  = Enum.Font.GothamBold
joinJobLabel.TextSize              = 10
joinJobLabel.TextColor3            = Color3.fromRGB(160, 162, 170)
joinJobLabel.TextXAlignment        = Enum.TextXAlignment.Left
joinJobLabel.Text                  = "JOB ID"

local joinJobBox = Instance.new("TextBox", serverContent)
joinJobBox.Size             = UDim2.new(1, -18, 0, 20)
joinJobBox.Position         = UDim2.new(0, 6, 0, 214)
joinJobBox.BackgroundColor3 = Color3.fromRGB(28, 30, 36)
joinJobBox.BorderSizePixel  = 0
joinJobBox.Font             = Enum.Font.Code
joinJobBox.TextSize         = 11
joinJobBox.TextColor3       = Color3.fromRGB(225, 226, 232)
joinJobBox.PlaceholderText  = "server instance id"
joinJobBox.PlaceholderColor3= Color3.fromRGB(120, 122, 130)
joinJobBox.Text             = ""
joinJobBox.ClearTextOnFocus = false
joinJobBox.TextXAlignment   = Enum.TextXAlignment.Left
local jjPad = Instance.new("UIPadding", joinJobBox)
jjPad.PaddingLeft = UDim.new(0, 8)
Instance.new("UICorner", joinJobBox).CornerRadius = UDim.new(0, 5)

-- Join button + status
local joinStatus = Instance.new("TextLabel", serverContent)
joinStatus.Size                  = UDim2.new(1, -100, 0, 20)
joinStatus.Position              = UDim2.new(0, 6, 0, 240)
joinStatus.BackgroundTransparency= 1
joinStatus.Font                  = Enum.Font.Gotham
joinStatus.TextSize              = 10
joinStatus.TextColor3            = Color3.fromRGB(160, 162, 170)
joinStatus.TextXAlignment        = Enum.TextXAlignment.Left
joinStatus.Text                  = ""

local joinBtn = Instance.new("TextButton", serverContent)
joinBtn.Size             = UDim2.new(0, 88, 0, 20)
joinBtn.Position         = UDim2.new(1, -94, 0, 240)
joinBtn.BackgroundColor3 = Color3.fromRGB(46, 90, 60)
joinBtn.BorderSizePixel  = 0
joinBtn.Font             = Enum.Font.GothamBold
joinBtn.TextSize         = 11
joinBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
joinBtn.AutoButtonColor  = true
joinBtn.Text             = "Join Server"
Instance.new("UICorner", joinBtn).CornerRadius = UDim.new(0, 5)

track(joinBtn.MouseButton1Click:Connect(function()
    local pidRaw = joinPlaceBox.Text
    local jidRaw = joinJobBox.Text

    local pid = tonumber(pidRaw)
    if not pid or pid <= 0 then
        joinStatus.Text = "Invalid Place ID"
        joinStatus.TextColor3 = Color3.fromRGB(255, 140, 140)
        notify("Invalid Place ID", Color3.fromRGB(255, 140, 140))
        return
    end
    if jidRaw == "" or string.len(jidRaw) < 1 then
        joinStatus.Text = "Job ID required"
        joinStatus.TextColor3 = Color3.fromRGB(255, 140, 140)
        notify("Job ID required", Color3.fromRGB(255, 140, 140))
        return
    end

    joinStatus.Text = "Joining..."
    joinStatus.TextColor3 = Color3.fromRGB(140, 200, 255)
    notify("Joining server...", Color3.fromRGB(140, 200, 255))

    queueScript()

    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(pid, jidRaw, player)
    end)

    if not ok then
        joinStatus.Text = "Failed: " .. tostring(err):sub(1, 40)
        joinStatus.TextColor3 = Color3.fromRGB(255, 140, 140)
        notify("Join failed: " .. tostring(err):sub(1, 50), Color3.fromRGB(255, 140, 140))
    else
        joinStatus.Text = "Teleporting..."
        joinStatus.TextColor3 = Color3.fromRGB(140, 230, 160)
        notify("Teleporting...", Color3.fromRGB(140, 230, 160))
    end
end))

--// ─────────────── Section: Server Management ───────────────
local smHeader = Instance.new("TextLabel", serverContent)
smHeader.Size                  = UDim2.new(1, -16, 0, 14)
smHeader.Position              = UDim2.new(0, 6, 0, 270)
smHeader.BackgroundTransparency= 1
smHeader.Font                  = Enum.Font.GothamBold
smHeader.TextSize              = 11
smHeader.TextColor3            = Color3.fromRGB(120, 160, 255)
smHeader.TextXAlignment        = Enum.TextXAlignment.Left
smHeader.Text                  = "SERVER MANAGEMENT"

-- Helper to create a full-width action button
local function makeActionBtn(y, text, color)
    local btn = Instance.new("TextButton", serverContent)
    btn.Size             = UDim2.new(1, -18, 0, 26)
    btn.Position         = UDim2.new(0, 6, 0, y)
    btn.BackgroundColor3 = color
    btn.BorderSizePixel  = 0
    btn.Font             = Enum.Font.GothamBold
    btn.TextSize         = 12
    btn.TextColor3       = Color3.fromRGB(255, 255, 255)
    btn.AutoButtonColor  = true
    btn.Text             = text
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
    return btn
end

-- Rejoin button
local rejoinBtn = makeActionBtn(290, "Rejoin Current Server", Color3.fromRGB(50, 70, 110))

track(rejoinBtn.MouseButton1Click:Connect(function()
    local pid = game.PlaceId
    local jid = game.JobId
    if jid == "" then
        notify("No server to rejoin (singleplayer)", Color3.fromRGB(255, 140, 140))
        return
    end

    rejoinBtn.Text = "Rejoining..."
    rejoinBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
    notify("Rejoining current server...", Color3.fromRGB(140, 200, 255))

    queueScript()

    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(pid, jid, player)
    end)

    if not ok then
        rejoinBtn.Text = "Rejoin Current Server"
        rejoinBtn.BackgroundColor3 = Color3.fromRGB(50, 70, 110)
        notify("Rejoin failed: " .. tostring(err):sub(1, 50), Color3.fromRGB(255, 140, 140))
    else
        notify("Teleporting to current server...", Color3.fromRGB(140, 230, 160))
    end
end))

-- Server Hop button
local hopBtn = makeActionBtn(322, "Server Hop", Color3.fromRGB(70, 90, 50))

track(hopBtn.MouseButton1Click:Connect(function()
    local pid = game.PlaceId
    local currentJid = game.JobId

    hopBtn.Text = "Searching..."
    hopBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
    notify("Searching for another server...", Color3.fromRGB(140, 200, 255))

    task.spawn(function()
        local servers, err = fetchServers(pid, 5)
        local target = nil

        if not err and #servers > 0 then
            for _, s in ipairs(servers) do
                -- Roblox API uses "id", "playing", "maxPlayers" (some use playerCapacity)
                local sId = s.id or s.Id
                local sPlaying = tonumber(s.playing) or tonumber(s.Playing) or 0
                local sMax = tonumber(s.maxPlayers) or tonumber(s.MaxPlayers) or tonumber(s.playerCapacity) or 100
                if sId and sId ~= currentJid and sPlaying < sMax then
                    target = { id = sId, playing = sPlaying }
                    break
                end
            end
        end

        if not target then
            hopBtn.Text = "Server Hop"
            hopBtn.BackgroundColor3 = Color3.fromRGB(70, 90, 50)
            if err then
                notify("Error: " .. err, Color3.fromRGB(255, 140, 140))
            elseif #servers == 0 then
                notify("No servers returned by API", Color3.fromRGB(255, 140, 140))
            else
                notify("No other available server found", Color3.fromRGB(255, 140, 140))
            end
            return
        end

        hopBtn.Text = "Joining..."
        notify("Joining server (" .. target.playing .. " players)...", Color3.fromRGB(140, 200, 255))

        queueScript()

        local ok, err2 = pcall(function()
            TeleportService:TeleportToPlaceInstance(pid, target.id, player)
        end)

        if not ok then
            hopBtn.Text = "Server Hop"
            hopBtn.BackgroundColor3 = Color3.fromRGB(70, 90, 50)
            notify("Server hop failed: " .. tostring(err2):sub(1, 50), Color3.fromRGB(255, 140, 140))
        else
            notify("Teleporting to new server...", Color3.fromRGB(140, 230, 160))
        end
    end)
end))

-- Smallest Server button
local smallestBtn = makeActionBtn(354, "Join Smallest Server", Color3.fromRGB(90, 70, 50))

track(smallestBtn.MouseButton1Click:Connect(function()
    local pid = game.PlaceId
    local currentJid = game.JobId

    smallestBtn.Text = "Searching all pages..."
    smallestBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
    notify("Fetching server list (this may take a moment)...", Color3.fromRGB(140, 200, 255))

    task.spawn(function()
        -- Fetch up to 10 pages to find the truly smallest server
        local servers, err = fetchServers(pid, 10)
        local smallest = nil
        local smallestCount = math.huge

        if not err and #servers > 0 then
            for _, s in ipairs(servers) do
                -- Handle different field name casings
                local sId = s.id or s.Id
                local sPlaying = tonumber(s.playing) or tonumber(s.Playing) or 0
                local sMax = tonumber(s.maxPlayers) or tonumber(s.MaxPlayers) or tonumber(s.playerCapacity) or 100
                -- Skip current server, full servers, and unavailable servers
                if sId and sId ~= currentJid and sPlaying < sMax and sPlaying >= 0 then
                    if sPlaying < smallestCount then
                        smallestCount = sPlaying
                        smallest = { id = sId, playing = sPlaying }
                    end
                end
            end
        end

        if not smallest then
            smallestBtn.Text = "Join Smallest Server"
            smallestBtn.BackgroundColor3 = Color3.fromRGB(90, 70, 50)
            if err then
                notify("Error: " .. err, Color3.fromRGB(255, 140, 140))
            elseif #servers == 0 then
                notify("No servers returned by API", Color3.fromRGB(255, 140, 140))
            else
                notify("No suitable server found after checking all pages", Color3.fromRGB(255, 140, 140))
            end
            return
        end

        smallestBtn.Text = "Joining..."
        notify("Joining smallest server (" .. smallest.playing .. " players)...", Color3.fromRGB(140, 200, 255))

        queueScript()

        local ok, err2 = pcall(function()
            TeleportService:TeleportToPlaceInstance(pid, smallest.id, player)
        end)

        if not ok then
            smallestBtn.Text = "Join Smallest Server"
            smallestBtn.BackgroundColor3 = Color3.fromRGB(90, 70, 50)
            notify("Join failed: " .. tostring(err2):sub(1, 50), Color3.fromRGB(255, 140, 140))
        else
            notify("Teleporting to smallest server...", Color3.fromRGB(140, 230, 160))
        end
    end)
end))

-- Set server scroll canvas to fit all content (smallest button ends at y=380)
serverScroll.CanvasSize = UDim2.new(0, 0, 0, 390)

--// ─────────────── Tab switching ───────────────
local function showTab(tabName)
    if tabName == "Main" then
        mainView.Visible = true
        logsView.Visible = false
        serverView.Visible = false
        infoView.Visible = false
        paintTab(mainBtn, true)
        paintTab(logsBtn, false)
        paintTab(serverBtn, false)
        paintTab(infoBtn, false)
    elseif tabName == "Logs" then
        mainView.Visible = false
        logsView.Visible = true
        serverView.Visible = false
        infoView.Visible = false
        paintTab(mainBtn, false)
        paintTab(logsBtn, true)
        paintTab(serverBtn, false)
        paintTab(infoBtn, false)
    elseif tabName == "Server" then
        mainView.Visible = false
        logsView.Visible = false
        serverView.Visible = true
        infoView.Visible = false
        paintTab(mainBtn, false)
        paintTab(logsBtn, false)
        paintTab(serverBtn, true)
        paintTab(infoBtn, false)
    elseif tabName == "Info" then
        mainView.Visible = false
        logsView.Visible = false
        serverView.Visible = false
        infoView.Visible = true
        paintTab(mainBtn, false)
        paintTab(logsBtn, false)
        paintTab(serverBtn, false)
        paintTab(infoBtn, true)
    end
    activeTab = tabName
end

track(mainBtn.MouseButton1Click:Connect(function() showTab("Main") end))
track(logsBtn.MouseButton1Click:Connect(function() showTab("Logs") end))
track(serverBtn.MouseButton1Click:Connect(function() showTab("Server") end))
track(infoBtn.MouseButton1Click:Connect(function() showTab("Info") end))
showTab("Main")

--// ─────────────── Unload logic ───────────────
local function unload()
    if unloaded then return end
    unloaded = true

    -- Save current panel position before destroying
    if frame then
        local pos = frame.Position
        settings.panelPos = {
            x   = pos.X.Offset,
            y   = pos.Y.Scale,
            oy  = pos.Y.Offset,
        }
        saveSettings(settings)
    end

    -- Un-freeze if needed (just un-anchor, don't touch WalkSpeed)
    if frozen and player.Character then
        local hrp = player.Character:FindFirstChild("HumanoidRootPart")
        if hrp then hrp.Anchored = false end
    end
    frozen = false
    lockedCFrame = nil

    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    connections = {}

    if screen and screen.Parent then
        screen:Destroy()
    end

    -- Clear global reference so future re-executions know we're gone
    if getgenv then
        getgenv().AfkTrackerUnload = nil
    end
end

track(unloadBtn.MouseButton1Click:Connect(unload))

-- Register unload in getgenv so future re-executions can clean us up
if getgenv then
    getgenv().AfkTrackerUnload = unload
end

--// ─────────────── Helpers ───────────────
local function fmt(seconds)
    seconds = math.max(0, math.floor(seconds))
    return string.format("%d:%02d:%02d",
        math.floor(seconds / 3600),
        math.floor((seconds % 3600) / 60),
        seconds % 60)
end

local function bump()
    lastInput    = tick()
    afkStartTick = nil
end

--// ─────────────── Input detection (mouse MOVE ignored) ───────────────
track(UIS.InputBegan:Connect(function(input, gpe)
    if unloaded then return end

    local t = input.UserInputType
    local isRealInput = (
        t == Enum.UserInputType.Keyboard
        or t == Enum.UserInputType.MouseButton1
        or t == Enum.UserInputType.MouseButton2
        or t == Enum.UserInputType.MouseButton3
        or t == Enum.UserInputType.Touch
        or t == Enum.UserInputType.Gamepad1
        or t == Enum.UserInputType.Gamepad2
        or t == Enum.UserInputType.Gamepad3
        or t == Enum.UserInputType.Gamepad4
    )
    if isRealInput then
        bump()
    end

    -- RightShift toggles panel (PC mode; mobile uses the Hide button)
    if platform == "PC"
    and input.KeyCode == TOGGLE_KEY
    and not UIS:GetFocusedTextBox() then
        setPanelVisible(not panelVisible)
    end
end))

track(UIS.InputChanged:Connect(function(input, gpe)
    if unloaded then return end
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseWheel
    or t == Enum.UserInputType.Touch then
        bump()
    end
end))

--// ─────────────── Anti-AFK (VirtualUser on player.Idled) ───────────────
track(player.Idled:Connect(function()
    if unloaded or not antiAfkEnabled then return end
    local cam = workspace.CurrentCamera
    if not cam then return end

    local fireTime = tick()
    VirtualUser:Button2Down(Vector2.zero, cam.CFrame)
    task.wait(1)
    VirtualUser:Button2Up(Vector2.zero, cam.CFrame)

    addLogEntry(fireTime)
end))

--// ─────────────── Dragging (main panel) ───────────────
local dragging, dragStart, startPos
track(frame.InputBegan:Connect(function(input)
    if unloaded then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        dragging  = true
        dragStart = input.Position
        startPos  = frame.Position
        bump()
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end))

track(UIS.InputChanged:Connect(function(input)
    if unloaded or not dragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
    or input.UserInputType == Enum.UserInputType.Touch then
        local d = input.Position - dragStart
        frame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + d.X,
            startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end))

--// ─────────────── Dragging (floating button) ───────────────
local fDragging, fDragStart, fStartPos
track(floatBtn.InputBegan:Connect(function(input)
    if unloaded then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        fDragging  = true
        fDragStart = input.Position
        fStartPos  = floatBtn.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                fDragging = false
            end
        end)
    end
end))

track(UIS.InputChanged:Connect(function(input)
    if unloaded or not fDragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
    or input.UserInputType == Enum.UserInputType.Touch then
        local d = input.Position - fDragStart
        floatBtn.Position = UDim2.new(
            fStartPos.X.Scale, fStartPos.X.Offset + d.X,
            fStartPos.Y.Scale, fStartPos.Y.Offset + d.Y)
    end
end))

--// ─────────────── Update loop ───────────────
local lastLogRefresh = 0
track(Run.Heartbeat:Connect(function()
    if unloaded then return end
    local now = tick()

    -- Injected time uses os.time() (real-world clock) for persistence across re-execs
    inGameLbl.Text = "Injected since: " .. fmt(os.time() - gameJoinTime)

    local since = now - lastInput
    if since < 1 then
        lastInputLbl.Text = "Last input: now"
    elseif since < 60 then
        lastInputLbl.Text = string.format("Last input: %ds ago", math.floor(since))
    else
        lastInputLbl.Text = "Last input: " .. fmt(since) .. " ago"
    end

    if since >= AFK_THRESHOLD then
        if afkStartTick == nil then afkStartTick = lastInput end
        afkLbl.Text       = "AFK for: " .. fmt(now - afkStartTick)
        afkLbl.TextColor3 = Color3.fromRGB(255, 140, 140)
    else
        afkLbl.Text       = "AFK for: 0:00:00"
        afkLbl.TextColor3 = Color3.fromRGB(140, 230, 160)
    end

    if now - lastLogRefresh >= 1 then
        lastLogRefresh = now
        for _, entry in ipairs(logEntries) do
            if entry.label and entry.label.Parent then
                local ago = now - entry.timestamp
                if ago < 1 then
                    entry.label.Text = "Sent right click: just now"
                else
                    entry.label.Text = "Sent right click: " .. fmt(ago) .. " ago"
                end
            end
        end
    end
end))
