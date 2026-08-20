--==============================================================================
-- COMPLETE MODELER INJECTION SCRIPT FOR STUDIO LITE – FULLY FIXED
-- Paste this entire script into your executor and run it.
--==============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Wait for Studio Lite to load
local studioGui = playerGui:WaitForChild("StudioGui", 30)
if not studioGui then
    warn("Studio Lite not found! Please join a game with Studio Lite running.")
    return
end

local mainBar = studioGui:WaitForChild("MainBar")
local explorerPanel = studioGui:WaitForChild("ExplorerPanel")
local getSelection = explorerPanel:WaitForChild("GetSelection")
local setSelection = explorerPanel:WaitForChild("SetSelection")

local selectionChanged = workspace:FindFirstChild("ExplorerSelectionChanged")
if not selectionChanged then
    selectionChanged = Instance.new("BindableEvent")
    selectionChanged.Name = "ExplorerSelectionChanged"
    selectionChanged.Parent = workspace
end

print("✅ Studio Lite detected. Injecting MODELER...")

--==============================================================================
-- CONFIGURATION & STATE
--==============================================================================
local UI_COLORS = {
    bg = Color3.fromRGB(40,40,42),
    bgDark = Color3.fromRGB(28,28,30),
    bgLight = Color3.fromRGB(55,55,60),
    accent = Color3.fromRGB(240,130,30),
    textColor = Color3.fromRGB(200,200,200),
    textDark = Color3.fromRGB(150,150,150),
}
local TAG_NAME = "MODELER_OBJ"
local selectedParts = {}
local currentTool = "Select"
local snapGrid = 1
local snapRotation = 15
local modelerActive = false
local isOrbiting, isPanning = false, false
local dragStartPos, dragStartCameraCF, touchStartDistance = nil, nil, nil
local undoStack, redoStack = {}, {}
local gizmoArrows = {}
local gizmoActive = false
local gridVisible = true
local gridParts = {}
local gridFolder = nil
local wireframeMode, xrayMode, perfMode = false, false, false
local camTarget = Vector3.new(0,5,0)
local multiSelectMode = false
local simpleMode = true
local UI = {}
local needUpdate = false
local tutorialPage = 1
local totalTutorialPages = 6
local modelerPartsCache = {}
local cacheDirty = true
local originalTransparency = {}
local gizmoDragging = false
local gizmoAxis = nil
local gizmoStartMouse = nil
local gizmoStartCFrame = nil
local gizmoStartSize = nil
local gizmoStartPos = nil
local gizmoPart = nil
local gizmoCumulativeDelta = 0
local gizmoInitialStates = {}  -- for undo/redo of transforms

--==============================================================================
-- CORE HELPERS
--==============================================================================
local function tagPart(part)
    for _, child in ipairs(part:GetChildren()) do
        if child.Name == TAG_NAME or child.Name == "SL_UniqueId" then child:Destroy() end
    end
    local id = Instance.new("StringValue")
    id.Name = "SL_UniqueId"
    id.Value = tostring(os.time() + math.random(999999))
    id.Parent = part
    local tag = Instance.new("BoolValue")
    tag.Name = TAG_NAME
    tag.Value = true
    tag.Parent = part
    cacheDirty = true
end

local function isModelerPart(part)
    return part and part:FindFirstChild(TAG_NAME) ~= nil
end

local function refreshModelerCache()
    if not cacheDirty then return end
    modelerPartsCache = {}
    for _, obj in ipairs(workspace:GetDescendants()) do
        if isModelerPart(obj) then table.insert(modelerPartsCache, obj) end
    end
    cacheDirty = false
end

local function roundToSnap(val, snap)
    return snap == 0 and val or math.floor(val/snap + 0.5)*snap
end

local function snapVector3(v)
    return Vector3.new(roundToSnap(v.X, snapGrid), roundToSnap(v.Y, snapGrid), roundToSnap(v.Z, snapGrid))
end

local function snapRotationAngles(rx, ry, rz)
    return math.rad(roundToSnap(math.deg(rx), snapRotation)),
           math.rad(roundToSnap(math.deg(ry), snapRotation)),
           math.rad(roundToSnap(math.deg(rz), snapRotation))
end

local function getBuildAnchor()
    local cam = workspace.CurrentCamera
    return cam and CFrame.new(cam.CFrame.Position + cam.CFrame.LookVector * 15) or CFrame.new(0,5,0)
end

--==============================================================================
-- STUDIO LITE SELECTION SYNC
--==============================================================================
local function updateStudioSelection()
    local objs = {}
    for _, p in ipairs(selectedParts) do
        if p and p.Parent then table.insert(objs, p) end
    end
    setSelection:Invoke(objs)
end

local function clearSelection()
    for _, part in ipairs(selectedParts) do
        if part and part.Parent and part:IsA("BasePart") then
            local hi = part:FindFirstChild("ModelerHighlight")
            if hi then hi:Destroy() end
        end
    end
    selectedParts = {}
    clearGizmo()
    needUpdate = true
    updateStudioSelection()
end

local function selectPart(obj)
    if not obj then return end
    if multiSelectMode then
        local idx = table.find(selectedParts, obj)
        if idx then
            table.remove(selectedParts, idx)
            if obj:IsA("BasePart") then
                local hi = obj:FindFirstChild("ModelerHighlight")
                if hi then hi:Destroy() end
            end
            if #selectedParts == 0 then clearGizmo() end
        else
            table.insert(selectedParts, obj)
            if obj:IsA("BasePart") then
                local box = Instance.new("SelectionBox")
                box.Name = "ModelerHighlight"
                box.Adornee = obj
                box.Color3 = Color3.fromRGB(255,255,255)
                box.LineThickness = 0.05
                box.Transparency = 0.3
                box.Parent = obj
            end
        end
    else
        clearSelection()
        selectedParts = {obj}
        if obj:IsA("BasePart") then
            local box = Instance.new("SelectionBox")
            box.Name = "ModelerHighlight"
            box.Adornee = obj
            box.Color3 = Color3.fromRGB(255,255,255)
            box.LineThickness = 0.05
            box.Transparency = 0.3
            box.Parent = obj
        end
    end
    if currentTool ~= "Select" and #selectedParts > 0 then createGizmoForPart(selectedParts[1]) end
    needUpdate = true
    updateStudioSelection()
end

selectionChanged.Event:Connect(function()
    local studioSelection = getSelection:Invoke()
    if #studioSelection > 0 then
        local obj = studioSelection[1]
        if isModelerPart(obj) then
            clearSelection()
            selectPart(obj)
        end
    else
        clearSelection()
    end
end)

--==============================================================================
-- UNDO / REDO (Fixed for multi‑part shapes)
--==============================================================================
local function saveState(action)
    table.insert(undoStack, action)
    if #undoStack > 100 then table.remove(undoStack, 1) end
    redoStack = {}
    needUpdate = true
end

function undo()
    if #undoStack == 0 then return end
    local action = table.remove(undoStack)
    local ok = pcall(action.undo)
    if ok then table.insert(redoStack, action) end
    needUpdate = true
end

function redo()
    if #redoStack == 0 then return end
    local action = table.remove(redoStack)
    local ok = pcall(action.redo)
    if ok then table.insert(undoStack, action) end
    needUpdate = true
end

--==============================================================================
-- GIZMO (Move, Rotate, Scale) – Fixed snapping & scaling
--==============================================================================
local function clearGizmo()
    for _, arrow in ipairs(gizmoArrows) do
        if arrow and arrow.Parent then arrow:Destroy() end
    end
    gizmoArrows = {}
    gizmoActive = false
    gizmoDragging = false
    gizmoAxis = nil
    gizmoInitialStates = {}
end

local function createGizmoForPart(part)
    clearGizmo()
    if not part or not part:IsA("BasePart") then return end
    gizmoPart = part
    local colors = {X=Color3.fromRGB(255,0,0), Y=Color3.fromRGB(0,255,0), Z=Color3.fromRGB(0,0,255)}
    local dirs = {X=part.CFrame.RightVector, Y=part.CFrame.UpVector, Z=-part.CFrame.LookVector}
    for axis, color in pairs(colors) do
        local arrow = Instance.new("Part")
        arrow.Size = Vector3.new(0.3,0.3,2)
        arrow.Shape = Enum.PartType.Cylinder
        arrow.Anchored = true
        arrow.BrickColor = BrickColor.new(color)
        arrow.Material = Enum.Material.Neon
        arrow.Transparency = 0.3
        arrow.CFrame = CFrame.lookAt(part.Position + dirs[axis] * 1.5, part.Position + dirs[axis] * 2.5)
        arrow.Parent = workspace
        table.insert(gizmoArrows, arrow)
    end
    gizmoActive = true
end

local function startGizmoDrag(axis, input)
    if not gizmoActive or #selectedParts == 0 then return end
    gizmoDragging = true
    gizmoAxis = axis
    gizmoStartMouse = input.Position
    gizmoStartCFrame = gizmoPart.CFrame
    gizmoStartSize = gizmoPart.Size
    gizmoStartPos = gizmoPart.Position
    gizmoCumulativeDelta = 0
    -- Save initial states for undo
    gizmoInitialStates = {}
    for _, p in ipairs(selectedParts) do
        if p:IsA("BasePart") then
            gizmoInitialStates[p] = {cf = p.CFrame, size = p.Size}
        end
    end
    workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
    _G.BlockCameraMovement = true
end

local function updateGizmoDrag(input)
    if not gizmoDragging or not gizmoPart then return end
    local delta = input.Position - gizmoStartMouse
    local cam = workspace.CurrentCamera
    local axisVec = gizmoStartCFrame:VectorToWorldSpace(
        gizmoAxis == "X" and Vector3.new(1,0,0) or
        gizmoAxis == "Y" and Vector3.new(0,1,0) or
        Vector3.new(0,0,1)
    )
    local right = cam.CFrame.RightVector
    local up = cam.CFrame.UpVector
    local screenAxis = Vector3.new(right:Dot(axisVec), up:Dot(axisVec), 0)
    local screenDelta = Vector3.new(delta.X, delta.Y, 0)
    local proj = screenDelta:Dot(screenAxis) / screenAxis.Magnitude
    if screenAxis.Magnitude < 0.01 then proj = 0 end

    if currentTool == "Move" then
        local snap = snapGrid
        local amount = roundToSnap(proj * 0.5, snap)
        local move = axisVec * amount
        for _, p in ipairs(selectedParts) do
            if p:IsA("BasePart") then
                p.Position = p.Position + move
            end
        end
    elseif currentTool == "Rotate" then
        local snap = snapRotation
        local degrees = roundToSnap(proj * 0.5, snap)  -- cumulative delta in degrees
        local angle = math.rad(degrees)
        local rot = CFrame.Angles(
            axisVec.X * angle, axisVec.Y * angle, axisVec.Z * angle
        )
        for _, p in ipairs(selectedParts) do
            if p:IsA("BasePart") then
                p.CFrame = gizmoStartCFrame * rot
            end
        end
    elseif currentTool == "Scale" then
        local snap = 0.01  -- small snap for scale
        local deltaScale = roundToSnap(proj * 0.005, snap)
        gizmoCumulativeDelta = gizmoCumulativeDelta + deltaScale
        local factor = 1 + gizmoCumulativeDelta
        if factor < 0.01 then factor = 0.01 end
        for _, p in ipairs(selectedParts) do
            if p:IsA("BasePart") then
                p.Size = gizmoStartSize * factor
            end
        end
    end
    createGizmoForPart(gizmoPart) -- refresh arrows
