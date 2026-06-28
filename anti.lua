--[[ ============================================================
    Session & AFK Tracker  -  Executor UI
    ------------------------------------------------------------
    Sidebar UI with two tabs:
      - Main  : in-game time, last input, AFK timer,
                Anti-AFK toggle, Freeze toggle
      - Logs  : scrolling log of every anti-AFK right-click,
                each entry shows "Sent right click: just now"
                and then counts up every second

    Freeze toggle:
      - Anchors HumanoidRootPart (no movement, no knockback,
        no physics interaction at all)
      - Zeros WalkSpeed as a backup
      - Re-applies automatically on respawn

    - Mouse MOVEMENT is ignored (you can wiggle freely)
    - Built-in anti-AFK (VirtualUser Button2 on player.Idled)
    - Press RightShift to hide / show the panel
    - Unload button on sidebar fully tears everything down
    - No console output
--============================================================ ]]

--// ─────────────── Config ───────────────
local AFK_THRESHOLD = 5
local TOGGLE_KEY    = Enum.KeyCode.RightShift   -- hide / show panel
local MAX_LOGS      = 100

--// ─────────────── Services ───────────────
local Players     = game:GetService("Players")
local UIS         = game:GetService("UserInputService")
local Run         = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local player      = Players.LocalPlayer
local gui         = player:WaitForChild("PlayerGui")

--// ─────────────── State ───────────────
local scriptStart    = tick()
local lastInput      = tick()
local afkStartTick   = nil
local antiAfkEnabled = true
local frozen         = false
local savedWalkSpeed = nil
local unloaded       = false

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
frame.Size             = UDim2.new(0, 320, 0, 180)
frame.Position         = UDim2.new(0, 16, 0.5, -90)
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

local mainBtn = makeTabBtn("MainTab", "Main", 30)
local logsBtn = makeTabBtn("LogsTab", "Logs", 64)
local infoBtn = makeTabBtn("InfoTab", "Info", 98)

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
paintTab(infoBtn, false)

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
-- Maximum freeze: anchors HRP, zeros WalkSpeed, AND runs a Stepped hook
-- that force-resets the HRP CFrame every frame.
--
-- The Stepped lock is what resists "drag" abilities that move you via
-- CFrame (teleport-style knockback). Anchoring alone won't stop those
-- because the drag script sets CFrame directly. By re-applying our
-- locked CFrame on every Stepped (which fires BEFORE physics each frame),
-- we overwrite whatever the drag set.
--
-- Note: we do NOT touch JumpPower/JumpHeight/Jumping state. Anchoring
-- already prevents jumping (jump = physics force, anchored parts ignore
-- all physics forces), and messing with those values breaks jumping
-- after unfreezing on games that use custom jump systems.
local lockedCFrame = nil

local function applyFreezeToCharacter(char)
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hrp then return end

    if frozen then
        if hum and savedWalkSpeed == nil then
            savedWalkSpeed = hum.WalkSpeed
        end
        hrp.Anchored = true
        if hum then hum.WalkSpeed = 0 end
        -- Capture the locked position the moment freeze turns on
        lockedCFrame = hrp.CFrame
    else
        hrp.Anchored = false
        lockedCFrame = nil
        if hum and savedWalkSpeed ~= nil then
            hum.WalkSpeed = savedWalkSpeed
        end
    end
end

-- Stepped hook: fires every frame BEFORE physics step.
-- If anything dragged our HRP via CFrame since last frame, this restores it.
-- This is what makes the freeze resist mob drag abilities.
track(Run.Stepped:Connect(function()
    if unloaded or not frozen then return end
    local char = player.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp or not lockedCFrame then return end

    -- Re-anchor (in case a game un-anchored it) and force CFrame back
    if not hrp.Anchored then hrp.Anchored = true end
    hrp.CFrame = lockedCFrame

    -- Also kill any velocity the drag may have imparted
    hrp.AssemblyLinearVelocity  = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
end))

local function setFrozen(state)
    frozen = state
    -- Reset saved WalkSpeed when turning off so we re-capture next time
    if not frozen then
        savedWalkSpeed = nil
    end
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
    -- Wait for the character's HRP to exist before anchoring
    local hrp = char:WaitForChild("HumanoidRootPart", 5)
    if hrp then
        task.wait(0.1)  -- let other CharacterAdded handlers settle
        if frozen and not unloaded then
            applyFreezeToCharacter(char)
        end
    end
end))

-- Apply to current character if it already exists
if player.Character then
    applyFreezeToCharacter(player.Character)
end

--// ─────────────── Stat lines (shifted down to fit Freeze button) ───────────────
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

local inGameLbl    = makeLine(58)
local lastInputLbl = makeLine(82)
local afkLbl       = makeLine(106)