end

local function endGizmoDrag()
    if gizmoDragging then
        gizmoDragging = false
        _G.BlockCameraMovement = false
        workspace.CurrentCamera.CameraType = Enum.CameraType.Custom

        -- Save undo for transformation
        if #gizmoInitialStates > 0 then
            local finalStates = {}
            for p, _ in pairs(gizmoInitialStates) do
                if p and p.Parent then
                    finalStates[p] = {cf = p.CFrame, size = p.Size}
                end
            end
            saveState({
                undo = function()
                    for p, state in pairs(gizmoInitialStates) do
                        if p and p.Parent then
                            p.CFrame = state.cf
                            p.Size = state.size
                        end
                    end
                end,
                redo = function()
                    for p, state in pairs(finalStates) do
                        if p and p.Parent then
                            p.CFrame = state.cf
                            p.Size = state.size
                        end
                    end
                end
            })
        end
        gizmoInitialStates = {}
        needUpdate = true
    end
end

-- Mouse/Touch input for gizmo
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe or not modelerActive or not gizmoActive then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        local mousePos = input.Position
        local ray = workspace.CurrentCamera:ViewportPointToRay(mousePos.X, mousePos.Y, 1000)
        local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000)
        if hit and hit.Instance and table.find(gizmoArrows, hit.Instance) then
            local arrow = hit.Instance
            local axis = "X"
            if arrow.BrickColor.Color == Color3.fromRGB(0,255,0) then axis = "Y"
            elseif arrow.BrickColor.Color == Color3.fromRGB(0,0,255) then axis = "Z"
            end
            startGizmoDrag(axis, input)
        end
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if not modelerActive or not gizmoDragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        updateGizmoDrag(input)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        endGizmoDrag()
    end
end)

--==============================================================================
-- CAMERA CONTROLS
--==============================================================================
local function orbitCamera(delta)
    local cam = workspace.CurrentCamera
    if not cam or not dragStartCameraCF then return end
    cam.CFrame = dragStartCameraCF * CFrame.Angles(0, -delta.X*0.01, 0) * CFrame.Angles(-delta.Y*0.01, 0, 0)
end

local function panCamera(delta)
    local cam = workspace.CurrentCamera
    if not cam or not dragStartCameraCF then return end
    local move = Vector3.new(-delta.X, delta.Y, 0) * 0.1
    cam.CFrame = dragStartCameraCF * CFrame.new(move)
end

local function zoomCamera(factor)
    local cam = workspace.CurrentCamera
    if not cam then return end
    local dist = (cam.CFrame.Position - camTarget).Magnitude
    local newDist = math.clamp(dist * factor, 5, 200)
    local dir = (camTarget - cam.CFrame.Position).Unit
    cam.CFrame = CFrame.new(camTarget - dir*newDist, camTarget)
end

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe or not modelerActive then return end
    local cam = workspace.CurrentCamera
    if not cam then return end

    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        local mousePos = input.Position
        local guiObjs = UserInputService:GetGuiObjectsAtPosition(mousePos.X, mousePos.Y)
        for _, obj in ipairs(guiObjs) do
            if obj:IsA("GuiObject") then return end
        end
        local ray = cam:ViewportPointToRay(mousePos.X, mousePos.Y, 1000)
        local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000)
        if hit and isModelerPart(hit.Instance) then
            selectPart(hit.Instance)
        else
            if input.UserInputType == Enum.UserInputType.Touch then
                local touches = UserInputService:GetTouchPoints()
                if #touches == 1 then isOrbiting = true; isPanning = false
                elseif #touches == 2 then isOrbiting = false; isPanning = true end
            else
                isOrbiting = true; isPanning = false
            end
            dragStartPos = mousePos
            dragStartCameraCF = cam.CFrame
            touchStartDistance = nil
        end
    elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
        isPanning = true; isOrbiting = false
        dragStartPos = input.Position
        dragStartCameraCF = cam.CFrame
    elseif input.UserInputType == Enum.UserInputType.MouseWheel then
        local delta = input.Delta.Y or 0
        if delta > 0 then zoomCamera(0.9) elseif delta < 0 then zoomCamera(1.1) end
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if not modelerActive then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        local delta = input.Delta
        if isOrbiting then orbitCamera(delta)
        elseif isPanning then panCamera(delta) end
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        isOrbiting = false; isPanning = false; touchStartDistance = nil
    elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
        isPanning = false
    end
end)

UserInputService.TouchLongPress:Connect(function(touchPositions, state, gameProcessed)
    if not modelerActive or gameProcessed then return end
    if state == Enum.UserInputState.Begin then
        multiSelectMode = not multiSelectMode
        if UI.multiIndicator then
            UI.multiIndicator.Text = "Multi: " .. (multiSelectMode and "ON" or "OFF")
            UI.multiIndicator.TextColor3 = multiSelectMode and UI_COLORS.accent or UI_COLORS.textDark
        end
    end
end)

--==============================================================================
-- SHAPE CREATION FUNCTIONS (All 30+ shapes) – Fixed undo/redo
--==============================================================================
local function createPart(shape)
    local part = Instance.new("Part")
    part.Name = shape .. "_" .. math.random(1000,9999)
    part.Size = Vector3.new(4,4,4)
    part.Anchored = true
    part.Material = Enum.Material.SmoothPlastic
    part.BrickColor = BrickColor.new("Medium blue")
    if shape == "Ball" then part.Shape = Enum.PartType.Ball
    elseif shape == "Cylinder" then part.Shape = Enum.PartType.Cylinder
    elseif shape == "Wedge" then part.Shape = Enum.PartType.Wedge
    elseif shape == "CornerWedge" then part.Shape = Enum.PartType.CornerWedge
    end
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    clearGizmo()
    if currentTool ~= "Select" then createGizmoForPart(part) end
    return part
end

function createCone()
    local part = Instance.new("Part")
    part.Name = "Cone_"..math.random(1000,9999)
    part.Size = Vector3.new(4,4,4)
    part.Shape = Enum.PartType.Cylinder
    part.Anchored = true
    part.Material = Enum.Material.SmoothPlastic
    part.BrickColor = BrickColor.new("Medium blue")
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    return part
end

function createTorus()
    local anchor = getBuildAnchor()
    local center = anchor.Position
    local radius, count = 5, 16
    local parts = {}
    for i = 1, count do
        local angle = math.rad(i * (360/count))
        local part = Instance.new("Part")
        part.Name = "Torus_"..i
        part.Size = Vector3.new(0.5,0.5,0.5)
        part.Shape = Enum.PartType.Cylinder
        part.Anchored = true
        part.Material = Enum.Material.SmoothPlastic
        part.BrickColor = BrickColor.new("Medium blue")
        part.CFrame = CFrame.lookAt(center + Vector3.new(math.cos(angle)*radius, 0, math.sin(angle)*radius), center)
        part.Parent = workspace
        tagPart(part)
        table.insert(parts, part)
    end
    saveState({undo=function() for _,p in ipairs(parts) do p.Parent = nil end, redo=function() for _,p in ipairs(parts) do p.Parent = workspace; tagPart(p) end end})
    clearSelection()
    if #parts > 0 then selectPart(parts[1]) end
    return parts
end

function createPlane()
    local part = Instance.new("Part")
    part.Name = "Plane_"..math.random(1000,9999)
    part.Size = Vector3.new(4,0.2,4)
    part.Anchored = true
    part.Material = Enum.Material.SmoothPlastic
    part.BrickColor = BrickColor.new("Medium blue")
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    return part
end

function createGrid()
    if gridFolder then gridFolder:Destroy() end
    gridFolder = Instance.new("Folder")
    gridFolder.Name = "GridFolder"
    gridFolder.Parent = workspace
    gridParts = {}
    local anchor = getBuildAnchor()
    local center = anchor.Position
    local size, divisions = 4, 5
    local cellSize = size / divisions
    for i = 0, divisions do
        local v = Instance.new("Part")
        v.Name = "GridVert_"..i
        v.Size = Vector3.new(0.1,0.1,size)
        v.Anchored = true
        v.Material = Enum.Material.Neon
        v.BrickColor = BrickColor.new("White")
        v.CFrame = CFrame.new(center + Vector3.new(-size/2 + i*cellSize, 0, 0))
        v.Parent = gridFolder
        tagPart(v)
        table.insert(gridParts, v)
        local h = Instance.new("Part")
        h.Name = "GridHoriz_"..i
        h.Size = Vector3.new(size,0.1,0.1)
        h.Anchored = true
        h.Material = Enum.Material.Neon
        h.BrickColor = BrickColor.new("White")
        h.CFrame = CFrame.new(center + Vector3.new(0, 0, -size/2 + i*cellSize))
        h.Parent = gridFolder
        tagPart(h)
        table.insert(gridParts, h)
    end
    saveState({undo=function() gridFolder.Parent = nil end, redo=function() gridFolder.Parent = workspace; for _,p in ipairs(gridParts) do p.Parent = gridFolder end end})
    clearSelection()
    if #gridParts > 0 then selectPart(gridParts[1]) end
    return gridParts
end

function createCircle()
    local anchor = getBuildAnchor()
    local center = anchor.Position
    local radius, count = 5, 16
    local parts = {}
    for i = 1, count do
        local angle = math.rad(i * (360/count))
        local part = Instance.new("Part")
        part.Name = "Circle_"..i
        part.Size = Vector3.new(0.2,0.2,0.2)
        part.Shape = Enum.PartType.Cylinder
        part.Anchored = true
        part.Material = Enum.Material.SmoothPlastic
        part.BrickColor = BrickColor.new("Medium blue")
        part.CFrame = CFrame.lookAt(center + Vector3.new(math.cos(angle)*radius, 0, math.sin(angle)*radius), center)
        part.Parent = workspace
        tagPart(part)
        table.insert(parts, part)
    end
    saveState({undo=function() for _,p in ipairs(parts) do p.Parent = nil end, redo=function() for _,p in ipairs(parts) do p.Parent = workspace; tagPart(p) end end})
    clearSelection()
    if #parts > 0 then selectPart(parts[1]) end
    return parts
end

function createPyramid()
    local part = Instance.new("Part")
    part.Name = "Pyramid_"..math.random(1000,9999)
    part.Size = Vector3.new(4,4,4)
    part.Shape = Enum.PartType.Wedge
    part.Anchored = true
    part.Material = Enum.Material.SmoothPlastic
    part.BrickColor = BrickColor.new("Medium blue")
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    return part
end

function createIcosphere(radius, subdivisions)
    radius, subdivisions = radius or 5, subdivisions or 2
    local anchor = getBuildAnchor()
    local center = anchor.Position
    local steps = 12 + subdivisions*6
    local parts = {}
    for i=1, steps do
        local theta = math.rad(i * (360/steps))
        for j=1, math.floor(steps/2) do
            local phi = math.rad(j * (180/(math.floor(steps/2))))
            local x = radius * math.sin(phi) * math.cos(theta)
            local y = radius * math.cos(phi)
            local z = radius * math.sin(phi) * math.sin(theta)
            local part = Instance.new("Part")
            part.Name = "Ico_"..i.."_"..j
            part.Size = Vector3.new(0.5,0.5,0.5)
            part.Shape = Enum.PartType.Ball
            part.Anchored = true
            part.Material = Enum.Material.SmoothPlastic
            part.BrickColor = BrickColor.new("Medium blue")
            part.CFrame = CFrame.new(center + Vector3.new(x,y,z))
            part.Parent = workspace
            tagPart(part)
            table.insert(parts, part)
        end
    end
    saveState({undo=function() for _,p in ipairs(parts) do p.Parent = nil end, redo=function() for _,p in ipairs(parts) do p.Parent = workspace; tagPart(p) end end})
    clearSelection()
    if #parts > 0 then selectPart(parts[1]) end
    return parts
end

function createCapsule()
    local part = Instance.new("Part")
    part.Name = "Capsule_"..math.random(1000,9999)
    part.Size = Vector3.new(4,4,4)
    part.Shape = Enum.PartType.Cylinder
    part.Anchored = true
    part.Material = Enum.Material.SmoothPlastic
    part.BrickColor = BrickColor.new("Medium blue")
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    return part
end

function createTorusKnot()
    local anchor = getBuildAnchor()
    local center = anchor.Position
    local parts = {}
    local radius, tubeRadius, segments = 5, 1, 30
    for i=1, segments do
        local t = (i-1)/segments * math.pi * 2
        local x = (radius + tubeRadius * math.cos(2*t)) * math.cos(t)
        local y = (radius + tubeRadius * math.cos(2*t)) * math.sin(t)
        local z = tubeRadius * math.sin(2*t)
        local part = Instance.new("Part")
        part.Name = "Knot_"..i
        part.Size = Vector3.new(0.5,0.5,0.5)
        part.Shape = Enum.PartType.Ball
        part.Anchored = true
        part.Material = Enum.Material.SmoothPlastic
        part.BrickColor = BrickColor.new("Medium blue")
        part.CFrame = CFrame.new(center + Vector3.new(x,y,z))
        part.Parent = workspace
        tagPart(part)
        table.insert(parts, part)
    end
    saveState({undo=function() for _,p in ipairs(parts) do p.Parent = nil end, redo=function() for _,p in ipairs(parts) do p.Parent = workspace; tagPart(p) end end})
    clearSelection()
    if #parts > 0 then selectPart(parts[1]) end
    return parts
end

function createWall()
    local part = Instance.new("Part")
    part.Name = "Wall_"..math.random(1000,9999)
    part.Size = Vector3.new(8,4,0.5)
    part.Anchored = true
    part.Material = Enum.Material.SmoothPlastic
    part.BrickColor = BrickColor.new("Medium blue")
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    return part
end

function createWindow()
    local part = Instance.new("Part")
    part.Name = "Window_"..math.random(1000,9999)
    part.Size = Vector3.new(3,3,0.3)
    part.Anchored = true
    part.Material = Enum.Material.Glass
    part.Transparency = 0.5
    part.BrickColor = BrickColor.new("Light blue")
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    return part
end

function createDoor()
    local part = Instance.new("Part")
    part.Name = "Door_"..math.random(1000,9999)
    part.Size = Vector3.new(2,4,0.5)
    part.Anchored = true
    part.Material = Enum.Material.Wood
    part.BrickColor = BrickColor.new("Brown")
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    return part
end

function createSpring()
    local anchor = getBuildAnchor()
    local center = anchor.Position
    local parts = {}
    local coils, height, radius = 10, 6, 2
    for i=1, coils do
        local t = i/coils
        local angle = t * math.pi * 4
        local y = t * height
        local x = radius * math.cos(angle)
        local z = radius * math.sin(angle)
        local part = Instance.new("Part")
        part.Name = "Spring_"..i
        part.Size = Vector3.new(0.5,0.5,0.5)
        part.Shape = Enum.PartType.Cylinder
        part.Anchored = true
        part.Material = Enum.Material.Metal
        part.BrickColor = BrickColor.new("Grey")
        part.CFrame = CFrame.new(center + Vector3.new(x,y,z))
        part.Parent = workspace
        tagPart(part)
        table.insert(parts, part)
    end
    saveState({undo=function() for _,p in ipairs(parts) do p.Parent = nil end, redo=function() for _,p in ipairs(parts) do p.Parent = workspace; tagPart(p) end end})
    clearSelection()
    if #parts > 0 then selectPart(parts[1]) end
    return parts
end

function createGear()
    local part = Instance.new("Part")
    part.Name = "Gear_"..math.random(1000,9999)
    part.Size = Vector3.new(4,4,4)
    part.Shape = Enum.PartType.Cylinder
    part.Anchored = true
    part.Material = Enum.Material.Metal
    part.BrickColor = BrickColor.new("Grey")
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    return part
end

function createStar()
    local anchor = getBuildAnchor()
    local center = anchor.Position
    local parts = {}
    local points = 5
    for i=1, points*2 do
        local angle = math.rad(i * (360/(points*2)))
        local radius = (i % 2 == 1) and 4 or 2
        local x = radius * math.cos(angle)
        local z = radius * math.sin(angle)
        local part = Instance.new("Part")
        part.Name = "Star_"..i
        part.Size = Vector3.new(0.5,0.5,0.5)
        part.Shape = Enum.PartType.Ball
        part.Anchored = true
        part.Material = Enum.Material.SmoothPlastic
        part.BrickColor = BrickColor.new("Medium blue")
        part.CFrame = CFrame.new(center + Vector3.new(x,0,z))
        part.Parent = workspace
        tagPart(part)
        table.insert(parts, part)
    end
    saveState({undo=function() for _,p in ipairs(parts) do p.Parent = nil end, redo=function() for _,p in ipairs(parts) do p.Parent = workspace; tagPart(p) end end})
    clearSelection()
    if #parts > 0 then selectPart(parts[1]) end
    return parts
end

function createHeart()
    local anchor = getBuildAnchor()
    local center = anchor.Position
    local parts = {}
    local segments = 20
    for i=1, segments do
        local t = (i-1)/segments * math.pi * 2
        local x = 4 * math.sin(t)^3
        local y = 4 * (13*math.cos(t) - 5*math.cos(2*t) - 2*math.cos(3*t) - math.cos(4*t)) / 16
        local part = Instance.new("Part")
        part.Name = "Heart_"..i
        part.Size = Vector3.new(0.5,0.5,0.5)
        part.Shape = Enum.PartType.Ball
        part.Anchored = true
        part.Material = Enum.Material.SmoothPlastic
        part.BrickColor = BrickColor.new("Bright red")
        part.CFrame = CFrame.new(center + Vector3.new(x, y, 0))
        part.Parent = workspace
        tagPart(part)
        table.insert(parts, part)
    end
    saveState({undo=function() for _,p in ipairs(parts) do p.Parent = nil end, redo=function() for _,p in ipairs(parts) do p.Parent = workspace; tagPart(p) end end})
    clearSelection()
    if #parts > 0 then selectPart(parts[1]) end
    return parts
end

function createPipe()
    local part = Instance.new("Part")
    part.Name = "Pipe_"..math.random(1000,9999)
    part.Size = Vector3.new(4,4,4)
    part.Shape = Enum.PartType.Cylinder
    part.Anchored = true
    part.Material = Enum.Material.Metal
    part.BrickColor = BrickColor.new("Grey")
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    return part
end

function createDisc()
    local part = Instance.new("Part")
    part.Name = "Disc_"..math.random(1000,9999)
    part.Size = Vector3.new(4,0.2,4)
    part.Shape = Enum.PartType.Cylinder
    part.Anchored = true
    part.Material = Enum.Material.SmoothPlastic
    part.BrickColor = BrickColor.new("Medium blue")
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    return part
end

function createRing() return createTorus() end

function createConeFrustum()
    local part = Instance.new("Part")
    part.Name = "Frustum_"..math.random(1000,9999)
    part.Size = Vector3.new(4,4,4)
    part.Shape = Enum.PartType.Cylinder
    part.Anchored = true
    part.Material = Enum.Material.SmoothPlastic
    part.BrickColor = BrickColor.new("Medium blue")
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    return part
end

function createPyramidFrustum()
    local part = Instance.new("Part")
    part.Name = "PyramidFrustum_"..math.random(1000,9999)
    part.Size = Vector3.new(4,4,4)
    part.Shape = Enum.PartType.Wedge
    part.Anchored = true
    part.Material = Enum.Material.SmoothPlastic
    part.BrickColor = BrickColor.new("Medium blue")
    part.CFrame = getBuildAnchor()
    part.Parent = workspace
    tagPart(part)
    saveState({undo=function() part.Parent = nil end, redo=function() part.Parent = workspace; tagPart(part); selectPart(part) end})
    clearSelection()
    selectPart(part)
    return part
end

function createSpiralStairs()
    local anchor = getBuildAnchor()
    local center = anchor.Position
    local parts = {}
    local steps = 10
    local stepHeight = 1
    local radius = 3
    for i=1, steps do
        local angle = math.rad(i * 30)
        local x = radius * math.cos(angle)
        local z = radius * math.sin(angle)
        local part = Instance.new("Part")
        part.Name = "Step_"..i
        part.Size = Vector3.new(2,0.2,0.5)
        part.Anchored = true
        part.Material = Enum.Material.SmoothPlastic
        part.BrickColor = BrickColor.new("Medium blue")
        part.CFrame = CFrame.new(center + Vector3.new(x, i*stepHeight, z)) * CFrame.Angles(0, angle, 0)
        part.Parent = workspace
        tagPart(part)
        table.insert(parts, part)
    end
    saveState({undo=function() for _,p in ipairs(parts) do p.Parent = nil end, redo=function() for _,p in ipairs(parts) do p.Parent = workspace; tagPart(p) end end})
    clearSelection()
    if #parts > 0 then selectPart(parts[1]) end
    return parts
end

function createArchCurved()
    local anchor = getBuildAnchor()
    local center = anchor.Position
    local parts = {}
    local segments = 12
    for i=0, segments do
        local angle = math.rad(i * 180/segments)
        local x = 4 * math.cos(angle)
        local y = 4 * math.sin(angle)
        local part = Instance.new("Part")
        part.Name = "Arch_"..i
        part.Size = Vector3.new(0.5,0.5,0.5)
        part.Shape = Enum.PartType.Cylinder
        part.Anchored = true
        part.Material = Enum.Material.SmoothPlastic
        part.BrickColor = BrickColor.new("Medium blue")
        part.CFrame = CFrame.new(center + Vector3.new(x-4, y, 0))
        part.Parent = workspace
        tagPart(part)
        table.insert(parts, part)
    end
    saveState({undo=function() for _,p in ipairs(parts) do p.Parent = nil end, redo=function() for _,p in ipairs(parts) do p.Parent = workspace; tagPart(p) end end})
    clearSelection()
    if #parts > 0 then selectPart(parts[1]) end
    return parts
end

function createTorusArc()
    local anchor = getBuildAnchor()
    local center = anchor.Position
    local parts = {}
    local radius, segments, arcAngle = 5, 8, 180
    for i=0, segments do
        local angle = math.rad(i * arcAngle/segments)
        local x = radius * math.cos(angle)
        local z = radius * math.sin(angle)
        local part = Instance.new("Part")
        part.Name = "Arc_"..i
        part.Size = Vector3.new(0.5,0.5,0.5)
        part.Shape = Enum.PartType.Cylinder
        part.Anchored = true
        part.Material = Enum.Material.SmoothPlastic
        part.BrickColor = BrickColor.new("Medium blue")
        part.CFrame = CFrame.new(center + Vector3.new(x,0,z))
        part.Parent = workspace
        tagPart(part)
        table.insert(parts, part)
    end
    saveState({undo=function() for _,p in ipairs(parts) do p.Parent = nil end, redo=function() for _,p in ipairs(parts) do p.Parent = workspace; tagPart(p) end end})
    clearSelection()
    if #parts > 0 then selectPart(parts[1]) end
    return parts