-- Footer hint
local hintLbl = Instance.new("TextLabel", mainView)
hintLbl.Size                  = UDim2.new(1, -24, 0, 18)
hintLbl.Position              = UDim2.new(0, 14, 1, -22)
hintLbl.BackgroundTransparency= 1
hintLbl.Font                  = Enum.Font.Gotham
hintLbl.TextSize              = 10
hintLbl.TextColor3            = Color3.fromRGB(140, 142, 150)
hintLbl.TextXAlignment        = Enum.TextXAlignment.Left
hintLbl.Text                  = "RightShift to hide/show"

--// ─────────────── Logs view ───────────────
local logsView = Instance.new("Frame", frame)
logsView.Name             = "LogsView"
logsView.Size             = UDim2.new(1, -SIDEBAR_W, 1, 0)
logsView.Position         = UDim2.new(0, SIDEBAR_W, 0, 0)
logsView.BackgroundTransparency = 1
logsView.Visible          = false

local logsTitle = Instance.new("TextLabel", logsView)
logsTitle.Size                  = UDim2.new(1, -24, 0, 24)
logsTitle.Position              = UDim2.new(0, 12, 0, 6)
logsTitle.BackgroundTransparency= 1
logsTitle.Font                  = Enum.Font.GothamBold
logsTitle.TextSize              = 14
logsTitle.TextColor3            = Color3.fromRGB(255, 255, 255)
logsTitle.TextXAlignment        = Enum.TextXAlignment.Left
logsTitle.Text                  = "Anti-AFK Logs"

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
scroll.AutomaticCanvasSize         = Enum.AutomaticSize.Y
scroll.ScrollingDirection          = Enum.ScrollingDirection.Y

local listLayout = Instance.new("UIListLayout", scroll)
listLayout.SortOrder         = Enum.SortOrder.LayoutOrder
listLayout.Padding           = UDim.new(0, 4)
listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

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
    { text = "The Freeze feature anchors your character.", color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
    { text = "If the game has an anti-cheat, this may",     color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
    { text = "get you kicked. Use with caution.",           color = Color3.fromRGB(225, 226, 232), bold = false, size = 11 },
}

local infoY = 34
for _, line in ipairs(infoLines) do
    local lbl = Instance.new("TextLabel", infoView)
    lbl.Size                  = UDim2.new(1, -24, 0, line.size + 6)
    lbl.Position              = UDim2.new(0, 14, 0, infoY)
    lbl.BackgroundTransparency= 1
    lbl.Font                  = line.bold and Enum.Font.GothamBold or Enum.Font.Gotham
    lbl.TextSize              = line.size
    lbl.TextColor3            = line.color
    lbl.TextXAlignment        = Enum.TextXAlignment.Left
    lbl.TextYAlignment        = Enum.TextYAlignment.Center
    lbl.Text                  = line.text
    infoY = infoY + line.size + 6
end

--// ─────────────── Tab switching ───────────────
local function showTab(tabName)
    if tabName == "Main" then
        mainView.Visible = true
        logsView.Visible = false
        infoView.Visible = false
        paintTab(mainBtn, true)
        paintTab(logsBtn, false)
        paintTab(infoBtn, false)
    elseif tabName == "Logs" then
        mainView.Visible = false
        logsView.Visible = true
        infoView.Visible = false
        paintTab(mainBtn, false)
        paintTab(logsBtn, true)
        paintTab(infoBtn, false)
    elseif tabName == "Info" then
        mainView.Visible = false
        logsView.Visible = false
        infoView.Visible = true
        paintTab(mainBtn, false)
        paintTab(logsBtn, false)
        paintTab(infoBtn, true)
    end
    activeTab = tabName
end

track(mainBtn.MouseButton1Click:Connect(function() showTab("Main") end))
track(logsBtn.MouseButton1Click:Connect(function() showTab("Logs") end))
track(infoBtn.MouseButton1Click:Connect(function() showTab("Info") end))
showTab("Main")

--// ─────────────── Unload logic ───────────────
local function unload()
    if unloaded then return end
    unloaded = true

    -- If frozen, fully un-freeze so the player isn't stuck after unload
    if frozen and player.Character then
        local hrp = player.Character:FindFirstChild("HumanoidRootPart")
        if hrp then hrp.Anchored = false end
        local hum = player.Character:FindFirstChildOfClass("Humanoid")
        if hum and savedWalkSpeed ~= nil then
            hum.WalkSpeed = savedWalkSpeed
        end
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
end

track(unloadBtn.MouseButton1Click:Connect(unload))

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

    if input.KeyCode == TOGGLE_KEY and not UIS:GetFocusedTextBox() then
        frame.Visible = not frame.Visible
    end
end))

track(UIS.InputChanged:Connect(function(input, gpe)
    if unloaded then return end
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseWheel
    or t == Enum.UserInputType.Touch
    or t == Enum.UserInputType.GamepadAxis then
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

--// ─────────────── Dragging ───────────────
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

--// ─────────────── Update loop ───────────────
local lastLogRefresh = 0
track(Run.Heartbeat:Connect(function()
    if unloaded then return end
    local now = tick()

    inGameLbl.Text = "In-game: " .. fmt(now - scriptStart)

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