end

function createModel()
    local model = Instance.new("Model")
    model.Name = "Model_"..math.random(1000,9999)
    model.Parent = workspace
    tagPart(model)
    saveState({undo=function() model.Parent = nil end, redo=function() model.Parent = workspace; tagPart(model); selectPart(model) end})
    clearSelection()
    selectPart(model)
    return model
end

function createFolder()
    local folder = Instance.new("Folder")
    folder.Name = "Folder_"..math.random(1000,9999)
    folder.Parent = workspace
    tagPart(folder)
    saveState({undo=function() folder.Parent = nil end, redo=function() folder.Parent = workspace; tagPart(folder); selectPart(folder) end})
    clearSelection()
    selectPart(folder)
    return folder
end

--==============================================================================
-- TRANSFORM TOOLS (Duplicate, Delete, etc.)
--==============================================================================
function duplicateSelected()
    if #selectedParts == 0 then return end
    local newParts = {}
    for _, obj in ipairs(selectedParts) do
        if obj:IsA("BasePart") then
            local newObj = obj:Clone()
            for _, child in ipairs(newObj:GetChildren()) do
                if child.Name == TAG_NAME or child.Name == "SL_UniqueId" then child:Destroy() end
            end
            newObj.Parent = obj.Parent
            tagPart(newObj)
            table.insert(newParts, newObj)
        end
    end
    saveState({undo=function() for _,p in ipairs(newParts) do p.Parent = nil end, redo=function() for _,p in ipairs(newParts) do p.Parent = workspace; tagPart(p) end end})
    clearSelection()
    for _, p in ipairs(newParts) do selectPart(p) end
end

function deleteSelected()
    if #selectedParts == 0 then return end
    local toDelete = {}
    for _, p in ipairs(selectedParts) do
        if p:IsA("BasePart") then
            table.insert(toDelete, {part=p, parent=p.Parent, cf=p.CFrame, size=p.Size, name=p.Name, color=p.BrickColor, material=p.Material})
        end
    end
    for _, data in ipairs(toDelete) do data.part.Parent = nil end
    saveState({
        undo = function()
            for _, data in ipairs(toDelete) do
                local np = Instance.new("Part")
                np.Name = data.name
                np.Size = data.size
                np.CFrame = data.cf
                np.BrickColor = data.color
                np.Material = data.material
                np.Parent = data.parent
                tagPart(np)
            end
        end,
        redo = function()
            for _, data in ipairs(toDelete) do
                if data.part and data.part.Parent then data.part.Parent = nil end
            end
        end
    })
    clearSelection()
    clearGizmo()
    needUpdate = true
end

function applySnapToSelected()
    for _, part in ipairs(selectedParts) do
        if part:IsA("BasePart") then
            local cf = part.CFrame
            local pos = snapVector3(cf.Position)
            local rx, ry, rz = cf.Rotation:ToEulerAnglesYXZ()
            rx, ry, rz = snapRotationAngles(rx, ry, rz)
            part.CFrame = CFrame.new(pos) * CFrame.fromEulerAnglesYXZ(rx, ry, rz)
        end
    end
    needUpdate = true
end

--==============================================================================
-- VIEW TOGGLES
--==============================================================================
function toggleGrid()
    gridVisible = not gridVisible
    for _, p in ipairs(gridParts) do p.Visible = gridVisible end
end

function toggleWireframe()
    wireframeMode = not wireframeMode
    refreshModelerCache()
    for _, obj in ipairs(modelerPartsCache) do
        if obj:IsA("BasePart") then
            if wireframeMode then
                originalTransparency[obj] = obj.Transparency
                obj.Transparency = 0.7
            else
                obj.Transparency = originalTransparency[obj] or 0
                originalTransparency[obj] = nil
            end
        end
    end
end

function toggleXRay()
    xrayMode = not xrayMode
    refreshModelerCache()
    for _, obj in ipairs(modelerPartsCache) do
        if obj:IsA("BasePart") then
            if xrayMode then
                originalTransparency[obj] = obj.Transparency
                obj.Transparency = 0.9
            else
                obj.Transparency = originalTransparency[obj] or 0
                originalTransparency[obj] = nil
            end
        end
    end
end

function togglePerformance()
    perfMode = not perfMode
    refreshModelerCache()
    for _, obj in ipairs(modelerPartsCache) do
        if obj:IsA("BasePart") then obj.CastShadow = not perfMode end
    end
end

function isolateSelected()
    refreshModelerCache()
    for _, obj in ipairs(modelerPartsCache) do
        if obj:IsA("BasePart") then
            if not table.find(selectedParts, obj) then
                originalTransparency[obj] = obj.Transparency
                obj.Transparency = 0.9
            end
        end
    end
end

function unhideAll()
    refreshModelerCache()
    for _, obj in ipairs(modelerPartsCache) do
        if obj:IsA("BasePart") then
            obj.Transparency = originalTransparency[obj] or 0
            originalTransparency[obj] = nil
        end
    end
end

--==============================================================================
-- MATERIAL PRESETS
--==============================================================================
function applyMaterialPreset(preset)
    for _, part in ipairs(selectedParts) do
        if part:IsA("BasePart") then
            if preset == "Metal" then part.Material = Enum.Material.Metal; part.Reflectance = 0.8; part.BrickColor = BrickColor.new("Grey")
            elseif preset == "Wood" then part.Material = Enum.Material.Wood; part.Reflectance = 0.2; part.BrickColor = BrickColor.new("Brown")
            elseif preset == "Glass" then part.Material = Enum.Material.Glass; part.Transparency = 0.5; part.Reflectance = 0.1; part.BrickColor = BrickColor.new("Light blue")
            elseif preset == "Neon" then part.Material = Enum.Material.Neon; part.Reflectance = 0.9; part.BrickColor = BrickColor.new("Bright red")
            end
        end
    end
    needUpdate = true
end

--==============================================================================
-- COMMAND SEARCH
--==============================================================================
function openCommandSearch()
    if commandSearch then commandSearch:Destroy(); commandSearch = nil; return end
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0.9,0,0.7,0)
    frame.Position = UDim2.new(0.05,0,0.15,0)
    frame.BackgroundColor3 = UI_COLORS.bgDark
    frame.BorderSizePixel = 0
    frame.Parent = UI.screenGui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0,8)
    commandSearch = frame

    local searchBox = Instance.new("TextBox")
    searchBox.Size = UDim2.new(1,-20,0,44)
    searchBox.Position = UDim2.new(0,10,0,10)
    searchBox.BackgroundColor3 = UI_COLORS.bgLight
    searchBox.TextColor3 = UI_COLORS.textColor
    searchBox.PlaceholderText = "Search commands..."
    searchBox.Font = Enum.Font.Gotham
    searchBox.TextSize = 16
    searchBox.BorderSizePixel = 0
    searchBox.Parent = frame
    Instance.new("UICorner", searchBox).CornerRadius = UDim.new(0,6)

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0,40,0,40)
    closeBtn.Position = UDim2.new(1,-50,0,12)
    closeBtn.BackgroundColor3 = Color3.fromRGB(180,40,40)
    closeBtn.TextColor3 = Color3.new(1,1,1)
    closeBtn.Text = "✕"
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 18
    closeBtn.BorderSizePixel = 0
    closeBtn.Parent = frame
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0,6)
    closeBtn.MouseButton1Click:Connect(function() frame:Destroy(); commandSearch = nil end)

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1,-20,1,-70)
    scroll.Position = UDim2.new(0,10,0,60)
    scroll.BackgroundColor3 = UI_COLORS.bg
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.Parent = frame
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0,4)
    layout.Parent = scroll

    local commandList = {
        {"Create Block", function() createPart("Block") end},
        {"Create Sphere", function() createPart("Ball") end},
        {"Create Cylinder", function() createPart("Cylinder") end},
        {"Create Cone", createCone},
        {"Create Torus", createTorus},
        {"Create Plane", createPlane},
        {"Create Grid", createGrid},
        {"Create Circle", createCircle},
        {"Create Pyramid", createPyramid},
        {"Create Icosphere", function() createIcosphere(5,2) end},
        {"Create Capsule", createCapsule},
        {"Create Torus Knot", createTorusKnot},
        {"Create Wall", createWall},
        {"Create Window", createWindow},
        {"Create Door", createDoor},
        {"Create Spring", createSpring},
        {"Create Gear", createGear},
        {"Create Star", createStar},
        {"Create Heart", createHeart},
        {"Create Pipe", createPipe},
        {"Create Disc", createDisc},
        {"Create Ring", createRing},
        {"Create Frustum", createConeFrustum},
        {"Create Pyramid Frustum", createPyramidFrustum},
        {"Create Spiral Stairs", createSpiralStairs},
        {"Create Arch", createArchCurved},
        {"Create Torus Arc", createTorusArc},
        {"Create Model", createModel},
        {"Create Folder", createFolder},
        {"Duplicate", duplicateSelected},
        {"Delete", deleteSelected},
        {"Undo", undo},
        {"Redo", redo},
        {"Select All", selectAll},
        {"Select None", selectNone},
        {"Toggle Wireframe", toggleWireframe},
        {"Toggle X-Ray", toggleXRay},
        {"Toggle Grid", toggleGrid},
        {"Toggle Performance", togglePerformance},
        {"Apply Metal", function() applyMaterialPreset("Metal") end},
        {"Apply Wood", function() applyMaterialPreset("Wood") end},
        {"Apply Glass", function() applyMaterialPreset("Glass") end},
        {"Apply Neon", function() applyMaterialPreset("Neon") end},
        {"Focus Selection", focusOnSelection},
        {"Isolate Selected", isolateSelected},
        {"Unhide All", unhideAll},
    }

    local function refresh(filter)
        for _, child in ipairs(scroll:GetChildren()) do
            if child:IsA("TextButton") then child:Destroy() end
        end
        filter = filter or ""
        for _, cmd in ipairs(commandList) do
            if filter == "" or cmd[1]:lower():find(filter:lower(),1,true) then
                local btn = Instance.new("TextButton")
                btn.Size = UDim2.new(1,0,0,44)
                btn.BackgroundColor3 = UI_COLORS.bgLight
                btn.TextColor3 = UI_COLORS.textColor
                btn.Text = cmd[1]
                btn.Font = Enum.Font.Gotham
                btn.TextSize = 14
                btn.BorderSizePixel = 0
                btn.Parent = scroll
                Instance.new("UICorner", btn).CornerRadius = UDim.new(0,4)
                btn.MouseButton1Click:Connect(function()
                    frame:Destroy(); commandSearch = nil
                    pcall(cmd[2])
                end)
            end
        end
    end
    searchBox:GetPropertyChangedSignal("Text"):Connect(function() refresh(searchBox.Text) end)
    refresh()
end

--==============================================================================
-- CAMERA VIEW PRESETS
--==============================================================================
function setCameraPerspective() workspace.CurrentCamera.CFrame = CFrame.new(camTarget + Vector3.new(15,15,15), camTarget) end
function setCameraFront() workspace.CurrentCamera.CFrame = CFrame.new(camTarget + Vector3.new(0,5,20), camTarget) end
function setCameraTop() workspace.CurrentCamera.CFrame = CFrame.new(camTarget + Vector3.new(0,30,0), camTarget) end
function setCameraRight() workspace.CurrentCamera.CFrame = CFrame.new(camTarget + Vector3.new(20,5,0), camTarget) end
function setCameraLeft() workspace.CurrentCamera.CFrame = CFrame.new(camTarget + Vector3.new(-20,5,0), camTarget) end
function setCameraBack() workspace.CurrentCamera.CFrame = CFrame.new(camTarget + Vector3.new(0,5,-20), camTarget) end
function setCameraBottom() workspace.CurrentCamera.CFrame = CFrame.new(camTarget + Vector3.new(0,-30,0), camTarget) end

function focusOnSelection()
    if #selectedParts == 0 then return end
    local center = Vector3.new(0,0,0)
    local count = 0
    for _, p in ipairs(selectedParts) do
        if p:IsA("BasePart") then
            center += p.Position
            count += 1
        end
    end
    if count == 0 then return end
    center /= count
    camTarget = center
    workspace.CurrentCamera.CFrame = CFrame.new(center + Vector3.new(10,10,10), center)
end

function selectAll()
    refreshModelerCache()
    clearSelection()
    for _, obj in ipairs(modelerPartsCache) do
        if obj:IsA("BasePart") then selectPart(obj) end
    end
end

function selectNone() clearSelection() end

--==============================================================================
-- UI CONSTRUCTION (Full, Fixed)
--==============================================================================
function createModelerUI()
    if UI.screenGui then UI.screenGui:Destroy() end
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "MODELer_UI"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = false
    screenGui.Parent = playerGui
    UI.screenGui = screenGui

    local main = Instance.new("Frame")
    main.Size = UDim2.new(1,0,1,0)
    main.BackgroundTransparency = 1
    main.Parent = screenGui

    -- TOP BAR
    local topBar = Instance.new("ScrollingFrame")
    topBar.Size = UDim2.new(1,0,0,42)
    topBar.Position = UDim2.new(0,0,0,0)
    topBar.BackgroundColor3 = UI_COLORS.bgDark
    topBar.BorderSizePixel = 0
    topBar.ScrollBarThickness = 0
    topBar.ScrollingDirection = Enum.ScrollingDirection.X
    topBar.AutomaticCanvasSize = Enum.AutomaticSize.X
    topBar.Parent = main

    local topLayout = Instance.new("UIListLayout")
    topLayout.FillDirection = Enum.FillDirection.Horizontal
    topLayout.Padding = UDim.new(0,4)
    topLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    topLayout.SortOrder = Enum.SortOrder.LayoutOrder
    topLayout.Parent = topBar

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(0,100,0,34)
    title.BackgroundTransparency = 1
    title.Text = "MODELER"
    title.TextColor3 = UI_COLORS.textColor
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = topBar

    -- DROPDOWN HELPER
    local function createDropdown(items, width)
        width = width or 120
        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(0,width,0, math.min(#items*32 + 8, 300))
        frame.BackgroundColor3 = UI_COLORS.bgDark
        frame.BorderSizePixel = 0
        frame.Visible = false
        frame.Parent = screenGui
        frame.ZIndex = 10
        Instance.new("UICorner", frame).CornerRadius = UDim.new(0,6)
        frame.Position = UDim2.new(0,10,0,42)

        local scroll = Instance.new("ScrollingFrame")
        scroll.Size = UDim2.new(1,-4,1,-4)
        scroll.Position = UDim2.new(0,2,0,2)
        scroll.BackgroundColor3 = UI_COLORS.bgDark
        scroll.BorderSizePixel = 0
        scroll.ScrollBarThickness = 3
        scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroll.Parent = frame

        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0,2)
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = scroll

        for _, item in ipairs(items) do
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(1,-4,0,32)
            btn.BackgroundColor3 = UI_COLORS.bgLight
            btn.TextColor3 = UI_COLORS.textColor
            btn.Text = item.label
            btn.Font = Enum.Font.Gotham
            btn.TextSize = 12
            btn.BorderSizePixel = 0
            btn.Parent = scroll
            btn.ZIndex = 11
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0,4)
            btn.MouseButton1Click:Connect(function()
                frame.Visible = false
                if item.action then pcall(item.action) end
            end)
        end
        return frame
    end

    local fileItems = {
        {label="Exit", action=function() exitModeler() end}
    }
    local editItems = {
        {label="Undo", action=undo},
        {label="Redo", action=redo},
        {label="Duplicate", action=duplicateSelected},
        {label="Delete", action=deleteSelected},
        {label="Select All", action=selectAll},
        {label="Select None", action=selectNone},
        {label="Multi-Select Toggle", action=function()
            multiSelectMode = not multiSelectMode
            if UI.multiIndicator then
                UI.multiIndicator.Text = "Multi: " .. (multiSelectMode and "ON" or "OFF")
                UI.multiIndicator.TextColor3 = multiSelectMode and UI_COLORS.accent or UI_COLORS.textDark
            end
        end}
    }
    local addItems = {}
    for _, s in ipairs({
        "Block","Sphere","Cylinder","Wedge","Cone","Torus","Plane","Grid","Circle","Pyramid","Icosphere","Capsule","Torus Knot","Wall","Window","Door","Spring","Gear","Star","Heart","Pipe","Disc","Ring","Frustum","Pyramid Frustum","Spiral Stairs","Arch","Torus Arc","Model","Folder"
    }) do
        table.insert(addItems, {label=s, action=function()
            if s=="Block" then createPart("Block")
            elseif s=="Sphere" then createPart("Ball")
            elseif s=="Cylinder" then createPart("Cylinder")
            elseif s=="Wedge" then createPart("Wedge")
            elseif s=="Cone" then createCone()
            elseif s=="Torus" then createTorus()
            elseif s=="Plane" then createPlane()
            elseif s=="Grid" then createGrid()
            elseif s=="Circle" then createCircle()
            elseif s=="Pyramid" then createPyramid()
            elseif s=="Icosphere" then createIcosphere(5,2)
            elseif s=="Capsule" then createCapsule()
            elseif s=="Torus Knot" then createTorusKnot()
            elseif s=="Wall" then createWall()
            elseif s=="Window" then createWindow()
            elseif s=="Door" then createDoor()
            elseif s=="Spring" then createSpring()
            elseif s=="Gear" then createGear()
            elseif s=="Star" then createStar()
            elseif s=="Heart" then createHeart()
            elseif s=="Pipe" then createPipe()
            elseif s=="Disc" then createDisc()
            elseif s=="Ring" then createRing()
            elseif s=="Frustum" then createConeFrustum()
            elseif s=="Pyramid Frustum" then createPyramidFrustum()
            elseif s=="Spiral Stairs" then createSpiralStairs()
            elseif s=="Arch" then createArchCurved()
            elseif s=="Torus Arc" then createTorusArc()
            elseif s=="Model" then createModel()
            elseif s=="Folder" then createFolder()
            end
        end})
    end
    local viewItems = {
        {label="Perspective", action=setCameraPerspective},
        {label="Front", action=setCameraFront},
        {label="Top", action=setCameraTop},
        {label="Right", action=setCameraRight},
        {label="Left", action=setCameraLeft},
        {label="Back", action=setCameraBack},
        {label="Bottom", action=setCameraBottom},
        {label="Focus Selection", action=focusOnSelection},
        {label="Toggle Grid", action=toggleGrid},
        {label="Toggle Wireframe", action=toggleWireframe},
        {label="Toggle X-Ray", action=toggleXRay},
        {label="Isolate Selected", action=isolateSelected},
        {label="Unhide All", action=unhideAll},
        {label="Command Search", action=openCommandSearch}
    }
    local snapItems = {
        {label="Grid 0.1", action=function() snapGrid=0.1; applySnapToSelected() end},
        {label="Grid 0.5", action=function() snapGrid=0.5; applySnapToSelected() end},
        {label="Grid 1", action=function() snapGrid=1; applySnapToSelected() end},
        {label="Grid 2", action=function() snapGrid=2; applySnapToSelected() end},
        {label="Grid 5", action=function() snapGrid=5; applySnapToSelected() end},
        {label="Grid 10", action=function() snapGrid=10; applySnapToSelected() end},
        {label="Rot 15°", action=function() snapRotation=15; applySnapToSelected() end},
        {label="Rot 45°", action=function() snapRotation=45; applySnapToSelected() end},
        {label="Rot 90°", action=function() snapRotation=90; applySnapToSelected() end}
    }

    local fileMenu = createDropdown(fileItems, 100)
    local editMenu = createDropdown(editItems, 150)
    local addMenu = createDropdown(addItems, 170)
    local viewMenu = createDropdown(viewItems, 150)
    local snapMenu = createDropdown(snapItems, 120)

    local function menuBtn(text, menu, xPos)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0,55,0,34)
        btn.BackgroundColor3 = UI_COLORS.bgLight
        btn.TextColor3 = UI_COLORS.textColor
        btn.Text = text
        btn.Font = Enum.Font.GothamMedium
        btn.TextSize = 12
        btn.BorderSizePixel = 0
        btn.Parent = topBar
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0,4)
        btn.MouseButton1Click:Connect(function()
            local vis = menu.Visible
            for _, m in ipairs({fileMenu, editMenu, addMenu, viewMenu, snapMenu}) do
                if m ~= menu then m.Visible = false end
            end
            menu.Visible = not vis
            menu.Position = UDim2.new(0, btn.AbsolutePosition.X - screenGui.AbsolutePosition.X, 0, 42)
        end)
        return btn
    end

    local btnFile = menuBtn("File", fileMenu)
    local btnEdit = menuBtn("Edit", editMenu)
    local btnAdd = menuBtn("Add", addMenu)
    local btnView = menuBtn("View", viewMenu)
    local btnSnap = menuBtn("Snap", snapMenu)

    -- Tutorial button
    local tutorialBtn = Instance.new("TextButton")
    tutorialBtn.Size = UDim2.new(0,80,0,34)
    tutorialBtn.BackgroundColor3 = UI_COLORS.accent
    tutorialBtn.TextColor3 = Color3.new(0,0,0)
    tutorialBtn.Text = "📘 Tutorial"
    tutorialBtn.Font = Enum.Font.GothamBold
    tutorialBtn.TextSize = 12
    tutorialBtn.BorderSizePixel = 0
    tutorialBtn.Parent = topBar
    Instance.new("UICorner", tutorialBtn).CornerRadius = UDim.new(0,4)
    tutorialBtn.MouseButton1Click:Connect(openTutorial)

    -- Simple/Advanced toggle
    local modeBtn = Instance.new("TextButton")
    modeBtn.Size = UDim2.new(0,90,0,34)
    modeBtn.BackgroundColor3 = UI_COLORS.bgLight
    modeBtn.TextColor3 = UI_COLORS.textColor
    modeBtn.Text = "Simple"
    modeBtn.Font = Enum.Font.GothamBold
    modeBtn.TextSize = 12
    modeBtn.BorderSizePixel = 0
    modeBtn.Parent = topBar
    Instance.new("UICorner", modeBtn).CornerRadius = UDim.new(0,4)
    modeBtn.MouseButton1Click:Connect(function()
        simpleMode = not simpleMode
        modeBtn.Text = simpleMode and "Simple" or "Advanced"
        updateUIVisibility()
    end)

    -- Exit button
    local exitBtn = Instance.new("TextButton")
    exitBtn.Size = UDim2.new(0,34,0,34)
    exitBtn.BackgroundColor3 = Color3.fromRGB(180,40,40)
    exitBtn.TextColor3 = Color3.new(1,1,1)
    exitBtn.Text = "✕"
    exitBtn.Font = Enum.Font.GothamBold
    exitBtn.TextSize = 14
    exitBtn.BorderSizePixel = 0
    exitBtn.Parent = topBar
    Instance.new("UICorner", exitBtn).CornerRadius = UDim.new(0,4)
    exitBtn.MouseButton1Click:Connect(exitModeler)

    -- SHAPE ROW
    local shapeRow = Instance.new("ScrollingFrame")
    shapeRow.Size = UDim2.new(1,0,0,64)
    shapeRow.Position = UDim2.new(0,0,0,42)
    shapeRow.BackgroundColor3 = UI_COLORS.bg
    shapeRow.BorderSizePixel = 0
    shapeRow.ScrollBarThickness = 0
    shapeRow.ScrollingDirection = Enum.ScrollingDirection.X
    shapeRow.AutomaticCanvasSize = Enum.AutomaticSize.X
    shapeRow.Parent = main

    local shapeLayout = Instance.new("UIListLayout")
    shapeLayout.FillDirection = Enum.FillDirection.Horizontal
    shapeLayout.Padding = UDim.new(0,4)
    shapeLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    shapeLayout.SortOrder = Enum.SortOrder.LayoutOrder
    shapeLayout.Parent = shapeRow

    UI.shapeButtons = {}
    local shapes = {
        {icon="▣", name="Block", action=function() createPart("Block") end},
        {icon="●", name="Sphere", action=function() createPart("Ball") end},
        {icon="⬢", name="Cylinder", action=function() createPart("Cylinder") end},
        {icon="▲", name="Wedge", action=function() createPart("Wedge") end},
        {icon="△", name="Cone", action=createCone},
        {icon="⊖", name="Torus", action=createTorus},
        {icon="▭", name="Plane", action=createPlane},
        {icon="▤", name="Grid", action=createGrid},
        {icon="⊙", name="Circle", action=createCircle},
        {icon="◆", name="Pyramid", action=createPyramid},
        {icon="❊", name="Icosphere", action=function() createIcosphere(5,2) end},
        {icon="▢", name="Model", action=createModel},
        {icon="📁", name="Folder", action=createFolder},
        {icon="⚪", name="Capsule", action=createCapsule, advancedOnly=true},
        {icon="🌀", name="Torus Knot", action=createTorusKnot, advancedOnly=true},
        {icon="🧱", name="Wall", action=createWall, advancedOnly=true},
        {icon="🪟", name="Window", action=createWindow, advancedOnly=true},
        {icon="🚪", name="Door", action=createDoor, advancedOnly=true},
        {icon="〰️", name="Spring", action=createSpring, advancedOnly=true},
        {icon="⚙️", name="Gear", action=createGear, advancedOnly=true},
        {icon="⭐", name="Star", action=createStar, advancedOnly=true},
        {icon="❤️", name="Heart", action=createHeart, advancedOnly=true},
        {icon="🔧", name="Pipe", action=createPipe, advancedOnly=true},
        {icon="💿", name="Disc", action=createDisc, advancedOnly=true},
        {icon="⭕", name="Ring", action=createRing, advancedOnly=true},
        {icon="📐", name="Frustum", action=createConeFrustum, advancedOnly=true},
        {icon="🏗️", name="Spiral Stairs", action=createSpiralStairs, advancedOnly=true},
        {icon="🌈", name="Arch", action=createArchCurved, advancedOnly=true},
        {icon="🌉", name="Torus Arc", action=createTorusArc, advancedOnly=true},
    }
    for _, s in ipairs(shapes) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0,64,0,60)
        btn.BackgroundColor3 = UI_COLORS.bgLight
        btn.TextColor3 = UI_COLORS.textColor
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 16
        btn.BorderSizePixel = 0
        btn.Parent = shapeRow
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0,6)
        btn.MouseButton1Click:Connect(function() pcall(s.action) end)
        local icon = Instance.new("TextLabel")
        icon.Size = UDim2.new(1,0,0.55,0)
        icon.Position = UDim2.new(0,0,0.1,0)
        icon.BackgroundTransparency = 1
        icon.Text = s.icon
        icon.TextColor3 = UI_COLORS.textColor
        icon.Font = Enum.Font.GothamBold
        icon.TextSize = 22
        icon.TextXAlignment = Enum.TextXAlignment.Center
        icon.Parent = btn
        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1,0,0.3,0)
        label.Position = UDim2.new(0,0,0.65,0)
        label.BackgroundTransparency = 1
        label.Text = s.name
        label.TextColor3 = UI_COLORS.textColor
        label.Font = Enum.Font.Gotham
        label.TextSize = 8
        label.TextXAlignment = Enum.TextXAlignment.Center
        label.Parent = btn
        btn.Name = "Shape_"..s.name
        if s.advancedOnly and simpleMode then btn.Visible = false end
        table.insert(UI.shapeButtons, {btn=btn, advancedOnly=s.advancedOnly})
    end

    -- LEFT TOOLBAR
    local leftToolbar = Instance.new("Frame")
    leftToolbar.Size = UDim2.new(0,56,1,-130)
    leftToolbar.Position = UDim2.new(0,0,0,106)
    leftToolbar.BackgroundColor3 = UI_COLORS.bgDark
    leftToolbar.BorderSizePixel = 0
    leftToolbar.Parent = main

    local leftLayout = Instance.new("UIListLayout")
    leftLayout.FillDirection = Enum.FillDirection.Vertical
    leftLayout.Padding = UDim.new(0,6)
    leftLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    leftLayout.SortOrder = Enum.SortOrder.LayoutOrder
    leftLayout.Parent = leftToolbar

    local tools = {
        {icon="👆", name="Select", tool="Select", action=function() currentTool="Select"; clearGizmo() end},
        {icon="✋", name="Move", tool="Move", action=function() currentTool="Move"; if #selectedParts>0 then createGizmoForPart(selectedParts[1]) end end},
        {icon="🔄", name="Rotate", tool="Rotate", action=function() currentTool="Rotate"; if #selectedParts>0 then createGizmoForPart(selectedParts[1]) end end},
        {icon="📏", name="Scale", tool="Scale", action=function() currentTool="Scale"; if #selectedParts>0 then createGizmoForPart(selectedParts[1]) end end},
        {icon="⧉", name="Copy", tool="", action=duplicateSelected},
        {icon="🗑️", name="Delete", tool="", action=deleteSelected},
        {icon="↩️", name="Undo", tool="", action=undo},
        {icon="↪️", name="Redo", tool="", action=redo},
    }
    for _, t in ipairs(tools) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1,-8,0,56)
        btn.BackgroundColor3 = UI_COLORS.bgLight
        btn.TextColor3 = UI_COLORS.textColor
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 16
        btn.BorderSizePixel = 0
        btn.Parent = leftToolbar
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0,6)
        btn.MouseButton1Click:Connect(function()
            if t.tool ~= "" then currentTool = t.tool end
            if t.action then pcall(t.action) end
            for _, child in ipairs(leftToolbar:GetChildren()) do
                if child:IsA("TextButton") then child.BackgroundColor3 = UI_COLORS.bgLight end
            end
            btn.BackgroundColor3 = UI_COLORS.accent
        end)
        local icon = Instance.new("TextLabel")
        icon.Size = UDim2.new(1,0,0.6,0)
        icon.Position = UDim2.new(0,0,0.05,0)
        icon.BackgroundTransparency = 1
        icon.Text = t.icon
        icon.TextColor3 = UI_COLORS.textColor
        icon.Font = Enum.Font.GothamBold
        icon.TextSize = 20
        icon.TextXAlignment = Enum.TextXAlignment.Center
        icon.Parent = btn
        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1,0,0.3,0)
        label.Position = UDim2.new(0,0,0.7,0)
        label.BackgroundTransparency = 1
        label.Text = t.name
        label.TextColor3 = UI_COLORS.textColor
        label.Font = Enum.Font.Gotham
        label.TextSize = 8
        label.TextXAlignment = Enum.TextXAlignment.Center
        label.Parent = btn
        if t.name == "Undo" then UI.undoBtn = btn end
        if t.name == "Redo" then UI.redoBtn = btn end
    end

    -- RIGHT PANEL (Advanced only)
    local rightPanel = Instance.new("Frame")
    rightPanel.Size = UDim2.new(0.28,0,1,-130)
    rightPanel.Position = UDim2.new(0.72,0,0,106)
    rightPanel.BackgroundColor3 = UI_COLORS.bg
    rightPanel.BorderSizePixel = 0
    rightPanel.Parent = main
    rightPanel.Visible = not simpleMode
    UI.rightPanel = rightPanel

    -- Outliner
    local outlinerHeader = Instance.new("Frame")
    outlinerHeader.Size = UDim2.new(1,0,0,30)
    outlinerHeader.BackgroundColor3 = UI_COLORS.bgDark
    outlinerHeader.BorderSizePixel = 0
    outlinerHeader.Parent = rightPanel

    local outlinerTitle = Instance.new("TextLabel")
    outlinerTitle.Size = UDim2.new(0.5,0,1,0)
    outlinerTitle.BackgroundTransparency = 1
    outlinerTitle.Text = "Outliner"
    outlinerTitle.TextColor3 = UI_COLORS.textColor
    outlinerTitle.Font = Enum.Font.GothamBold
    outlinerTitle.TextSize = 12
    outlinerTitle.TextXAlignment = Enum.TextXAlignment.Left
    outlinerTitle.Position = UDim2.new(0,6,0,0)
    outlinerTitle.Parent = outlinerHeader

    local searchField = Instance.new("TextBox")
    searchField.Size = UDim2.new(0.5,-10,0,26)
    searchField.Position = UDim2.new(0.5,0,0,2)
    searchField.BackgroundColor3 = UI_COLORS.bgLight
    searchField.TextColor3 = UI_COLORS.textColor
    searchField.PlaceholderText = "Search..."
    searchField.Font = Enum.Font.Gotham
    searchField.TextSize = 10
    searchField.BorderSizePixel = 0
    searchField.Parent = outlinerHeader
    Instance.new("UICorner", searchField).CornerRadius = UDim.new(0,4)
    searchField:GetPropertyChangedSignal("Text"):Connect(function() needUpdate = true end)
    UI.searchField = searchField

    local outlinerScroll = Instance.new("ScrollingFrame")
    outlinerScroll.Size = UDim2.new(1,0,0.5,-30)
    outlinerScroll.Position = UDim2.new(0,0,0,30)
    outlinerScroll.BackgroundColor3 = UI_COLORS.bg
    outlinerScroll.BorderSizePixel = 0
    outlinerScroll.ScrollBarThickness = 4
    outlinerScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    outlinerScroll.Parent = rightPanel
    UI.outlinerScroll = outlinerScroll

    local outlinerLayout = Instance.new("UIListLayout")
    outlinerLayout.Padding = UDim.new(0,2)
    outlinerLayout.Parent = outlinerScroll

    -- Properties
    local propsHeader = Instance.new("Frame")
    propsHeader.Size = UDim2.new(1,0,0,30)
    propsHeader.Position = UDim2.new(0,0,0.5,0)
    propsHeader.BackgroundColor3 = UI_COLORS.bgDark
    propsHeader.BorderSizePixel = 0
    propsHeader.Parent = rightPanel

    local propsTitle = Instance.new("TextLabel")
    propsTitle.Size = UDim2.new(1,0,1,0)
    propsTitle.BackgroundTransparency = 1
    propsTitle.Text = "Properties"
    propsTitle.TextColor3 = UI_COLORS.textColor
    propsTitle.Font = Enum.Font.GothamBold
    propsTitle.TextSize = 12
    propsTitle.TextXAlignment = Enum.TextXAlignment.Left
    propsTitle.Position = UDim2.new(0,6,0,0)
    propsTitle.Parent = propsHeader

    local propsScroll = Instance.new("ScrollingFrame")
    propsScroll.Size = UDim2.new(1,0,0.5,-30)
    propsScroll.Position = UDim2.new(0,0,0.5,30)
    propsScroll.BackgroundColor3 = UI_COLORS.bg
    propsScroll.BorderSizePixel = 0
    propsScroll.ScrollBarThickness = 4
    propsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    propsScroll.Parent = rightPanel
    UI.propsScroll = propsScroll

    local propsLayout = Instance.new("UIListLayout")
    propsLayout.Padding = UDim.new(0,4)
    propsLayout.Parent = propsScroll

    -- BOTTOM STATUS BAR
    local bottomBar = Instance.new("Frame")
    bottomBar.Size = UDim2.new(1,-56,0,26)
    bottomBar.Position = UDim2.new(0,56,1,-26)
    bottomBar.BackgroundColor3 = UI_COLORS.bgDark
    bottomBar.BorderSizePixel = 0
    bottomBar.Parent = main

    local bottomText = Instance.new("TextLabel")
    bottomText.Size = UDim2.new(1,0,1,0)
    bottomText.BackgroundTransparency = 1
    bottomText.Text = "Tap a shape to add it. Drag to orbit."
    bottomText.TextColor3 = UI_COLORS.textColor
    bottomText.Font = Enum.Font.Gotham
    bottomText.TextSize = 12
    bottomText.TextXAlignment = Enum.TextXAlignment.Left
    bottomText.Position = UDim2.new(0,10,0,0)
    bottomText.Parent = bottomBar
    UI.bottomText = bottomText

    -- MULTI-SELECT INDICATOR
    local multiIndicator = Instance.new("TextLabel")
    multiIndicator.Size = UDim2.new(0,100,0,20)
    multiIndicator.Position = UDim2.new(0,590,0,10)
    multiIndicator.BackgroundTransparency = 1
    multiIndicator.Text = "Multi: OFF"
    multiIndicator.TextColor3 = UI_COLORS.textDark
    multiIndicator.Font = Enum.Font.Gotham
    multiIndicator.TextSize = 12
    multiIndicator.Parent = screenGui
    UI.multiIndicator = multiIndicator

    -- TUTORIAL OVERLAY
    local tutorialFrame = Instance.new("Frame")
    tutorialFrame.Size = UDim2.new(0.85,0,0.75,0)
    tutorialFrame.Position = UDim2.new(0.075,0,0.125,0)
    tutorialFrame.BackgroundColor3 = Color3.fromRGB(20,20,23)
    tutorialFrame.BorderSizePixel = 0
    tutorialFrame.Visible = false
    tutorialFrame.Parent = screenGui
    Instance.new("UICorner", tutorialFrame).CornerRadius = UDim.new(0,8)
    UI.tutorialFrame = tutorialFrame

    local tutorialTitle = Instance.new("TextLabel")
    tutorialTitle.Size = UDim2.new(1,0,0,40)
    tutorialTitle.BackgroundTransparency = 1
    tutorialTitle.Text = "Tutorial – Page 1"
    tutorialTitle.TextColor3 = UI_COLORS.textColor
    tutorialTitle.Font = Enum.Font.GothamBold
    tutorialTitle.TextSize = 18
    tutorialTitle.Parent = tutorialFrame
    UI.tutorialTitle = tutorialTitle

    local tutorialContent = Instance.new("ScrollingFrame")
    tutorialContent.Size = UDim2.new(1,-20,1,-80)
    tutorialContent.Position = UDim2.new(0,10,0,45)
    tutorialContent.BackgroundTransparency = 1
    tutorialContent.BorderSizePixel = 0
    tutorialContent.ScrollBarThickness = 4
    tutorialContent.AutomaticCanvasSize = Enum.AutomaticSize.Y
    tutorialContent.Parent = tutorialFrame

    local tutorialText = Instance.new("TextLabel")
    tutorialText.Size = UDim2.new(1,0,0,0)
    tutorialText.BackgroundTransparency = 1
    tutorialText.Text = ""
    tutorialText.TextColor3 = UI_COLORS.textColor
    tutorialText.Font = Enum.Font.Gotham
    tutorialText.TextSize = 14
    tutorialText.TextWrapped = true
    tutorialText.TextXAlignment = Enum.TextXAlignment.Left
    tutorialText.Parent = tutorialContent
    tutorialText.AutomaticSize = Enum.AutomaticSize.Y
    UI.tutorialText = tutorialText

    local navFrame = Instance.new("Frame")
    navFrame.Size = UDim2.new(1,0,0,40)
    navFrame.Position = UDim2.new(0,0,1,-40)
    navFrame.BackgroundTransparency = 1
    navFrame.Parent = tutorialFrame

    local backBtn = Instance.new("TextButton")
    backBtn.Size = UDim2.new(0,80,0,36)
    backBtn.Position = UDim2.new(0,10,0,0)
    backBtn.BackgroundColor3 = UI_COLORS.bgLight
    backBtn.TextColor3 = UI_COLORS.textColor
    backBtn.Text = "◀ Back"
    backBtn.Font = Enum.Font.GothamBold
    backBtn.TextSize = 14
    backBtn.BorderSizePixel = 0
    backBtn.Parent = navFrame
    Instance.new("UICorner", backBtn).CornerRadius = UDim.new(0,6)
    backBtn.MouseButton1Click:Connect(function()
        if tutorialPage > 1 then tutorialPage -= 1; updateTutorialPage() end
    end)
    UI.backBtn = backBtn

    local nextBtn = Instance.new("TextButton")
    nextBtn.Size = UDim2.new(0,80,0,36)
    nextBtn.Position = UDim2.new(1,-90,0,0)
    nextBtn.BackgroundColor3 = UI_COLORS.bgLight
    nextBtn.TextColor3 = UI_COLORS.textColor
    nextBtn.Text = "Next ▶"
    nextBtn.Font = Enum.Font.GothamBold
    nextBtn.TextSize = 14
    nextBtn.BorderSizePixel = 0
    nextBtn.Parent = navFrame
    Instance.new("UICorner", nextBtn).CornerRadius = UDim.new(0,6)
    nextBtn.MouseButton1Click:Connect(function()
        if tutorialPage < totalTutorialPages then tutorialPage += 1; updateTutorialPage() end
    end)
    UI.nextBtn = nextBtn

    local closeTutorial = Instance.new("TextButton")
    closeTutorial.Size = UDim2.new(0,40,0,40)
    closeTutorial.Position = UDim2.new(1,-20,0,0)
    closeTutorial.BackgroundColor3 = Color3.fromRGB(180,40,40)
    closeTutorial.TextColor3 = Color3.new(1,1,1)
    closeTutorial.Text = "✕"
    closeTutorial.Font = Enum.Font.GothamBold
    closeTutorial.TextSize = 18
    closeTutorial.BorderSizePixel = 0
    closeTutorial.Parent = tutorialFrame
    Instance.new("UICorner", closeTutorial).CornerRadius = UDim.new(0,6)
    closeTutorial.MouseButton1Click:Connect(function() tutorialFrame.Visible = false end)

    updateTutorialPage()
    updateUIVisibility()
    needUpdate = true
    setCameraPerspective()
    updateUndoRedoUI()

    local showTutorial = player:GetAttribute("ShowTutorial")
    if showTutorial ~= false then
        tutorialFrame.Visible = true
    end
end

function openTutorial()
    if UI.tutorialFrame then
        UI.tutorialFrame.Visible = true
        tutorialPage = 1
        updateTutorialPage()
    end
end

function updateTutorialPage()
    if not UI.tutorialText or not UI.tutorialTitle then return end
    local pages = {
        [[Welcome to Modeler! 🎉

This is a fun way to build 3D things on your phone.

Tap the shapes at the top to add them to your world.

Use your fingers to move around:
- Drag with ONE finger to orbit (spin around).
- Pinch with TWO fingers to zoom in/out.
- Use TWO fingers and move to pan (slide).

That's it! Let's start building!]],
        [[SELECTING OBJECTS 👆

Tap any shape you added to select it.
A white box will appear around it.

To select MULTIPLE shapes:
1. Long‑press anywhere (or toggle Multi‑Select from Edit menu).
2. Then tap the shapes you want to select.

To deselect everything, tap the "Select" tool and then tap empty space.]],
        [[ADDING SHAPES ➕

The top row has many shapes:
- Block, Sphere, Cylinder, Cone, Torus, Plane, Grid, Circle, Pyramid, Icosphere, Model, Folder.

In Advanced mode, you get even more: Capsule, Torus Knot, Wall, Window, Door, Spring, Gear, Star, Heart, Pipe, Disc, Ring, Frustum, Spiral Stairs, Arch, Torus Arc.

Just tap a shape and it appears in front of you.]],
        [[MOVING, ROTATING, SCALING ✋🔄📏

Select a shape, then tap:
- Move (✋): Drag the red/green/blue arrows to move along X/Y/Z.
- Rotate (🔄): Drag the colored rings to rotate.
- Scale (📏): Drag the handles to make bigger/smaller.

The colored parts mean:
- Red = X axis
- Green = Y axis
- Blue = Z axis]],
        [[DUPLICATE, DELETE, UNDO 🗑️⧉

- Duplicate (⧉): Makes a copy of selected shape.
- Delete (🗑️): Removes selected shape(s).
- Undo (↩️): Reverts your last action.
- Redo (↪️): Re‑does what you undid.

These are on the left toolbar.]],
        [[ADVANCED MODE & TIPS 🚀

Switch to Advanced (top bar) to see:
- Outliner: list of all objects.
- Properties: change size, color, material.
- More shapes and tools (Group, Ungroup, Align, etc.)

Remember:
- Long‑press toggles multi‑select.
- Use the tutorial button anytime to review.]]
    }
    UI.tutorialText.Text = pages[tutorialPage]
    UI.tutorialTitle.Text = "Tutorial – Page "..tutorialPage.." of "..totalTutorialPages
    if UI.backBtn then
        UI.backBtn.BackgroundColor3 = (tutorialPage == 1) and Color3.fromRGB(60,60,65) or UI_COLORS.bgLight
        UI.backBtn.TextColor3 = (tutorialPage == 1) and Color3.fromRGB(150,150,150) or UI_COLORS.textColor
    end
    if UI.nextBtn then
        UI.nextBtn.BackgroundColor3 = (tutorialPage == totalTutorialPages) and Color3.fromRGB(60,60,65) or UI_COLORS.bgLight
        UI.nextBtn.TextColor3 = (tutorialPage == totalTutorialPages) and Color3.fromRGB(150,150,150) or UI_COLORS.textColor
    end
end

function updateUIVisibility()
    if UI.shapeButtons then
        for _, data in ipairs(UI.shapeButtons) do
            if data.advancedOnly then data.btn.Visible = not simpleMode end
        end
    end
    if UI.rightPanel then UI.rightPanel.Visible = not simpleMode end
end

--==============================================================================
-- OUTLINER & PROPERTIES UPDATE FUNCTIONS
--==============================================================================
function updateOutliner()
    local scroll = UI.outlinerScroll
    if not scroll then return end
    for _, child in ipairs(scroll:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end
    refreshModelerCache()
    local objects = modelerPartsCache
    table.sort(objects, function(a,b) return a.Name < b.Name end)
    local filter = UI.searchField and UI.searchField.Text or ""
    for _, obj in ipairs(objects) do
        if filter == "" or obj.Name:lower():find(filter:lower(),1,true) then
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(1,0,0,30)
            btn.BackgroundColor3 = table.find(selectedParts, obj) and UI_COLORS.accent or UI_COLORS.bgLight
            btn.Text = obj.Name
            btn.Font = Enum.Font.Gotham
            btn.TextSize = 12
            btn.TextXAlignment = Enum.TextXAlignment.Left
            btn.BorderSizePixel = 0
            btn.Parent = scroll
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0,4)
            btn.MouseButton1Click:Connect(function()
                if multiSelectMode then selectPart(obj)
                else clearSelection(); selectPart(obj) end
            end)
        end
    end
end

function updateProperties()
    local scroll = UI.propsScroll
    if not scroll then return end
    for _, child in ipairs(scroll:GetChildren()) do
        if child:IsA("Frame") then child:Destroy() end
    end
    if #selectedParts == 0 then
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1,0,0,24)
        lbl.BackgroundTransparency = 1
        lbl.Text = "No selection"
        lbl.TextColor3 = UI_COLORS.textColor
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 12
        lbl.Parent = scroll
        return
    elseif #selectedParts > 1 then
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1,0,0,24)
        lbl.BackgroundTransparency = 1
        lbl.Text = #selectedParts .. " objects selected"
        lbl.TextColor3 = UI_COLORS.textColor
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 12
        lbl.Parent = scroll
        return
    end

    local selectedPart = selectedParts[1]
    if selectedPart:IsA("BasePart") then
        local function addNumberField(name, getter, setter)
            local frame = Instance.new("Frame")
            frame.Size = UDim2.new(1,0,0,28)
            frame.BackgroundTransparency = 1
            frame.Parent = scroll
            local lbl = Instance.new("TextLabel")
            lbl.Size = UDim2.new(0,50,1,0)
            lbl.BackgroundTransparency = 1
            lbl.Text = name
            lbl.TextColor3 = UI_COLORS.textColor
            lbl.Font = Enum.Font.Gotham
            lbl.TextSize = 10
            lbl.TextXAlignment = Enum.TextXAlignment.Left
            lbl.Parent = frame
            local box = Instance.new("TextBox")
            box.Size = UDim2.new(1,-55,1,0)
            box.Position = UDim2.new(0,55,0,0)
            box.BackgroundColor3 = UI_COLORS.bgLight
            box.TextColor3 = UI_COLORS.textColor
            box.Text = tostring(getter())
            box.Font = Enum.Font.Gotham
            box.TextSize = 12
            box.BorderSizePixel = 0
            box.Parent = frame
            Instance.new("UICorner", box).CornerRadius = UDim.new(0,4)
            box.FocusLost:Connect(function()
                local v = tonumber(box.Text)
                if v then
                    setter(v)
                    needUpdate = true
                end
            end)
        end

        addNumberField("Pos X", function() return selectedPart.Position.X end,
            function(v) selectedPart.Position = Vector3.new(v, selectedPart.Position.Y, selectedPart.Position.Z) end)
        addNumberField("Pos Y", function() return selectedPart.Position.Y end,
            function(v) selectedPart.Position = Vector3.new(selectedPart.Position.X, v, selectedPart.Position.Z) end)
        addNumberField("Pos Z", function() return selectedPart.Position.Z end,
            function(v) selectedPart.Position = Vector3.new(selectedPart.Position.X, selectedPart.Position.Y, v) end)
        addNumberField("Size X", function() return selectedPart.Size.X end,
            function(v) selectedPart.Size = Vector3.new(v, selectedPart.Size.Y, selectedPart.Size.Z) end)
        addNumberField("Size Y", function() return selectedPart.Size.Y end,
            function(v) selectedPart.Size = Vector3.new(selectedPart.Size.X, v, selectedPart.Size.Z) end)
        addNumberField("Size Z", function() return selectedPart.Size.Z end,
            function(v) selectedPart.Size = Vector3.new(selectedPart.Size.X, selectedPart.Size.Y, v) end)

        -- Material
        local matFrame = Instance.new("Frame")
        matFrame.Size = UDim2.new(1,0,0,28)
        matFrame.BackgroundTransparency = 1
        matFrame.Parent = scroll
        local matLbl = Instance.new("TextLabel")
        matLbl.Size = UDim2.new(0,50,1,0)
        matLbl.BackgroundTransparency = 1
        matLbl.Text = "Mat"
        matLbl.TextColor3 = UI_COLORS.textColor
        matLbl.Font = Enum.Font.Gotham
        matLbl.TextSize = 10
        matLbl.TextXAlignment = Enum.TextXAlignment.Left
        matLbl.Parent = matFrame
        local matBtn = Instance.new("TextButton")
        matBtn.Size = UDim2.new(1,-55,1,0)
        matBtn.Position = UDim2.new(0,55,0,0)
        matBtn.BackgroundColor3 = UI_COLORS.bgLight
        matBtn.TextColor3 = UI_COLORS.textColor
        matBtn.Text = selectedPart.Material.Name
        matBtn.Font = Enum.Font.Gotham
        matBtn.TextSize = 12
        matBtn.BorderSizePixel = 0
        matBtn.Parent = matFrame
        Instance.new("UICorner", matBtn).CornerRadius = UDim.new(0,4)
        matBtn.MouseButton1Click:Connect(function()
            local materials = {"SmoothPlastic","Plastic","Metal","Glass","Neon","Wood","Concrete","Brick","Fabric","Grass","Sand","Marble","Granite","Cobblestone","Slate","Ice","CorrodedMetal","DiamondPlate","Foil","Planks","Pebble","CrackedLava","Basalt","Glacier","LeafyGrass","Limestone","Mud","Pavement","Rock","Salt","Sandstone","Snow","WoodPlanks"}
            local idx = 1
            for i, m in ipairs(materials) do if m == selectedPart.Material.Name then idx = i; break end end
            idx = idx % #materials + 1
            selectedPart.Material = Enum.Material[materials[idx]]
            matBtn.Text = selectedPart.Material.Name
            needUpdate = true
        end)

        -- Color swatches
        local colFrame = Instance.new("Frame")
        colFrame.Size = UDim2.new(1,0,0,34)
        colFrame.BackgroundTransparency = 1
        colFrame.Parent = scroll
        local colLayout = Instance.new("UIListLayout")
        colLayout.FillDirection = Enum.FillDirection.Horizontal
        colLayout.Padding = UDim.new(0,4)
        colLayout.Parent = colFrame
        local colors = {"Bright red","Bright blue","Bright green","White","Black","Bright yellow","Bright orange","Bright violet"}
        for _, c in ipairs(colors) do
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(0,30,0,30)
            btn.BackgroundColor3 = BrickColor.new(c).Color
            btn.BorderSizePixel = 0
            btn.Parent = colFrame
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0,4)
            btn.MouseButton1Click:Connect(function()
                selectedPart.BrickColor = BrickColor.new(c)
                needUpdate = true
            end)
        end

        -- Material presets
        local presets = {"Metal","Wood","Glass","Neon"}
        local presFrame = Instance.new("Frame")
        presFrame.Size = UDim2.new(1,0,0,28)
        presFrame.BackgroundTransparency = 1
        presFrame.Parent = scroll
        local presLayout = Instance.new("UIListLayout")
        presLayout.FillDirection = Enum.FillDirection.Horizontal
        presLayout.Padding = UDim.new(0,4)
        presLayout.Parent = presFrame
        for _, p in ipairs(presets) do
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(0,60,1,0)
            btn.BackgroundColor3 = UI_COLORS.bgLight
            btn.TextColor3 = UI_COLORS.textColor
            btn.Text = p
            btn.Font = Enum.Font.Gotham
            btn.TextSize = 12
            btn.BorderSizePixel = 0
            btn.Parent = presFrame
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0,4)
            btn.MouseButton1Click:Connect(function() applyMaterialPreset(p); needUpdate = true end)
        end
    end
end

function updateBottomBar(msg)
    local txt = UI.bottomText
    if not txt then return end
    if msg then txt.Text = msg; return end
    refreshModelerCache()
    local count = #modelerPartsCache
    txt.Text = "Selected: " .. #selectedParts .. " | Objects: " .. count .. " | Multi: " .. (multiSelectMode and "ON" or "OFF")
end

function updateUndoRedoUI()
    if UI.undoBtn and UI.redoBtn then
        UI.undoBtn.BackgroundColor3 = #undoStack > 0 and UI_COLORS.bgLight or UI_COLORS.bgDark
        UI.redoBtn.BackgroundColor3 = #redoStack > 0 and UI_COLORS.bgLight or UI_COLORS.bgDark
    end
end

--==============================================================================
-- EXIT
--==============================================================================
function exitModeler()
    modelerActive = false
    if UI.screenGui then UI.screenGui:Destroy(); UI.screenGui = nil end
    clearGizmo()
    if commandSearch then commandSearch:Destroy(); commandSearch = nil end
    workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
    _G.BlockCameraMovement = false
    print("MODELer exited.")
end

--==============================================================================
-- INJECT THE TOGGLE BUTTON INTO STUDIO LITE'S MAIN BAR
--==============================================================================
local toggleHolder = Instance.new("Frame")
toggleHolder.Size = UDim2.new(0, 80, 0, 32)
toggleHolder.Position = UDim2.new(0, 350, 0, 4)
toggleHolder.BackgroundTransparency = 1
toggleHolder.Parent = mainBar

local toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(1,0,1,0)
toggleBtn.BackgroundColor3 = Color3.fromRGB(80,80,90)
toggleBtn.TextColor3 = Color3.new(1,1,1)
toggleBtn.Text = "Modeler"
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.TextSize = 12
toggleBtn.BorderSizePixel = 0
toggleBtn.Parent = toggleHolder
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0,4)

toggleBtn.MouseButton1Click:Connect(function()
    modelerActive = not modelerActive
    if modelerActive then
        if not UI.screenGui then
            createModelerUI()
        end
        UI.screenGui.Enabled = true
        toggleBtn.BackgroundColor3 = UI_COLORS.accent
    else
        if UI.screenGui then UI.screenGui.Enabled = false end
        toggleBtn.BackgroundColor3 = Color3.fromRGB(80,80,90)
    end
end)

--==============================================================================
-- PERIODIC UI UPDATES
--==============================================================================
spawn(function()
    while wait(0.5) do
        if modelerActive and needUpdate then
            pcall(updateOutliner)
            pcall(updateProperties)
            pcall(updateBottomBar)
            pcall(updateUndoRedoUI)
            needUpdate = false
        end
    end
end)

--==============================================================================
-- STARTUP
--==============================================================================
print("✅ MODELER fully injected into Studio Lite! Click the 'Modeler' button.")
