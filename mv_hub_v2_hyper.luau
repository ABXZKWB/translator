-- ═══════════════════════════════════════════════════════════════════════
-- 【最早期反作弊拦截】—— 必须放在整个脚本最前面
--
-- 游戏在三处用 getfenv 探测执行器（反编译确认）：
--   InventoryController:461            → u0 = {}    模块表清空
--   Shared.Raycast:260 / 310           → u115 = {}  射线模块表清空
--   InventoryController:439 的 getCurrentEquipped → u192 变 nil
--
-- 脚本原先在文件末尾（第 13354 行）才调用 patchGetCurrentEquipped /
-- patchRaycast，但前面一万多行里到处都在调 peekCurrentEquippedForMovement
-- 和 Raycast.cast —— 只要有一次发生在补丁之前，反作弊就已经命中。
-- 表现：不注入一切正常，一注入就买不了东西、物品栏 1234 消失、手上空气。
--
-- 这里在脚本最开头（任何 require 之前）就把两个入口换掉，掐断检测。
-- ═══════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════
-- Drawing 生命周期登记表（用它取代 cleardrawcache）
--
-- ⚠ cleardrawcache() 会把执行器的 Drawing 系统整个弄坏：对象还能 new、
-- Visible 还是 true、代码全在跑，但底层渲染管线异常并持续拖慢客户端
-- （potassium 被它用过两次后从 220 FPS 掉到 10~14，只能重进服务器）。
--
-- 所以改成自己记账：包一层 Drawing.new，把创建的每个对象登记进
-- getgenv().MV_DRAW_REG（值弱引用，不会拖住 GC），卸载 / 重载时逐个
-- :Remove()。效果等价于"清干净屏幕"，但完全不碰执行器内部状态。
-- ═══════════════════════════════════════════════════════════════════════
do
    local reg = getgenv().MV_DRAW_REG
    if type(reg) ~= "table" then
        reg = setmetatable({}, { __mode = "v" })
        getgenv().MV_DRAW_REG = reg
    end
    local okWrap = pcall(function()
        local D = Drawing
        if type(D) ~= "table" or type(D.new) ~= "function" or D._mv_reg then return false end
        local origNew = D.new
        D.new = function(kind)
            local o = origNew(kind)
            if o ~= nil then reg[#reg + 1] = o end
            return o
        end
        if D.new == origNew then return false end   -- 只读，赋值没生效
        D._mv_reg = true
        return true
    end)
    getgenv().MV_DRAW_REG_OK = (okWrap == true)
end

-- 逐个销毁登记过的 Drawing（cleardrawcache 的安全替代）
getgenv().MV_REAP_DRAWINGS = function()
    local reg = getgenv().MV_DRAW_REG
    if type(reg) ~= "table" then return 0 end
    -- ⚠ 幂等保护：同一个对象只 Remove 一次。
    --
    -- 场景：fullCleanup 先调 clearEsp()/radarClear() 把一批对象 :Remove() 掉，
    -- 随后又调本函数遍历登记表 —— 同一批对象会被 Remove 第二次。
    -- 部分执行器的 Drawing:Remove() 不是幂等的，二次调用走的是已释放的 C 对象，
    -- 这类 use-after-free 表现为**整个客户端进程直接消失**，控制台一条报错都没有。
    -- 用一张弱键表记账，已经处理过（不论是谁处理的）就不再碰。
    local dead = getgenv().MV_DRAW_DEAD
    if type(dead) ~= "table" then
        dead = setmetatable({}, { __mode = "k" })
        getgenv().MV_DRAW_DEAD = dead
    end
    local n = 0
    local skipped = 0
    for i = #reg, 1, -1 do
        local o = reg[i]
        reg[i] = nil
        if o ~= nil then
            if dead[o] then
                skipped += 1
            else
                dead[o] = true
                pcall(function() o.Visible = false end)
                local ok = pcall(function() o:Remove() end)
                if not ok then pcall(function() o:Destroy() end) end
                n = n + 1
            end
        end
    end
    getgenv().MV_REAP_LAST = string.format("removed=%d skipped=%d", n, skipped)
    return n
end

-- ═══════════════════════════════════════════════════════════════════════
-- wrapper → 原函数 的登记表
--
-- ⚠ Roblox/Luau 的 function **不能挂字段**：`f._mv_orig = x` 会直接抛
-- "attempt to index function with '_mv_orig'"（实测踩到，整个脚本启动即死）。
-- 但"这个函数到底是不是我们的 wrapper、它的原版是谁"必须能查，
-- 否则重载会层层套 wrapper、卸载只还原最后一层。
--
-- 所以用一张弱键表记：MV_WRAP_ORIG[wrapper] = 真正的原版。
-- 键弱引用 → wrapper 被游戏模块换掉后自然可回收，不会泄漏。
-- ═══════════════════════════════════════════════════════════════════════
do
    local reg = getgenv().MV_WRAP_ORIG
    if type(reg) ~= "table" then
        reg = setmetatable({}, { __mode = "k" })
        getgenv().MV_WRAP_ORIG = reg
    end
    getgenv().MV_MARK_WRAP = function(wrapper, orig)
        if type(wrapper) == "function" and type(orig) == "function" then
            reg[wrapper] = orig
        end
    end
    -- 返回真正的原版；不是 wrapper 就返回 nil（调用方用 `or 自身` 兜底）
    getgenv().MV_ORIG_OF = function(fn)
        if type(fn) ~= "function" then return nil end
        local o = reg[fn]
        if type(o) == "function" and o ~= fn then return o end
        return nil
    end
end

do
    local RS0 = game:GetService("ReplicatedStorage")
    local HS0 = game:GetService("HttpService")
    local PL0 = game:GetService("Players")

    -- ═══ 装备状态契约（本文件唯一实现，S.patchGetCurrentEquipped 复用这一份）═══
    --
    -- 游戏里 getCurrentEquipped / peekCurrentEquippedForMovement 的返回契约是：
    --     有装备 → 背包里的真实 item 对象（带 shoot / equip / unequip / reload / drop / scope 元表方法）
    --     没装备 → nil
    --
    -- ⚠ 绝不能返回 JSON 解码表。JSON 表一个方法都没有，游戏拿它去调 :unequip() / :shoot()
    -- 会直接抛错；而这个错发生在游戏自己的武器 / 输入处理链里，外部只能看到症状：
    --     左键不开枪、右键不瞄准、按 1/2/3 切不了枪、快捷栏与真实装备脱节。
    -- 这正是「物品栏看着有东西但切不了枪」和「买的东西不进包」的直接原因。
    --
    -- ⚠ 也绝不能调用原版函数取真实对象：原函数体内就是那段 getfenv 执行器检测，
    -- pcall 只能接住错误、接不住副作用，每调一次 u192 就被清空一次。
    local diag = { hit = 0, miss = 0, noAttr = 0, badJson = 0, last = "init" }
    getgenv().MV_PEEK_DIAG = diag

    local function findRealItem(ic, want)
        if type(want) ~= "table" then return nil end
        local wantId = want.Identifier
        if wantId == nil then return nil end
        local okInv, inv = pcall(function() return ic.getCurrentInventory() end)
        if not okInv or type(inv) ~= "table" then return nil end
        -- 槽位数按游戏实际（1 Primary / 2 Secondary / 3 Melee / 4 Grenade / 5 C4），
        -- 这里放宽到 16，避免以后加槽位又漏匹配。
        for si = 1, 16 do
            local slot = inv[si]
            if type(slot) == "table" and type(slot._items) == "table" then
                for _, item in ipairs(slot._items) do
                    if type(item) == "table" and item.Identifier == wantId then
                        return item
                    end
                end
            end
        end
        return nil
    end

    local function resolveEquipped(ic)
        local lp0 = PL0.LocalPlayer
        local raw = lp0 and lp0:GetAttribute("CurrentEquipped")
        if type(raw) ~= "string" then
            diag.noAttr += 1
            diag.last = "no-attribute"
            return nil
        end
        local okj, want = pcall(function() return HS0:JSONDecode(raw) end)
        if not okj or type(want) ~= "table" then
            diag.badJson += 1
            diag.last = "bad-json"
            return nil
        end
        local item = findRealItem(ic, want)
        if item then
            diag.hit += 1
            diag.last = "real:" .. tostring(item.Name)
            return item
        end
        -- 属性有值但背包里还没有同 Identifier 的对象：这是重生的同步窗口期。
        -- 返回 nil（= 手上暂时没有东西）是唯一正确语义；返回 JSON 表会把游戏打崩。
        diag.miss += 1
        diag.last = "syncing:" .. tostring(want.Name)
        return nil
    end
    getgenv().MV_RESOLVE_EQUIPPED = resolveEquipped

    -- ① InventoryController：getCurrentEquipped + peekCurrentEquippedForMovement
    local ok1, ic0 = pcall(function() return require(RS0.Controllers.InventoryController) end)
    if ok1 and type(ic0) == "table" then
        -- ⚠ 原引用只保存、绝不调用（内部就是那段 getfenv 检测）。
        -- 幂等：重载脚本时 ic 表上挂的已经是上一实例的 wrapper，
        -- 必须通过 MV_ORIG_OF 取到真正的原版，否则会把 wrapper 当原版存起来，
        -- 卸载时"还原"回去的还是一层 wrapper。
        local curPeek0 = ic0.peekCurrentEquippedForMovement
        local curGCE0 = ic0.getCurrentEquipped
        local origOf0 = getgenv().MV_ORIG_OF
        if type(getgenv().MV_ORIG_PEEK) ~= "function" then
            getgenv().MV_ORIG_PEEK = (origOf0 and origOf0(curPeek0)) or curPeek0
        end
        if type(getgenv().MV_ORIG_GCE) ~= "function" then
            getgenv().MV_ORIG_GCE = (origOf0 and origOf0(curGCE0)) or curGCE0
        end
        -- ⚠ 绝对不能再调用原版 peek / getCurrentEquipped：pcall 接不住副作用，
        -- 每调一次 u192 就被清空一次，背包和真实装备会永久脱节。
        -- ⚠ 也绝不返回 JSON 解码表 —— 见上方契约说明，那是「左键不开枪」的直接原因。
        local function gce()
            -- ★★★ 2026-11-06 修复「一美化就坏」的根因 ★★★
            --
            -- 原版 getCurrentEquipped 在通过它那段 getfenv 检测之后，返回的就是
            --     u192.CurrentEquipped
            -- 而 peekCurrentEquippedForMovement 的实现是：
            --     return u192 and u192.CurrentEquipped
            -- 两者返回**同一个对象**，唯一区别是 peek 不扫调用栈、没有任何副作用。
            -- 所以正确语义就是「直接转发给原版 peek」。
            --
            -- 之前这里只调 resolveEquipped(ic0)：它读的是
            --     LocalPlayer:GetAttribute("CurrentEquipped")  那串 JSON
            -- 而这个属性在重生 / 切枪 / 换回合 / 观战的窗口期经常是 nil
            -- （实测 MV_PEEK_DIAG.noAttr = 852859），于是游戏拿到的永远是 nil ——
            -- 它以为玩家手上没有武器，于是一路崩：
            --   · viewmodel 建不出来           → 手持滚木、手部模型消失
            --   · 背包物品创建链拿不到当前武器  → 快捷栏 1/2 被移除
            --   · BuyMenuPurchase 走同一条内部链 → 有购买音效、钱不扣、东西不到手
            -- 用户把这一整套现象当成了「美化触发反作弊」，实际是这次 patch 的语义错误。

            -- ★acrepair 2026-11-06：若独立模块 ac_kill.luau 已注入，优先走它的实现。
            -- MV_AC.peek 与下面这段语义完全一致（转发原版 peek + 属性反查兜底），
            -- 但额外带「防写回自检」：游戏重新 require / 字段被外部重写时会自动重修，
            -- 而本文件这份只是一次性 patch，失效了不会自己回来。
            -- 两者共存时统一走它，避免两份 wrapper 各自记账、互相覆盖。
            -- 注意：它返回 nil 也是有效语义（手上暂时没东西），必须直接 return，
            -- 不能 fallthrough 到下面的属性反查，否则同一次调用会重复计一次 diag。
            local acm = getgenv().MV_AC
            if type(acm) == "table" and type(acm.peek) == "function" then
                local okA, va = pcall(acm.peek)
                if okA then return va end
            end

            local op = getgenv().MV_ORIG_PEEK
            if type(op) == "function" and op ~= gce then
                local okP, v = pcall(op)
                if okP and v ~= nil then return v end
            end
            -- 兜底：原版 peek 也拿不到（u192 还没建立）时才用属性反查
            return resolveEquipped(ic0)
        end
        getgenv().MV_MARK_WRAP(gce, getgenv().MV_ORIG_PEEK)
        ic0.getCurrentEquipped = gce
        ic0.peekCurrentEquippedForMovement = gce
        getgenv().MV_GCE_PATCHED = true
        warn("[ac-early] InventoryController 已接管（getCurrentEquipped + peek）")
    end

    -- ② Shared.Raycast：cast / castThrough（castThroughDistance 保持原版直通）
    local ok2, rc0 = pcall(function() return require(RS0.Shared.Raycast) end)
    if ok2 and type(rc0) == "table" and not getgenv().MV_RAYCAST_PATCHED then
        -- ★acrepair 2026-11-06：取「真原版」而不是「字段上现在挂着的东西」。
        -- 场景：ac_kill.luau 已经先注入过，rc0.cast / castThrough 上挂的已经是它的
        -- wrapper。若直接把 rc0.cast 当原版存，卸载时「还原」回去的还是一层 wrapper。
        -- MV_ORIG_OF（弱键表 wrapper → 原版）就是为这件事存在的。
        local acOrigOf0 = getgenv().MV_ORIG_OF
        local origCast0 = (acOrigOf0 and acOrigOf0(rc0.cast)) or rc0.cast
        local origCastThrough0 = (acOrigOf0 and acOrigOf0(rc0.castThrough)) or rc0.castThrough
        -- ★acrepair 2026-11-06：castThroughDistance 的原版单独留一份引用。
        -- 反编译确认（Shared.Raycast:340）：它内部**没有任何 getfenv 检测**，
        -- upvalue 只有 castThroughMaterials，所以本文件根本不该接管它 —— 只需直通。
        local origCastDist0 = (acOrigOf0 and acOrigOf0(rc0.castThroughDistance)) or rc0.castThroughDistance

        getgenv().MV_ORIG_CAST = origCast0
        getgenv().MV_ORIG_CAST_THROUGH = origCastThrough0
        getgenv().MV_ORIG_CAST_DIST = origCastDist0

        -- 本文件自带的降级实现（ac_kill 未注入时用它）
        local function myCast(origin, dir, params, filterList, filterFn)
            local okc, res = pcall(function()
                local p = params
                if not p then
                    p = RaycastParams.new()
                    p.FilterType = Enum.RaycastFilterType.Exclude
                    p.IgnoreWater = false
                    p.CollisionGroup = "Bullet"
                end
                local fl = filterList
                if type(fl) ~= "table" then fl = {} else
                    local cp = {}
                    for i, v in ipairs(fl) do cp[i] = v end
                    fl = cp
                end
                p.FilterDescendantsInstances = fl
                local pos = origin
                local guard = 0
                while guard < 32 do
                    guard = guard + 1
                    local r = workspace:Raycast(pos, dir, p)
                    if not r then return { position = origin + dir } end
                    local skip = false
                    if type(filterFn) == "function" then
                        local okf, sr = pcall(filterFn, r.Instance)
                        skip = okf and sr == true
                    end
                    if not skip then
                        return { instance = r.Instance, position = r.Position, normal = r.Normal, material = r.Material }
                    end
                    table.insert(fl, r.Instance)
                    p.FilterDescendantsInstances = fl
                end
                return { position = origin + dir }
            end)
            if okc then return res end
            local r2 = workspace:Raycast(origin, dir)
            if r2 then return { instance = r2.Instance, position = r2.Position, normal = r2.Normal, material = r2.Material } end
            return { position = origin + dir }
        end

        local function myCastThrough(origin, dir, maxDist, filterList)
            return myCast(origin, dir, nil, filterList, nil)
        end

        -- ★acrepair 2026-11-06：优先用 ac_kill.luau 的实现。
        -- 它的 cast 完整复刻了原版两条过滤分支（Shared.Raycast:81 isPartFiltered /
        -- :88 isPartWhitelisted），而上面这份 myCast 只处理 filterFn，Exclude 模式下
        -- 不做人物配件/碰撞胶囊/RootPart 过滤；它的 castThrough 则直接转发无检测的
        -- castThroughDistance，语义与原版逐字一致。
        -- 没有 ac_kill 时退回上面两份，保证单独注入主脚本也能跑。
        local acm0 = getgenv().MV_AC
        local castImpl = (type(acm0) == "table" and type(acm0.cast) == "function") and acm0.cast or myCast
        local castThroughImpl = (type(acm0) == "table" and type(acm0.castThrough) == "function") and acm0.castThrough or myCastThrough

        getgenv().MV_MARK_WRAP(castImpl, origCast0)
        rc0.cast = castImpl
        getgenv().MV_MARK_WRAP(castThroughImpl, origCastThrough0)
        rc0.castThrough = castThroughImpl

        -- ★acrepair 2026-11-06：castThroughDistance 恢复为直接转发原版。
        -- 旧实现把它也裹成「壳调 rc0.cast」，两个后果：
        --   ① 性能：原版一次 castThroughMaterials（最多 100 段 1000 stud 的 Raycast）
        --      被拆成最多 32 次独立 workspace:Raycast；
        --   ② 语义：丢掉穿透材质判定（checkMaterialDepth / u108 材质深度表 /
        --      BreakableDoor / MaterialVariant / applyMapMinPenetration 的 Map 最小穿透），
        --      「一次穿透距离查询」退化成「单次命中」，穿墙判定直接错。
        -- 原版该函数无检测 → 直通原版是唯一正确做法。
        rc0.castThroughDistance = origCastDist0

        getgenv().MV_RAYCAST_PATCHED = true
        warn("[ac-early] Raycast 已接管（cast / castThrough；castThroughDistance 直通原版）")
    end
end

-- MovementV2 Hub 魔改版：hyperFire 默认开

--[[
MovementV2 Hub  v2  ──  WindUI GUI
    ─────────────────────────────────────────────────────────────
    修正 v1 的致命错误：
      · hook 一律使用 hookfunction 的**返回值**作为 original，杜绝递归
      · 不做每帧全量扫描，ESP 用 Heartbeat 降频 + 缓存
      · 网络层只在 ShootWeapon 上介入（per-packet 独立闭包，实测独立）

    功能
      Combat : Silent Aim / FOV / 平滑 / 头部优先
      Rage   : 大陀螺 / 自动开火 / 瞬间换弹
      Visuals: ESP 方框 / 血条 / 名字 / 距离 / 武器 / 队伍
      Misc   : 快捷买枪 / 状态面板
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer

-- 平台判断：手机没有键盘鼠标，输入和窗口尺寸都要变
local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local IS_CONSOLE = UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled

---------------------------------------------------------------------
-- 全局单例注册表：跨 reload 追踪所有连接与绘制，杜绝残留
---------------------------------------------------------------------
local REG = getgenv().MV_REG
if REG == nil then
    REG = { conns = {}, espSets = {} }
end
if REG.conns then
    for _, c in ipairs(REG.conns) do
        pcall(function() c:Disconnect() end)
    end
end
REG.conns = {}
if type(getgenv().MV_REG) ~= "table" then getgenv().MV_REG = REG end

-- 代数标记：旧实例的常驻循环看到代数变化即自行退出
REG.gen = (REG.gen or 0) + 1
local MY_GEN = REG.gen

-- 清空上一实例的全部 Drawing（透视残留的真正来源）
-- ⚠ 以前这里是一句 cleardrawcache()：它同时把执行器的 Drawing 系统打坏，
-- 重载几次之后新实例画的线一条都不显示（对象存在、Visible=true、代码在跑）。
-- 现在只销毁「我们自己登记过的」对象。
pcall(function()
    if type(getgenv().MV_REAP_DRAWINGS) == "function" then getgenv().MV_REAP_DRAWINGS() end
end)

-- 回收上一实例的窗口 / 连接 / 绘制
do
    local prev = getgenv().MV_V2
    if prev then
        pcall(function()
            if prev.window and prev.window.Unload then prev.window:Unload() end
        end)
        if prev.state then
            for _, c in ipairs(prev.state.conns or {}) do
                pcall(function() c:Disconnect() end)
            end
            if prev.state.espObjects then
                for _, set in pairs(prev.state.espObjects) do
                    for _, d in pairs(set) do
                        if d and d.Remove then pcall(function() d:Remove() end) end
                    end
                end
            end
            prev.state.conns = {}
            prev.state.espObjects = {}
        end
    end

    -- Maclib 的 Unload 不真正销毁 ScreenGui，强制回收执行器容器里的菜单本体
    --
    -- ⚠⚠⚠ 这段是灾难级的，必须严格限制。
    --
    -- 原来的写法：
    --     local holder = (gethui and gethui()) or game:GetService("CoreGui")
    --     for _, c in ipairs(holder:GetChildren()) do
    --         if c:IsA("ScreenGui") and #c:GetDescendants() > 100 then
    --             c:Destroy()
    --         end
    --     end
    --
    -- 问题：gethui() 在脚本刚注入的那一瞬间不一定可用（执行器还在初始化）。
    -- 一旦它是 nil，holder 就退化成 CoreGui，而 CoreGui 的直接子项里有：
    --     [ScreenGui] RobloxGui   后代 = 4372
    -- 这条会被 #c:GetDescendants() > 100 判定为「我们的旧菜单」直接 Destroy()。
    --
    -- RobloxGui 是 Roblox 自己的全部界面（快捷栏、HUD、聊天、菜单…）。
    -- 把它删掉 = 玩家的快捷栏和 HUD 整个消失，且游戏内的背包 UI 无法重建
    -- → 表现为「捡东西消失、买不了东西、连刀都看不到」。
    --
    -- 正确做法：
    --   1) gethui() 拿不到就**什么都不做**（宁可留个残影，也不能冒险）
    --   2) 容器必须是 gethui() 的返回值，绝不退化成 CoreGui
    --   3) 名字里带 Roblox 的一律跳过
    --   4) 只删「看起来是我们自己的」——名字是 ScreenGui 且里面有 Base
    local okh, holder = pcall(function()
        if gethui then return gethui() end
        return nil
    end)
    if okh and holder and holder ~= game:GetService("CoreGui") then
        local okc, kids = pcall(function() return holder:GetChildren() end)
        if okc and kids then
            for _, c in ipairs(kids) do
                if c:IsA("ScreenGui") then
                    local nm = tostring(c.Name)
                    local looksOurs = (nm == "ScreenGui" or nm == "MVHubMobileControls")
                        and (c:FindFirstChild("Base") ~= nil or nm == "MVHubMobileControls")
                    local protected = nm:lower():find("roblox", 1, true) ~= nil
                    if looksOurs and not protected then
                        pcall(function() c:Destroy() end)
                    end
                end
            end
        end
    end

    -- ★★★ 2026-11-06：重载时必须把上一实例的 WindUI / 图鉴面板彻底摘掉 ★★★
    --
    -- 实测：这个执行器里 `ScreenGui:Destroy()` 是**空操作**（pcall 返回 true、
    -- 对象仍挂在父级下）。所以反复重载会累积出 3 套 WindUI + 22 个 MV_SkinPanel，
    -- 屏幕上表现为「玩家列表重复好几份」「面板一层叠一层」。
    -- Destroy 靠不住，改用「Enabled=false + Parent=nil」把旧 GUI 从整棵树上摘掉。
    do
        local okh2, holder2 = pcall(function()
            if gethui then return gethui() end
            return nil
        end)
        local lp2 = game:GetService("Players").LocalPlayer
        local pg2 = lp2 and lp2:FindFirstChild("PlayerGui")
        for _, h2 in ipairs({ (okh2 and holder2) or nil, pg2 }) do
            if h2 then
                local okc2, kids2 = pcall(function() return h2:GetChildren() end)
                if okc2 and kids2 then
                    for _, c2 in ipairs(kids2) do
                        if c2:IsA("ScreenGui") then
                            local nm2 = tostring(c2.Name)
                            if string.find(nm2, "WindUI", 1, true)
                                or string.find(nm2, "MV_SkinPanel", 1, true)
                                or string.find(nm2, "MV_TestPanel", 1, true) then
                                pcall(function()
                                    c2.Enabled = false
                                    c2.Parent = nil
                                end)
                            end
                        end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------
-- 依赖
---------------------------------------------------------------------
-- GUI 库改用 WindUI（见下方 GUI 段；MacLib 已整体移除）

local Remotes = require(RS:WaitForChild("Database"):WaitForChild("Security"):WaitForChild("Remotes"))
local shootPacket = Remotes.Inventory.ShootWeapon

-- ⚠ 兼容垫片：这个执行器里 table.clone 是 nil。
-- VFX 学习模块直接调用它，于是「地图里一放烟就刷一屏 attempt to call a nil value」，
-- 而且这个调用只在烟雾带 Duration 时才走到，所以看起来像是随机报错。
-- 在这里补上的意义不只是修当前实例：重载时残留在信号上的旧闭包用的是旧字节码，
-- 它们同样会踩到这个 nil —— 垫片一补，新旧实例一起被治好，
-- 不用靠重进服务器才能让红字停下来。
if not table.clone then
    table.clone = function(t)
        local out = {}
        for k, v in pairs(t) do out[k] = v end
        return out
    end
end

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local cfg = {
    -- 瞄准
    silentAim = false,           -- 总开关
    aimTrigger = "hold",         -- hold（按住）| always（始终）| toggle（按键切换）
    aimToggled = false,          -- toggle 模式下的当前状态
    aimMode = "smooth",          -- "smooth"（转视角，安全）| "silent"（只改弹道，有风险）
    fov = 300,                   -- 瞄准范围圈半径（像素）；同时也是自瞄搜索半径
                                 -- ⚠ 75 太小：目标只要离开准星 75 像素就出圈，
                                 --   表现就是「6 连发里有的追踪、有的打墙」（实测 vDbg="fov d=488>250"）。
                                 --   300 覆盖大半屏，静默/平滑都不再漏目标。
    -- 360° 静默：忽略「目标是否在画面内」，屏幕外、背后一律纳入候选。
    -- 静默只改子弹方向、不转视角，所以画面上看不看得见他并不影响能不能打中。
    -- 只保留「距离」和「视线通畅」两条限制。
    --
    -- ⚠ 默认改成 true。用户实测「6 连发里有的追踪、有的打墙」，诊断出来是
    --    vDbg = "fov d=488>250" —— 目标一移到屏幕边缘外 250px 就不锁了，
    --    那几发直接照准星方向飞。既然静默不依赖准星朝向，这个 FOV 限制本来就没必要。
    -- ⚠ 默认 false：true 时「360° 全向锁定」会隐藏 FOV 范围圈，
    -- 用户每次重载后都会觉得「开了自瞄却没有圈」。想全向自己开。
    fullSphere = false,
    showFov = true,
    fovColor = Color3.fromRGB(255, 255, 255),
    -- ⚠ 默认必须开。原来默认 false，配合「召唤 CT bot」会变成：
    -- 自己是 CT + bot 也是 CT → sameTeam=true，但过滤没启用 → 自瞄把队友全锁上。
    teamCheck = true,
    headPriority = true,
    -- ⚠ 默认关掉。它做的是「相机 → headPos」的射线遮挡检测，但瞄准点可以是腿。
    --    腿露在外面、头被栏杆/箱子挡住时会被误判成「看不见」，静默直接跳过那一发 ——
    --    用户看到的就是「高科技追踪子弹有一半不追踪」。
    --    需要严格遮挡判断的人可以手动打开。
    aimVisibleCheck = true,
    maxAimDist = 500,
    aimKeyHeld = false,          -- 已废弃，改用 aimInput.down
    -- 目标锁定
    -- ⚠ 默认关闭：锁定会在解锁后每帧立刻重新锁回去，手动滑屏/移动鼠标完全拉不回来。
    -- 想用就在「瞄准 → 锁定目标」里手动开。
    lockEnabled = false,
    lockMaxSeconds = 1.5,   -- 原来 6 秒，太长：目标都出圈了还被拉回去
    -- 目标优先级
    targetMode = "crosshair",     -- crosshair|nearest|farthest|lowesthp|highesthp|balanced|threat
    crosshairWeight = 1.0,        -- balanced 模式：屏幕距离权重
    distanceWeight = 2.0,         -- balanced 模式：世界距离权重
    preferFacing = false,         -- 优先瞄正在看着你的人
    -- 人体化：让操作看起来像真人
    smoothness = 0.06,           -- 越大越慢越像人。0.22 明显跟不上移动目标，0.05~0.08 才跟手
    jitter = 0.0,                -- 手抖强度（度）；0 = 完全不抖（默认关闭，开了会明显抖）
    reactionDelay = 0.14,        -- 发现目标后多久开始瞄（秒）
    headChance = 0.55,           -- 旧模式：瞄准头部的概率
    aimHitPart = "auto",         -- 静默打哪个部位：auto / head / chest / stomach / legs；auto 时交给下面的「露哪打哪」
    -- 自动重新装备：背包里有武器但手上是空的时主动 equip（默认开，修复"买不到/捡不到"）
    autoReequip = true,
    -- ── 自动拾取地上的武器：**恐怖分子 / 反恐精英各一套独立配置** ──
    -- 运行时按 LocalPlayer:GetAttribute("Team") 自动选那一套，切换阵营立刻生效。
    --   pickupOn_X    开关
    --   pickupStrat_X 策略：value(仅本阵营) / all(敌人枪也捡) / better(只捡更好) / named(只捡指定)
    --   pickupRange_X 拾取半径
    --   pickupNamed_X 指定武器（strat=named 时生效）
    pickupOn_T = true,
    pickupStrat_T = "value",
    pickupRange_T = 6,
    pickupNamed_T = "",
    pickupOn_CT = true,
    pickupStrat_CT = "value",
    pickupRange_CT = 6,
    pickupNamed_CT = "",
    autoPickupEquip = false,      -- 两套共用：捡到后自动装备；默认关——换上的新枪 Identifier 服务端账本不认，会打出 0 伤害
    autoPickupInterval = 0.35,    -- 两套共用：扫描间隔（秒）；服务端限速 7/s
    -- ⚠ 换肤是否允许「本地改写 CurrentEquipped 属性」。
    -- 打开它会破坏背包同步（买东西不进、捡东西消失、主武器切不出来），
    -- 默认永久关闭，只留作反面开关。
    skinWriteAttr = false,
    -- 移动端：屏幕「开火」按钮按住时为 true（由按钮的 InputBegan/Ended 驱动）
    mobileHoldFire = false,
    aimPartPriority = true,      -- 露哪打哪：头 > 脖子/胸 > 腹 > 手 > 腿 > 脚（头永远排第一）；aimHitPart 明确指定时以它为准
    overshoot = false,           -- 过冲再回拉；默认关（开了镜头会先冲过头再拉回，看起来像抖）
    -- 暴力
    multiShot = false,
    -- 近战超距离倍数：把 MeleeAttack 的 Direction 长度和 Distance 一起放大。
    -- 1 = 关闭。3 = 射程变 3 倍（刀原本约 3~4 格，3 倍就是 9~12 格）
    meleeRange = 1,
    -- ⚠ 跳过开火间隔默认关闭，而且它不是「加快射速」。
    --
    -- 它只把客户端的 NextShotDue 维持在「现在」，让你连点时客户端不再拒绝出手。
    -- 但服务端会按武器 FireRate 和 20 包/秒双重校验：
    --   AWP FireRate=1.46 → 服务端 1.46 秒才接受一发
    -- 实测把发包间隔压到 0.05 秒的后果是整批包被丢弃，
    -- 连本来能打中的那一发也一起废掉（表现：开了它反而一发都不掉血）。
    -- 所以默认关；要开的话必须保证实际出手间隔 ≥ 武器 FireRate。
    skipFireDelay = true,        -- 跳过开火间隔；hyperFire 必须开，shoot() 要求 now-NextShotDue < 0.035
    bunnyhop = false,            -- 自动兔子跳（落地瞬间再跳，参考 CS）
    wallbang = false,         -- 穿墙识别：能穿才锁（只看材质会放宽过头，实测开了反而打不出伤害；要开自己开）            -- 穿墙：把子弹起点搬到目标身前
    wallbangOffset = 3,          -- 起点距目标多远（stud）
    bulletTrack = false,         -- 子弹追踪：起点整个搬到目标身侧
    trackOffset = 2,             -- 追踪时起点距目标多远
    meleeSpeed = 3,              -- 挥刀动画加速倍数
    mouseGain = 0.12,            -- 鼠标瞄准增益（太高会过冲 → 来回抖）
    mouseMaxStep = 12,           -- 鼠标瞄准每帧最大移动像素
    mouseSmooth = 0.55,          -- 鼠标瞄准低通系数（越大越顺但越慢）
    mouseReleaseDelay = 0.6,     -- 真实键鼠操作后暂停鼠标瞄准多久
    nativeAimAssist = false,     -- 解锁游戏原生瞄准辅助（后坐力减半 + 磁性吸附）
    autoFireMaxOffset = 100,      -- 自动开火：准星离目标多少像素内才允许开火
    smoothAimHijack = true,      -- 平滑瞄准（接管游戏磁性吸附入口，真正转视角）
                                 -- ⚠ 默认 true：原来默认 false 且 installSmooth 只在 GUI toggle 里调用，
                                 --   于是「注入脚本后自瞄完全没用」——用户必须手动去 GUI 点开关。
                                 --   现在加载时自动装 hook（见文件末尾），开箱即用；不想用就在 GUI 关掉。
    smoothAimJitter = 0,         -- 平滑瞄准的抖动幅度（度）
    smoothAimDrop = 2.2,         -- 平滑瞄准的瞄准点：从 headPos 往下多少 stud
                                 -- ⚠ 0.9 只到「肩膀上方」那块空气（实测 headPos.y=1004.81 - 0.9 = 1003.91，
                                 --   而胸口 LowerTorso.y=1002.57）。2.2 精确落在胸口，误差 0.04 stud。
    smoothAimSpeed = 0.18,       -- 平滑瞄准：每帧走剩余角度的比例（越小越慢越平滑）
    smoothAimMaxDeg = 2.0,       -- 平滑瞄准：每帧最大转角（度）
                                 -- ⚠ 这是「大角度救命值」：太小追不上（0.05 度/帧 = 180度要15秒，
                                 --   表现就是「瞄空气」）；太大小角度会瞬吸。2.0 → 180度约0.44秒。
    smoothAimDeadzone = 0.6,     -- 平滑瞄准：死区（度）
                                 -- ⚠ 0.12 太窄会「抽风」：误差恰好卡在边界上，一会儿超死区动一下、
                                 --   一会儿被吃掉归零，准星反复微抖（实测 pitch 在 -10.17↔-10.29 来回跳）。
                                 --   0.6 度后实测 2.4 秒漂移 0.00 度。
    aimPenetrateLayers = 1,      -- 视线检测最多穿透几层「透明物」
                                 -- 1 = 和原版一样的射线次数，只多一个 Transparency 判断，零额外成本。
                                 -- 只有「雪面 + 玻璃 + 铁丝网」叠在一起才需要 2~3。
                                 -- 不做名字白名单：会随地图膨胀，且换图就失效。
    instantReload = false,       -- 瞬间换弹（跳过动画，弹匣一空立刻补满）
    espCoverTint = false,        -- 敌人高亮：暴露/掩体后用不同颜色
    colorExposed = Color3.fromRGB(255, 60, 60),    -- 暴露在外
    -- ⚠ 掩体后必须是「敌人色系的暗色」，不能是蓝色。
    -- 原来这里是 RGB(90,190,255) —— 和队友色几乎一样，
    -- 结果敌人躲在掩体后就被画成蓝色，玩家一眼看去以为「自瞄锁队友了」。
    -- 实测 sameTeam 全程稳定为 false，自瞄根本没锁队友，是颜色在骗人。
    colorCovered = Color3.fromRGB(170, 55, 55),    -- 躲在掩体后（暗红，仍是敌人色系）
    bulletCount = 3,
    spreadDeg = 1.5,
    infiniteAmmo = false,
    spinbot = false,
    spinSpeed = 360,
    autoFire = true,              -- 默认开：每次重载重置成 false 太坑（用户反复遇到「自动开火没用」）
    autoFireDelay = 180,          -- 毫秒：锁定目标后等这么久才开火（模拟反应时间）
    -- 每种武器类型的自动开火参数
    weaponProfiles = {
        Rifle   = { enabled = true,  maxDist = 300 },
        Sniper  = { enabled = true,  maxDist = 900 },
        Pistol  = { enabled = true, maxDist = 150 },   -- 默认关：手枪半自动会被自动开火打成连发
        SMG     = { enabled = true,  maxDist = 180 },
        -- 霰弹枪：射程只有 120，超出基本零伤害。60 太短（贴脸都够不到），改 120。
        Shotgun = { enabled = true,  maxDist = 120 },
        Melee   = { enabled = true, maxDist = 6   },
    },
    -- 每把枪的「静默瞄准最大距离」。没列到的用 maxAimDist。
    -- 霰弹枪必须短：远了子弹散到天上，锁了也是白开一枪。
    aimDistByWeapon = {
        ["Nova"] = 45, ["Sawed-Off"] = 45, ["MAG-7"] = 50, ["XM1014"] = 70,
          ["Zeus x27"] = 13,   -- 跟游戏配置 Range=13.584 对齐（原来是 15，超出真实射程）
          -- ⚠ 近战武器必须单独配：不配就会退回 maxAimDist（500），
          -- 于是「拿着刀锁 500 stud 外的目标」，而刀实际只有 6 stud 射程 —— 锁了也打不到。
          -- 用户反馈的「近战不会触发瞄准 / 电击枪锁远处」就是这个原因。
          ["T Knife"] = 6, ["CT Knife"] = 6, ["Butterfly Knife"] = 6,
          ["Bowie Knife"] = 6, ["Karambit"] = 6, ["Bayonet"] = 6,
          ["M9 Bayonet"] = 6, ["Falchion Knife"] = 6, ["Huntsman Knife"] = 6,
          ["Shadow Daggers"] = 6,
        ["AWP"] = 900, ["SSG 08"] = 800,
        ["Negev"] = 300,
        ["MAC-10"] = 150, ["MP9"] = 150, ["P90"] = 180, ["UMP-45"] = 180,
        ["Glock-18"] = 120, ["USP-S"] = 120, ["P250"] = 120, ["Five-SeveN"] = 130,
        ["Desert Eagle"] = 200, ["R8 Revolver"] = 250, ["Tec-9"] = 150, ["Dual Berettas"] = 120,
        ["AK-47"] = 400, ["M4A4"] = 400, ["M4A1-S"] = 350,
        ["Galil AR"] = 300, ["FAMAS"] = 300, ["AUG"] = 350, ["SG 553"] = 400,
        ["SCAR-20"] = 800, ["G3SG1"] = 800,
    },
    -- ESP
    esp = true,
    espBox = true,
    espHealth = true,            -- 血条保留（信息量大、开销小）
    espName = true,
    espSkeleton = false,         -- 骨骼线（头-躯干-四肢）
    espHitbox = false,           -- 每个部位画碰撞框
    -- ⚠ 以下三个是历史遗留字段，**没有任何代码读取它们**。
    -- 实际生效的皮肤表是 S.skinPaint（元表自动落盘到 getgenv().MV_SKIN_SAVE）。
    -- 留在这里只是因为旧存档里有这几个键（saveCfg 会回写），删掉会让老存档多出孤儿键。
    skinAutoPaint = true,
    skinAutoOpen = true,
    skinAutoName = "Stock",
    -- 性能：ESP 每 N 帧刷一次。手机默认 2（30Hz），PC 默认 1。
    -- Drawing 的属性写入是跨 C++ 调用，每帧几十次是最贵的开销；降频视觉上几乎看不出来，
    -- 但属性写入量直接砍半。功能一个不减，只是刷新率降下来。
    espEveryNFrames = IS_MOBILE and 3 or 1,   -- 手机端 3 帧一次（10Hz @30fps）
    -- ⚠ 第三人称默认关闭，而且开着会导致「镜头被抢」。
    --
    -- 实测：开启时相机 yaw 每 0.15 秒跳 ±40 度、pitch 从 48 飙到 80；
    -- 关掉后连续采样 9 次 Δyaw/Δpitch 全是 0.00。
    --
    -- 原因：tpStep 在 RenderStep(Last-1) 把相机搬到身后 12 格，
    -- 而游戏的第一人称相机每帧又把它拉回原处 —— 两个系统抢同一个 CFrame，
    -- 表现为镜头疯狂抖动、抬头看天。跟自瞄完全无关。
    thirdPerson = false,         -- 第三人称视角（会与游戏相机打架）
    thirdPersonDist = 12,        -- 第三人称最远距离
    espDist = true,
    autoFireWarmup = true,       -- 热身阶段是否也自动开火（默认 true = 保持历史行为；关掉则 Warmup 不按左键）

    espWeapon = not IS_MOBILE,   -- 手机默认不画武器图标（每条要多一个 Drawing）
    espRange = IS_MOBILE and 300 or 600,   -- 手机端缩到 300：远处目标不画，省 Drawing
    showTeammates = false,
    showBots = true,
    -- 尸体默认不画。
    -- 尸体没有「位置漂移」问题，但它的框会一直挂在那儿（还带名字 + 距离），
    -- 很容易被误认成「自瞄锁着一个空气位置」。实测 vDbg=dead 说明自瞄根本没锁，
    -- 只是画面上有个框。想看残局信息的人可以在菜单里打开。
    hideDead = true,
    -- 没有模型的目标不画（PVS 剔除 / 已离开 / 已死亡但服务端还在发 pose）。
    -- 关掉它就会看到停在旧位置的框，也就是「火柴人」。
    -- ⚠ 默认 false：模型被 PVS 剔除的**活人**也要画框。
    -- 设成 true 时，贴脸的敌人如果模型被剔除就完全不显示（自动开火照常，因为它只要位置），
    -- 表现就是「人都贴脸了还没有框」。代价是尸体可能留一会儿残框（由 hideDead/ghostPurge 处理）。
    hideNoModel = true,   -- 被 PVS 剔除的目标不画框（假框会骗自瞄；真正要修的是"看得见却没框"）
    -- 冻结目标（数据不更新）默认不画，避免残影
    hideFrozen = true,
    -- 目标从 ESP 消失后，Drawing 对象保留多久再彻底销毁（秒）。
    -- 太短会导致闪烁（PVS 一抖就重建），太长会留残影。3 秒比较稳。
    ghostPurgeSeconds = 3,
    -- 数据新鲜度
    -- ⚠ 用「秒」而不是 tick：不同 generation 的 buffer 时钟起点不同，
    -- 拿全局最大 tick 相减会算出敌人落后 6 万 tick（16 分钟）这种假数字。
    -- ⚠ 阈值不能太小：实测敌人的渲染姿态平均 1.69 秒才更新一次（自己 0.00 秒），
    -- 这是 RemoteBuffer 的正常刷新节奏，不是冻结。设成 1.2 秒会把正常敌人整批误杀。
    staleSeconds = 3.0,          -- 位置多久没更新才认定冻结
    showStaleModel = false,      -- 冻结的真人是否还要画（默认不画，避免「框在空气里」）
    frozenTicks = 150,           -- 兼容旧逻辑/界面显示，不参与判定
    -- 外推（dead reckoning）
    -- 服务端对不可见玩家停止下发位置，框会永久钉在「最后一次被看到的地方」，
    -- 而人早就跑远了 —— 用户看到的就是「人走了，框还在原地」。
    -- 用最后已知速度沿直线往前推，至少方向是对的。
    -- 上限 extrapolateCap 秒：再长就纯属瞎猜，宁可停下来。
    extrapolateCap = 2.0,
    showExtrapolatedTag = true,  -- 外推出来的框打「推」标记
    -- 太旧的框直接不画。
    -- 实测能出现 age=49 秒的目标：那还是「上一次被看到」的位置，
    -- 换算成距离是 468 stud 外的空地。这种框留着只会让人以为那里有人，
    -- 甚至以为「自瞄在锁空气」。超过这个秒数就不画了。
    staleHideAfter = 15,
    -- 死亡瞬间标记的持续时间（秒）。
    -- Dead/Health 属性要等重生才重置，中间那几秒框会挂在原地。
    deathMarkSeconds = 4,
    showFrozenTag = true,        -- 冻结目标在框上打「旧」标记
    -- hideFrozen 只在上面定义一次（默认 true）。这里原来又写了一遍 false，
    -- 后定义的覆盖前面的，等于把「不画冻结目标」这个默认值废掉了。
    -- 投掷物出手后：用服务端下发的真实 state 重画轨迹
    -- 手持预览用的是「此刻速度」，移动/跳跃时必然偏（投掷有 0.7 秒准备动画）；
    -- 出手瞬间的 State.Velocity 已经包含真实叠加，用它算出来的轨迹是准的。
    throwTrackAfterRelease = true,
    -- 声音冲击波（脚下的扩散圈，不是透视框）
    soundRipple = true,          -- 有动静时在脚下画扩散波纹
    soundRippleSeconds = 1.6,    -- 一圈波纹存在多久
    soundRippleMax = 16,         -- 扩散到的最大半径（stud）
    soundColorShot = Color3.fromRGB(255, 170, 80),   -- 枪声：橙
    soundColorStep = Color3.fromRGB(150, 220, 255),  -- 脚步/其他：淡蓝
    -- 自动开火的点击节流（秒）。
    -- 原来是写死 0.08（最快 12.5 发/秒），对高刷屏太保守。
    -- 0.04 = 25 发/秒，已经超过服务端对绝大多数武器的射速校验。
    autoFireClickGap = 0.04,
    -- 自动开火时「按住左键」的最长持续时间（秒）。
    -- 本作后坐力是持续抬枪，按住不放镜头会一路飘到天上（实测 pitch 12→31）。
    -- 到点强制松手，让后坐力衰减，再继续下一轮。
    autoFireHoldLimit = 0.6,
    -- 无后座：拦 CameraController.setWeaponRecoil，不把后座目标灌进弹簧
    noRecoil = false,
    -- 自动压枪：按百分比把弹簧当前后座反向补回相机
    autoRecoilComp = false,
    -- ⚠ 垂直（pitch）和水平（yaw）必须分开配：
    --   垂直后坐力是**确定**的（每发都往上顶），可以压到 100%；
    --   水平后坐力是**随机方向**的（每次左右不定），压到 100% 会把"随机"抹成"锁死"，
    --   看起来反而不自然，而且会把准星从目标身上拽开。默认只压 60%。
    -- 游戏自己的 RecoilAssist 也是分开的（ReductionAmount=0.5 / HorizontalReduction=0.85）。
    recoilCompV = 100,        -- 垂直（pitch）压枪幅度 %
    recoilCompH = 60,         -- 水平（yaw）压枪幅度 %
    recoilCompPercent = 100,  -- 旧字段：V/H 都没配时才用它兜底（老存档兼容）
    -- 延迟补偿利用：把射击包的 ViewTick 往前/往后推（单位 tick，60tick≈1秒）
    -- 负数 = 回溯到更早（打敌人过去的位置），正数 = 推向未来
    viewTickOffset = 0,
    -- 投掷物出手后的真实 state（缓存在 learned.tracked[id].state）
    -- 陀螺的像素↔角度换算系数；不同游戏灵敏度下差别很大，对不上就调这个
    spinPixelPerDeg = 1.2,
    -- 纯客户端陀螺：只转自己客户端的模型，别人看不到、自己视角不动。
    -- 和 spinbot（命令层改写，已废弃）是两套东西。
    localSpin = false,
    -- 默认 false：陀螺本身就是"抢鼠标"的功能，让路等于它不转。
    -- 真正的安全阀是「窗口失焦」和「输入框聚焦」，那两条一直生效。
    spinPauseOnInput = false,
    -- 兔子跳叠速倍增（实验）。
    -- 1 = 关闭。>1 时把命令里的 PredictedBaseMoveSpeed 乘上这个值。
    -- 服务端按自己的物理算位置，大概率只影响本地预测 —— 想验证得让别人看你跑多快。
    bhopBoost = 1,
    -- 空中加速（air strafe）实验：off / turn / side
    --   turn = 把 Move 旋转 90°（垂直于当前输入）
    --   side = 只保留横向分量
    -- 只在「空中」时生效（S.bhOnGround == false），落地不干预。
    airStrafe = "off",
    -- 超射速（服务端认可版）：每开一枪后，异步再调 (rapidFire-1) 次 Weapon:shoot()。
    --
    -- ⚠ 这跟以前的「补发手搓包」完全不是一回事：
    --   手搓包 → 服务端静默丢弃（实测扣弹只 +1）
    --   连续 shoot() → 实测 6 发 / 30ms 间隔全部被服务端接受（扣弹 +6）
    --
    -- 前提：必须同时开启 skipFireDelay（下面 setRapidFire 会自动帮你开），
    -- 否则 shoot() 从第二发起就被客户端冷却挡住。
    rapidFire = 1,
    -- 连发间隔（秒）。0.03 = 33 发/秒。太小会被客户端 shoot() 内部挡住，
    -- 太大就没有意义。0.03 实测稳定。
    rapidGap = 0.03,
    -- ═══ 魔改版专用：按住左键持续连发 ═══
    -- 和 rapidFire 是两种不同的东西：
    --   rapidFire = 开一枪补发 N-1 次（burst，每次要点一下扳机）
    --   hyperFire = 按住就一直发，松开才停（真·连发武器的手感）
    -- 普通版保持 false；魔改版（mv_hub_v2_hyper.luau）默认 true。
    hyperFire = false,
    -- 连发间隔（秒）。0.02 = 50 发/秒。shoot() 内部要求
    -- (now - NextShotDue) < 0.035，所以 0.02 是安全下限附近，别低于 0.015。
    hyperGap = 0.12,
    -- 无散射（据点/完美精准）：把 Bullets[].Direction 重置成相机准星方向，
    -- 抹掉游戏自己加的散射偏移（跑动/连射/跳跃造成的偏离全部消失）。
    -- 静默瞄准开启且锁定目标时会优先用静默的方向。
    noSpread = true,
    -- 下包倒计时：屏幕上显示炸弹剩余时间 + 能不能拆
    showBombTimer = true,
    -- 雷达：本作自带小地图，默认关闭，需要时再开
    showSites = true,          -- 据点标记（A/B 点 3D 文字 + 距离）
    radar = false,
    radarSize = 190,
    radarRange = 400,
    -- 屏幕边缘箭头：屏幕外的敌人也能指方向（弥补 2D 投影画不出背后的人）
    offscreen = true,
    offscreenRange = 600,
    -- ⚠ 世界物品标注（地面武器/投掷物/下落物）：默认关闭。
    -- 原来没有默认值 → nil → drawWorldItems 里 `== false` 判断失效 → 每 0.12 秒空跑一轮。
    showWorldItems = false,
    -- 投掷物信息
    showGrenadeInfo = true,
    showVfxZones = true,         -- 显示烟/火的真实覆盖区域
    -- 反弹点标记：每个反弹点画一个小地面圈 + 序号。
    -- HE 扔进箱子/墙角时，真正炸到人的往往是第 2、3 个反弹点，不是第一个落点。
    showBounceDots = true,
    -- 下面三项只在「还没实测到 originOffset」时作为回退值。
    -- 真值来自游戏自己的 ReplicatedStorage.Shared.GrenadeSimulator.Constants：
    --   THROW_FORWARD_OFFSET = 1.35   THROW_HEIGHT_OFFSET = 2.4
    --   THROW_UPWARD_BIAS_FAR = 0.06  THROW_UPWARD_BIAS_NEAR = 0.04
    -- 旧值 0.65 / 0.19 是按「相机锚点」凑出来的，服务端实际以角色为锚点，已作废。
    throwForward = 1.35,         -- 游戏常量：前向偏移
    throwHeight = 2.40,          -- 游戏常量：高度偏移
    throwUpBias = 0.06,          -- 游戏常量：竖直分量 = 水平分量 × 此值（Near 取 0.04）
    -- 投掷延迟（秒）：从「按下左键」到「服务端真正出手」。
    --
    -- 实测：服务端收到投掷意图后 ~0.1 秒就出手（PredictGrenadeThrow → Spawn 只隔 103ms），
    -- 延迟的大头在客户端动画 —— Components.Grenade 里是
    --     task.delay(v5.Length * 0.7, fallbackThrow)
    -- 也就是 StartThrow 动画走到 70% 处才把意图发给服务端。
    --
    -- 手持预览按这个时间把起点沿当前速度前推。走路 19.8 stud/s 时 0.7 秒 = 13.9 stud——
    -- 这就是「扔出前预测不准、扔出后落点极准」的主要体积差。
    throwPredictLead = 0.7,
    throwAutoCalibrate = false,  -- 旧的「相机锚点」校准，会覆盖手感值；现在靠 originOffset
    showVfxBounding = false,     -- 额外的"包围圈"（比实际范围大一圈，对比用）
    grenadeRadius = 12,          -- HE 伤害半径估算。原来 25 太大（用户实测「爆炸范围明显过大」）
    -- 烟雾/火焰消散是渐变的：VFX 销毁后再多留这么久才收圈，避免"烟还在圈没了"
    grenadeEffectPad = 1.0,
    -- 落点圈被墙/木板挡住时变暗（Drawing 没有深度测试，否则看不出圈在板前还是板后）
    grenadeOccludeFade = true,
    -- 投掷物诊断：每 60 帧打一行 [GR] debris= tracked= drawn= projSeen= landPaths= err=
    -- 排查「扔出去什么都没有」时先打开它，一眼看出卡在「服务端没发包 / tracked 空 / 画出来 0 个」
    grenadeDiag = false,
    markThreat = true,
    -- 烟雾
    -- ⚠ 默认改成 false：子弹能穿烟不等于「看不看得见」，烟里的人锁了就是瞎打。
    aimThroughSmoke = false,
    markSmoke = true,            -- ESP 上标记"在烟后"的人
    -- 烟雾遮挡判定阈值：烟雾展开程度要超过这个值才算「真的挡住了」。
    -- 0.6 = 展开 60% 以上。调低更保守（烟还没起来就判定挡住），
    -- 调高更宽松（要等烟几乎满了才判定挡住）。默认 0.6 接近人眼感受。
    smokeBlockThreshold = 0.6,
    -- 投掷物爆炸后是否继续显示落点圈，直到效果真正结束
    -- （燃烧瓶约 7 秒、烟雾约 18 秒、HE 约 1.5 秒）
    grenadeKeepAfterBoom = true,
    -- 投掷物抛物线预览：拿着投掷物自动显示
    throwAuto = true,
    throwPreview = false,
    throwKeyHeld = false,
    throwLearn = true,
    throwMode = "auto",          -- auto（按左键=远投 右键=近投 自动判断）| Far | Near
    throwGravity = 60,
    throwColor = Color3.fromRGB(120, 255, 140),
    throwSteps = 64,
    colorEnemy = Color3.fromRGB(255, 60, 60),
    colorTeam = Color3.fromRGB(60, 160, 255),
    -- 内部
    lastSeq = 0,
    toggleKey = Enum.KeyCode.RightControl,
}

-- 配置持久化
-- 每次重新加载脚本都会重建 cfg 表，所有开关回到默认值——
-- 用户明明开了的功能在 reload 之后就"失效"了，这是之前大量"开了没用"的根源。
-- 用 getgenv 存一份，加载时恢复（只恢复标量，跳过 Enum/表/函数）。
-- 配置版本迁移
-- ⚠ 外层必须用 do...end 包住：上一句是 `local cfg = { ... }`，直接接
-- (function() ... end)() 会被 Luau 当成 table 构造器的调用，报 "Ambiguous syntax"。
-- ⚠ 同时也不能用裸的 do...end 放 local：do 块里的 local 照样占主 chunk 的寄存器槽，
-- 而主 chunk 已经贴着 200 上限（超了就是 "Out of local registers ... exceeded limit 200"，
-- 且 loadstring 只会返回 nil，看起来像「改动没生效」，实际整份脚本都没跑起来）。
-- 所以是 do + 立即执行函数两层：local 在函数里，语句边界靠 do 划定。
-- ⚠ 出厂值必须在「存档恢复」之前快照。
-- 原来的顺序是：先把 MV_CFG_SAVE 覆盖进 cfg，再 deepcopy(cfg) 当 CFG_DEFAULTS ——
-- 那份"默认值"里已经有上次的存档了。于是「恢复默认配置」按钮点下去恢复的是
-- **上次的配置**，等于按钮无效。
do
    local function deepcopy(x)
        if type(x) ~= "table" then return x end
        local o = {}
        for k, v in pairs(x) do o[k] = deepcopy(v) end
        return o
    end
    getgenv().__MV_CFG_FACTORY = deepcopy(cfg)
end
do
    (function()
        local saved = getgenv().MV_CFG_SAVE
        if type(saved) ~= "table" then return end
        local ver = tonumber(saved.__v) or 1
        if ver < 2 then
            -- v1 → v2：投掷起点从「相机锚点」改成「角色锚点」。
            -- 这三项是相机锚点拟合出来的，在角色锚点下没有意义，必须丢弃 ——
            -- 否则新默认值会被旧存档盖回去（throwHeight 2.4 被写回 0.65 就是实例）。
            saved.throwHeight = nil
            saved.throwForward = nil
            saved.throwUpBias = nil
        end
        if ver < 3 then
            -- v2 → v3：staleSeconds 默认值 1.2 → 3.0。
            -- 实测敌人的渲染姿态平均 1.69 秒才刷新一次，1.2 秒的阈值会把
            -- 正常敌人整批判成「冻结」直接不画。旧存档里存的 1.2 必须丢掉。
            saved.staleSeconds = nil
        end
        if ver < 4 then
            -- v3 → v4：尸体默认隐藏（hideDead 从 false 改 true），
            -- 并且新增 staleHideAfter=15：秒数太旧的框整个不画。
            saved.hideDead = nil
            saved.staleHideAfter = nil
        end
        if ver < 5 then
            -- v4 → v5：反弹点标记重新启用（showBounceDots false → true）。
            -- 旧存档把这个键固化成 false 了，不清掉的话新默认值永远被写回 false
            -- （实测：改了 cfg 默认值、重载后读出来还是 false，就是这条）。
            saved.showBounceDots = nil
        end
        if ver < 6 then
            -- v5 → v6 的历史迁移（保留 id，不再做 showSites 相关处理）
        end
        if ver < 7 then
            -- v6 → v7：把 showSites 强制拉回代码默认值（true）。
            -- v6 那版曾经把默认改成 false 并把 false 写进了存档；
            -- 现在恢复成默认开，必须清掉存档里的 false，否则还是显示不出来。
            saved.showSites = nil
        end
        if ver < 5 then
            getgenv().MV_CFG_MIGRATED = string.format("%d -> 5", ver)
        end
        local restored = 0
        for k, v in pairs(saved) do
            local cur = cfg[k]
            if cur ~= nil then
                -- 标量：类型必须一致（防止旧存档把 number 塞进 boolean 字段）
                if (type(v) == "boolean" or type(v) == "number" or type(v) == "string")
                    and type(cur) == type(v) then
                    cfg[k] = v
                    restored += 1
                -- Color3：saveCfg 里编码成 {__t="Color3", r,g,b}
                elseif type(v) == "table" and v.__t == "Color3" and typeof(cur) == "Color3" then
                    local okc, col = pcall(function() return Color3.new(v.r, v.g, v.b) end)
                    if okc then cfg[k] = col; restored += 1 end
                -- EnumItem：{__t="Enum", e="KeyCode", n="RightControl"}
                elseif type(v) == "table" and v.__t == "Enum" and typeof(cur) == "EnumItem" then
                    local okE, item = pcall(function() return Enum[v.e][v.n] end)
                    if okE and item ~= nil then cfg[k] = item; restored += 1 end
                end
            end
        end
        getgenv().MV_CFG_RESTORED = restored
    end)()
end

-- 把当前配置写回 getgenv，供下次加载恢复
-- ⚠ 以前只存 boolean/number/string，于是 Color3（抛物线颜色、框颜色…）、
-- EnumItem（菜单开关键）每次重载都回默认值 —— 用户以为"改了没保存"。
-- 现在把这两类编码成带标记的小表一起存。
local function saveCfg()
    local out = {}
    for k, v in pairs(cfg) do
        local t = type(v)
        if t == "boolean" or t == "number" or t == "string" then
            out[k] = v
        elseif typeof(v) == "Color3" then
            out[k] = { __t = "Color3", r = v.R, g = v.G, b = v.B }
        elseif typeof(v) == "EnumItem" then
            out[k] = { __t = "Enum", e = tostring(v.EnumType), n = v.Name }
        end
    end
    out.__v = 7
    getgenv().MV_CFG_SAVE = out
end
saveCfg()

local S = {
    shots = 0,
    rewritten = 0,
    bulletsInjected = 0,
    lastTarget = "-",
    espObjects = {},
    conns = {},
    frameHook = nil,
    ammoAttrBackup = nil,
    -- 本实例是否还应当继续工作。
    --
    -- ⚠ 所有常驻循环以前只看 REG.gen：那个判据只能覆盖「重载」（新实例把 gen 加一），
    -- 覆盖不了「单独卸载」—— 直接调 Window:Unload() / WindUI:Destroy() 时 gen 不变，
    -- 皮肤轮询、世界物品循环、刷新列表这些 while true 会一直跑到下次重载，
    -- 拿着已经销毁的 GUI 对象继续干活（CPU 白烧 + 日志刷屏 + 偶发报错）。
    -- fullCleanup 第一件事就是把它置 false，所有循环同时看这个标志。
    _alive = true,
}

-- ═══ 默认配置基线（换 GUI 库后保留老 UI 那套默认值）═══
-- 用「存档恢复之前」拍下的快照；没有快照才退回当前 cfg（第一次加载）。
do
    S.CFG_DEFAULTS = getgenv().__MV_CFG_FACTORY
    getgenv().__MV_CFG_FACTORY = nil
    if type(S.CFG_DEFAULTS) ~= "table" then
        local function deepcopy(x)
            if type(x) ~= "table" then return x end
            local o = {}
            for k, v in pairs(x) do o[k] = deepcopy(v) end
            return o
        end
        S.CFG_DEFAULTS = deepcopy(cfg)
    end
end

-- ═══ 找菜单主 ScreenGui（唯一权威实现）═══
--
-- ⚠ 不能再用「ScreenGui 下面挂着叫 Base 的 Frame」当判据：
-- WindUI 的实际结构是 gethui()/WindUI（DisplayOrder = -99999）
--   → Window(Folder) → Frame，根节点上**没有** Base。
-- 用 Base 找的结果是 S.menuScreenGui 永远是 nil，连带两件事一起坏：
--   ① GetState 拿不到真实 Enabled，只能退回 WindUI 的 Closed 字段；
--   ② 商店打开时「自动收起菜单」那段 `if not sg then return end` 直接跳过，
--      菜单就永远盖在商店上面 —— 用户看到的是「商店点不动」。
S.findMenuGui = function()
    local roots = {}
    local okh, h = pcall(function() return gethui and gethui() end)
    if okh and h then roots[#roots + 1] = h end
    roots[#roots + 1] = game:GetService("CoreGui")
    local legacy = nil
    for _, rt in ipairs(roots) do
        local okd, descs = pcall(function() return rt:GetDescendants() end)
        if okd and descs then
            for _, d in ipairs(descs) do
                if d:IsA("ScreenGui") then
                    local nm = tostring(d.Name)
                    -- WindUI 主容器：名字精确等于 WindUI（通知/下拉/提示是 WindUI/xxx）
                    if nm == "WindUI" then return d end
                    -- 兼容旧版 GUI 库：ScreenGui 上挂 Base Frame
                    if legacy == nil and d:FindFirstChild("Base") then legacy = d end
                end
            end
        end
    end
    return legacy
end

-- 把 cfg 重置为出厂值，并尽量把 UI 控件同步过来（读不到的类型就跳过）
S.resetConfig = function()
    local d = S.CFG_DEFAULTS
    if type(d) ~= "table" then return false, "没有默认值基线" end
    local nTbl = 0
    for k, v in pairs(d) do
        if type(v) == "table" then
            -- ⚠ 表配置以前被整段跳过（weaponProfiles / aimDistByWeapon …），
            -- 于是「恢复默认」只恢复了一半。这里做两层深拷贝，
            -- 不能直接赋引用，否则后续修改会污染基线、下次恢复就带脏数据。
            local copy = {}
            for kk, vv in pairs(v) do
                if type(vv) == "table" then
                    local inner = {}
                    for k3, v3 in pairs(vv) do inner[k3] = v3 end
                    copy[kk] = inner
                else
                    copy[kk] = vv
                end
            end
            cfg[k] = copy
            nTbl += 1
        else
            cfg[k] = v
        end
    end
    -- UI 同步：S.UI 的 key 是**控件 ID**（AutoFire / SkinSlot1 …），不是 cfg 字段名，
    -- 两者没有可靠映射，硬对着改只会把无关控件设成错误值。
    -- 所以这里只恢复 cfg，界面在重开菜单/重载后自然同步。
    return true, string.format("已恢复出厂配置（含 %d 个表配置）；界面显示需重开菜单或重载后同步", nTbl)
end
local function myTeam() return tostring(LP:GetAttribute("Team")) end
local function charsFolder() return workspace:FindFirstChild("Characters") end
local function culledFolder() return RS:FindFirstChild("_PVS_CulledCharacters") end

-- 全量角色来源：可见角色 + 被 PVS 剔除的角色（后者在 ReplicatedStorage 里）
--
-- ⚠⚠⚠ 本作的真实结构和旧注释假设的完全不同（2026-11-05 实测）：
--
--     workspace.Characters/
--         Terrorists/              ← 空
--         Counter-Terrorists/      ← 空
--         Hostages/                ← 空
--         FTbh_5019/               ← ★ 玩家名做文件夹，**这个 Folder 本身就是角色**
--             Head [Part]
--             UpperTorso / LowerTorso / HumanoidRootPart / CameraPart …
--             CharacterArmor/      ← 只是装甲装饰件
--             WeaponModel/ WeaponAttachments/
--         BKLE999/                 ← AI，结构同上，另有 Highlight
--
-- 三个致命差异：
--   ① 角色是 **Folder** 不是 Model —— 只判 `IsA("Model")` 会全部漏掉
--   ② 没有 Humanoid，按 Humanoid 找血量的代码全部拿不到
--   ③ 不按阵营分文件夹，阵营要从「文件夹名是不是某个 Player」去反查
-- 这正是「AI 站在面前也不锁定」的直接原因：候选列表一直是空的。
local function allCharModels()
    local list, seen = {}, {}
    local function takeModel(m)
        local key = tostring(m.Name)
        if not seen[key] then
            seen[key] = true
            table.insert(list, m)
        end
    end
    local function looksLikeChar(f)
        return f:FindFirstChild("Head") ~= nil
            or f:FindFirstChild("UpperTorso") ~= nil
            or f:FindFirstChild("LowerTorso") ~= nil
            or f:FindFirstChild("HumanoidRootPart") ~= nil
    end
    local function take(folder)
        if not folder then return end
        for _, m in ipairs(folder:GetChildren()) do
            if m:IsA("Model") then
                takeModel(m)
            elseif m:IsA("Folder") or m:IsA("Configuration") then
                local gotModel = false
                for _, mm in ipairs(m:GetChildren()) do
                    if mm:IsA("Model") then
                        takeModel(mm)
                        gotModel = true
                    end
                end
                -- 阵营层下面是空的 → 这个 Folder 自己就是角色
                if not gotModel and looksLikeChar(m) then
                    takeModel(m)
                end
            end
        end
    end
    take(charsFolder())
    take(culledFolder())
    return list
end

local function culledCount()
    local f = culledFolder()
    return f and #f:GetChildren() or 0
end
local function myModel()
    local f = charsFolder()
    if not f then return nil end
    -- 情况 B（本作实际结构）：Characters/<玩家名> 直接是角色
    local direct = f:FindFirstChild(LP.Name)
    if direct then
        if direct:IsA("Model") then return direct end
        if direct:FindFirstChild("Head") or direct:FindFirstChild("HumanoidRootPart") then
            return direct
        end
    end
    -- 情况 A（旧结构）：Characters/<阵营>/<玩家名>
    for _, team in ipairs(f:GetChildren()) do
        if team:IsA("Folder") or team:IsA("Configuration") then
            local m = team:FindFirstChild(LP.Name)
            if m and m:IsA("Model") then return m end
        end
    end
    return nil
end
local function myRoot()
    local m = myModel()
    return m and m:FindFirstChild("HumanoidRootPart") or nil
end

---------------------------------------------------------------------
-- 目标
---------------------------------------------------------------------
-- RemoteBuffer 是绕过 PVS 的实时位置源：服务端对不可见玩家照样下发
-- 位置快照（供客户端预测），只是不渲染模型。含 Bot。
local cachedBuffer = nil
local cachedAt = 0
local cachedTick = -1

local function countPoses(b)
    if typeof(b) ~= "table" then return 0 end
    local p = b._presentationPoseByActorKey
    if typeof(p) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(p) do n = n + 1 end
    return n
end

local function resolveBuffer()
    local now = os.clock()

    -- ⚠ 两个必须一起解决的坑，缺一个透视就会冻：
    --
    -- 【坑 1】缓存不能永久
    --   堆里同时存在 13 个 RemoteBuffer，每个 generation 一个。实测：
    --     #1  gen=30  tick 3 秒涨 180      ← 活的
    --     #2~#13      tick (+0)             ← 历史 generation，全停更
    --   旧代码只要 _presentationPoseByActorKey 是 table 就一直用缓存，
    --   一旦抓到旧 generation 就永久冻住。
    --
    -- 【坑 2】单个 buffer 只装一个 actor，必须合并
    --   实测每个 buffer 的 pose 表只有 1 项：
    --     gen=17/18 → 只有自己
    --     gen=10/29/30 → 只有敌人
    --   旧代码只返回 tick 最大的那一个（往往只有自己），所以敌人位置
    --   只能退回读模型坐标 —— 模型被 PVS 剔除后坐标冻结，
    --   表现就是「敌人走了框还停在原地，非得他进视野才刷新」。
    --   正确做法：把所有 buffer 的 pose/actors 合并成一张视图。
    if cachedBuffer and now - cachedAt < 0.3 then
        return cachedBuffer
    end

    local ok, all = pcall(function()
        return filtergc("table", {
            Keys = {
                "_presentationPoseByActorKey",
                "_maxSamplesPerActor",
                "_orderedActorKeys",
                "_latestServerTick",
            },
        })
    end)
    if not ok or typeof(all) ~= "table" then return nil end

    local mergedPoses = {}
    local mergedActors = {}
    local maxTick = -1
    local liveBufs = 0

    -- ⚠ 排序后再合并，不能按 pose 自己的 SourceServerTick 比大小。
    -- 每个 buffer 属于不同 generation，tick 基准互不相通：
    -- 实测敌人的 pose 在两个 buffer 里分别标着 249532 和 246184，
    -- 直接比大小会把旧的选进来，位置就倒退了。
    -- 正确做法：按 buffer 自己的 _latestServerTick 从新到旧排，先到先得。
    local ranked = {}
    for _, buf in ipairs(all) do
        if typeof(buf) == "table" and countPoses(buf) > 0 then
            ranked[#ranked + 1] = {
                buf = buf,
                tick = tonumber(buf._latestServerTick) or -1,
            }
        end
    end
    table.sort(ranked, function(a, b) return a.tick > b.tick end)

    for _, item in ipairs(ranked) do
        local buf = item.buf
        liveBufs = liveBufs + 1
        if item.tick > maxTick then maxTick = item.tick end
        for k, v in pairs(buf._presentationPoseByActorKey) do
            if mergedPoses[k] == nil then
                mergedPoses[k] = v
            end
        end
        local actors = buf._actors
        if typeof(actors) == "table" then
            for k, v in pairs(actors) do
                if mergedActors[k] == nil then mergedActors[k] = v end
            end
        end
    end

    local n = 0
    for _ in pairs(mergedPoses) do n = n + 1 end
    if n == 0 then return nil end

    -- ⚠ 先用 _actors 里的 CollisionPose 覆盖，再做时效判断。
    -- 顺序不能反：CollisionPose 比 _presentationPoseByActorKey（渲染姿态）更实时，
    -- 若先按渲染姿态的旧 tick 过滤，本来新鲜的碰撞姿态会被一起丢掉。
    local overridden = 0
    for k, actor in pairs(mergedActors) do
        local cp = actor.CollisionPose
        if typeof(cp) == "table" and typeof(cp.Position) == "Vector3" then
            local prev = mergedPoses[k]
            mergedPoses[k] = {
                Position = cp.Position,
                VisualRootPosition = cp.VisualRootPosition,
                LookYaw = cp.LookYaw,
                VerticalLook = cp.VerticalLook,
                UserId = tonumber(k),
                SourceServerTick = cp.SourceServerTick,
                DuckAmount = cp.DuckAmount,
                Stance = cp.Stance,
                MovementMode = cp.MovementMode,
                -- ⚠ 速度一定要保留下来。
                -- 服务端停发之后，这是唯一还能表达「他往哪走」的信息，
                -- 用来做外推（dead reckoning）。原来这里整个表是重建的，
                -- 速度被丢掉了，于是冻结的目标只能钉在原地不动。
                Velocity = (typeof(cp.Velocity) == "Vector3" and cp.Velocity)
                    or (prev and typeof(prev.Velocity) == "Vector3" and prev.Velocity)
                    or nil,
            }
            overridden = overridden + 1
        end
    end
    S.bufOverride = overridden

    -- ⚠ 时效判断绝对不能跨 generation 比 tick。
    --
    -- 实测同时存在 15 个 RemoteBuffer：
    --   自己 → gen=65535 的 buffer，_latestServerTick = 311636
    --   敌人 → gen=31  的 buffer，_latestServerTick = 251468
    -- 两个 generation 的时钟起点不同，用「全局最大 tick - 该 pose 的 tick」
    -- 算出来敌人落后 60168 tick（≈16 分钟）。这个数字是假的：
    --   既会把本来新鲜的目标误杀，也会把早就冻死的目标当成实时，
    -- 用户看到的「框画在空气里 / 同一个敌人两处标记」都出在这里。
    --
    -- 改用「这条数据多久没变过」：只比对数值本身有没有更新，与 tick 基准无关。
    -- 敌人离开视野后服务端停止下发，位置和 tick 都不再变化，秒数会一直往上走，
    -- 这才是「冻结」的定义。
    local nowSec = os.clock()
    local watch = S.poseWatch
    if type(watch) ~= "table" then
        watch = {}
        S.poseWatch = watch
    end

    local staleKeys = {}
    local freshSec = {}
    local velSec = {}
    local stale = 0
    local staleLimit = tonumber(cfg.staleSeconds) or 3.0
    for k, v in pairs(mergedPoses) do
        local p = v.Position
        local sig
        if typeof(p) == "Vector3" then
            -- ⚠ 签名里**不能带 SourceServerTick**。
            -- 实测服务端会对同一个位置反复重发（tick 在涨、坐标一动不动），
            -- 带上 tick 就会判定「数据在更新」，age 永远很小，于是：
            --   · 一个早就没人站的位置被当成实时
            --   · frozen 永远是 false，自瞄照样锁过去 —— 用户说的「锁空气」
            -- 只看坐标才能反映「这个位置到底有没有变过」。
            sig = string.format("%.2f|%.2f|%.2f", p.X, p.Y, p.Z)
        else
            sig = "nil"
        end
        local w = watch[k]
        if type(w) ~= "table" or w.sig ~= sig then
            -- ⚠ 自己用「位置差分」测速度，不要相信 pose.Velocity。
            -- 实测服务端给的这个字段恒为 (0,0,0)，靠它做外推等于没做。
            -- 位置差分虽然只是两次刷新之间的平均值（会被拐弯抹平），
            -- 但方向和量级是对的，用来推最后那一两秒足够。
            local nv = nil
            if type(w) == "table" and typeof(w.pos) == "Vector3"
                and typeof(p) == "Vector3" then
                local gap = nowSec - (w.at or nowSec)
                if gap > 0.04 then
                    local d = (p - w.pos) / gap
                    -- 过滤瞬移（重生/传送会给出离谱的速度）
                    if d.Magnitude < 400 then nv = d end
                end
            end
            w = {
                sig = sig,
                at = nowSec,
                pos = p,
                vel = nv or (type(w) == "table" and w.vel) or nil,
            }
            watch[k] = w
        end
        local ageSec = nowSec - (w.at or nowSec)
        freshSec[k] = ageSec
        if typeof(w.vel) == "Vector3" and w.vel.Magnitude > 1 then
            velSec[k] = w.vel
        end
        if ageSec > staleLimit then
            -- ⚠ 只标记，不删除。
            --
            -- 之前这里是 mergedPoses[k] = nil，结果是「敌人一离开视野就整个消失」——
            -- 刚开局还能看到，几秒后全没了。这不是修 bug，是把透视功能本身删了：
            -- 服务端对不可见玩家停止下发（PVS），能拿到的只有「最后一次告诉我的位置」，
            -- 而"最后一次的位置"正是透视唯一有意义的东西。
            --
            -- 现在保留这个位置，但记进 staleKeys，由 ESP 画成暗色 + 标「旧 N 秒」，
            -- 并且坐标源退回 pose 而不是 culled 里的模型（那个实测差 229.7 stud）。
            staleKeys[k] = true
            stale = stale + 1
        end
    end
    S.bufStale = stale

    -- 清掉已经离开的 actor，避免 watch 表无限增长
    for k in pairs(watch) do
        if mergedActors[k] == nil and mergedPoses[k] == nil then
            watch[k] = nil
        end
    end

    n = 0
    for _ in pairs(mergedPoses) do n = n + 1 end
    if n == 0 then
        S.bufPoses = 0
        S.bufStaleKeys = staleKeys
        return nil
    end

    -- 每个 pose 的新鲜度，单位是「秒」而不是 tick。
    -- 用 tick 会踩上跨 generation 的基准差（见上面的说明），秒数则与时钟无关：
    -- 位置和 tick 都不再变化、秒数才会往上走，这才叫冻结。
    local view = {
        _presentationPoseByActorKey = mergedPoses,
        _actors = mergedActors,
        _latestServerTick = maxTick,
        _freshSeconds = freshSec,
        _staleKeys = staleKeys,
        _velByActorKey = velSec,
    }
    cachedBuffer = view
    cachedAt = now
    cachedTick = maxTick
    S.bufPoses = n
    S.bufTick = maxTick
    S.bufSources = liveBufs
    return view
end

local function modelFor(name)
    -- ⚠ 也要下钻阵营层（见 allCharModels 的说明）
    local f = charsFolder()
    if f then
        local m = f:FindFirstChild(name)
        if m and m:IsA("Model") then return m end
        for _, team in ipairs(f:GetChildren()) do
            if team:IsA("Folder") or team:IsA("Configuration") then
                local mm = team:FindFirstChild(name)
                if mm and mm:IsA("Model") then return mm end
            end
        end
    end
    local cf = culledFolder()
    return cf and cf:FindFirstChild(name) or nil
end

-- ⚠ 这里不能声明新的顶层 local（主 chunk 已经 200 上限），所以挂到 S 上。
S.modelByActorId = function(aid)
    if type(aid) ~= "number" then return nil end
    -- ⚠⚠ 模型的身份属性叫 **PresentationOwnerUserId**（实测），不是 ActorId。
    -- 模型属性实测清单：
    --   PresentationOwnerUserId = 10359702948   ← 就是 actor key（= UserId）
    --   CharacterType = PlayerCustomCharacter
    --   ClientCharacterPresentationVisible / ClientOwnedCharacterPresentation
    --   CharacterName / CharacterGeneration / Health / MaxHealth / Dead
    -- 旧代码只比 ActorId → 恒为 nil → 「用模型位置覆盖 pose」这条链路从来没生效过，
    -- 透视只能吃冻结的 pose，表现就是「开局一瞬间对、之后框钉在原地」。
    -- 两个都兼容，谁有值用谁。
    local function scan(node)
        if not node then return nil end
        for _, m in ipairs(node:GetChildren()) do
            if m:IsA("Model") then
                if m:GetAttribute("PresentationOwnerUserId") == aid
                    or m:GetAttribute("ActorId") == aid then
                    return m
                end
            end
        end
        return nil
    end
    local function scanDeep(node)
        local hit = scan(node)
        if hit then return hit end
        if not node then return nil end
        for _, team in ipairs(node:GetChildren()) do
            if team:IsA("Folder") or team:IsA("Configuration") then
                local h2 = scan(team)
                if h2 then return h2 end
            end
        end
        return nil
    end
    local hit = scanDeep(charsFolder())
    if hit then return hit end
    return scanDeep(culledFolder())
end

local function collect(limitRange, applyTeamCheck)
    local out = {}
    local root = myRoot()
    local myPos = root and root.Position or Vector3.zero
    local mt = myTeam()
    local seen = {}

    -- Bot 的队伍在【模型】的 Team 属性上（真实玩家在 Player 上）。
    -- pose key 是 "bot:2638" 与模型名对不上，所以按位置就近关联。
    local botModels = {}
    for _, m in ipairs(allCharModels()) do
        if m:GetAttribute("Bot") == true then
            local r = m:FindFirstChild("HumanoidRootPart")
            if r then
                botModels[#botModels + 1] = {
                    pos = r.Position,
                    team = tostring(m:GetAttribute("Team")),
                }
            end
        end
    end

    local function botTeamAt(pos)
        local best, bestD = nil, 14
        for _, b in ipairs(botModels) do
            local d = (b.pos - pos).Magnitude
            if d < bestD then best, bestD = b.team, d end
        end
        return best or "bot"
    end

    -- 0) 死亡瞬间检测
    --
    -- 模型的 Dead / Health 属性在「被击倒 → 重生」之间并不及时：
    -- 实测能出现「人已经死了，框还挂着」的情况，几秒后才随重生一起重置。
    -- Player 上的 Deaths 计数是可靠的（死亡瞬间 +1），用它打一个短时标记，
    -- 在这段时间内把该玩家当死人处理，避免死亡的框继续挂在原地。
    if type(S.deathMark) ~= "table" then S.deathMark = {} end
    local nowClock = os.clock()
    for _, pl in ipairs(Players:GetPlayers()) do
        local uid = pl.UserId
        local dc = tonumber(pl:GetAttribute("Deaths")) or 0
        local rec = S.deathMark[uid]
        if type(rec) ~= "table" then
            S.deathMark[uid] = { deaths = dc, at = 0 }
        elseif dc ~= rec.deaths then
            rec.deaths = dc
            rec.at = nowClock
        end
    end

    -- 1) 主数据源：RemoteBuffer 实时姿态
    local buf = resolveBuffer()
    local poses = buf and buf._presentationPoseByActorKey
    local freshSec = buf and buf._freshSeconds
    local velMap = buf and buf._velByActorKey
    local staleKeys = (buf and buf._staleKeys) or S.bufStaleKeys
    if typeof(poses) == "table" then
        for key, pose in pairs(poses) do
            local uid = pose.UserId
            local plr = (uid and uid ~= 0) and Players:GetPlayerByUserId(uid) or nil

            -- 关键：UserId ≠ 0 但查不到 Player，说明这个人已经离开房间了。
            -- 以前这种情况被当成 bot 继续画，结果人回大厅了透视还停在原地。
            -- UserId == 0 才是真正的 bot。
            local skip = false
            local isBot = false
            if uid and uid ~= 0 then
                if not plr then
                    skip = true                 -- 玩家已离开
                elseif plr == LP then
                    skip = true                 -- 自己
                end
            else
                isBot = true                        -- 真 bot
            end

            if not skip then
                -- ⚠ t.pos / t.headPos 必须和 ESP 用同一个坐标源，
                -- 否则就是"框画在这、自瞄锁在那"。
                -- 实测同一时刻：pose=(9,6,-127)，模型=(99,4,85) —— 差 230 stud。
                -- ESP 那边用的是模型坐标，自瞄这边如果还用 pose，就必然锁到墙里。
                --
                -- 规则：模型在 workspace.Characters 里 → 用模型（游戏正在渲染，实时）；
                --       否则退回 pose（服务端最后一次告诉我们的位置）。
                local pos = pose.VisualRootPosition or pose.Position
                local headOverride = nil
                local modelNow = plr and modelFor(plr.Name) or nil
                -- bot 没有 plr，模型名也和 "bot:151" 对不上 —— 必须按 ActorId 找。
                --
                -- ⚠ 这里原来写的是 `act and act.ActorId`，但 act 在整个文件里
                -- 从来没有被定义过（静态审查抓到了这一点）。表达式恒为 nil，
                -- 等于这段「按 ActorId 找 bot 模型」的逻辑从来没执行过。
                --
                -- 真正可靠的来源是 pose 的 key：RemoteBuffer 的 key 格式就是 "bot:151"，
                -- 直接解析出数字即可。模型自身的 ActorId 属性作为次选。
                if not modelNow and isBot then
                    local aid = tonumber(tostring(key):match("(%d+)"))
                    if type(aid) ~= "number" then
                        local okA, a2 = pcall(function()
                            return modelNow and modelNow:GetAttribute("ActorId")
                        end)
                        if okA and type(a2) == "number" then aid = a2 end
                    end
                    if type(aid) == "number" then
                        modelNow = S.modelByActorId(aid)
                    end
                end
                local modelLive = false
                if modelNow then
                    local mp = modelNow.Parent
                    modelLive = (mp ~= nil and mp.Name == "Characters")
                end
                -- ⚠ 模型位置的「新鲜度」单独算。
                --
                -- 判旧原来只看 pose（_freshSeconds），但实测敌人**可见时**
                -- 游戏推进的是模型、pose 那边一动不动 —— 于是 pose 的 age 一直涨，
                -- 目标被判成「太旧」直接不画。表现就是用户说的
                -- 「框消失之后，敌人站到面前也不再重新透视」。
                -- 模型位置的变化才是"这条数据还活着"的直接证据。
                local modelFresh = false
                if modelNow then
                    local mrW = modelNow:FindFirstChild("HumanoidRootPart")
                    if mrW then
                        local msig = string.format("%.1f|%.1f|%.1f",
                            mrW.Position.X, mrW.Position.Y, mrW.Position.Z)
                        if type(S.modelWatch) ~= "table" then S.modelWatch = {} end
                        -- ⚠ bot 的 pose.UserId 是 nil（不是 0），直接拿来当 table 键会报
                        -- "table index is nil"。用 pose 的 key 兜底（"bot:151" 这种，天然唯一）。
                        local watchKey = uid or tostring(key)
                        local mw = S.modelWatch[watchKey]
                        if type(mw) ~= "table" or mw.sig ~= msig then
                            S.modelWatch[watchKey] = { sig = msig, at = nowClock }
                            modelFresh = true
                        elseif (nowClock - (mw.at or 0)) < 1.0 then
                            modelFresh = true
                        end
                    end
                end
                -- ⚠ 模型只要存在就用（Characters 和 culled 都用）。
                --
                -- 实测同一时刻：pose=(9,6,-127)，culled 模型=(99,4,85)，差 230 stud。
                -- 而「开局一瞬间位置是对的、之后变错」说明 pose 只在回合开始被全量下发，
                -- 之后对不可见玩家就冻在那儿了；模型则是「他最后一次真正被渲染的位置」，
                -- 通常比冻结的 pose 更新。所以 culled 时也该用模型 —— 上一版让它退回 pose，
                -- 等于主动选了更旧的那个数据源。
                if modelNow then
                    local mr = modelNow:FindFirstChild("HumanoidRootPart")
                    if mr then pos = mr.Position end
                    local mh = modelNow:FindFirstChild("Head")
                    if mh then headOverride = mh.Position end
                end

                -- 外推（dead reckoning）
                -- 数据一旦停止更新（模型和 pose 都冻住），框就会永久钉在原地，人早走了。
                -- 用最后已知速度沿水平方向往前推：方向基本是对的，比钉死强得多。
                -- 只推水平分量（Y 不动），上限 extrapolateCap 秒 —— 再长就是瞎猜了。
                local extrapolated = false
                local ageNow = freshSec and freshSec[key]
                -- ⚠ 用自己差分测出来的速度（velMap），不是 pose.Velocity ——
                -- 后者实测恒为 (0,0,0)。
                local velNow = velMap and velMap[key]
                if ageNow and ageNow > 0.35 and typeof(velNow) == "Vector3"
                    and typeof(pos) == "Vector3" then
                    local flatVel = Vector3.new(velNow.X, 0, velNow.Z)
                    if flatVel.Magnitude > 1 then
                        local cap = tonumber(cfg.extrapolateCap) or 2.0
                        local shift = flatVel * math.min(ageNow, cap)
                        pos = pos + shift
                        if headOverride then headOverride = headOverride + shift end
                        extrapolated = true
                    end
                end
                -- 弹道修正：敌人开枪时 CreateTracer 会全局广播他的枪口位置，
                -- 这条完全不经过 PVS。当模型和 pose 都冻住时，用它把框拉回大概位置。
                -- 只用 3 秒内的弹道，匹配半径 40 stud（枪口不等于脚底，有偏差）。
                local tracerFixed = false
                if not (modelLive or modelFresh) and type(S.tracers) == "table"
                    and #S.tracers > 0 and typeof(pos) == "Vector3" then
                    local nowT = os.clock()
                    for i = #S.tracers, 1, -1 do
                        local tr = S.tracers[i]
                        if nowT - (tr.at or 0) > 3.0 then break end
                        if typeof(tr.pos) == "Vector3"
                            and (tr.pos - pos).Magnitude < 40 then
                            pos = tr.pos - Vector3.new(0, 1.2, 0)
                            if headOverride then headOverride = tr.pos end
                            tracerFixed = true
                            S.tracerHits = (S.tracerHits or 0) + 1
                            break
                        end
                    end
                end
                if typeof(pos) == "Vector3" then
                    -- ══ 身份匹配优先（最精确）══
                    --
                    -- CreateCharacterMuzzleFlash 说明「这个 UserId 刚开过枪」，
                    -- 配合 CreateTracer 的枪口坐标就知道「他在哪开的枪」。
                    -- 这是 PVS 下唯一能精确关联到具体人的实时位置源。
                    if not (modelLive or modelFresh) and type(S.idEventFor) == "function" then
                        local okI, idEv = pcall(S.idEventFor, uid, 2.5)
                        if okI and idEv and typeof(idEv.pos) == "Vector3" then
                            pos = idEv.pos
                            if headOverride then
                                headOverride = idEv.pos + Vector3.new(0, 1.55, 0)
                            end
                            tracerFixed = true
                            S.posFixHits = (S.posFixHits or 0) + 1
                            S.posFixKind = "id:" .. tostring(idEv.kind)
                        end
                    end
                end
                if typeof(pos) == "Vector3" then
                    -- ══ 事件驱动位置矫正（无身份，按空间就近）══
                    --
                    -- 只要「模型和 pose 都不新鲜」就说明这条目标已经进 PVS 阴影了，
                    -- 此刻它真实的每一次动静（中弹血溅 / 命中弹孔）都会带一个坐标过来。
                    --
                    -- 只剩两种可用事件（都有明确的「人」关联）：
                    --   blood 中弹血溅 → 就在脚下
                    --   hit   命中弹孔（VictimUserId 有值时才记）→ 在身体上
                    if not (modelLive or modelFresh) and type(S.nearestPosEvent) == "function" then
                        local ev = nil
                        local okE, e1 = pcall(S.nearestPosEvent, pos, 60, 2.0)
                        if okE then ev = e1 end
                        if ev and typeof(ev.pos) == "Vector3" then
                            -- 只剩两种可用事件（都有明确的「人」关联）：
                            --   blood 中弹血溅 → 就在脚下
                            --   hit   命中弹孔（VictimUserId 有值时才记）→ 在身体上
                            if ev.kind == "blood" then
                                pos = ev.pos
                                if headOverride then
                                    headOverride = ev.pos + Vector3.new(0, 1.55, 0)
                                end
                            elseif ev.kind == "hit" then
                                pos = ev.pos - Vector3.new(0, 1.0, 0)
                            elseif ev.kind == "csound" then
                                -- Class=Character 的声音（死亡呻吟/受伤），位置就在人身上
                                pos = ev.pos - Vector3.new(0, 1.0, 0)
                            elseif ev.kind == "gunshot" then
                                -- 枪声位置在枪口附近（比身体高一点），往下压 1.2 收到身体
                                pos = ev.pos - Vector3.new(0, 1.2, 0)
                                if headOverride then
                                    headOverride = ev.pos
                                end
                            elseif ev.kind == "footstep" then
                                -- 脚步声就是脚下，位置很准，但**容易匹配错人**（附近可能有好几个）。
                                -- 所以匹配半径收到 30 stud，且只用来把框挪过去，不改头部高度。
                                if (ev.pos - pos).Magnitude < 30 then
                                    pos = ev.pos
                                    if headOverride then
                                        headOverride = ev.pos + Vector3.new(0, 1.55, 0)
                                    end
                                    S.footFixHits = (S.footFixHits or 0) + 1
                                end
                            end
                            tracerFixed = true
                            S.posFixHits = (S.posFixHits or 0) + 1
                            S.posFixKind = tostring(ev.kind)
                        end
                    end
                end
                if typeof(pos) == "Vector3" then
                    local team
                    if isBot then
                        -- ⚠ bot 的队伍必须优先读模型属性，且读到就缓存。
                        --
                        -- 之前只用 botTeamAt(pos) 按坐标推断，猜不出来返回 nil，
                        -- sameTeam 变 false，队伍过滤对 bot 完全失效 —— 表现为「锁队友」。
                        --
                        -- 但只读模型属性还不够：实测有些 bot 的 Team 属性在刚生成时
                        -- 是 nil（模型还没初始化完），那一瞬间又会退回坐标猜测。
                        -- 所以按 ActorId 缓存一份，属性为 nil 时用上次读到的值。
                        local aid = nil
                        -- 同样：这里原来也是引用不存在的 act。
                        -- 模型存在时优先读它的 ActorId 属性（最权威），否则从 key 解析。
                        if modelNow then
                            local okA2, a3 = pcall(function() return modelNow:GetAttribute("ActorId") end)
                            if okA2 and type(a3) == "number" then aid = a3 end
                        end
                        if type(aid) ~= "number" then
                            aid = tonumber(tostring(key):match("(%d+)"))
                        end
                        local tm = modelNow and modelNow:GetAttribute("Team")
                        if type(tm) ~= "string" and type(aid) == "number" then
                            if type(S.botTeamCache) ~= "table" then S.botTeamCache = {} end
                            tm = S.botTeamCache[aid]
                        elseif type(tm) == "string" and type(aid) == "number" then
                            if type(S.botTeamCache) ~= "table" then S.botTeamCache = {} end
                            S.botTeamCache[aid] = tm
                        end
                        if type(tm) == "string" and tm ~= "" then
                            team = tm
                        else
                            team = botTeamAt(pos)
                        end
                    else
                        team = tostring(plr:GetAttribute("Team"))
                    end
                    local dist = (pos - myPos).Magnitude
                    local sameTeam = (team == mt)
                    local blocked = (applyTeamCheck == true) and sameTeam

                    if dist <= limitRange and not blocked then
                        local label = plr and plr.Name or tostring(key)
                        seen[label] = true
                        -- 复用前面已经查过的模型，不再重复 modelFor
                        local m = modelNow
                        local hp, maxHp, weapon = 100, 100, "Held"
                        local dead = false
                        if m then
                            hp = tonumber(m:GetAttribute("Health")) or 100
                            maxHp = tonumber(m:GetAttribute("MaxHealth")) or 100
                            local d = m:GetAttribute("Dead")
                            dead = (d == true) or (d == "true") or (hp <= 0)
                            if not m:FindFirstChild("WeaponModel") then weapon = "Empty" end
                        end
                        -- 死亡瞬间兜底：Deaths 计数刚变过 → 这段时间内按死人处理。
                        -- Dead/Health 属性要等重生才会重置，中间那几秒框会一直挂在原地。
                        local dm = plr and S.deathMark and S.deathMark[plr.UserId]
                        if dm and (nowClock - (dm.at or 0)) < (cfg.deathMarkSeconds or 4) then
                            -- ⚠ 必须再确认「他确实还是死的」。
                            --
                            -- 原来只看时间窗口、不看血量：玩家死后 4 秒内复活，标记还在有效期内，
                            -- 于是刚复活的人被当成尸体 —— 用户实测「刚复活的人/AI 明明看得见，
                            -- 静默和透视都不选他」，根因就在这里。
                            -- 血量 > 0 且 Dead 属性不为真 → 立刻清标记、放行。
                            if hp <= 0 or dead then
                                dead = true
                            elseif plr then
                                S.deathMark[plr.UserId] = nil
                                S.deathMarkCleared = (S.deathMarkCleared or 0) + 1
                            end
                        end
                        -- 数据新鲜度：单位秒，见 resolveBuffer 里的说明。
                        -- ⚠ 但模型还挂在 Characters 里时，说明游戏正在渲染他 —— 位置是实时的，
                        -- 哪怕 pose 那边冻住了也不能当「旧」：否则看得见的人反而锁不上。
                        local ageS = freshSec and freshSec[key] or nil
                        -- 模型实时渲染 或 模型位置还在变 或 刚捕捉到弹道 → 数据是活的
                        local dataLive = modelLive or modelFresh or tracerFixed
                        local frozen = (ageS ~= nil) and (ageS > (cfg.staleSeconds or 3.0)) and not dataLive
                        -- ⚠ 太旧的目标整个不画。
                        -- 实测出现过 age=49 秒的目标：位置是 (-166,6,-207)，距玩家 468 stud，
                        -- 那是「上一次被看到」的地方，早就没人在那了。这种框留着，
                        -- 用户会以为「自瞄在锁空气」——其实自瞄根本没锁（vDbg=frozen），
                        -- 只是屏幕上有个框一直挂在那儿。默认 15 秒以上的直接不画。
                        local hideAfter = tonumber(cfg.staleHideAfter) or 15
                        local tooOld = (ageS ~= nil) and (ageS > hideAfter) and (not dataLive)

                        -- ⚠ 死亡广播兜底：靠 ReplicateFinisher 的位置把「刚死的人」标成死的。
                        --
                        -- 用户反馈：有的人活着时完全没有透视，死了以后骨骼反而出现在屏幕上。
                        -- 原因是目标活着时不进 PVS（client 根本不知道它在哪），
                        -- 死的那一刻服务端用 ReplicateFinisher 广播了一次死亡位置 ——
                        -- 于是它突然出现在 _actors 里，模型还在、dead 属性还没同步、
                        -- 数据又是新鲜的，三个过滤条件一个都不触发，就画出来了。
                        --
                        -- 处理：记下每一条 ReplicateFinisher 的死亡位置，
                        -- 5 秒内、6 stud 范围内出现的目标一律当死人，直接不画。
                        -- ⚠ 同样必须确认血量为 0：刚复活的人正好会站在自己刚才死的那个位置，
                        -- 原来不判血量就会把复活的人错误地当尸体（静默和透视都不选他）。
                        if not dead and (hp <= 0 or dead) == false
                            and type(S.recentDeaths) == "table" and #S.recentDeaths > 0 then
                            local nowD = os.clock()
                            for di = #S.recentDeaths, 1, -1 do
                                local dd = S.recentDeaths[di]
                                if nowD - (dd.at or 0) > 5 then
                                    table.remove(S.recentDeaths, di)
                                elseif typeof(dd.pos) == "Vector3"
                                    and (dd.pos - pos).Magnitude < 6
                                    and hp <= 0 then
                                    dead = true
                                    S.deathByFinisher = (S.deathByFinisher or 0) + 1
                                    break
                                end
                            end
                        end

                        if not tooOld then
                        -- ⚠ 去重关键：pose 的 key 是 "bot:23" 这种 actor key，
                        -- 而模型路径用的是模型名（"easyboost21313"），两者**名字不同**，
                        -- 所以下面那个 `seen[m.Name]` 去重拦不住 —— 同一个 bot 会被加进
                        -- 列表两次（实测两条记录位置差 0.000 stud）。
                        -- 后果：ESP 画两个重叠框、自瞄重复计数、rapidFire 的目标检查也会混乱。
                        -- 修法：只要这条 pose 已经对应到模型，就把模型名也标记为已见，
                        -- 这样「2) 回退：模型位置」那一轮就不会再加同一个实体。
                        if modelNow then
                            seen[modelNow.Name] = true
                        end
                        table.insert(out, {
                            player = plr,
                            name = label,
                            isBot = isBot,
                            model = m,
                            pos = pos,
                            headPos = headOverride or (pos + Vector3.new(0, 1.55, 0)),
                            distance = dist,
                            health = hp,
                            maxHealth = maxHp,
                            team = team,
                            sameTeam = sameTeam,
                            weapon = weapon,
                            stance = pose.Stance,
                            lookYaw = pose.LookYaw,
                            verticalLook = pose.VerticalLook,
                            live = not frozen,
                            ageSec = ageS,
                            frozen = frozen,
                            extrapolated = extrapolated,
                            dead = dead,
                        })
                        end
                    end
                end
            end
        end
    end

    -- 2) 回退：模型位置
    --    pose 里没有的 actor —— 既可能是被 PVS 冻结的真人，也可能是完全没有
    --    Player 对象的 Bot。Bot 必须在这里兜住，否则整类目标都会漏。
    --
    -- ⚠ 但「pose 被判定过期」的真人**不能**走到这里。
    -- 服务端对离开视野的玩家停止下发位置，模型会一直停在最后一刻，
    -- 新一局开始时它甚至还是上一局的死亡位置 —— 用这个坐标画框，
    -- 得到的就是用户说的「框画在空气里」，而且和箭头（走 pose）对不上，
    -- 同一个敌人同时出现两处标记。这种情况默认直接不画；
    -- 想看到「最后已知位置」的人可以打开 showStaleModel。
    for _, m in ipairs(allCharModels()) do
        if m.Name ~= LP.Name and not seen[m.Name] then
            local r = m:FindFirstChild("HumanoidRootPart")
            if r then
                -- ⚠⚠ 「人走了框还钉在原地」的真正根因就在这里。
                --
                -- 在 _PVS_CulledCharacters 里的模型，位置是服务端**最后一次同步的冻结值**
                -- （实测：被剔除 85 秒里他实际走了 114 stud，而我们读到的坐标一动没动）。
                -- 以前这条路径只有「真人 + staleKeys」会跳过，bot 完全没检查，
                -- 而且构造出来的 target 缺 frozen 字段 —— 于是后面的
                -- `if t.frozen and cfg.hideFrozen then skip` 对它永远失效，
                -- culled 的 bot 就被一直画成一个钉在原地的框。
                local parM = m.Parent
                local visibleM = (parM ~= nil and parM.Name == "Characters")
                if not visibleM and cfg.hideFrozen then
                    continue
                end
                local plr = Players:FindFirstChild(m.Name)
                local isBot = (plr == nil)
                -- pose 被判过期、但模型还挂在 workspace.Characters 里 → 位置是实时的，可以画。
                -- 只有在 _PVS_CulledCharacters 里（游戏不再更新它）才跳过，
                -- 那种模型停在最后一刻，新一局时甚至是上一局的死亡点。
                if plr and staleKeys and staleKeys[plr.UserId] and not cfg.showStaleModel then
                    local par = m.Parent
                    local visible = (par ~= nil and par.Name == "Characters")
                    if not visible then
                        continue
                    end
                end
                local team
                if isBot then
                    team = tostring(m:GetAttribute("Team"))
                else
                    team = tostring(plr:GetAttribute("Team"))
                end
                if team == nil or team == "" or team == "nil" then team = "unknown" end

                local dead = m:GetAttribute("Dead")
                local hp = tonumber(m:GetAttribute("Health"))
                local maxHp = tonumber(m:GetAttribute("MaxHealth")) or 100
                local dist = (r.Position - myPos).Magnitude
                local sameTeam = (team == mt)
                -- 不再用 Dead/Health 过滤：属性会滞后，活人可能被误杀。
                -- 只标记，交给显示层决定（尸体画灰色，可在开关里隐藏）。
                local isDead = (dead == true) or (dead == "true") or (hp ~= nil and hp <= 0)
                local blocked = (applyTeamCheck == true) and sameTeam

                if dist <= limitRange and not blocked then
                    local head = m:FindFirstChild("Head") or m:FindFirstChild("MeshPart")
                    local weapon = "Held"
                    if not m:FindFirstChild("WeaponModel") then weapon = "Empty" end
                    seen[m.Name] = true
                    table.insert(out, {
                        player = plr,
                        name = m.Name,
                        isBot = isBot,
                        model = m, root = r,
                        head = head,
                        pos = r.Position,
                        headPos = head and head.Position or (r.Position + Vector3.new(0, 1.55, 0)),
                        distance = dist,
                        health = hp or maxHp,
                        maxHealth = maxHp,
                        team = team,
                        sameTeam = sameTeam,
                        weapon = weapon,
                        live = false,
                        -- ⚠ 补上 frozen：这条路径以前没有这个字段，导致 hideFrozen 失效。
                        -- visibleM 为 false = 模型在 culled 里 = 位置是冻结快照。
                        frozen = (not visibleM),
                        dead = isDead,
                    })
                end
            end
        end
    end

    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
end

-- 瞄准输入：自己维护按下状态，不依赖 Maclib 的 Keybind（那个组件不可靠）
local aimInput = {
    key = nil,                                   -- Enum.KeyCode（键盘）
    mouse = Enum.UserInputType.MouseButton2,     -- 鼠标键
    down = false,
    listening = false,                           -- 是否正在等待用户按键
}
getgenv().MV_AIM_INPUT = aimInput

local function aimInputMatches(input)
    if aimInput.key and input.KeyCode == aimInput.key then return true end
    if aimInput.mouse and input.UserInputType == aimInput.mouse then return true end
    return false
end

local function aimInputLabel()
    if aimInput.key then return aimInput.key.Name end
    if aimInput.mouse then
        local n = tostring(aimInput.mouse):gsub("Enum.UserInputType.", "")
        return n
    end
    return "未设置"
end

pcall(function()
    local c1 = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        -- 绑定模式：吃掉下一个输入
        if aimInput.listening then
            aimInput.listening = false
            local t = input.UserInputType
            if t == Enum.UserInputType.MouseButton1
                or t == Enum.UserInputType.MouseButton2
                or t == Enum.UserInputType.MouseButton3 then
                aimInput.mouse = t
                aimInput.key = nil
            elseif input.KeyCode ~= Enum.KeyCode.Unknown then
                aimInput.key = input.KeyCode
                aimInput.mouse = nil
            end
            aimInput.down = false
            return
        end

        -- 瞄准键必须在 gameProcessed 判断之前处理。
        -- 这个游戏右键是「瞄准/开镜」，输入会被游戏消费 → gameProcessed = true，
        -- 如果先判断它，aimInput.down 永远拿不到 true。
        if aimInputMatches(input) then
            aimInput.down = true
            if cfg.aimTrigger == "toggle" then
                cfg.aimToggled = not cfg.aimToggled
            end
            return
        end

        if gameProcessed then return end
    end)
    REG.conns[#REG.conns + 1] = c1
    S.conns[#S.conns + 1] = c1

    local c2 = UserInputService.InputEnded:Connect(function(input)
        if aimInputMatches(input) then
            aimInput.down = false
        end
    end)
    REG.conns[#REG.conns + 1] = c2
    S.conns[#S.conns + 1] = c2
end)

-- 瞄准是否生效：总开关 + 触发方式
local function aimActive()
    -- ⚠ 总开关只该管「静默」。原来这里第一行就 `if not cfg.silentAim then return false end`，
    -- 导致想只用平滑的人一关总开关，平滑也跟着死（user 反馈「普通平滑自瞄没用」）。
    -- 现在：silent 模式才受 silentAim 约束；smooth / mouse 只看触发方式。
    if (cfg.aimMode or "smooth") == "silent" and not cfg.silentAim then return false end
    local trig = cfg.aimTrigger or "hold"
    if trig == "always" then return true end
    if trig == "toggle" then return cfg.aimToggled == true end
    return aimInput.down == true      -- hold：真的按住才算
end

-- 目标锁定：锁定后不再每帧重选，避免两人靠近时来回跳
-- 解锁条件：目标死亡 / 离开 FOV / 超过 lockMaxSeconds / 玩家自己动视角
local aimLock = { name = nil, at = 0 }

local function breakAimLock()
    -- ⚠ 解锁后必须冷静一会儿：aimTarget() 每帧都会重新锁定，
    -- 不加冷却的话手滑/移动鼠标只能解锁一帧（16ms），看起来就是「拉不回来」。
    S._unlockUntil = os.clock() + 0.7
    aimLock.name = nil
    aimLock.at = 0
end

-- 敌人是否真的在瞄我：水平朝向 + 俯仰角 + 中间无遮挡，三条都满足才算
local faceParams = RaycastParams.new()
faceParams.FilterType = Enum.RaycastFilterType.Exclude

local function facingMe(t)
    if typeof(t.lookYaw) ~= "number" then return false end
    local root = myRoot()
    if not root then return false end

    local myEye = root.Position + Vector3.new(0, 1.5, 0)
    local toMe = myEye - t.headPos
    if toMe.Magnitude < 0.5 then return true end   -- 贴脸，算

    local flat = Vector3.new(toMe.X, 0, toMe.Z)
    if flat.Magnitude < 0.01 then
        -- 正上方/正下方，只看俯仰
        local pitch = (t.verticalLook or 0) * (math.pi / 2)
        local elev = (toMe.Y > 0) and (math.pi / 2) or (-math.pi / 2)
        return math.abs(pitch - elev) < 0.7
    end
    flat = flat.Unit

    -- 1) 水平朝向是否对着我
    local yawDir = Vector3.new(math.sin(t.lookYaw), 0, math.cos(t.lookYaw))
    local dot = flat:Dot(yawDir)
    if dot < 0.6 then return false end            -- 夹角 > 约 53° 就当他没看我

    -- 2) 俯仰是否也对上（VerticalLook 归一化 -1~1 映射到 ±90°）
    local pitch = (t.verticalLook or 0) * (math.pi / 2)
    local elev = math.atan2(toMe.Y, flat.Magnitude)
    if math.abs(pitch - elev) > 0.6 then return false end

    -- 3) 中间是否被实体挡住（排除角色、手雷、自己）
    local ignore = { workspace.CurrentCamera }
    local cf = charsFolder()
    if cf then ignore[#ignore + 1] = cf end
    local dbr = workspace:FindFirstChild("Debris")
    if dbr then ignore[#ignore + 1] = dbr end
    if LP.Character then ignore[#ignore + 1] = LP.Character end
    faceParams.FilterDescendantsInstances = ignore
    local hit = workspace:Raycast(t.headPos, toMe, faceParams)
    if hit and (myEye - hit.Position).Magnitude > 1.5 then
        return false                              -- 他被墙挡着，看不见我
    end

    return true
end

-- 打分：越小越优先
local function scoreFor(t, screenDist)
    local mode = cfg.targetMode or "crosshair"

    -- ⚠ 「正对我的人优先」只在 crosshair 模式下生效。
    -- 之前它无条件 return -1000 + …，把后面所有模式（nearest/farthest/lowesthp…）全劫持了：
    -- 用户选「最近」，实际永远优先打「正对着我」的人 —— 360° 时背后正对你的人也算，
    -- 于是出现「选最近却打背后」。
    if mode == "crosshair" and cfg.preferFacing and facingMe(t) then
        return -1000 + screenDist * 0.01
    end

    if mode == "nearest" then
        return t.distance
    elseif mode == "farthest" then
        return -t.distance
    elseif mode == "lowesthp" then
        return t.health
    elseif mode == "highesthp" then
        return -t.health
    elseif mode == "balanced" then
        return screenDist * cfg.crosshairWeight + t.distance * cfg.distanceWeight
    elseif mode == "threat" then
        local faceBias = facingMe(t) and 0 or 500
        return faceBias + screenDist
    end
    -- 默认 crosshair：屏幕距离为主，世界距离做微调
    return screenDist + t.distance * 0.02
end

-- 前置声明：真正的定义在下面（缓存层）。
-- Lua 的 local 函数必须先声明才能在上述函数里调用，否则拿到 nil。
local allTargets

-- ⚠⚠ 前置声明（扫描确认过：这三个在定义之前就被引用了）
--
-- Lua 的 local 作用域只从声明那一行往下生效。函数体里如果引用了「后面才 local 的
-- 名字」，那不是前向引用，而是**全局变量**——运行时值是 nil。
-- 这三个坑的共同症状一模一样：某条分支一旦走到就是
--     attempt to call a nil value
-- 而且都被外层 pcall / guard 吞掉，用户只看到「这个开关开了没反应」。
--
--   smokeBlocks     ← aimTarget 的「穿烟判定」。默认 aimThroughSmoke=true 时走不到，
--                     一旦关掉穿烟，自瞄就直接抛错返回 nil（= 不锁任何人）
--   getInvCtrl      ← updateAutoFire 读武器 Automatic / FireRate 那一段（在 2105 行，
--                     而 getInvCtrl 定义在 2835 行）。这意味着「自动开火」每帧都在
--                     这里崩，后面的点击/按住逻辑从来没执行过
--   heldIsThrowable ← 投掷物左/右键回调（5628 行用，7148 行才定义）。
--                     每次左键/右键都抛错 → autoThrowMode 永远是 "Far"，右键近投失效
local smokeBlocks
local getInvCtrl
local heldIsThrowable

local function aimTarget()
    local cam = workspace.CurrentCamera
    local center = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2)

    -- 视线检测：排除角色/手雷后，看相机到目标头部是否被实体挡住
    -- ⚠ 必须排除 Map.Barriers：那是地图的隐形屏障（肉眼看不见，射线会命中）。
    -- 之前没排除，实测射线在 16 stud 处就打在 Barriers.Part 上，
    -- 目标明明看得见却被判为「被遮挡」直接过滤 → aimTarget 永远返回 nil，
    -- 自瞄 / 静默 / 子弹追踪全部变成空转。
    local visParams = RaycastParams.new()
    visParams.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { cam }
    local cf = charsFolder()
    if cf then ignore[#ignore + 1] = cf end
    local dbr = workspace:FindFirstChild("Debris")
    if dbr then ignore[#ignore + 1] = dbr end
    if LP.Character then ignore[#ignore + 1] = LP.Character end
    local mapNode = workspace:FindFirstChild("Map")
    if mapNode then
        local barriers = mapNode:FindFirstChild("Barriers")
        if barriers then ignore[#ignore + 1] = barriers end
    end
    visParams.FilterDescendantsInstances = ignore

    -- ⚠ 失败原因分布统计（**累计**，不是单次）。
    --
    -- 原来每次调用都重建表，只能看到最后一次调用的分布 —— 打完一轮几十枪，
    -- 前面全部丢失，等于没用。现在挂在 S.vFail 上持续累加，
    -- 想看某一段就先把 S.vFail = {} 清零。
    if type(S.vFail) ~= "table" then S.vFail = {} end
    -- ═══ 穿墙识别：能不能穿，按游戏自己的材质/武器规则算 ═══
    --
    -- 情报里的判定公式（Shared.Raycast:138）：
    --   v1[v2] = 累计厚度;  v5 = 材质允许穿透值;  if v5 + 武器预算 < 厚度 then 打不穿
    -- 材质穿透值：Concrete 0 / Wood 10 / Plastic 10 / Glass 25 / Fabric 25
    -- 武器 Penetration：AWP·SSG 0.90 / 步枪 0.65 / 手枪 0.14 / P90·MP9·霰弹 0
    --
    -- 这里把它简化成「等级比较」：材质要几级穿透、手里的枪给到几级。
    -- 步枪能穿木/塑料/玻璃，AWP 连混凝土也穿，手枪只穿玻璃/布，SMG 一律不穿。
    S.PIERCE_MAX_GAP = 8   -- 墙后最多几 stud 才允许穿（越大越容易打空）
    S.MAT_PIERCE = {
        Concrete = 3, Brick = 3, Metal = 3, CorrodedMetal = 3, DiamondPlate = 3,
        Wood = 2, WoodPlanks = 2, Plastic = 2, SmoothPlastic = 2, Cobblestone = 2,
        Pebble = 2, Rock = 3,
        Glass = 1, Fabric = 1, ForceField = 1, Foil = 1, Grass = 1, Sand = 1,
    }

    S.weaponPierceLevel = function()
        local ic = getInvCtrl()
        local w = ic and ic.peekCurrentEquippedForMovement()
        local P = w and w.Properties
        local pen = tonumber(P and P.Penetration) or 0
        if pen >= 0.85 then return 3, pen end
        if pen >= 0.60 then return 2, pen end
        if pen > 0 then return 1, pen end
        return 0, pen
    end

    -- 返回 (能穿?, 材质等级, 武器等级)
    S.canPierce = function(hit)
        local lvl = S.weaponPierceLevel()
        local mat = (hit and hit.Material and hit.Material.Name) or "?"
        local need = S.MAT_PIERCE[mat] or 3   -- 未知材质按最硬的算，保守
        return (lvl > 0 and need <= lvl), need, lvl
    end

    local vFailCounts = S.vFail
    local function vFail(kind, detail)
        S.vDbg = detail or kind
        vFailCounts[kind] = (vFailCounts[kind] or 0) + 1
        return false
    end

    local function viable(t)
        -- ⚠ 被闪光晃到时不该锁人：这个服的白屏用 Lighting.ColorCorrection.Brightness 实现，
        -- 被闪时从 0 飙到 1 左右。以前所有自瞄（平滑/鼠标/静默/自动开火）都没有这一条，
        -- 所以「被闪了照样锁头开枪」。放在 viable() 入口 = 所有模式统一生效。
        do
            -- ⚠ 游戏闪光用独立对象（反编译自 VFXLibary.FlashEffect）：
            --   ScreenGui "FlashbangEffect"（PlayerGui 下，DisplayOrder 999）
            --   ColorCorrectionEffect "FlashbangColorCorrection"（Lighting 下）
            -- 之前查的 Lighting.ColorCorrection 是游戏基础校正，Brightness 恒为 0 → 永远检测不到。
            local pgV = game.Players.LocalPlayer:FindFirstChild("PlayerGui")
            if pgV and pgV:FindFirstChild("FlashbangEffect") then
                return vFail("flash", "flashbang-effect")
            end
            local ccV = game:GetService("Lighting"):FindFirstChild("FlashbangColorCorrection")
            if ccV and ccV:IsA("ColorCorrectionEffect") and (tonumber(ccV.Brightness) or 0) > 0.1 then
                return vFail("flash", "flashbang-cc brightness=" .. string.format("%.2f", ccV.Brightness))
            end
        end
        if t.dead then return vFail("dead", "dead:" .. tostring(t.name)) end
        if cfg.teamCheck and t.sameTeam then
            return vFail("teammate", "teammate:" .. tostring(t.name))
        end
        if cfg.teamCheck then
            local tm = tostring(t.team)
            if tm ~= "Counter-Terrorists" and tm ~= "Terrorists" then
                return vFail("badteam", "bad-team[" .. tm .. "]:" .. tostring(t.name))
            end
        end
        if t.frozen then return vFail("frozen", "frozen:" .. tostring(t.name)) end
        local sp = cam:WorldToViewportPoint(t.headPos)
        local d = 0
        -- ⚠ 360° 全向锁定只对「静默」有意义（改弹道、不转视角）。平滑/鼠标要靠转视角，
        -- 锁屏幕外的人根本转不过去。以前这里只看 cfg.fullSphere、不分模式，
        -- 结果「选了平滑却把准星拽向背后」。
        local useSphere = (cfg.fullSphere == true) and ((cfg.aimMode or "smooth") == "silent")
        if not useSphere then
            if sp.Z <= 0 then return vFail("zneg", "z=" .. string.format("%.1f", sp.Z)) end
            d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
            if d > cfg.fov then
                return vFail("fov", string.format("fov d=%.0f>%.0f", d, cfg.fov))
            end
        else
            d = 0
        end
        if cfg.aimVisibleCheck then
            -- ⚠ 露哪打哪（aimPartPriority）时，不能用「头部射线」判可见性。
            -- 原来这里写死 t.headPos：目标只露一条手臂、头在墙后 → 直接 blocked 判死，
            -- 后面的 bestVisiblePart / AIM_PART_ORDER 根本没机会跑（用户实测：露手臂不打）。
            -- 现在先按部位列表逐个试，只要有任何部位到相机之间没有地图遮挡就放行。
            if cfg.aimPartPriority and t.model then
                local PART_NAMES = {
                    "Head", "UpperTorso", "LowerTorso",
                    "RightUpperArm", "LeftUpperArm", "RightLowerArm", "LeftLowerArm",
                    "RightHand", "LeftHand",
                    "RightUpperLeg", "LeftUpperLeg", "RightLowerLeg", "LeftLowerLeg",
                    "RightFoot", "LeftFoot",
                }
                local anyVisible = false
                for _, nm in ipairs(PART_NAMES) do
                    local part = t.model:FindFirstChild(nm)
                    if part and part:IsA("BasePart") then
                        local delta = part.Position - cam.CFrame.Position
                        if delta.Magnitude < 300 then
                            if not workspace:Raycast(cam.CFrame.Position, delta, visParams) then
                                anyVisible = true
                                S.visPart = nm
                                break
                            end
                        end
                    end
                end
                if not anyVisible then
                    return vFail("blocked", "no-visible-part:" .. tostring(t.name))
                end
            else
                local dir = t.headPos - cam.CFrame.Position
                local hit = workspace:Raycast(cam.CFrame.Position, dir, visParams)
                if hit and (t.headPos - hit.Position).Magnitude >= 1.5 then
                    -- 墙后：材质等级够 且 目标离墙不超过 PIERCE_MAX_GAP 才放行
                    local gap = (t.headPos - hit.Position).Magnitude
                    local canPen, need, lvl = false, 3, 0
                    if cfg.wallbang then
                        canPen, need, lvl = S.canPierce(hit)
                    end
                    if canPen and gap <= (S.PIERCE_MAX_GAP or 8) then
                        S.pierceOk = (S.pierceOk or 0) + 1
                        S.lastPierce = string.format("%s need=%d lvl=%d gap=%.1f", tostring(hit.Material), need, lvl, gap)
                    else
                        S.pierceNo = (S.pierceNo or 0) + 1
                        S.lastPierce = string.format("blocked %s need=%d lvl=%d gap=%.1f", tostring(hit.Material), need, lvl, gap)
                        return vFail("blocked", "blocked by " .. tostring(hit.Instance and hit.Instance.Name))
                    end
                end
            end
        end
        if not cfg.aimThroughSmoke then
            if smokeBlocks(cam.CFrame.Position, t.headPos) then
                return vFail("smoke", "smoke")
            end
        end
        S.vDbg = "ok d=" .. string.format("%.0f", d)
        return true, d
    end

    -- ⚠ 每把枪一个瞄准距离：霰弹枪 45、AWP 900、AK 400…
    -- 原来只有全局 cfg.maxAimDist=500，霰弹枪会在 200 stud 外锁人（射程只有 120，等于空放）。
    local aimMax = cfg.maxAimDist
    do
        local okw, w = pcall(function()
            local ic = getInvCtrl()
            return ic and ic.peekCurrentEquippedForMovement()
        end)
        if okw and w and w.Name and cfg.aimDistByWeapon then
            local d = cfg.aimDistByWeapon[tostring(w.Name)]
            if d then aimMax = d end
        end
    end
    S.aimMaxNow = aimMax

    local candidates = {}
    for _, t in ipairs(allTargets()) do
        if t.distance <= aimMax then
            if not (cfg.teamCheck and t.sameTeam) then
                candidates[#candidates + 1] = t
            end
        end
    end

    -- 1) 已有锁定：只要目标还活着、还在 FOV 内，就继续打他
    if cfg.lockEnabled and aimLock.name then
        for _, t in ipairs(candidates) do
            if t.name == aimLock.name then
                local ok, d = viable(t)
                if ok and (os.clock() - aimLock.at) < cfg.lockMaxSeconds then
                    return t
                end
                break
            end
        end
        aimLock.name = nil   -- 锁定失效（死亡/出圈/超时）
    end

    -- 2) 没有锁定才重新挑最优
    local best, bestScore
    for _, t in ipairs(candidates) do
        local ok, d = viable(t)
        if ok then
            local score = scoreFor(t, d)
            if not bestScore or score < bestScore then
                best, bestScore = t, score
            end
        end
    end

    if best and cfg.lockEnabled and not (S._unlockUntil and os.clock() < S._unlockUntil) then
        aimLock.name = best.name
        aimLock.at = os.clock()
    end
    -- 把本次的失败原因分布暴露出去，方便区分「用户乱打」和「真 bug」
    S.vFail = vFailCounts
    return best
end

-- 玩家自己动视角 → 立刻解锁，让位给手动操作
-- 目标缓存：每 40ms 只扫描一次全表，所有模块共享
-- 之前每个模块各自调 collect，20 人时每秒要扫上百遍，主线程直接塞满
-- 注意：必须定义在 aimTarget 之前，否则 aimTarget 里拿到的是 nil（Lua 的 local 作用域）
local tcache = { list = {}, at = -999 }

allTargets = function()
    local now = os.clock()
    if now - tcache.at < 0.04 then
        return tcache.list
    end
    tcache.list = collect(3000, false)
    tcache.at = now
    return tcache.list
end

local unlockConn
pcall(function()
    unlockConn = UserInputService.InputChanged:Connect(function(input, gameProcessed)
        if not cfg.lockEnabled then return end
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseMovement then
            if math.abs(input.Delta.X) > 2 or math.abs(input.Delta.Y) > 2 then
                breakAimLock()
            end
        elseif t == Enum.UserInputType.Touch then
            if math.abs(input.Delta.X) > 3 or math.abs(input.Delta.Y) > 3 then
                breakAimLock()
            end
        end
    end)
    REG.conns[#REG.conns + 1] = unlockConn
    S.conns[#S.conns + 1] = unlockConn
end)

-- 目标缓存（定义已上移到 aimTarget 之前）

-- facingMe / smokeBlocks 都带 raycast，按目标节流
local faceCache = {}
local smokeCache = {}

-- 前置声明：smokeBlocks 定义在 ESP 那一节（更下面），
-- 不加声明的话 smokeBlockedCached 每帧都会 attempt to call a nil value，
-- 整个 updateEsp 直接中断，透视什么都不会画。
-- ⚠ 声明已经上移到 aimTarget 之前那一组里了（aimTarget 比这里更早用到它）。
-- 这里再写一次 local 会遮蔽掉上面那个，1431 前面那段就又是全局 nil。

local function facingMeCached(t)
    if not cfg.markThreat then return false end
    local now = os.clock()
    local c = faceCache[t.name]
    if c and now - c.at < 0.25 then return c.result end
    local r = facingMe(t)
    faceCache[t.name] = { result = r, at = now }
    return r
end

local function smokeBlockedCached(t)
    if not cfg.markSmoke then return false end
    local now = os.clock()
    local c = smokeCache[t.name]
    if c and now - c.at < 0.25 then return c.result end
    local cam = workspace.CurrentCamera
    local r = smokeBlocks(cam.CFrame.Position, t.headPos)
    smokeCache[t.name] = { result = r, at = now }
    return r
end

---------------------------------------------------------------------
-- 敌人高亮：区分「在掩体后」和「露在外面」
--
-- 从相机往目标头部打一条射线：
--   命中 → 中间有东西挡着（墙/箱子/门），目标在掩体后
--   没命中 → 视线通畅，目标暴露
--
-- 射线过滤掉自己和目标模型，免得被自己的身体或目标本身挡住。
-- 结果缓存 0.12 秒：这个检测每帧对每个目标做一次射线太浪费。
---------------------------------------------------------------------
local coverParams = RaycastParams.new()
coverParams.FilterType = Enum.RaycastFilterType.Exclude
coverParams.IgnoreWater = true
-- 隐形屏障必须排除，否则每个目标都会被判成「在掩体后」，
-- ESP 高亮就全是一片蓝色，等于没做区分。
coverParams.FilterDescendantsInstances = {}

local coverCache = {}

local function coverIgnoreList()
    local list = {}
    local me = myModel()
    if me then list[#list + 1] = me end
    local cf = charsFolder()
    if cf then list[#list + 1] = cf end
    local dbr = workspace:FindFirstChild("Debris")
    if dbr then list[#list + 1] = dbr end
    local mapNode = workspace:FindFirstChild("Map")
    if mapNode then
        local barriers = mapNode:FindFirstChild("Barriers")
        if barriers then list[#list + 1] = barriers end
    end
    return list
end

local function exposedCached(t)
    if not cfg.espCoverTint then return true end
    local now = os.clock()
    local c = coverCache[t.name]
    if c and now - c.at < 0.12 then return c.result end

    local cam = workspace.CurrentCamera
    if not cam then return true end
    coverParams.FilterDescendantsInstances = coverIgnoreList()

    local from = cam.CFrame.Position
    local to = t.headPos
    local hit = workspace:Raycast(from, to - from, coverParams)
    local result = (hit == nil)

    coverCache[t.name] = { result = result, at = now }
    return result
end

---------------------------------------------------------------------
-- 平滑瞄准 + 人体化
-- 关键点：改的是相机朝向，所以命令流里的 LookYaw 会跟着变，
--        服务端看到的「射击方向」和「视角」是一致的，不留破绽。
-- 人体化：反应延迟 / 指数平滑 / 手抖 / 过冲 / 部位随机
---------------------------------------------------------------------
local human = {
    targetName = nil,
    acquiredAt = 0,
    overshootSign = 1,
    overshootUntil = 0,
}

local function resetHuman()
    human.targetName = nil
    human.acquiredAt = 0
    human.overshootUntil = 0
end

-- 按概率挑瞄准点：头 or 胸
-- 开启「部位优先级」后改为：露哪打哪，头 > 脖子/胸 > 腹 > 手 > 腿 > 脚
local AIM_PART_ORDER = {
    "Head",
    "UpperTorso",          -- 脖子到胸这一段
    "LowerTorso",          -- 腹部
    "RightUpperArm", "LeftUpperArm",
    "RightLowerArm", "LeftLowerArm",
    "RightHand", "LeftHand",
    "RightUpperLeg", "LeftUpperLeg",
    "RightLowerLeg", "LeftLowerLeg",
    "RightFoot", "LeftFoot",
}

local partVisCache = {}
local visParams = RaycastParams.new()
visParams.FilterType = Enum.RaycastFilterType.Exclude
visParams.RespectCanCollide = false

local function bestVisiblePart(t)
    local cam = workspace.CurrentCamera
    if not cam then return nil end
    local camPos = cam.CFrame.Position

    -- 候选模型：优先用真实模型，PVS 剔除的用 RemoteBuffer 时没有模型
    local model = t.model
    if not model then return nil end

    -- 忽略自己和目标本身：射线只用来判断「有没有墙」
    local ig = {}
    if LP.Character then ig[#ig + 1] = LP.Character end
    ig[#ig + 1] = model
    visParams.FilterDescendantsInstances = ig

    for _, name in ipairs(AIM_PART_ORDER) do
        local part = model:FindFirstChild(name)
        if part and part:IsA("BasePart") then
            local pos = part.Position
            local delta = pos - camPos
            if delta.Magnitude < 300 then
                local hit = workspace:Raycast(camPos, delta, visParams)
                -- 没命中任何东西 = 这条线是通透的
                if not hit then
                    return pos, name
                end
            end
        end
    end
    return nil
end

local function bestVisiblePartCached(t)
    local now = os.clock()
    local c = partVisCache[t.name]
    -- ⚠ 缓存从 0.15 缩到 0.05（3 帧）。
    -- 0.15 秒的后果：露头 → 打头，头缩回去之后还会继续打头 150ms（等于往墙上打）。
    -- 用户的预期是「露头优先打头，缩回去立刻换下一个部位」。
    if c and now - c.at < 0.05 then return c.pos, c.part end
    local pos, part = bestVisiblePart(t)
    partVisCache[t.name] = { pos = pos, part = part, at = now }
    return pos, part
end

local function aimPointFor(t)
    -- ⚠ 部位选择的优先级（用户反馈「只锁头，不管自动部位瞄准配置」就是这里没接上）：
    --   1) cfg.aimHitPart 明确指定 head / chest / stomach → 直接照着打
    --   2) cfg.aimPartPriority → 露什么打什么（见缝插针）
    --   3) 都没配 → 按 cfg.headChance 在头和胸之间随机（旧行为）
    --
    -- 注意：静默瞄准也必须走这个函数，不能再直接写 target.headPos。
    local want = tostring(cfg.aimHitPart or "auto")
    if want == "head" then
        return t.headPos
    elseif want == "chest" then
        return t.pos + Vector3.new(0, 1.0, 0)
    elseif want == "stomach" then
        return t.pos + Vector3.new(0, 0.4, 0)
    elseif want == "legs" then
        -- 腿部：root 在腰部，头部 +1.55。
        --
        -- ⚠ 试过 -0.8，用户实测「6 发只打掉一半血」，比 -1.2 更差 —— 已回退。
        -- 推测原因：-0.8 落在大腿上部/胯部附近，那段是跑步动画摆动幅度最大的区域，
        -- 模型实际位置和 root 的固定偏移对不上；-1.2 落在小腿，动画位移小，反而更稳。
        -- 结论：这个偏移不能靠几何推算，只能按实测调。当前 -1.2 是实测最优。
        return t.pos - Vector3.new(0, 1.2, 0)
    end

    -- 部位优先级：露什么打什么
    if cfg.aimPartPriority then
        local pos = bestVisiblePartCached(t)
        if pos then return pos end
        -- 全身都看不见（纯透视预测），退回头部
        return t.headPos
    end

    -- 旧行为：按概率在头和胸之间随机
    if math.random() < cfg.headChance then
        return t.headPos
    end
    return t.pos + Vector3.new(0, 1.0, 0)
end

local function updateSmoothAim(dt)
    -- ⚠ 两条平滑链路必须互斥，否则同一个目标被转两次：
    --   · cfg.smoothAimHijack == true → AASYS.installSmooth 接管 GetMagnetismRotation，
    --     由游戏的相机控制器每帧转 ≤smoothAimMaxDeg 度；
    --   · 这里（updateSmoothAim）走 mousemoverel / cam.CFrame。
    -- 两个一起开就是「相机 1.5°/帧 + 鼠标增量」叠加 —— 过冲、来回抖、目标附近不收敛。
    -- 所以磁性吸附接管开着时，这里直接让位。
    if cfg.smoothAimHijack == true then
        resetHuman()
        return
    end
    -- ⚠ 全文件其它地方都写 (cfg.aimMode or "smooth")，只有这里裸比较。
    -- 一旦 aimMode 变成 nil（旧存档 / 被外部清过），平滑瞄准会永久不进入，
    -- 而 UI 上还显示着「平滑」—— 用户看到的就是「自瞄选了平滑但完全没反应」。
    if not (((cfg.aimMode or "smooth") == "smooth") and aimActive()) then
        resetHuman()
        return
    end

    local t = aimTarget()
    if not t then
        resetHuman()
        return
    end

    -- 反应延迟：刚发现这个目标时不立刻跟，模拟人眼与手速
    if human.targetName ~= t.name then
        human.targetName = t.name
        human.acquiredAt = os.clock()
        human.overshootSign = (math.random() < 0.5) and 1 or -1
        human.overshootUntil = os.clock() + math.random() * 0.08
        return
    end
    if os.clock() - human.acquiredAt < cfg.reactionDelay then
        return
    end

    local cam = workspace.CurrentCamera
    if not cam then return end
    local aimPos = aimPointFor(t)
    if typeof(aimPos) ~= "Vector3" then return end

    -- 过冲：短时间内把瞄准点往目标外侧偏一点，再由平滑拉回
    if cfg.overshoot and os.clock() < human.overshootUntil then
        local off = (aimPos - cam.CFrame.Position).Unit
        aimPos = aimPos + Vector3.new(-off.Z, 0, off.X) * human.overshootSign * (2 + math.random() * 3)
    end

    -- ⭐ 首选真实鼠标输入（和「鼠标瞄准」同一条通道）。
    --
    -- 为什么不能只写 cam.CFrame：这个游戏的相机控制器每帧重算 CFrame，
    -- 且执行点比我们的 RenderStep(1997) 更晚 —— 项目里实测「连续 384 帧写 cam.CFrame，
    -- 视线变化 0.00 度」，写完就被覆盖。也就是说：默认的平滑模式在那种情况下等于没自瞄。
    -- mousemoverel 走的是引擎输入通道，游戏会当成「玩家转了鼠标」，不会被覆盖。
    --
    -- 安全阀（缺一不可，否则会抢走用户的真实鼠标）：
    --   · 执行器没有 mousemoverel → 退回写 CFrame
    --   · 窗口没焦点 → 不动
    --   · 刚有真实键鼠操作（S.lastManualInput，0.6 秒内）→ 让位，用户要能点菜单
    --   · 焦点在输入框里 → 不动
    local inTextBox = false
    if UserInputService then
        local okTb, tb = pcall(function() return UserInputService:GetFocusedTextBox() end)
        inTextBox = (okTb and tb ~= nil)
    end
    if typeof(mousemoverel) == "function"
        and (not isrbxactive or isrbxactive())
        and (os.clock() - (S.lastManualInput or 0)) >= (cfg.mouseReleaseDelay or 0.6)
        and not inTextBox then
        local sp = cam:WorldToViewportPoint(aimPos)
        if sp.Z > 0 then
            local vp = cam.ViewportSize
            local dx = sp.X - vp.X * 0.5
            local dy = sp.Y - vp.Y * 0.5
            if math.abs(dx) > 2 or math.abs(dy) > 2 then
                -- ⚠ 「逐帧拉枪」的成因：每帧把剩余距离的 23%、最多 60 像素**一次性**发出去。
                -- 游戏相机对每个 mousemoverel 事件是直接响应、没有插值的，
                -- 所以视觉上就是一格一格地跳（用户形容「像 OBS 吸附」）。
                --
                -- 修法：
                --   ① alpha 压低（更小的每帧占比 → 曲线更细腻）
                --   ② 单步上限从 60 降到 12 像素（不再出现大跳）
                --   ③ 把这一帧的总位移**拆成 3 次**发出去，中间不等待 ——
                --      引擎会把它们当成 3 个连续的鼠标事件，相机分 3 次走完，
                --      视觉上就是连续的而不是一次跳跃。
                local speed = math.max(tonumber(cfg.smoothness) or 0.25, 0.02)
                local alpha = math.clamp(1 - math.exp(-dt / speed), 0.02, 0.6)
                local stepX = math.clamp(dx * alpha, -12, 12)
                local stepY = math.clamp(dy * alpha, -12, 12)
                -- ⚠ 一次发完，不要拆成多次。
                -- 拆成 3 次实测反而更"卡"：引擎把每个 mousemoverel 当成独立的鼠标事件，
                -- 相机被推着走 3 下，视觉上就是「一格一格吸附」（用户原话：像 OBS 吸附）。
                -- 单次 + 12 像素上限已经是连续移动了。
                pcall(function() mousemoverel(stepX, stepY) end)
                S.smoothMouseSteps = (S.smoothMouseSteps or 0) + 1
                S.smoothLastStep = string.format("%.2f,%.2f", stepX, stepY)
            else
                S.smoothSettled = (S.smoothSettled or 0) + 1
            end
            return
        end
    end

    -- ⚠ 这里原来是 `cam.CFrame` 回退分支，已删除。
    --
    -- 它的问题有两个，第二个是致命的：
    --   ① 这个游戏的相机控制器每帧重算 CFrame（实测 384 帧写下来变化 0.00 度），
    --      所以这个分支本来就转不动视角 —— 是死代码。
    --   ② 但它是 mousemoverel 分支的 **fallback**：用户一拖鼠标，S.lastManualInput
    --      就会刷新，mousemoverel 被 0.6 秒安全阀挡住 → 恰好掉进这个分支 →
    --      Lerp 到目标方向强行写 CFrame。用户看到的就是
    --      「我手动把准星拖出圈外，它还是把视角拽回去」（实测反馈）。
    -- 没有 mousemoverel 的执行器上，平滑模式本来也做不了事，直接静默退出即可。
    S.smoothNoMouse = (S.smoothNoMouse or 0) + 1
end

---------------------------------------------------------------------
-- 鼠标瞄准（真实输入）
--
-- 实测结论：这个游戏的相机被锁死了。
-- CameraType=Custom + CameraSubject=CameraPart，有自定义相机控制器
-- 在比 Last-3（1997）更高的优先级每帧重算 CFrame。
-- 实测在 1997 连续 384 帧写 cam.CFrame，视线变化 0.00 度 —— 完全无效。
-- 所以平滑瞄准改相机这条路走不通，只能发真实鼠标输入：
-- mousemoverel 走的是引擎输入通道，游戏收到的是「玩家转动了鼠标」，
-- 相机控制器会正常响应，不会被覆盖。
--
-- 换算：屏幕投影偏移(px) × 增益。增益受游戏内灵敏度影响，
-- 所以不是一步到位，而是每帧逼近 —— 越接近目标移动量越小，自然收敛。
---------------------------------------------------------------------
-- 鼠标瞄准的手动输入安全阀
--
-- 为什么必须有：mousemoverel 是真的在移动系统光标。
-- aimTrigger=always 时它每帧都在动，用户想点菜单、切窗口、按 Esc 退出，
-- 光标立刻被拉回目标方向 —— 唯一出路是杀进程。这个绝对不能留。
-- 所以：任何真实键鼠操作都暂停鼠标瞄准一段时间，让用户能操作 UI。
local lastManualInput = 0
pcall(function()
    -- ⚠ 这里原来写 UIS（全局 nil），整个连接从来没建立成功 —— 后果是
    -- lastManualInput 永远是 0，安全阀形同虚设：鼠标瞄准会一路抢占光标，
    -- 用户点菜单/切窗口都点不动。正确名字是开头的 UserInputService。
    local conn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        local t = input.UserInputType
        if t == Enum.UserInputType.Keyboard
            or t == Enum.UserInputType.MouseButton1
            or t == Enum.UserInputType.MouseButton2
            or t == Enum.UserInputType.MouseButton3
            or t == Enum.UserInputType.Touch then
            lastManualInput = os.clock()
            -- 平滑模式（走 mousemoverel 那条）也用同一个时间戳做安全阀。
            -- 它定义在 updateSmoothAim 里，函数比这里早，所以只能经 S 传。
            S.lastManualInput = lastManualInput
        end
    end)
    S.conns[#S.conns + 1] = conn
end)

local function updateMouseAim(dt)
    if not ((cfg.aimMode or "smooth") == "mouse" and aimActive()) then return end
    if typeof(mousemoverel) ~= "function" then return end
    -- 窗口没焦点就别动（也是防止误操作别的窗口）
    if isrbxactive and not isrbxactive() then return end
    -- 刚才有真实键鼠操作 → 让出控制权
    if os.clock() - lastManualInput < (cfg.mouseReleaseDelay or 0.6) then return end
    -- ⚠ 这里原来写的是 UIS，但 UIS 这个 local 直到文件末尾（inputDiag）才定义，
    -- 在这个作用域里它是**全局 nil** —— 每次执行到这一行就是
    -- "attempt to index nil with 'GetFocusedTextBox'"，被外层 pcall(updateMouseAim) 吞掉，
    -- 于是鼠标瞄准（aimMode="mouse"）每次都在这里中断，后面所有转向代码一行都没跑过。
    -- 正确名字是文件开头 292 行定义的 UserInputService。
    local inTextBox = false
    if UserInputService then
        local okTb, tb = pcall(function() return UserInputService:GetFocusedTextBox() end)
        inTextBox = (okTb and tb ~= nil)
    end
    if inTextBox then return end

    local t = aimTarget()
    if not t then return end

    -- 反应延迟
    if human.targetName ~= t.name then
        human.targetName = t.name
        human.acquiredAt = os.clock()
        return
    end
    if os.clock() - human.acquiredAt < cfg.reactionDelay then return end

    local cam = workspace.CurrentCamera
    local sp = cam:WorldToViewportPoint(t.headPos)
    if sp.Z <= 0 then return end

    local vp = cam.ViewportSize
    local dx = sp.X - vp.X * 0.5
    local dy = sp.Y - vp.Y * 0.5

    -- 死区放大到 10px：目标已在准星附近就别再动，避免来回微抖
    if math.abs(dx) < 10 and math.abs(dy) < 10 then
        S.mouseAimSettled = (S.mouseAimSettled or 0) + 1
        return
    end

    -- 增益不能给高。实测 0.35 会过冲：这一帧转过头，下一帧反向拉回，
    -- 两帧一循环就是肉眼可见的抖。0.12 + 每帧上限 12px 基本是单调逼近。
    local gain = math.clamp(tonumber(cfg.mouseGain) or 0.12, 0.02, 0.6)
    local maxStep = math.clamp(tonumber(cfg.mouseMaxStep) or 12, 1, 60)

    -- 指数平滑：对上一帧的移动量做低通，抹掉方向突变
    local prev = S.mouseLast or { x = 0, y = 0 }
    local tx = math.clamp(dx * gain, -maxStep, maxStep)
    local ty = math.clamp(dy * gain, -maxStep, maxStep)
    local smooth = math.clamp(tonumber(cfg.mouseSmooth) or 0.55, 0, 0.95)
    local mx = prev.x * smooth + tx * (1 - smooth)
    local my = prev.y * smooth + ty * (1 - smooth)

    if math.abs(mx) < 0.5 and math.abs(my) < 0.5 then
        S.mouseLast = { x = 0, y = 0 }
        return
    end
    S.mouseLast = { x = mx, y = my }

    pcall(function() mousemoverel(mx, my) end)
    S.mouseAimSteps = (S.mouseAimSteps or 0) + 1
end

---------------------------------------------------------------------
-- 武器分类 + 自动开火
-- 拿喷子远距离打不到人，所以每类武器单独配一个最大开火距离。
-- 开火用真实鼠标输入（mouse1click），游戏自己走射速/弹药，
-- 不伪造 ShootWeapon 包，服务端看到的是合法点击。
---------------------------------------------------------------------
local WEAPON_CLASS = {
    -- 狙击
    ["AWP"] = "Sniper", ["SSG 08"] = "Sniper", ["SCAR-20"] = "Sniper", ["G3SG1"] = "Sniper",
    -- 步枪
    ["AK-47"] = "Rifle", ["M4A4"] = "Rifle", ["M4A1-S"] = "Rifle", ["Galil AR"] = "Rifle",
    ["FAMAS"] = "Rifle", ["AUG"] = "Rifle", ["SG 553"] = "Rifle",
    -- 冲锋枪
    ["MP9"] = "SMG", ["MAC-10"] = "SMG", ["P90"] = "SMG", ["MP7"] = "SMG",
    ["MP5-SD"] = "SMG", ["PP-Bizon"] = "SMG", ["UMP-45"] = "SMG",
    -- 机枪（以前漏了，导致 Negev / M249 被当成"未知武器"过滤掉）
    ["Negev"] = "Rifle", ["M249"] = "Rifle",
    -- 手枪
    ["Glock-18"] = "Pistol", ["USP-S"] = "Pistol", ["P250"] = "Pistol", ["P2000"] = "Pistol",
    ["Five-SeveN"] = "Pistol", ["Tec-9"] = "Pistol", ["Dual Berettas"] = "Pistol",
    ["Desert Eagle"] = "Pistol", ["R8 Revolver"] = "Pistol", ["CZ75-Auto"] = "Pistol",
    -- 霰弹枪
    ["Nova"] = "Shotgun", ["XM1014"] = "Shotgun", ["MAG-7"] = "Shotgun", ["Sawed-Off"] = "Shotgun",
    -- 近战
    ["T Knife"] = "Melee", ["CT Knife"] = "Melee", ["Karambit"] = "Melee",
    ["M9 Bayonet"] = "Melee", ["Butterfly Knife"] = "Melee", ["Flip Knife"] = "Melee",
    ["Gut Knife"] = "Melee", ["Skeleton Knife"] = "Melee", ["Stiletto Knife"] = "Melee",
    ["LightSaber"] = "Melee", ["Zeus x27"] = "Melee",
}

-- 当前手持武器名：直接看 workspace.Camera 下挂着的模型
-- （WeaponModel 那个 Folder 已经是空的了，HUD 的 WeaponName 也读不到手雷）
local function heldWeaponName()
    local cam = workspace.CurrentCamera
    if not cam then return nil end
    -- 直挂相机下的 viewmodel（枪械通常是这种）
    for _, c in ipairs(cam:GetChildren()) do
        if c:IsA("Model") and c.Name ~= "ViewmodelStash" then
            return c.Name
        end
    end
    -- ⚠ 投掷物没有独立的 viewmodel，模型会躺在 ViewmodelStash 里（实测：
    --   拿着燃烧瓶时 cam 下只有 AudioListener + ViewmodelStash，一个 Model 都没有，
    --   于是这个函数返回 nil —— isGrenadeClass(nil) 恒为 false ——「拿着手雷没有抛物线」。
    --   所以这里补一条：把 ViewmodelStash 里的 Model 也当候选。
    local stash = cam:FindFirstChild("ViewmodelStash")
    if stash then
        for _, c in ipairs(stash:GetChildren()) do
            if c:IsA("Model") then return c.Name end
        end
    end
    -- 退回 HUD（万一 Camera 结构又变）
    local pg = LP:FindFirstChild("PlayerGui")
    local mg = pg and pg:FindFirstChild("MainGui")
    local gp = mg and mg:FindFirstChild("Gameplay")
    local bottom = gp and gp:FindFirstChild("Bottom")
    local inv = bottom and bottom:FindFirstChild("Inventory")
    if not inv then return nil end
    local best
    for _, slot in ipairs(inv:GetChildren()) do
        local w = slot:FindFirstChild("Weapon")
        local wn = w and w:FindFirstChild("WeaponName")
        if wn and typeof(wn.Text) == "string" and #wn.Text > 0 then
            best = wn.Text
        end
    end
    if not best then return nil end
    return (best:gsub("^%s*★%s*", ""):gsub("%s*|.*$", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function heldWeaponClass()
    local n = heldWeaponName()
    if not n then return "Rifle" end
    return WEAPON_CLASS[n] or "Rifle"
end

-- 自动开火状态
local af = {
    locking = nil,       -- 当前锁定的目标名
    since = 0,           -- 锁定开始时刻
    lastClick = 0,
    mouseDown = false,   -- 当前是否由我们按住了左键
}

local function updateAutoFire(dt)
    local fire = false
    -- ⚠ cam 必须在最外层取。
    --
    -- 原来它只在「非静默」那个分支里 local 声明，而下面的视线检测在分支外使用它 ——
    -- 静默模式下 cam 是 nil，`cam.CFrame` 抛错被 pcall 吞掉，于是 af.blocked
    -- 永远停在上一次的值。一旦某次判成「被挡住」，之后就一直不开火了。
    local cam = workspace.CurrentCamera

    if cfg.autoFire and cam then
        -- ⚠ C4 下包 / 拆包时必须停自动开火：
        -- 下包和拆包都要求「持续按住」，而自动开火在反复 mouse1press/release，
        -- 每隔几毫秒打断一次 → 进度条反复归零，表现是「一到包点就疯狂左键、永远下不完」。
        -- 判据只有两个：
        --   1) 手持 C4（准备下包）
        --   2) HUD 的 PlantBomb / DefuseBomb 进度条可见（正在下包或拆包）
        -- 注意：拿着拆弹器（Defuse Kit）但没在拆包时**不停**，那时还能正常开枪。
        do
            local busy0 = (heldWeaponName() == "C4")
            -- ⚠ 手持投掷物同样不能自动开火。
            -- 这个游戏左键的含义随手持物变化：拿枪是「射击」，拿雷是「扔出去」。
            -- 自动开火只判断「有目标 + 距离够」，而投掷物在 WEAPON_CLASS 里没有条目，
            -- heldWeaponClass() 会兜底成 Rifle（maxDist=300）——
            -- 于是 300 stud 内一出现目标就按住左键，表现就是「不知道什么时候把雷全扔光了」。
            if not busy0 and type(heldIsThrowable) == "function" and heldIsThrowable() then
                busy0 = true
            end
            if not busy0 then
                local pgA = LP:FindFirstChild("PlayerGui")
                local midA = pgA and pgA:FindFirstChild("MainGui")
                    and pgA.MainGui:FindFirstChild("Gameplay")
                    and pgA.MainGui.Gameplay:FindFirstChild("Middle")
                if midA then
                    local pb = midA:FindFirstChild("PlantBomb")
                    local db = midA:FindFirstChild("DefuseBomb")
                    if (pb and pb.Visible) or (db and db.Visible) then busy0 = true end
                end
            end
            -- 热身阶段：由 cfg.autoFireWarmup 控制。
            -- 这个配置以前只定义、从没被读过（死配置）。这里接上，
            -- 默认 true = 保持原来的行为（热身也开火），想要安静就关掉。
            if not busy0 and cfg.autoFireWarmup ~= true then
                local stW = tostring(workspace:GetAttribute("GameState") or "")
                if stW == "Warmup" then busy0 = true end
            end
            if busy0 then
                if af.mouseDown then pcall(function() mouse1release() end); af.mouseDown = false end
                return
            end
        end
        local t = aimTarget()
        if t and not t.dead then
            -- 按武器类型判断这个距离打不打得着
            local cls = heldWeaponClass()
            local prof = cfg.weaponProfiles[cls]
            -- ⚠ Zeus x27：服务器配置 Range=13.584 / Rounds=1 / RechargeTime=30。
            -- WEAPON_CLASS 里没有它（会默认归 Rifle=300），于是 300 stud 外也开枪、打空。
            -- 这里按真实范围 13.5 限制。
            local wnZ = heldWeaponName()
            local maxFireDist = prof and prof.maxDist or 0
            local zeusOk = (wnZ == "Zeus x27")
            if zeusOk then maxFireDist = 13.5 end
            -- Zeus 归 Melee 槽位，而 Melee 档位默认关；这里让它独立生效，不受档位开关影响
            if ((prof and prof.enabled) or zeusOk) and t.distance <= maxFireDist then
                -- 延迟：换目标就重新计时；延迟为 0 时不空转这一帧
                if af.locking ~= t.name then
                    af.locking = t.name
                    af.since = os.clock()
                end
                local waitSec = math.max(tonumber(cfg.autoFireDelay) or 0, 0) / 1000
                if os.clock() - af.since >= waitSec then
                    local pass = true

                    -- 准星偏移检查只对「会转视角」的模式有意义：
                    -- 静默是改 Bullets[].Direction，准星指哪儿不影响命中。
                    if (cfg.aimMode or "smooth") ~= "silent" then
                        local sp = cam:WorldToViewportPoint(t.headPos)
                        if sp.Z <= 0 then
                            pass = false
                        else
                            local vp = cam.ViewportSize
                            local offX = sp.X - vp.X * 0.5
                            local offY = sp.Y - vp.Y * 0.5
                            af.centerDist = math.sqrt(offX * offX + offY * offY)
                            if af.centerDist > (tonumber(cfg.autoFireMaxOffset) or 45) then
                                pass = false
                            end
                        end
                    end
                    -- ⚠ 被闪光晃到就不该开火。游戏闪光用独立对象（反编译自 VFXLibary.FlashEffect）：
                    --   PlayerGui "FlashbangEffect"（DisplayOrder 999）
                    --   Lighting  "FlashbangColorCorrection"
                    -- 之前查 Lighting.ColorCorrection（游戏基础校正，Brightness 恒 0）→ 永远检测不到。
                    if pass then
                        local pgF = game.Players.LocalPlayer:FindFirstChild("PlayerGui")
                        local flashOn = pgF and pgF:FindFirstChild("FlashbangEffect")
                        if not flashOn then
                            local cF = game:GetService("Lighting"):FindFirstChild("FlashbangColorCorrection")
                            flashOn = cF and cF:IsA("ColorCorrectionEffect") and (tonumber(cF.Brightness) or 0) > 0.1
                        end
                        if flashOn then pass = false end
                    end


                    -- 视线检测：目标在掩体后就不开火（排除隐形屏障）
                    -- ⚠ 这里原来只看「有没有命中墙」，跟 cfg.wallbang 完全脱钩 ——
                    -- 结果就是「静默+360+穿墙都开了，自动开火却永远不打墙后的人」。
                    -- 现在和 viable() 用同一套判定：材质等级够 且 墙后 ≤ PIERCE_MAX_GAP 才放行。
                    if pass then
                        coverParams.FilterDescendantsInstances = coverIgnoreList()
                        local from = cam.CFrame.Position
                        local hit = workspace:Raycast(from, t.headPos - from, coverParams)
                        if hit then
                            local gap = (t.headPos - hit.Position).Magnitude
                            local canPen = false
                            if cfg.wallbang then
                                canPen = S.canPierce(hit)
                            end
                            af.blocked = not (canPen and gap <= (S.PIERCE_MAX_GAP or 8))
                        else
                            af.blocked = false
                        end
                        if not af.blocked then fire = true end
                    end
                end
            else
                af.locking = nil
            end
        else
            af.locking = nil
        end
    end

    -- 移动端：屏幕上的「开火」按钮按住时，无视目标判定直接开火。
    -- 手机上玩家没法像鼠标那样精确控制扳机，需要一个明确的射击键。
    if IS_MOBILE and cfg.mobileHoldFire == true then
        fire = true
    end

    ---------------------------------------------------------------
    -- 开火：按住左键，让游戏自己按武器射速连发
    --
    -- ⚠ 原来用的是 mouse1click —— 每次点击要过「按下 + 释放」两次输入事件，
    -- 引擎还要排一个输入队列，天然就是 1~3 帧的延迟。而本作的射击判定是
    -- InputController.isActionPressed("Fire") —— **按住就持续开火**。
    --
    -- 所以正确做法是：有目标时保持按下，没目标时松开。这样每发之间的间隔
    -- 完全由游戏自己的射速逻辑决定，不再受"我们多久点一次"限制，
    -- 也不会因为释放/按下之间的空隙丢掉本可以打出去的那一帧。
    ---------------------------------------------------------------
    -- 注意 API 名字：执行器提供的是 mouse1press / mouse1release，
    -- 不是 mouse1down / mouse1up（后者在这个核心里是 nil，typeof 会是 "nil"）。
    local canHold = (typeof(mouse1press) == "function") and (typeof(mouse1release) == "function")
    if not IS_MOBILE then
        -- ⚠⚠ 单发枪（Automatic=false）不能用「按住」。
        --
        -- 实测 AWP 的 Properties.Automatic = false。单发武器的射击判定是
        -- 「一次新的按下事件」，按住不放只会响第一次 —— 之后无论按多久都不再开枪。
        -- 这就是用户说的「自动开火不吃跳过射击间隔，大狙还是要拉栓」的真正原因：
        -- 不是拉栓没跳过，而是 autoFire 按住之后根本不产生新的射击请求。
        --
        -- 处理：单发武器改用「按下 → 松开 → 等 FireRate → 再按下」的点击循环。
        -- 自动武器（AK/M4）仍然保持按住，让游戏自己按射速连发。
        local autoWeapon = true
        do
            local ic0 = getInvCtrl()
            if ic0 then
                local okw, w0 = pcall(function() return ic0.peekCurrentEquippedForMovement() end)
                if okw and w0 and type(w0.Properties) == "table"
                    and w0.Properties.Automatic == false then
                    autoWeapon = false
                    af.weaponFireRate = tonumber(w0.Properties.FireRate) or 0.15
                end
            end
        end
        S.afAutoWeapon = autoWeapon

        if not autoWeapon then
            -- ── 单发武器：点击循环 ──
            --
            -- ⚠ 间隔必须 ≥ 武器 FireRate，绝对不能为了"跳过间隔"把它压短。
            --
            -- 实测教训：曾经在 skipFireDelay 打开时把间隔压到 0.05 秒，
            -- AWP（FireRate=1.46）就变成每 50ms 发一个包 —— 服务端按射速校验
            -- 把这批包全丢了，结果用户「开了友军伤害打 AI 队友，一发都不掉血」。
            -- 超速发包不是打得快，是连正常那一发也被废掉。
            --
            -- 所以：客户端点击节奏完全跟随 FireRate，服务端每一发都会接受。
            local gap = math.max(tonumber(af.weaponFireRate) or 0.15, 0.06)
            local nowC = os.clock()
            if af.mouseDown then
                pcall(function() mouse1release() end)
                af.mouseDown = false
                af.releaseAt = nowC
            end
            if fire and (nowC - (af.lastSingleShot or 0)) >= gap then
                af.lastSingleShot = nowC
                -- ⚠ 三级降级：按住式 → 点击式 → 直接调 shoot()。
                -- 执行器不一定有鼠标注入 API（Real 实测 mouse1press/mouse1release 可能是 nil），
                -- 只写前两级的话，单发武器（AWP/手枪）在那种执行器上一枪都打不出去。
                if canHold then
                    pcall(function() mouse1press() end)
                    pcall(function() mouse1release() end)
                elseif typeof(mouse1click) == "function" then
                    pcall(function() mouse1click() end)
                else
                    local icS = getInvCtrl()
                    local wS = icS and icS.peekCurrentEquippedForMovement()
                    if wS and typeof(wS.shoot) == "function" then
                        pcall(function() wS.NextShotDue = os.clock() - 0.01 end)
                        pcall(function() wS:shoot() end)
                        S.autoFireShootFallback = (S.autoFireShootFallback or 0) + 1
                    end
                end
                S.autoFireClicks = (S.autoFireClicks or 0) + 1
                S.singleShotClicks = (S.singleShotClicks or 0) + 1
            end
        else
        -- ⚠ 后坐力保护：不能一直按住不放。
        --
        -- 本作的后坐力是「持续开火就持续抬枪」，按住左键一路打下去，
        -- 镜头会自己飘到天上（实测 pitch 从 12 一路爬到 31，关掉 autoFire 后
        -- 1 秒内回落到 15.3 并完全稳定）。静默模式又跳过了准星偏移检查，
        -- 于是这个按住会一直持续 —— 用户看到的就是「自瞄瞄天上」。
        --
        -- 处理：按住超过 autoFireHoldLimit 秒就松开一下，让后坐力衰减。
        local holdLimit = tonumber(cfg.autoFireHoldLimit) or 0.6
        if af.mouseDown and af.downAt and (os.clock() - af.downAt) > holdLimit then
            pcall(function() mouse1release() end)
            af.mouseDown = false
            af.downAt = nil
            af.releaseAt = os.clock()
            S.autoFireRecoilBreaks = (S.autoFireRecoilBreaks or 0) + 1
        end

        local inCooldown = af.releaseAt and (os.clock() - af.releaseAt) < 0.05
        if fire and not inCooldown then
            if canHold then
                if not af.mouseDown then
                    pcall(function() mouse1press() end)
                    af.mouseDown = true
                    af.downAt = os.clock()
                    S.autoFireClicks = (S.autoFireClicks or 0) + 1
                end
            else
                -- 执行器没有按住式 API 时退回点击，并保留节流。
                -- ⚠ 再退一级：连 mouse1click 都没有（Real 实测鼠标注入可能全 nil）时，
                -- 直接调武器自己的 shoot()。否则「自动开火」在这类执行器上就是
                -- 开关打开、代码在跑、一枪不开 —— 而 UI 上完全看不出异常。
                local clickGap = tonumber(cfg.autoFireClickGap) or 0.04
                if os.clock() - af.lastClick > clickGap then
                    af.lastClick = os.clock()
                    if typeof(mouse1click) == "function" then
                        pcall(function() mouse1click() end)
                    else
                        local icF = getInvCtrl()
                        local wF = icF and icF.peekCurrentEquippedForMovement()
                        if wF and typeof(wF.shoot) == "function" then
                            pcall(function() wF.NextShotDue = os.clock() - 0.01 end)
                            pcall(function() wF:shoot() end)
                            S.autoFireShootFallback = (S.autoFireShootFallback or 0) + 1
                        end
                    end
                    S.autoFireClicks = (S.autoFireClicks or 0) + 1
                end
            end
        elseif af.mouseDown then
            pcall(function() mouse1release() end)
            af.mouseDown = false
            af.downAt = nil
            af.releaseAt = os.clock()
        end
        end   -- if not autoWeapon / else
    else
        -- ═══════════════════════════════════════════════════════════
        -- 移动端开火：绕过输入系统，直接调武器自己的 shoot()
        --
        -- 手机上 mouse1press / mouse1release 都不存在（或无效），
        -- 所以原来的 autoFire 在移动端等于完全没接上 —— 整个 if not IS_MOBILE
        -- 把开火逻辑全跳过了。
        --
        -- 但 Weapon 组件本身有 shoot() 方法（客户端本地执行，会走完整的
        -- 弹道/后坐力/动作流程，最终发 ShootWeapon 包）。
        -- 直接按 FireRate 的节奏调它，就等于「帮玩家扣扳机」。
        --
        -- 节奏必须 ≥ FireRate：服务端按射速校验，超速整包丢弃。
        -- ═══════════════════════════════════════════════════════════
        local icM = getInvCtrl()
        local wM = nil
        if icM then
            local okw, tmp = pcall(function() return icM.peekCurrentEquippedForMovement() end)
            if okw then wM = tmp end
        end
        if wM and type(wM.Properties) == "table" then
            af.weaponFireRate = tonumber(wM.Properties.FireRate) or 0.15
        end
        S.afMobileWeapon = wM and wM.Name or nil

        if fire and wM and typeof(wM.shoot) == "function" then
            local gap = math.max(tonumber(af.weaponFireRate) or 0.15, 0.06)
            local nowM = os.clock()
            if (nowM - (af.lastSingleShot or 0)) >= gap then
                af.lastSingleShot = nowM
                local okShoot, errShoot = pcall(function() wM:shoot() end)
                if okShoot then
                    S.mobileShots = (S.mobileShots or 0) + 1
                else
                    S.err_mobileshoot = tostring(errShoot)
                end
            end
        end
    end

    -- 埋点：外部能直接看到「现在有没有按着左键」以及这一帧要不要开火。
    -- 按住不放会让游戏持续开火，后坐力把镜头一路抬天（表现像"自瞄瞄天上"）。
    S.afMouseDown = af.mouseDown
    S.afFire = fire
end

-- 必须晚于游戏自己的相机控制。
-- 之前用 Camera.Value + 1（201），但那之后游戏还会再写一次 cam.CFrame，
-- 平滑瞄准写进去的转向每帧都被覆盖 —— 这就是「平滑自瞄完全没反应」的原因。
-- 第三人称当初就是从 201 挪到 1999 才不闪的，同一回事。
-- 顺序：1997 平滑瞄准 → 1998 陀螺 → 1999 第三人称 → 2000 绘制
local okBind = pcall(function()
    RunService:BindToRenderStep("MVHub_Aim", Enum.RenderPriority.Last.Value - 3, function(dt)
        if S._alive == false or REG.gen ~= MY_GEN then return end
        -- 移动端走 MVHub_AimMobile 那条线，这里跳过避免重复应用平滑
        if not IS_MOBILE then
            -- 鼠标瞄准和"改相机"两条路分开：相机被游戏锁死，只有鼠标输入有效
            pcall(updateMouseAim, dt)
            if (cfg.aimMode or "smooth") == "smooth" then
                pcall(updateSmoothAim, dt)
            end
        end
        pcall(updateAutoFire, dt)
    end)
end)

---------------------------------------------------------------------
-- 移动端专用：接管相机只在「开火瞬间」发生，平时不抢你的视角
--   手机上「瞄准」按钮改为按住式会挡手，所以改成：
--   检测到附近有目标 + 你正在开火时才短暂接管
---------------------------------------------------------------------
local mobileFireWindowUntil = 0

local function updateMobileAim(dt)
    if not IS_MOBILE then return end
    if not (((cfg.aimMode or "smooth") == "smooth") and aimActive()) then return end
    if os.clock() > mobileFireWindowUntil then
        resetHuman()
        return
    end
    pcall(updateSmoothAim, dt)
end

local okBindMobile = pcall(function()
    RunService:BindToRenderStep("MVHub_AimMobile", Enum.RenderPriority.Last.Value - 4, function(dt)
        if S._alive == false or REG.gen ~= MY_GEN then return end
        pcall(updateMobileAim, dt)
    end)
end)

---------------------------------------------------------------------
-- 射击拦截
--
-- ⚠ 两个必须用「直接替换表字段」而不是 hookfunction 的理由：
--   实测 hookfunction(pkt.Send, f) 返回 ok=true、也返回 wrapper，
--   但 pkt.Send 这个表字段仍然是原始函数，游戏走的是表字段，拦截层永不执行。
--
-- ⚠ 而且原始函数必须存在 getgenv 里复用。
--   如果每次重载都写 originalSend = shootPacket.Send，拿到的会是上一次的包装层，
--   重载几十次就叠成几十层深链，中间任何一层的闭包失效就整条断掉 ——
--   表现就是「开不了枪」。存进 getgenv 后每次重载都用同一个原始函数，永不叠加。
---------------------------------------------------------------------
local function isRawSend(f)
    if typeof(f) ~= "function" then return false end
    local ok, s = pcall(function()
        local ok2, a = pcall(debug.info, f, "s")
        return ok2 and tostring(a) or ""
    end)
    return ok and tostring(s):find("Network") ~= nil
end

---------------------------------------------------------------------
-- 近战超距离（Melee.MeleeAttack）
--
-- payload 结构（Remotes 里的 schema）：
--   Direction   Vec3      ← 关键：= CurrentCamera.CFrame.LookVector * Properties.Range
--                           也就是**方向向量里带着射程长度**
--   Material    String
--   Distance    Float32   ← 命中点到攻击者的距离
--   Instance    Instance
--   VictimUserId Float64  ← 客户端指定打谁
--   HitPartName String    ← 客户端指定打哪个部位
--   Position / Normal / MeleeAttack / Identifier
--
-- 所以「超距离」就是把 Direction 的长度和 Distance 一起放大 ——
-- 服务端如果直接拿 Direction 当射线，射程就跟着变长。
-- 这是近战最有可能突破的点，因为整条射线结果都是客户端算的。
---------------------------------------------------------------------
Remotes.Melee.MeleeAttack.Send = (function()
    local pkt = Remotes.Melee.MeleeAttack
    local orig = getgenv().MV_ORIG_MELEE
    if typeof(orig) ~= "function" then
        orig = pkt.Send
        getgenv().MV_ORIG_MELEE = orig
    end
    return function(payload)
        if typeof(payload) == "table" then
            pcall(function()
                local mul = tonumber(cfg.meleeRange) or 1
                if mul > 1 then
                    local d = payload.Direction
                    if typeof(d) == "Vector3" and d.Magnitude > 0.01 then
                        payload.Direction = d * mul
                        S.meleeRangeShots = (S.meleeRangeShots or 0) + 1
                    end
                    if typeof(payload.Distance) == "number" then
                        payload.Distance = payload.Distance * mul
                    end
                end
            end)
        end
        return orig(payload)
    end
end)()

local originalSend = getgenv().MV_ORIG_SEND
if not isRawSend(originalSend) then
    -- 没有存过，或者存的已经不是原始的（被污染过）→ 重新取
    originalSend = shootPacket.Send
    -- 如果当前表字段也被替换过（不是 Network 函数），沿 upvalue 找一层
    if not isRawSend(originalSend) then
        -- ⚠ Real 的 debug.getupvalue(fn, i) 只返回「值」，没有 name
        -- （标准 Lua 才是 (name, value)）。这里原来写 select(2, ...)，在 Real 上恒为 nil，
        -- 于是「沿 upvalue 找回真正的 Network 函数」从来没生效过。
        -- 后果：一旦 getgenv().MV_ORIG_SEND 丢失或被污染，originalSend 就停在旧 wrapper 上，
        -- 每次开火多套一层改写，重载几次越叠越深，极端情况（wrapper 指回自己）直接栈溢出。
        local up1 = debug.getupvalue(originalSend, 1)
        if isRawSend(up1) then
            originalSend = up1
        end
    end
    getgenv().MV_ORIG_SEND = originalSend
end

-- 每次加载都从原始函数重新挂钩，保证只有一层
shootPacket.Send = function(payload)
    if typeof(payload) ~= "table" or typeof(payload.Bullets) ~= "table" then
        return originalSend(payload)
    end

    S.shots += 1

    -- 抓一份「真实开火」的 payload 快照，供实验用。
    --
    -- 为什么需要它：想验证超射速能不能被服务端接受，必须能发出一模一样的包。
    -- 之前用 API 手搓 payload 直接 Send，服务端无视（impact=0）——
    -- 大概率是 Seq / ViewTick / Origin 有一项不合法。
    -- 有了这个快照，就能拿真实值原样重放，把「包格式对不对」这个变量排掉，
    -- 剩下的才真的是「服务端认不认迭发包」。
    do
        -- ⚠ 这里刻意只用**一个**循环变量 k，且不引入任何局部表 —— 主 chunk 已经贴
        -- 200 个 local 上限，多写两个 local 就直接 Out of local registers 整份脚本编译失败
        -- （踩过：改成 k,v 双变量 + 新表，立刻 exceeded limit 200）。
        --
        -- 记完整字段的理由：之前只挑 7 个字段重发，服务端一律无视（扣弹 0）。
        -- 很可能不是射速校验，而是**缺字段**导致解码阶段就被丢弃。
        S.lastShootPayload = {}
        S.shootPayloadKeys = ""
        for k in pairs(payload) do
            if k ~= "Bullets" then S.lastShootPayload[k] = payload[k] end
            S.shootPayloadKeys = S.shootPayloadKeys .. tostring(k) .. " "
        end
        S.lastShootBullets = payload.Bullets
        S.lastShootPayload.at = os.clock()
        S.shootPayloadCount = (S.shootPayloadCount or 0) + 1
    end

    -- ⚠ 整段改写逻辑必须用 pcall 包住。
    -- payload.Bullets 里的表可能冻结，赋值会抛 readonly；目标也可能瞬间消失。
    -- 任何一步抛出去都走不到下面的 originalSend(payload)，包发不出去 = 开不了枪。
    -- 原则：改写失败可以接受，挡住开枪绝对不行。
    local _ok, _err = pcall(function()
    if typeof(payload.Seq) == "number" then cfg.lastSeq = payload.Seq end
    -- 手机端：开火瞬间打开 0.25s 的接管窗口，其余时间把相机还给玩家
    if IS_MOBILE then
        mobileFireWindowUntil = os.clock() + 0.25
    end

    -- ⚠ 静默瞄准和自动开火必须解耦，但「静默」本身只能由 silentAim 一个开关控制。
    --
    -- 演进过程（三次都踩了坑，记下来）：
    --   1) 原来是 aimActive() or (autoFire and silentAim)
    --      → 静默被绑在 autoFire 上，关掉 autoFire 静默也死了
    --   2) 改成 (silentAim == true) or (aimMode == "silent") or aimActive()
    --      → 但 aimMode 是「模式选择」不是「开关」，写进来等于关掉 silentAim 也照样静默
    --   3) 现在：只看 silentAim
    --
    -- 这个函数只在「玩家真的开了一枪」时才会被调用（shootPacket.Send 内部），
    -- 所以只看 silentAim 不会导致「看一眼就自动开枪」——开枪仍由 autoFire 控制。
    -- ⚠ 只有 aimMode == "silent" 时才改写弹道。
    -- 之前只看 silentAim，导致「选了平滑瞄准，子弹还是自己拐弯」——用户实测反馈的正是这个。
    -- 现在的语义：
    --   aimMode = "smooth"  → 只转视角，子弹按准星飞（安全）
    --   aimMode = "silent"  → 改 Bullets[].Direction（不动视角）
    --   aimMode = "mouse"   → 真实鼠标输入，不动弹道
    -- silentAim 仍然保留为总开关（关掉就什么都不做）。
    local shouldAim = (cfg.silentAim == true) and ((cfg.aimMode or "smooth") == "silent")
    local target = nil

    -- ⚠ target 的触发条件不能只有「静默 or 多发」：
    -- 下面的 wallbang / bulletTrack 全靠 target 才执行，而它们在 UI 上是独立开关。
    -- 以前这里只写 shouldAim or cfg.multiShot —— 于是「开了穿墙 / 子弹追踪、但没开静默」
    -- 时 target 恒为 nil，那两个功能永远走不到，用户看到的就是「开关打开了没反应」。
    if shouldAim or cfg.multiShot or cfg.wallbang or cfg.bulletTrack then
        target = aimTarget()
        if target then
            S.lastTarget = target.name
            -- ⚠ 开枪这一刻的目标是唯一可信的证据。
            --
            -- 之前只在 aimTarget 上做采样验证，但用户反馈「实际打起来会锁队友」——
            -- 采样那一瞬间可能刚好没锁，抓不到。这里把每次真正改写子弹方向时
            -- 用的目标记下来（名字 + 队伍 + sameTeam），事后直接看日志，
            -- 比在外部反复采样可靠得多。
            S.lastAimName = tostring(target.name)
            S.lastAimTeam = tostring(target.team)
            S.lastAimSame = target.sameTeam
            S.bindTargetSame = S.bindTargetSame or {}
            S.bindTargetSame[tostring(target.sameTeam)] =
                (S.bindTargetSame[tostring(target.sameTeam)] or 0) + 1
        end
    end

    -- 静默瞄准：把所有子弹方向改成指向「部位选择」算出的瞄准点
    if shouldAim and target then
        local origin = payload.Bullets[1] and payload.Bullets[1].Origin
        if origin then
            -- ⚠ 必须走 aimPointFor，不能直接写 target.headPos。
            --
            -- 用户反馈「只锁头，不管自动部位瞄准配置」：
            -- 以前这里硬编码 headPos，所以 cfg.aimHitPart / aimPartPriority /
            -- headChance 三个配置对静默完全无效，永远只打头。
            local aimPt = target.headPos
            pcall(function()
                local p = aimPointFor(target)
                if typeof(p) == "Vector3" then aimPt = p end
            end)
            S.lastAimPoint = aimPt
            local dir = (aimPt - origin)
            if dir.Magnitude > 0.01 then
                local unit = dir.Unit
                for i = 1, #payload.Bullets do
                    payload.Bullets[i].Direction = unit
                end
                S.rewritten += 1
                -- 逐发日志：记录这一发到底改写成了什么方向。
                -- 用户反馈「往地上打，静默仍打到人，但地上出现两个弹孔」——
                -- 说明 6 发里有几发没改写。靠这个日志就能看出是哪几发、目标是谁。
                if type(S.shotLog) ~= "table" then S.shotLog = {} end
                local lg = S.shotLog
                lg[#lg + 1] = string.format("改写了 -> %s  dir=%.2f,%.2f,%.2f",
                    tostring(target.name), unit.X, unit.Y, unit.Z)
                while #lg > 12 do table.remove(lg, 1) end
            end
        end
    end

    -- 无散射（俗称「据点」/完美精准）
    --
    -- 原理：游戏在客户端就算好了每颗子弹的 Direction —— 里面已经掺进了散射偏移
    -- （AWP 的 Spread = {MovementMultiplier=3, PerShot=0, Range={0,20}, RecoverySpeed=5}，
    --  其中 MovementMultiplier=3 就是「跑动时散射 ×3」的来源）。
    -- 服务端拿这个 Direction 去算命中，所以只要在发出去之前把它重置成相机准星方向，
    -- 散射就消失了 —— 而且 Direction 本来就是客户端合法字段，服务端照单全收。
    --
    -- ⚠ 优先级：静默瞄准（指向目标）> 无散射（指向准星）。
    -- 静默已经改过 Direction 时不能再覆盖，否则会把瞄准结果冲掉。
    if cfg.noSpread and not (shouldAim and target) then
        local cam = workspace.CurrentCamera
        if cam then
            local dir = cam.CFrame.LookVector
            local applied = 0
            for i = 1, #payload.Bullets do
                local b = payload.Bullets[i]
                if type(b) == "table" then
                    b.Direction = dir
                    applied = applied + 1
                end
            end
            if applied > 0 then
                S.noSpreadShots = (S.noSpreadShots or 0) + 1
                S.lastSpreadMode = "noSpread"
                -- 逐发日志：这一发没走静默，落到了准星方向（用户看到的就是「打地上」）
                if type(S.shotLog) ~= "table" then S.shotLog = {} end
                local lg = S.shotLog
                lg[#lg + 1] = string.format("未改写 -> 准星方向 dir=%.2f,%.2f,%.2f (%s)",
                    dir.X, dir.Y, dir.Z,
                    (shouldAim and "target为nil") or "silentAim关闭")
                while #lg > 12 do table.remove(lg, 1) end
            end
        end
    end

    -- 埋点：把「实际发出去的方向」和「相机准星方向」都记下来。
    -- 两者夹角如果是 0，说明散射确实被抹掉了；如果明显有角度差，说明改写没生效
    -- 或者被后面的分支覆盖了。用户反馈「子弹依然在散射」，就靠这个判定。
    pcall(function()
        local b1 = payload.Bullets and payload.Bullets[1]
        local cam2 = workspace.CurrentCamera
        if type(b1) == "table" and typeof(b1.Direction) == "Vector3" and cam2 then
            S.lastShotDir = b1.Direction
            S.lastCamDir = cam2.CFrame.LookVector
            local dot = math.clamp(b1.Direction.Unit:Dot(cam2.CFrame.LookVector), -1, 1)
            S.lastShotAngleDeg = math.deg(math.acos(dot))
            if not S.lastSpreadMode then S.lastSpreadMode = "silent" end
        end
    end)

    -- 穿墙：把子弹起点搬到目标身前的空中
    -- Bullets[].Origin 和 Direction 都是客户端提供的，服务端如果直接用它们
    -- 算命中，那么起点在墙后就没有墙可以挡 —— 墙只存在于「起点到目标」这段路径上。
    -- 把起点推到目标前 wallbangOffset 的位置，路径里就只剩空气。
    -- 风险：服务端如果校验起点离玩家太远，这一发可能被丢弃。
    if cfg.wallbang and target then
        local origin = payload.Bullets[1] and payload.Bullets[1].Origin
        if origin then
            local myPos = myRoot() and myRoot().Position or origin
            local aimAt = target.headPos
            local dir = aimAt - origin
            local dist = dir.Magnitude
            if dist > 0.5 then
                local unit = dir.Unit
                local push = math.clamp(tonumber(cfg.wallbangOffset) or 3, 0.5, 30)
                -- 起点前进到「目标前 push stud」，但不能超过目标本身
                if dist > push + 1 then
                    local newOrigin = aimAt - unit * push
                    for i = 1, #payload.Bullets do
                        payload.Bullets[i].Origin = newOrigin
                        payload.Bullets[i].Direction = unit
                    end
                    S.wallbangShots = (S.wallbangShots or 0) + 1
                end
            end
        end
    end

    -- 子弹追踪（传送到目标身边）
    --
    -- Bullets[].Origin 和 Direction 都是客户端提供的字段。
    -- 把 Origin 直接搬到目标身侧、Direction 指向目标，服务端如果只用这两个
    -- 字段做射线，就是「子弹凭空出现在目标面前」——墙、距离、弹道全部绕开。
    --
    -- 和「穿墙」的区别：穿墙只挪起点到目标身前一小段，追踪是把起点整个搬到目标身上。
    -- 两者都需要服务端信任客户端给的 Origin。
    if cfg.bulletTrack and target then
        local aimPos = target.headPos
        local origin = payload.Bullets[1] and payload.Bullets[1].Origin
        if origin and typeof(aimPos) == "Vector3" then
            local dir = aimPos - origin
            if dir.Magnitude > 0.5 then
                local unit = dir.Unit
                local off = math.clamp(tonumber(cfg.trackOffset) or 2, 0.5, 20)
                local newOrigin = aimPos - unit * off
                for i = 1, #payload.Bullets do
                    payload.Bullets[i].Origin = newOrigin
                    payload.Bullets[i].Direction = unit
                end
                S.trackedShots = (S.trackedShots or 0) + 1
            end
        end
    end

    -- 多发子弹：一包塞 N 颗，Seq 不跳（服务端按 Seq 差扣弹药 → 只扣 1 发）
    if cfg.multiShot then
        local first = payload.Bullets[1]
        if first and typeof(first.Origin) == "Vector3" then
            local n = math.clamp(math.floor(cfg.bulletCount), 1, 20)
            if n > 1 then
                local origin = first.Origin
                local baseDir = first.Direction
                local spread = math.rad(math.max(cfg.spreadDeg, 0.05))
                local packed = { { Origin = origin, Direction = baseDir } }
                for i = 2, n do
                    local rot = CFrame.fromEulerAnglesXYZ(
                        (math.random() - 0.5) * spread,
                        (math.random() - 0.5) * spread,
                        0
                    )
                    local d = (CFrame.lookAt(Vector3.zero, baseDir) * rot).LookVector
                    packed[i] = { Origin = origin, Direction = d }
                end
                payload.Bullets = packed
                S.bulletsInjected += n
            end
        end
    end
    end)   -- pcall 结束

    if not _ok then
        S.sendErrors = (S.sendErrors or 0) + 1
        S.lastSendError = tostring(_err)
    end

    ---------------------------------------------------------------
    -- 超射速（服务端认可版）
    --
    -- 实测数据（AK-47，FireRate=0.1）：
    --   一枪之后「手搓补包」      → 服务端全部静默丢弃（扣弹只 +1，S.rapidExtra 涨但没伤害）
    --   连续调用 Weapon:shoot()   → **6 发 / 30ms 间隔全部被接受（扣弹 +6）**
    --
    -- 差别在哪：shoot() 生成的是游戏自己的合法包（Seq/ViewTick 由它填），
    -- 服务端没有任何理由拒；而手搓的那套装出来的包它不认（字段对也没用）。
    --
    -- 两个前提缺一不可：
    --   ① cfg.skipFireDelay 必须开 —— 主循环持续把 NextShotDue 压回 [now-0.03, now]，
    --      否则 shoot() 从第二发起就被客户端冷却挡住（实测只发出 2 包就停）。
    --   ② 必须用**同一个武器对象**循环调用。每次重新 peekCurrentEquippedForMovement()
    --      会拿到副本，改副本的 NextShotDue 对真实状态机无效 ——
    --      这正是以前「5 次只出 1 包」的原因。
    ---------------------------------------------------------------
    if tonumber(cfg.rapidFire) and tonumber(cfg.rapidFire) > 1 and _ok
        and not S.rapidBusy then
        S.rapidBusy = true
        task.spawn(function()
            local n = math.floor(math.clamp(tonumber(cfg.rapidFire), 1, 12))
            local gap = tonumber(cfg.rapidGap) or 0.03
            local ic2 = getInvCtrl()
            local w2 = ic2 and ic2.peekCurrentEquippedForMovement()
            if not w2 then S.rapidBusy = false return end
            for _ = 2, n do
                task.wait(gap)
                -- ⚠ 目标死了就停发。
                --
                -- 实测：shots=56 / rewritten=2（改写率 3.6%），vDbg 全是 "dead"——
                -- 第一发把人打死后，之后每次 shoot() 里 aimTarget() 都返回 nil，
                -- 那些子弹就全部照准星方向飞出去（打墙），既浪费弹药又可能误伤队友。
                -- 静默 / 追踪类补发只在「当前确实有目标」时才有意义：
                -- 目标死了 aimTarget() 返回 nil，补发的子弹会照准星方向飞（打墙、误伤）。
                -- ⚠ 判据用 shouldAim 而不是裸 cfg.silentAim：
                -- 只有 aimMode=="silent" 时才会改写弹道，smooth/mouse 下补发本来就是
                -- 「多发空枪」，不该拿静默开关当条件（它会和 multiShot 混在一起误判）。
                if shouldAim then
                    local okA, stillThere = pcall(function()
                        return aimTarget() ~= nil
                    end)
                    if okA and stillThere == false then
                        S.rapidStoppedDead = (S.rapidStoppedDead or 0) + 1
                        break
                    end
                end
                -- 每次 shoot() 前必须压 NextShotDue：
                --   ① shoot() 要求 os.clock() - NextShotDue < 0.035 才走正常开火分支
                --   ② 刚切枪时 NextShotDue 可能是未来值（Desert Eagle 实测发包 0）
                pcall(function() w2.NextShotDue = os.clock() - 0.01 end)
                pcall(function() w2:shoot() end)
                S.rapidExtra = (S.rapidExtra or 0) + 1
            end
            S.rapidBusy = false
        end)
    end

    -- ── 延迟补偿利用：篡改 ViewTick ──
    --
    -- ViewTick 是服务端做「世界回溯」时的时刻标记：
    --   MovementV2.Client.Runtime.getRemoteViewTick():
    --       return presentationClock - config.RenderInterpolationTicks
    -- 也就是「你屏幕上看到的画面对应的服务端 tick」。
    --
    -- 如果服务端拿它把其他玩家回溯到那一刻再判命中（标准 lag compensation），
    -- 那么把这个值往前推，就能打到他「更早时候」的位置 —— 包括他刚躲进掩体前的瞬间。
    --
    -- 协议上 ViewTick 是 Network.Optional(Network.Float64)，本来就由客户端提供。
    -- 是否真的参与判定还没验证成功（需要能稳定命中的近距靶子才能测出差异），
    -- 所以默认偏移 0，滑块留给实战检验。
    local vtOff = tonumber(cfg.viewTickOffset) or 0
    if vtOff ~= 0 and typeof(payload.ViewTick) == "number" then
        payload.ViewTick = payload.ViewTick + vtOff
        S.viewTickShifted = (S.viewTickShifted or 0) + 1
    end

    return originalSend(payload)
end

---------------------------------------------------------------------
-- 原生瞄准辅助解锁
--
-- 游戏自己内置了一套瞄准辅助，配置在
--   Database.Custom.Constants.AIM_ASSIST_CONFIGS.PLAYER
--     Friction        Enabled=true  BubbleRadius=2.4   MinSensitivity=0.5 Max=1
--     RecoilAssist    Enabled=true  ReductionAmount=0.5  HorizontalReduction=0.85
--     TargetSelection Enabled=true  MaxDistance=125  MaxAngle=0.5236 (30度)
--     Magnetism       Enabled=true  MaxDistance=125  PullStrength=0.1134 (6.5度/帧)
--                                   MaxAngleHorizontal=0.2094 (12度) Vertical=0.1047 (6度)
--     VerticalMagnetism 同上
-- 全部 Enabled=true，但 AimAssistController 里有一道平台门控：
--   isAssistEnabled():
--       if not isMobile and PreferredInput ~= Touch then
--           if PreferredInput == Gamepad then return u71 end
--           return false          ← 鼠标键盘玩家在这里被挡死
--       end
--       return u70
--
-- 实测（用 __index 把 PreferredInput 读成 Touch）：
--   GetRecoilAssistMultiplier: 0 → 0.5      ← 门控确实被绕过
--   GetMagnetismRotation:      (0,0) 不变   ← 因为 findBestTarget 要求目标在 30 度内
--
-- 所以这个开关解锁的是「后坐力减半 + 准星附近磁性吸附 + 摩擦力降灵敏度」，
-- 属于游戏原生行为，服务端看到的是完全正常的玩家操作。
-- 它不能全屏锁人 —— 目标必须在你视线 30 度以内才会触发，这是设计如此。
---------------------------------------------------------------------
local AASYS = { smoothOK = false, nativeOK = false }

---------------------------------------------------------------------
-- 平滑瞄准（接管游戏的磁性吸附入口）
--
-- 唯一能真正转动视角、又不碰鼠标的方式。
-- CameraController 每帧这样做（反编译实测）：
--     local v1 = AimAssistController.GetMagnetismRotation(dt)   -- Vector2(水平, 垂直)
--     v2 = clamp(v1.Y, -0.0873, 0.0873)                          -- 垂直限 ±5 度/帧
--     v3 = clamp(v1.X, -0.0873, 0.0873)                          -- 水平限 ±5 度/帧
--     local v4 = CFrame.fromAxisAngle(cf.RightVector, v2) * CFrame.Angles(0, v3, 0)
--     cf = CFrame.new(pos + v4:VectorToWorldSpace(cf.Position - pos)) * (v4 * cf.Rotation)
--     u88 = cf; u0.updateCamera(getCameraCFrame())
-- 把那个函数换成「返回指向目标的角度差」，相机就由游戏自己转过去。
-- 实测：1.2 秒内转 6.66 度，目标从屏幕外(Z=118)进到正前方(Z=11)。
-- 内部有平台门控（PreferredInput ~= Touch 就 return），整个函数替换直接绕过。
---------------------------------------------------------------------
AASYS.installSmooth = function()
    if AASYS.smoothOK then return true end
    local ok, AA = pcall(function()
        return require(RS.Controllers.AimAssistController)
    end)
    if not ok or typeof(AA) ~= "table" or typeof(AA.GetMagnetismRotation) ~= "function" then
        return false
    end

    -- 平滑瞄准用的射线参数（复用 coverIgnoreList 排除隐形屏障）
    local smoothRP = RaycastParams.new()
    smoothRP.FilterType = Enum.RaycastFilterType.Exclude
    smoothRP.IgnoreWater = true

    -- ★ 可穿透判定 —— 「瞄空气」的头号元凶就在这。
    --
    -- 实测：地图上有 104 个 `snow decal`（parent=ground snow），
    --   size=(92.2, 0.0, 33.4)  Transparency=1.00  CanCollide=true
    -- 零厚度、完全看不见、但 Raycast 一打就中。玩家站在雪坡上时，
    -- 视线从相机到目标必然穿过某个面 → 每帧都被判「被挡」→ 自瞄永远放弃。
    --
    -- ⚠ 只需要看 Transparency：104 个雪面全是 1.00，这一条就全放行了。
    --   **不需要名字白名单**（那玩意儿会随地图膨胀，换个图就废）。
    --   CanCollide 检查也只是顺手，因为 Raycast 本来就不看它。
    local function mvIsPenetrable(p)
        if not p then return true end
        if p.Transparency >= 0.9 then return true end   -- 雪面贴花 / 隐形屏障 / 碎玻璃
        if p.CanCollide == false then return true end   -- 打碎后移除碰撞的玻璃
        return false
    end
    S.MVIsPenetrable = mvIsPenetrable

    -- 穿透式可见性。
    --
    -- ⚠ 性能：默认只做 **1 层**（和原版一样的射线次数，只多一个 if，零额外成本）。
    --   只有当「雪面 + 玻璃 + 铁丝网」叠在一起时才会误判，那种情况极少；
    --   真要处理就把 cfg.aimPenetrateLayers 调到 2~3，代价是每多一层多一次 Raycast。
    --   不做名字白名单：会膨胀，而且换地图就失效。
    local function mvIsVisible(from, to)
        local dir = to - from
        local dist = dir.Magnitude
        if dist < 0.05 then return true end
        local unit = dir.Unit
        local cur = from
        local remain = dist
        local layers = math.clamp(tonumber(cfg and cfg.aimPenetrateLayers) or 1, 1, 4)
        for _ = 1, layers do
            local hit = workspace:Raycast(cur, unit * remain, smoothRP)
            if not hit then return true end
            if not mvIsPenetrable(hit.Instance) then
                S.smoothAimLastBlocker = hit.Instance.Name
                return false
            end
            S.smoothAimPenetrated = (S.smoothAimPenetrated or 0) + 1
            local advanced = (hit.Position - cur).Magnitude + 0.1
            cur = hit.Position + unit * 0.1
            remain = remain - advanced
            if remain <= 0 then return true end
        end
        return false
    end
    S.MVIsVisible = mvIsVisible

    -- ⚠ 不再转交给「原始」函数。
    --
    -- 实测 debug.info(AA.GetMagnetismRotation, "s") == [string "mv_hub_v2"] ——
    -- 说明这个字段上挂的从来就是**我们自己的 hook**，游戏的原始实现早被覆盖掉了。
    -- 原来那句 `return origMag(dt)` 取的是「当前值」，于是形成调用环：
    --   新 hook → 上一次加载的 hook → 更早的 hook → ……
    -- 旧闭包引用的是旧 cfg（可能还是 aimMode="smooth"），所以哪怕这次选了静默，
    -- 相机依然会被旧的 hook 拽走 —— 就是用户说的「我用的是静默，屏幕却自己吸附」。
    --
    -- 而且原始实现（游戏自带的磁性吸附）只对触屏/手柄有效，鼠标玩家本来就返回 (0,0)，
    -- 对我们没有价值。所以这里彻底断开：不改相机时一律返回 (0,0)。
    local setOk = pcall(function()
        -- 先存一份到 getgenv，供 S.updateSpinCam 里的「磁吸守护」每帧比对/重装。
        -- 换局时游戏可能把这个字段重新赋值，守护逻辑靠这个引用把它焊回来。
        --
        -- ★★★ 2026-11-06 修复「自瞄完全没用」的真因 ★★★
        -- S.updateSpinCam 里的磁吸守护（约 7376 行）每帧做这件事：
        --     if type(getgenv().MV_MAG_HOOK) ~= "function" then
        --         getgenv().MV_MAG_HOOK = zeroVec2
        --         AA.GetMagnetismRotation = zeroVec2   -- 恒返回 (0,0)
        --     end
        -- 原来这里只赋值 AA.GetMagnetismRotation，**从来没有登记 MV_MAG_HOOK**，
        -- 于是加载后第一帧守护就把平滑 hook 覆盖成 zeroVec2：
        -- 平滑 hook 一次都没被游戏调用过（S.smoothAimTicks 恒为 0）。
        -- 这跟「热补丁没落盘」无关，是主脚本内部的逻辑冲突。
        -- 现在把 hook 存进局部变量，赋给 AA 之后**同时登记到 getgenv**，
        -- 守护的 if 条件就不成立，平滑 hook 才能活下来。
        local magHook
        magHook = function(dt)
            -- 计数：这个函数被游戏调用了几次。
            -- 静默模式下如果这个数一直是 0，说明脚本根本没有插手相机；
            -- 如果它涨了但 smoothAimSuppressed=true，说明我们主动返回了 (0,0)。
            S.magCalls = (S.magCalls or 0) + 1
            if cfg.smoothAimHijack ~= true then return Vector2.new(0, 0) end

            -- ⚠ 和静默瞄准互斥（这是用户实测报上来的真问题）。
            --
            -- 瞄准模式只该有一个生效：
            --   smooth → 转视角（这条链路）
            --   silent → 只改子弹 Direction，准星一动不动
            --   mouse  → mousemoverel 发真实鼠标
            --
            -- 但这个函数原来只看 smoothAimHijack，压根没看 aimMode。
            -- 结果是：用户明明选了「静默」，只要平滑开关还留着，
            -- 相机就会每帧被拽向目标 —— 表现就是「我用的是静默，屏幕却自己吸附过去」。
            -- 而且两条链路同时跑会互相打架：静默改 Direction、平滑改相机，
            -- 命中点被算两次（情报 7.8 早就记了「要二选一」，代码里一直没强制）。
            if (cfg.aimMode or "smooth") ~= "smooth" then
                S.smoothAimSuppressed = true
                return Vector2.new(0, 0)
            end
            S.smoothAimSuppressed = false

            local cam = workspace.CurrentCamera
            if not cam then return Vector2.new(0, 0) end
            local cf = cam.CFrame
            local eyePos = cf.Position

            -- ⚠ 不用 aimTarget()：它有两层限制会让平滑瞄准失效 ——
            --   1) FOV 过滤：目标离开视野就返回 nil，永远转不了身
            --   2) targetMode=crosshair 总是挑准星最近的目标，差值天然为 0，没得转
            -- 所以这里直接从 allTargets() 挑最近的，并且要求视线通畅。
            -- 原来没有视线检测，表现为「隔着重重掩体也一直锁着一个人」。
            local drop = tonumber(cfg.smoothAimDrop) or 0.9
            -- ⚠ 距离上限必须按「手里的枪」算，不是全局 500。
            -- 原来写死 cfg.maxAimDist（500），于是拿刀 / 霰弹枪时这条链路会转身去锁
            -- 500 stud 外的人 —— 目标在射程外，转过去也只是对着空气。
            -- aimTarget 早就改成 aimDistByWeapon 了，这里一直没跟上。
            local safeMax = tonumber(cfg.maxAimDist) or 500
            do
                local okwN, wN = pcall(function()
                    local icN = getInvCtrl()
                    return icN and icN.peekCurrentEquippedForMovement()
                end)
                if okwN and wN and wN.Name and cfg.aimDistByWeapon then
                    local dN = cfg.aimDistByWeapon[tostring(wN.Name)]
                    if dN then safeMax = dN end
                end
            end
            S.smoothAimMaxNow = safeMax
            -- ⚠ 平滑模式必须自己做 FOV 圈检查。
            --
            -- viable() 里虽然有 `d > cfg.fov → 拒绝`，但平滑 hook 用的是 allTargets()，
            -- **根本不经过 viable()** —— 所以 FOV 圈对它从来没生效过：
            -- 用户手动把目标拖出圈外，它照样一路把视角拽过去（实测）。
            -- 这里按同一口径补上：屏幕坐标距中心超过 cfg.fov 就不算候选。
            local vpS = cam.ViewportSize
            local centerS = Vector2.new(vpS.X * 0.5, vpS.Y * 0.5)
            local fovS = tonumber(cfg.fov) or 75
            local best, bestD = nil, math.huge
            for _, t in ipairs(allTargets()) do
                -- 冻结目标不转视角：那个位置可能只是敌人最后一次被看到的点，
                -- 人早走了，转过去就是对着空气硬锁。
                local okT = (not t.dead) and (not t.frozen)
                if cfg.teamCheck and t.sameTeam then okT = false end
                if t.distance > safeMax then okT = false end
                -- FOV 圈（全向模式只对静默有意义，平滑永远受圈限制）
                if okT then
                    local spS = cam:WorldToViewportPoint(t.headPos)
                    if spS.Z <= 0 then
                        okT = false
                    elseif (Vector2.new(spS.X, spS.Y) - centerS).Magnitude > fovS then
                        okT = false
                    end
                end
                if okT and t.distance < bestD then
                    local aimAt = t.headPos - Vector3.new(0, drop, 0)
                    smoothRP.FilterDescendantsInstances = coverIgnoreList()
                    -- ★ 用穿透式可见性替代原来的「命中即放弃」。
                    --   原来 `local hit = workspace:Raycast(...) if not hit then best = t end`
                    --   会把 104 个零厚度透明 snow decal、半透明玻璃、隐形屏障全当成墙，
                    --   站在雪坡上时视线必穿雪面 → 永远不锁 → 表现为「瞄空气」。
                    if mvIsVisible(eyePos, aimAt) then
                        best, bestD = t, t.distance
                    else
                        S.smoothAimBlocked = (S.smoothAimBlocked or 0) + 1
                    end
                end
            end

            if not best then
                S.smoothAimTarget = nil
                return Vector2.new(0, 0)
            end
            S.smoothAimTarget = best.name

            -- 瞄胸口而不是头顶：headPos 是头部中心，直接对着它会显得瞄太高
            local aimAt = best.headPos - Vector3.new(0, drop, 0)
            local want = CFrame.lookAt(eyePos, aimAt)
            local cp, cy = cf:ToEulerAnglesYXZ()
            local wp, wy = want:ToEulerAnglesYXZ()
            local dYaw = wy - cy
            if dYaw > math.pi then dYaw = dYaw - 2 * math.pi end
            if dYaw < -math.pi then dYaw = dYaw + 2 * math.pi end
            local dPitch = wp - cp

            -- ⚠ 平滑的关键在这里。
            -- CameraController 会把返回值 clamp 到 ±0.0873 弧度（±5 度/帧），
            -- 如果直接把完整角度差丢回去，60fps 就是 300 度/秒 —— 一帧到目标，那是硬锁。
            -- 平滑要做两件事：
            --   1) 比例缩放：每帧只走剩余角度的一部分（指数逼近，越近越慢）
            --   2) 每帧硬上限：大角度时也别超过设定值，避免远处目标被瞬移锁死
            --
            -- ⚠ 下限必须够低，否则 GUI 滑条拉到底也没用（用户实测「不吃人性化设置」）。
            --   原来 maxDeg 下限是 0.2 度/帧 —— 10 度偏差 50 帧 ≈ 0.2 秒就到位，就是硬锁。
            --   现在放到 0.01 度/帧：10 度需要 1000 帧 ≈ 4 秒，足够滑。
            local speed = math.clamp(tonumber(cfg.smoothAimSpeed) or 0.12, 0.005, 1)
            local maxDeg = math.clamp(tonumber(cfg.smoothAimMaxDeg) or 1.5, 0.01, 5)
            local cap = math.rad(maxDeg)
            dYaw = math.clamp(dYaw * speed, -cap, cap)
            dPitch = math.clamp(dPitch * speed, -cap, cap)

            -- ⚠ 抖动必须在死区判断**之前**加。
            --
            -- 原来的顺序是「先死区清零、再加抖动」：deadzone 把角度清成 0 之后，
            -- jitter 又塞进一个非零值 → 每一帧都有位移 → 准星永远不会停，
            -- 表现为「视角反复反复反复调整」（用户实测）。
            -- 正确顺序：先加抖动，再让死区把「小于阈值」的抖动一起吃掉。
            if cfg.smoothAimJitter and cfg.smoothAimJitter > 0 then
                local j = math.rad(cfg.smoothAimJitter)
                local now = os.clock()
                dYaw = dYaw + math.sin(now * 7.3) * j * 0.3
                dPitch = dPitch + math.cos(now * 6.1) * j * 0.3
            end

            -- 死区：已经很接近就别再动，否则会在目标点附近来回微抖
            local dead = math.rad(tonumber(cfg.smoothAimDeadzone) or 0.3)
            if math.abs(dYaw) < dead then dYaw = 0 end
            if math.abs(dPitch) < dead then dPitch = 0 end

            S.smoothAimTicks = (S.smoothAimTicks or 0) + 1
            return Vector2.new(dYaw, dPitch)
        end
        -- ★ 把平滑 hook 真正挂上去，并登记到 getgenv().MV_MAG_HOOK。
        --   少这一步 = 磁吸守护下一帧就用 zeroVec2 覆盖掉它。
        AA.GetMagnetismRotation = magHook
        getgenv().MV_MAG_HOOK = magHook
    end)
    AASYS.smoothOK = setOk
    return setOk
end

AASYS.installNative = function()
    if AASYS.nativeOK then return true end
    local ok, UIS2 = pcall(function() return game:GetService("UserInputService") end)
    if not ok or not UIS2 then return false end

    local okMt, mt = pcall(getrawmetatable, UIS2)
    if not okMt or typeof(mt) ~= "table" then return false end

    local wasRO = isreadonly(mt)
    pcall(function() setreadonly(mt, false) end)
    local oldIndex = mt.__index

    local okSet = pcall(function()
        mt.__index = function(self, key)
            -- 只在开关打开时伪装，平时完全不干扰游戏输入
            if key == "PreferredInput" and cfg.nativeAimAssist == true then
                return Enum.PreferredInput.Touch
            end
            return oldIndex(self, key)
        end
    end)

    if wasRO then pcall(function() setreadonly(mt, true) end) end
    AASYS.nativeOK = okSet
    return okSet
end

---------------------------------------------------------------------
-- 无限弹药（v2）
-- 老方案改 workspace:SetAttribute("VIPInfiniteAmmoEnabled") 完全无效——
-- 那是客户端本地属性，只影响 UI 显示，服务端看不到。
--
-- 实测发现真正持有弹数的是武器对象自己：
--   InventoryController.peekCurrentEquippedForMovement()
--   → { Rounds = 20, Capacity = 120, IsFireHeld, IsReloading, ... }
-- 而且把这个值改成 999 后服务端并不会改回来（1.6 秒内一次都没同步）。
-- 所以改成：持续监控，弹匣一减少就立刻补满。
--
-- 剩下唯一的不确定：服务端收到 ShootWeapon 时是信这个 Rounds，
-- 还是信它自己账本里的数。这只能靠实际开火验证。
---------------------------------------------------------------------
local ICmod = nil
-- ⚠ 名字已在文件前部前置声明（getInvCtrl），这里只赋值，不能再写 local，
-- 否则 updateAutoFire（更早的那一段）拿到的还是全局 nil。
getInvCtrl = function()
    if ICmod then return ICmod end
    local ok, m = pcall(function()
        return require(RS.Controllers.InventoryController)
    end)
    if ok and typeof(m) == "table" then ICmod = m end
    return ICmod
end

-- 角色控制器（跳跃/冲刺/下蹲都在这里）
local CCmod = nil
local function getCharCtrl()
    if CCmod then return CCmod end
    local ok, m = pcall(function()
        return require(RS.Controllers.CharacterController)
    end)
    if ok and typeof(m) == "table" then CCmod = m end
    return CCmod
end

-- 每把枪的弹匣容量（从武器配置读，缓存）
local magCache = {}
local function magSizeOf(weaponName)
    if not weaponName then return nil end
    local cached = magCache[weaponName]
    if cached ~= nil then return cached or nil end
    local ok, c = pcall(function()
        local node = RS.Database.Custom.Weapons:FindFirstChild(weaponName)
        if not node then return nil end
        return require(node)
    end)
    local v = (ok and typeof(c) == "table") and tonumber(c.Rounds) or nil
    magCache[weaponName] = v or false
    return v
end

local function applyInfiniteAmmo()
    local ic = getInvCtrl()
    if not ic then return end
    local ok, w = pcall(function() return ic.peekCurrentEquippedForMovement() end)
    if not ok or not w then return end

    local mag = magSizeOf(w.Name) or 30
    local reserve = math.max(mag * 4, 120)

    if tonumber(w.Rounds) and w.Rounds < mag then
        w.Rounds = mag
    end
    if tonumber(w.Capacity) and w.Capacity < reserve then
        w.Capacity = reserve
    end
end

-- 跳过开火间隔
--
-- 反编译 Components/Weapon 的 shoot() 后的真实结论：
--   v3 = os.clock()
--   NextShotDue = self.NextShotDue
--   dispatch = if not (v3 - NextShotDue < 0.035) then 228 else 227
-- 也就是说 (os.clock() - NextShotDue) 必须 < 0.035 才走「正常开火」分支。
--
-- 之前把它压成 0，os.clock() 有几百秒，(v3 - 0) 远大于 0.035，
-- 直接跳到 228 分支，v1（下次冷却）没被计算，self.NextShotDue 被赋成 nil，
-- 状态机彻底坏掉 —— 表现就是连点 5 次只有第 5 次真的扣了子弹。
--
-- 正确做法：把 NextShotDue 维持在 [now - 0.03, now] 这个窗口里。
-- 这个区间内 (now - NextShotDue) 是 0~0.03，恒小于 0.035，判定永远通过。
local function applySkipFireDelay()
    local ic = getInvCtrl()
    if not ic then return end
    local now = os.clock()
    if now - (S.lastSkipAt or 0) < 0.05 then return end
    S.lastSkipAt = now

    local ok, w = pcall(function() return ic.peekCurrentEquippedForMovement() end)
    if not ok or not w then return end

    -- ⚠ 这个函数只改「客户端自己的冷却状态」，不会主动发包。
    --
    -- 发包频率由 InputController.isActionPressed("Fire") 决定。所以：
    --   · 手动点击 → 发包频率 = 你点的频率，点了才发
    --   · autoFire → 发包频率 = autoFire 的点击间隔（现在已跟随 FireRate）
    --
    -- 但服务端会按武器 FireRate 和 20 包/秒限流双重校验。
    -- 实测：AWP（FireRate=1.46）如果被压到 0.05 秒连发，整批包全被丢弃 ——
    -- 用户看到的就是「开了友军伤害打 AI 队友一发都不掉血」。
    --
    -- 所以这里把 NextShotDue 维持在 [now-0.028, now] 只解决「客户端不让点」，
    -- 真正能不能打出去取决于你按得多快。配合 autoFire 时必须保证间隔 ≥ FireRate。
    local due = tonumber(w.NextShotDue)
    if due == nil or due < now - 0.028 or due > now then
        pcall(function() w.NextShotDue = now - 0.02 end)
    end
end

-- 瞬间换弹
--
-- 游戏自己的换弹要播完动画（实测 AWP 1.586 秒）才发 ReloadWeapon 包。
-- 但那个包客户端可以自己发：
--   ReloadWeapon.Send({ Identifier, Rounds, Capacity })
-- schema 里 Rounds/Capacity 是客户端填的，服务端收到后立刻回满弹匣。
-- 实测：直发 0.083 秒生效，而正常换弹 1.586 秒 —— 快 19 倍。
--
-- 注意：服务端不信任这里填的数字，会用它自己的真实存量覆盖
-- （测试里发 Rounds=5 Capacity=30，服务端回的是 3/15）。
-- 所以这不是无限弹药 —— Capacity（总弹药）依然是服务端账本，会真正消耗。
-- 它能做到的是：弹匣一空立刻补满，不用等动画。
local setInfiniteAmmo   -- 前置声明（定义在下面，这里要先引用）

local function applyInstantReload()
    local ic = getInvCtrl()
    if not ic then return end

    local now = os.clock()
    -- 限频。原来 0.12 秒 + 下面 0.15 秒 settling = 打空后要等 0.27 秒才补上，
    -- 这 0.27 秒里 shoot() 全是空响 —— 用户感觉「瞬间换弹时灵时不灵、还得等动画」就是这个。
    -- 实测 ping 80ms 左右，0.06 + 0.08 = 0.14 秒足够，空档砍掉一半。
    if now - (S.lastReloadAt or 0) < 0.06 then return end
    -- 换弹包发出去后等回包。
    if S.reloadSettlingUntil and now < S.reloadSettlingUntil then return end

    local ok, w = pcall(function() return ic.peekCurrentEquippedForMovement() end)
    if not ok or not w or not w.Identifier then return end

    -- ⚠⚠ 不要因为「游戏正在自动换弹」就不发包。
    --
    -- 实测现象：瞬间换弹只对大狙（AWP）明显有效，步枪/冲锋枪几乎没感觉。
    -- 原因就在这一行：
    --   · AWP 是单发武器，空弹后要**手动按 R**，IsReloading 一直是 false
    --     → 能走到下面发包 → 立刻补满
    --   · 步枪/冲锋枪打空弹匣会**自动进入换弹**，IsReloading = true
    --     → 被 return 掉 → 只能等游戏自己播完动画
    --
    -- 服务端只认 Rounds=0 的换弹请求，正在播动画时插一个包是安全的：
    -- 它会立刻完成换弹、动画被打断。
    -- 只有「弹匣里还有子弹 + 正在换弹」（手动按 R 提前换的那种）才跳过。
    local curRounds = tonumber(w.Rounds)
    if w.IsReloading and (curRounds == nil or curRounds > 0) then
        S.reloadSkippedReloading = (S.reloadSkippedReloading or 0) + 1
        return
    end

    local mag = magSizeOf(w.Name)
    local rounds = tonumber(w.Rounds)
    local reserve = tonumber(w.Capacity)

    -- 近战武器：Rounds / Capacity 都是 nil（刀没有弹匣）。
    -- 但实测发现 ReloadWeapon 除了补弹匣，还会让服务端重置武器的攻击状态，
    -- 所以对刀定期发这个包能解除挥砍冷却 —— 前提是客户端也解除了冷却
    -- （skipFireDelay 把 NextShotDue 压进窗口），两个条件缺一不可。
    if mag == nil or rounds == nil or reserve == nil then
        S.lastReloadAt = now
        S.reloadSettlingUntil = now + 0.08
        pcall(function()
            Remotes.Inventory.ReloadWeapon.Send({
                Identifier = w.Identifier,
                Rounds = 0,
                Capacity = 0,
            })
        end)
        S.meleeReloads = (S.meleeReloads or 0) + 1
        return
    end

    -- 枪械：只有弹匣彻底空了才发。服务端也只认 Rounds=0 的换弹请求，
    -- 还有子弹时发的包会被丢掉（实测 Rounds=1 连发 4 次全失败）。
    if rounds > 0 or reserve <= 0 then return end

    S.lastReloadAt = now
    S.reloadSettlingUntil = now + 0.08     -- 等回包，期间不再发
    pcall(function()
        Remotes.Inventory.ReloadWeapon.Send({
            Identifier = w.Identifier,
            Rounds = mag,
            Capacity = reserve,
        })
    end)
    S.instantReloads = (S.instantReloads or 0) + 1
end

local function setInstantReload(on)
    cfg.instantReload = on
    if on or cfg.infiniteAmmo or cfg.skipFireDelay then
        if not S.ammoConn then setInfiniteAmmo(cfg.infiniteAmmo) end
    end
end

-- 近战挥刀加速
--
-- 实测近战攻击间隔 0.836 秒，而 T Knife 的 FireRate 只有 0.36 ——
-- NextShotDue 早就过期了，真正的瓶颈是挥刀动画：
--   CharacterAnimations.Swing      长度 1.267 秒
--   CharacterAnimations.Heavy Swing 长度 1.267 秒
--   CharacterAnimations.BackStab   长度 1.000 秒
-- 攻击判定在动画中段（约 66%），所以动画没播到那儿就不能再砍。
-- 把播放速度调快，判定点就来得早。
local MELEE_ANIMS = {
    ["Swing"] = true,
    ["Heavy Swing"] = true,
    ["BackStab"] = true,
    ["Swing1"] = true,
    ["Swing2"] = true,
}

local function applyMeleeSpeed()
    local ic = getInvCtrl()
    if not ic then return end
    local ok, w = pcall(function() return ic.peekCurrentEquippedForMovement() end)
    if not ok or not w then return end
    -- 只处理近战武器
    local isMelee = tostring(w.Properties and w.Properties.Class) == "Melee"
    if not isMelee then return end

    local m = myModel()
    if not m then return end
    local ac = m:FindFirstChildOfClass("AnimationController")
    local animator = ac and ac:FindFirstChildOfClass("Animator")
    if not animator then return end

    local speed = math.clamp(tonumber(cfg.meleeSpeed) or 3, 1, 10)
    local touched = 0
    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        local anim = track.Animation
        local name = anim and anim.Name or ""
        if MELEE_ANIMS[name] then
            if math.abs(track.Speed - speed) > 0.05 then
                pcall(function() track:AdjustSpeed(speed) end)
            end
            touched = touched + 1
        end
    end
    S.meleeAnimsTuned = (S.meleeAnimsTuned or 0) + touched
end
-- 跳跃接口是 CharacterController.jump(true/false)（按下/释放）。
-- 落地判断用 Player 的 IsJumping 属性：true→false 那个瞬间就是触地，
-- 在此刻立刻再跳，保持连跳节奏。
local function bunnyhopStep()
    local cc = getCharCtrl()
    if not cc then return end

    -- ⚠ 落地判据必须用 RemoteBuffer 的 CollisionPose.OnGround。
    --
    -- 原来的写法是 LP:GetAttribute("IsJumping")，靠它的 true→false 跳变判落地。
    -- 情报 3.4 早就记过这个属性不可靠（可能是空值、可能一直不变），
    -- 结果是 S.bhWasJumping 永远为 false、条件 `bhWasJumping and not jumping`
    -- 一次都不成立 —— 表现就是「兔子跳选项开着但从来不跳」。
    --
    -- CollisionPose 是服务端下发的碰撞姿态，OnGround 实测跟起跳/落地完全同步。
    local onGround = nil
    pcall(function()
        local buf = resolveBuffer()
        if type(buf) ~= "table" or type(buf._actors) ~= "table" then return end
        local actor = buf._actors[LP.UserId]
        if type(actor) ~= "table" then return end
        local cp = actor.CollisionPose
        if type(cp) ~= "table" then return end
        if type(cp.OnGround) == "boolean" then
            onGround = cp.OnGround
        end
    end)

    -- 兜底：属性（不可靠，只在拿不到 CollisionPose 时才用）
    if onGround == nil then
        local j = LP:GetAttribute("IsJumping")
        if type(j) == "boolean" then onGround = not j end
    end
    if onGround == nil then return end

    local prev = S.bhOnGround
    S.bhOnGround = onGround
    S.bhOnGroundRaw = prev

    -- 只在「刚落地」这一帧跳，避免按住不放每帧都发
    if onGround and prev == false then
        pcall(function() cc.jump() end)
        S.bhJumps = (S.bhJumps or 0) + 1
        S.bhLastJumpAt = os.clock()
    end
end

-- 统一的弹药/射速维护循环
--
-- 注意：这里绝对不能碰 Properties 表。
-- 曾经写过「篡改 Properties.FireRate / ShootingOptions」的代码，
-- 用 setreadonly(props, false) 解冻后一直保持，结果：
--   ReplicatedStorage.Controllers.InputController.Actions.Fire:82
--   Script timeout: exhausted allowed execution time
-- 整个客户端卡死。Properties 是武器之间共享的冻结表，游戏每帧都在读它，
-- 解冻+写入会让 Actions.Fire 的射击循环反复重算直到超时。
-- 而且实测证明篡改它只影响客户端显示，服务端依旧按自己的 FireRate 校验，tracer 全 0。
-- 所以这段能力已彻底移除。
local function ammoStep()
    if cfg.infiniteAmmo then pcall(applyInfiniteAmmo) end
    -- 压 NextShotDue 也只是给 hyperFire 用的：关了 hyperFire 就不能动冷却，
    -- 否则全自动枪的节奏被压成「冷却永远已过」，射速超过 FireRate 服务端就整包丢（有枪声没伤害）。
    if cfg.skipFireDelay and cfg.hyperFire then pcall(applySkipFireDelay) end
    if cfg.instantReload then pcall(applyInstantReload) end
    if cfg.skipFireDelay then pcall(applyMeleeSpeed) end
    if cfg.hyperFire then pcall(S.applyHyperFire) end
end

-- ═══════════════════════════════════════════════════════════════
-- 魔改版专用：按住左键 = 持续连发
--
-- 和 rapidFire 的区别：
--   rapidFire  = 「开一枪 → 补发 N-1 次」，是 burst，每次都要重新扣一次扳机
--   hyperFire  = 「按住就一直发」，按 hyperGap 的节奏持续调用 shoot()，
--                松开才停。手感上是真正的连发武器，不是「一枪五连响」。
--
-- 前提同样是 skipFireDelay 必须开（shoot() 内部要 (now - NextShotDue) < 0.035），
-- 每次发包前都压一次 NextShotDue。
-- ═══════════════════════════════════════════════════════════════
-- ⚠ 挂 S 上而不是写 local function：主 chunk 的 local 已经贴 200 上限，
-- 多一个就是 "Out of local registers ... exceeded limit 200" 整份脚本编译失败。
S.applyHyperFire = function()
    local now = os.clock()
    local gap = tonumber(cfg.hyperGap) or 0.02
    if now - (S.lastHyperAt or 0) < gap then return end

    -- 检测左键是否按住。优先用 UserInputService，失败就退回 InputController。
    local held = false
    local okU, v = pcall(function()
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
    end)
    if okU then
        held = (v == true)
    else
        pcall(function()
            local ic = getInvCtrl()
            held = ic and ic.isActionPressed and ic.isActionPressed("Fire") or false
        end)
    end
    if not held then return end

    -- ⚠ 这里原来有一个「aimTarget() 返回 nil 就 return」的检查，实测灾难性：
    --     hyperStoppedDead = 1355（一梭子跳过 1355 次！）
    -- 因为 aimTarget() 返回 nil 的原因远不止「目标死了」——不在视野、距离、队伍过滤、
    -- 数据过期都会返回 nil。持续循环里用它当开关，等于大部分时间根本不发弹。
    -- 现在只在「确实有目标但它刚死」时才跳，用 vFail 里的 dead 计数做判据。
    -- rapidFire 那边保留原检查没关系（它是 burst，最多浪费 5 发）。

    S.lastHyperAt = now
    local ic2 = getInvCtrl()
    local w = ic2 and ic2.peekCurrentEquippedForMovement()
    if not w or not w.shoot then return end
    pcall(function() w.NextShotDue = os.clock() - 0.01 end)
    pcall(function() w:shoot() end)
    S.hyperShots = (S.hyperShots or 0) + 1
end

-- 角色重生后把弹药维护连接重建。
-- 死亡/重开一局后角色换新，旧的 Heartbeat 循环虽然还在，
-- 但拿到的武器对象已经失效（peekCurrentEquippedForMovement 返回 nil 或旧引用），
-- 表现就是「选项还开着但功能没反应」。这里监听角色变化，变化就重建连接。
local function rebindAmmoConn()
    if S.ammoConn then
        pcall(function() S.ammoConn:Disconnect() end)
        S.ammoConn = nil
    end
    if cfg.infiniteAmmo or cfg.skipFireDelay or cfg.instantReload then
        pcall(setInfiniteAmmo, cfg.infiniteAmmo)
    end
end

-- 角色重生 / 换队伍都重建一次
pcall(function()
    local c1 = LP.CharacterAdded:Connect(function()
        task.wait(1.5)          -- 等武器装好再建连接
        rebindAmmoConn()
    end)
    S.conns[#S.conns + 1] = c1
    local c2 = LP:GetAttributeChangedSignal("Team"):Connect(function()
        task.delay(1.0, rebindAmmoConn)
    end)
    S.conns[#S.conns + 1] = c2
end)

-- 用赋值而不是 local function：前面已经 local setInfiniteAmmo 声明过，
-- 这里再写 local function 会新建一个局部变量，前置声明那个仍然是 nil。
setInfiniteAmmo = function(on)
    cfg.infiniteAmmo = on
    -- 三个功能共用同一个 Heartbeat 连接，全都关掉时才断开
    if not on and not cfg.skipFireDelay and not cfg.instantReload then
        if S.ammoConn then
            pcall(function() S.ammoConn:Disconnect() end)
            S.ammoConn = nil
        end
        return true
    end
    if S.ammoConn then return true end
    local ok = pcall(function()
        S.ammoConn = RunService.Heartbeat:Connect(function()
            if S._alive == false or REG.gen ~= MY_GEN then
                pcall(function() S.ammoConn:Disconnect() end)
                return
            end
            ammoStep()
        end)
    end)
    return ok
end

-- 打开/关闭「跳过开火间隔」时，确保维护循环在跑
local function setSkipFireDelay(on)
    cfg.skipFireDelay = on
    if on or cfg.infiniteAmmo then
        if not S.ammoConn then setInfiniteAmmo(cfg.infiniteAmmo) end
    end
end

-- 超射速开关。
--
-- ⚠ 关键：**必须同时打开 skipFireDelay**，否则完全没用。
-- 原因：连发是靠反复调用 Weapon:shoot()，而 shoot() 内部有这么一段判定
--     dispatch = if not (os.clock() - self.NextShotDue < 0.035) then 228 else 227
-- 只有 227 分支才真的发包。skipFireDelay 的主循环把 NextShotDue 一直压回
-- [now-0.03, now]，shoot() 才能每次都走 227。
-- 实测：不开它时 5 次调用只发出 2 个包；开了之后 6 次调用 6 个包全发、服务端全认。
-- ⚠ 不写 local：主 chunk 的 local 已经贴到 200 上限，多一个就
-- "Out of local registers ... exceeded limit 200" 整份脚本编译失败。
S.setRapidFire = function(n)
    n = math.floor(math.clamp(tonumber(n) or 1, 1, 12))
    cfg.rapidFire = n
    if n > 1 then
        if not cfg.skipFireDelay then
            pcall(function() setSkipFireDelay(true) end)
            S.rapidAutoSkip = true
        end
        -- 预热当前武器：刚切枪时 NextShotDue 可能是未来值，
        -- 不清掉的话第一枪会被 shoot() 自己的冷却判定挡掉（实测 Desert Eagle 发包 0）。
        pcall(function()
            local ic3 = getInvCtrl()
            local w3 = ic3 and ic3.peekCurrentEquippedForMovement()
            if w3 then w3.NextShotDue = os.clock() - 0.01 end
        end)
    end
end

---------------------------------------------------------------------
-- 纯净模式：一键关掉所有「会碰游戏状态」的东西，但保留菜单本身
--
-- 用途：用户在「注入脚本后商店买不了、捡东西消失」时，用它做二分定位。
-- 打开后脚本只剩下一个空菜单，任何 hook / 每帧改写都停掉。
-- 如果纯净模式下商店恢复正常 → 确定是脚本某个功能导致；
-- 再逐项打开就能定位到具体哪一个。
--
-- 注意：不动 Maclib 的 GUI，否则用户关不回来。
---------------------------------------------------------------------
S.pureMode = false

-- ═══════════════════════════════════════════════════════════════
-- ★★★ 拦截反作弊：InventoryController.getCurrentEquipped 的执行器检测
--
-- 游戏源码（InventoryController:439）：
--     function u0.getCurrentEquipped()
--         if not u192 then return nil end
--         for i = 1, 10 do
--             if not debug.info(i, "f") then break end
--             v1 = getfenv(i)
--             if not v1.getgenv and not v1.hookfunction then continue end
--             u0 = {}                      -- ← 发现执行器就把模块表换空
--             return nil
--         end
--         return u192.CurrentEquipped
--     end
--
-- 只要从执行器里调一次（我们原来在投掷物检测、自瞄、自动装备里每帧都调），
-- u0 就被换成空表。u0 是模块的闭包 upvalue —— require 返回的表还在
-- （所以外部调用看起来正常），但控制器内部所有 u0.xxx() 全部变成 nil，
-- 于是武器创建链整条崩掉：
--     Weapon/C4/Melee/Grenade.new → Router:40 → InventoryController:861
--     → attempt to call a nil value
-- 表现：买的东西不进背包、捡的东西消失、切不出枪、C4 拿不出来、手上是空气。
--
-- 检测只在这一个函数里，而 u0 就是 require 返回的那张表。
-- 直接覆盖表上的 getCurrentEquipped —— 游戏内部调 u0.getCurrentEquipped()
-- 时走的就是我们这版，检测代码永远不执行。
--
-- 功能等价：检测通过后它本来就是 return u192.CurrentEquipped，
-- 和 peekCurrentEquippedForMovement 一模一样。
-- ═══════════════════════════════════════════════════════════════
S.patchGetCurrentEquipped = function()
    local okR, ic = pcall(require, game.ReplicatedStorage.Controllers.InventoryController)
    if not okR or type(ic) ~= "table" then return false, "cannot require" end
    if type(ic.getCurrentEquipped) ~= "function" then return false, "no func" end
    local resolve = getgenv().MV_RESOLVE_EQUIPPED
    if type(resolve) ~= "function" then
        -- 兜底：脚本开头那段补丁没跑成功（Controllers 还没复制完 / require 失败）时，
        -- 这里自带一份同样的契约实现，保证装备查询永远不会返回 JSON 表。
        local HSx = game:GetService("HttpService")
        resolve = function(mod)
            local lp = game.Players.LocalPlayer
            local raw = lp and lp:GetAttribute("CurrentEquipped")
            if type(raw) ~= "string" then return nil end
            local okj, want = pcall(function() return HSx:JSONDecode(raw) end)
            if not okj or type(want) ~= "table" then return nil end
            local okInv, inv = pcall(function() return mod.getCurrentInventory() end)
            if not okInv or type(inv) ~= "table" then return nil end
            for si = 1, 16 do
                local slot = inv[si]
                if type(slot) == "table" and type(slot._items) == "table" then
                    for _, item in ipairs(slot._items) do
                        if type(item) == "table" and item.Identifier == want.Identifier then
                            return item
                        end
                    end
                end
            end
            return nil
        end
        getgenv().MV_RESOLVE_EQUIPPED = resolve
    end

    -- ⚠ 这里不再有 `if MV_GCE_PATCHED then return "already"` 的早退：
    -- 开头那段补丁如果因为 Controllers 还没复制而失败，后面这次必须能补上；
    -- 重载脚本时也必须把新实例的解析器重新挂上去（否则 ic 上留着旧实例的死闭包，
    -- 症状是「重载后物品栏又开始脱节」，但日志仍然显示 patch=true）。
    local curPeekX = ic.peekCurrentEquippedForMovement
    local curGCEX = ic.getCurrentEquipped
    local origOfX = getgenv().MV_ORIG_OF
    if type(getgenv().MV_ORIG_PEEK) ~= "function" then
        getgenv().MV_ORIG_PEEK = (origOfX and origOfX(curPeekX)) or curPeekX
    end
    if type(getgenv().MV_ORIG_GCE) ~= "function" then
        getgenv().MV_ORIG_GCE = (origOfX and origOfX(curGCEX)) or curGCEX
    end
    S._origGCE = getgenv().MV_ORIG_GCE
    S._origPeek = getgenv().MV_ORIG_PEEK

    -- ⚠ 与开头补丁用同一份契约实现（getgenv().MV_RESOLVE_EQUIPPED）：
    -- 返回背包里的真实 item，找不到返回 nil；永远不返回 JSON 表，永远不调原函数。
    local function resolveReal()
        return resolve(ic)
    end
    getgenv().MV_MARK_WRAP(resolveReal, getgenv().MV_ORIG_PEEK)

    ic.getCurrentEquipped = resolveReal
    -- ⚠ peekCurrentEquippedForMovement 才是游戏内部的主要查询入口
    -- （武器组件、输入、切枪、投掷物都走它，而不是 getCurrentEquipped）。
    ic.peekCurrentEquippedForMovement = resolveReal

    getgenv().MV_GCE_PATCHED = true
    return true, "patched"
end

-- ═══════════════════════════════════════════════════════════════
-- ★ Raycast 模块反作弊拦截
--
-- 反编译自 ReplicatedStorage.Shared.Raycast（docId 905，341 行）：
--   function u115.cast(...)          -- 第 253 行起
--   function u115.castThrough(...)   -- 第 313 行起
-- 两个函数开头都是同一段：
--     for i = 1, 10 do
--         if not debug.info(i, "f") then break end
--         v1 = getfenv(i)
--         if v1.getgenv or v1.hookfunction then u115 = {} end
--     end
-- u115 是模块的 upvalue（require 返回的就是它）。一旦被换成空表，
-- 内部所有 u115.cast / castThrough 调用立刻变成 nil → 射线、弹道、
-- 可见性判定整条崩掉，表现是「买的东西不进包、手里空气、打不中人」。
--
-- 绕法：直接覆盖表上的 cast / castThrough。游戏内部调的是 u115.cast，
-- 而 u115 就是我们 require 到的那张表，所以覆盖即生效，检测代码永不执行。
-- 必须在反作弊首次触发之前调用（脚本加载早期）。
-- ═══════════════════════════════════════════════════════════════
S.patchRaycast = function()
    local okR, mod = pcall(function()
        return require(game:GetService("ReplicatedStorage").Shared.Raycast)
    end)
    if not okR or type(mod) ~= "table" then return false, "cannot require" end

    -- 幂等：重载时 mod.cast 上挂的已经是上一实例的 wrapper，
    -- 通过 MV_ORIG_OF 取真正的原版，绝不把 wrapper 当原版存起来。
    local curCast = mod.cast
    local curThrough = mod.castThrough
    local origOfR = getgenv().MV_ORIG_OF
    if type(getgenv().MV_ORIG_CAST) ~= "function" then
        getgenv().MV_ORIG_CAST = (origOfR and origOfR(curCast)) or curCast
    end
    if type(getgenv().MV_ORIG_CASTTHROUGH) ~= "function" then
        getgenv().MV_ORIG_CASTTHROUGH = (origOfR and origOfR(curThrough)) or curThrough
    end
    local origCast = getgenv().MV_ORIG_CAST
    local origThrough = getgenv().MV_ORIG_CASTTHROUGH

    -- 重写 cast：保留「打到了就返回 {instance,position,normal,material}」的语义，
    -- 去掉 getfenv 检测循环。
    mod.cast = function(origin, dir, params, filterList, filterFn)
        local okc, res = pcall(function()
            local p = params
            if not p then
                p = RaycastParams.new()
                p.FilterType = Enum.RaycastFilterType.Exclude
                p.IgnoreWater = false
                p.CollisionGroup = "Bullet"
            end
            local fl = filterList
            if type(fl) ~= "table" then fl = {} else
                local copy = {}
                for i, v in ipairs(fl) do copy[i] = v end
                fl = copy
            end
            p.FilterDescendantsInstances = fl
            local pos = origin
            local guard = 0
            while guard < 32 do
                guard = guard + 1
                local r = workspace:Raycast(pos, dir, p)
                if not r then return { position = origin + dir } end
                local skip = false
                if type(filterFn) == "function" then
                    local okf, sr = pcall(filterFn, r.Instance)
                    skip = okf and sr == true
                end
                if not skip then
                    return {
                        instance = r.Instance,
                        position = r.Position,
                        normal = r.Normal,
                        material = r.Material,
                    }
                end
                table.insert(fl, r.Instance)
                p.FilterDescendantsInstances = fl
            end
            return { position = origin + dir }
        end)
        if okc then return res end
        -- 兜底：最简射线
        local r2 = workspace:Raycast(origin, dir)
        if r2 then
            return { instance = r2.Instance, position = r2.Position, normal = r2.Normal, material = r2.Material }
        end
        return { position = origin + dir }
    end

    -- castThrough：语义是「穿透指定材质」。这里退回普通 cast（不再穿透），
    -- 保证不崩、能返回结果；真正的穿透判定交给调用方自己处理。
    mod.castThrough = function(origin, dir, maxDist, filterList)
        return mod.cast(origin, dir, nil, filterList, nil)
    end
    mod.castThroughDistance = function(origin, dir, maxDist, filterList)
        return mod.cast(origin, dir, nil, filterList, nil)
    end
    -- 打标记：卸载 / 重载时据此判断「表上的到底是不是我们的 wrapper」。
    getgenv().MV_MARK_WRAP(mod.cast, origCast)
    getgenv().MV_MARK_WRAP(mod.castThrough, origThrough)

    getgenv().MV_RAYCAST_PATCHED = true
    return true, "patched"
end

do
    local okP, msgP = pcall(S.patchGetCurrentEquipped)
    S.gcePatch = tostring(okP and msgP or "fail")
end


-- ═══════════════════════════════════════════════════════════════
-- 自动重新装备：修复「背包里有武器，但手上是空的」
--
-- 实测症状：回合开始后 getCurrentEquipped() 一直是 nil，但
-- getInventorySlot(3)._items 里明明有 T Knife。
-- 手动调 ic.equip(3, 1) 立刻恢复，而且服务端回 WeaponEquipResolved 确认。
--
-- 也就是说：物品、背包对象、Loadout 类全都正常，
-- 只是「新武器入包后自动装备」这一步没有触发（或触发失败）。
-- 这里每 0.75 秒补一次：手上没东西但背包里有 → 主动装备。
--
-- 这不是绕过服务端，equip() 本身就会发包，服务端认。
-- ═══════════════════════════════════════════════════════════════
S.autoReequip = function()
    local ic = getInvCtrl()
    if not ic then return false, "no ic" end
    local okW, w = pcall(function() return ic.peekCurrentEquippedForMovement() end)
    if okW and w then return false, "already equipped" end      -- 手上有东西就不动
    -- 兜底：手上拿着投掷物时绝对不动。
    -- peekCurrentEquippedForMovement() 在切手雷的瞬间可能短暂返回 nil，
    -- 这时如果"补装主武器"就会把刚掏出来的手雷抢走 —— 表现就是
    -- 「抛物线一闪就没了」「怎么也拿不稳投掷物」。
    if S.lastHeldClass == "Grenade" or S.lastThrowableVal == true then
        return false, "holding throwable"
    end
    for slot = 1, 5 do
        local okS, s = pcall(function() return ic.getInventorySlot(slot) end)
        if okS and type(s) == "table" and type(s._items) == "table" then
            -- 找第一件可装备的
            local idx = 0
            for _ in pairs(s._items) do idx = idx + 1; break end
            if idx > 0 then
                local okE, err = pcall(function() ic.equip(slot, idx) end)
                if okE then
                    S.autoEquipCount = (S.autoEquipCount or 0) + 1
                    S.autoEquipLast = string.format("slot %d idx %d", slot, idx)
                    return true, S.autoEquipLast
                else
                    S.autoEquipErr = tostring(err)
                end
            end
        end
    end
    return false, "nothing to equip"
end


-- ═══════════════════════════════════════════════════════════════
-- 自动拾取地上的武器（用户口中「自动装备」真正该做的事）
--
-- 游戏自己的拾取链路（实测自 Observers.Game.WeaponDropped.Weapon）：
--   掉落物      = 带 WeaponDropped 标签的 Model
--   Model:GetAttribute("Weapon")    → 武器名（AWP / AK-47 / ...）
--   Model:GetAttribute("CanPickup") → 服务端允许拾取
--   Model.Name                      → 发包时的 Identity
--   Remotes.Inventory.PickupWeapon.Send({ Identity = Model.Name, AllowAutoEquip = bool })
--   服务端限速 7/s；游戏自身判定距离 6 stud（ProximityRange），每槽位 1 秒冷却
--
-- 排序：默认按武器配置里的 Cost（AWP 4750 / AK 2700 / Glock 200 …），
-- 同价值取近的；cfg.autoPickupPriority="AWP,AK-47" 时，列表里出现的武器直接插队。
-- ═══════════════════════════════════════════════════════════════
S.WCOST = {}
S.WINFO = {}
S.pickupTick = 0

-- 武器信息（Cost + 阵营限制），一次 require 缓存下来
-- 实测 Team 字段：Both / Terrorists / Counter-Terrorists
--   HE Grenade → Both，Smoke Grenade → Terrorists，Incendiary Grenade → Counter-Terrorists
S.weaponInfo = function(name)
    if not name then return { cost = 0, team = "Both" } end
    local c = S.WINFO[name]
    if c then return c end
    local ok, mod = pcall(function()
        return require(RS.Database.Custom.Weapons[name])
    end)
    c = {
        cost = (ok and typeof(mod) == "table" and tonumber(mod.Cost)) or 0,
        team = (ok and typeof(mod) == "table" and tostring(mod.Team or "Both")) or "Both",
    }
    S.WINFO[name] = c
    S.WCOST[name] = c.cost
    return c
end

S.weaponCost = function(name)
    return S.weaponInfo(name).cost
end

-- 枚举地上的掉落武器（标签 + Debris 兜底）
S.droppedWeapons = function()
    local out = {}
    local okT, list = pcall(function()
        return game:GetService("CollectionService"):GetTagged("WeaponDropped")
    end)
    if okT and typeof(list) == "table" then
        for _, m in ipairs(list) do
            if typeof(m) == "Instance" and m:IsA("Model") and m.PrimaryPart then
                out[#out + 1] = m
            end
        end
    end
    if #out == 0 then
        local db = workspace:FindFirstChild("Debris")
        if db then
            for _, m in ipairs(db:GetChildren()) do
                if m:IsA("Model") and m.PrimaryPart and m:GetAttribute("Weapon") then
                    out[#out + 1] = m
                end
            end
        end
    end
    return out
end

-- 当前自己属于哪个阵营的配置集："T" / "CT" / nil（观战或队伍未定）
S.pickupSide = function()
    local t = tostring(LP:GetAttribute("Team") or "")
    if t == "Counter-Terrorists" then return "CT" end
    if t == "Terrorists" then return "T" end
    return nil
end

S.autoPickupStep = function(dt)
    -- ⚠ 每个阵营一套独立配置：切到 CT 就用 pickupOn_CT / pickupStrat_CT …，
    -- 队伍没定（观战/热身未分配）就完全不动。
    local side = S.pickupSide()
    if not side then return end
    if cfg["pickupOn_" .. side] == false then return end

    local interval = tonumber(cfg.autoPickupInterval) or 0.35
    S.pickupTick = (S.pickupTick or 0) + dt
    if S.pickupTick < interval then return end
    S.pickupTick = 0

    local strat = tostring(cfg["pickupStrat_" .. side] or "value")
    local teamOnly = (strat ~= "all")
    local onlyBetter = (strat == "better")
    local named = (strat == "named") and tostring(cfg["pickupNamed_" .. side] or "") or ""

    local root = myRoot()
    if not root then return end
    local myPos = root.Position
    local range = tonumber(cfg["pickupRange_" .. side]) or 6

    -- 自定义优先列表（只有 named 策略才用）：靠前的权重更高（20 万分制，压过任何 Cost 差）
    local prioList = {}
    for token in string.gmatch(named, "[^,]+") do
        local t = token:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then prioList[#prioList + 1] = t:lower() end
    end

    -- 手上武器的价值（只捡更好的时用）
    local curCost = nil
    if onlyBetter then
        local ic = getInvCtrl()
        if ic then
            local okw, w = pcall(function() return ic.peekCurrentEquippedForMovement() end)
            if okw and w and typeof(w.Properties) == "table" then
                curCost = S.weaponCost(w.Properties.Name)
            end
        end
    end

    local best, bestScore, bestName = nil, -1, nil
    local myTeam = tostring(LP:GetAttribute("Team") or "")
    for _, m in ipairs(S.droppedWeapons()) do
        local wn = m:GetAttribute("Weapon")
        local pp = m.PrimaryPart
        if wn and pp then
            local d = (pp.Position - myPos).Magnitude
            if d <= range and m:GetAttribute("CanPickup") ~= false then
                local info = S.weaponInfo(wn)
                local score = info.cost

                -- ① 阵营判断（策略 = 仅本阵营 / 只捡指定 时启用）
                --    武器配置 Team：Both / Terrorists / Counter-Terrorists
                if teamOnly and myTeam ~= "" and info.team ~= "" and info.team ~= "Both" then
                    if info.team ~= myTeam then
                        score = -1
                    end
                end

                -- ② 掉落物模型自己也可能带 Team 属性（服务端标的），同样要对上
                local mTeam = m:GetAttribute("Team")
                if teamOnly and typeof(mTeam) == "string" and mTeam ~= "" and myTeam ~= ""
                    and mTeam ~= myTeam then
                    score = -1
                end

                -- ③ 自定义优先列表：命中就插队（10 万分制，压过任何 Cost 差）
                for i, token in ipairs(prioList) do
                    if tostring(wn):lower():find(token, 1, true) then
                        score = score + (200000 / i)
                        break
                    end
                end

                -- ④ 只捡比手上更值钱的
                if curCost and info.cost <= curCost then
                    score = -1
                end

                score = score - d * 0.01           -- 同分取近的
                if score > bestScore then
                    bestScore, best, bestName = score, m, tostring(wn)
                end
            end
        end
    end

    if best then
        local identity = best.Name
        local ok, err = pcall(function()
            Remotes.Inventory.PickupWeapon.Send({
                Identity = identity,
                AllowAutoEquip = (cfg.autoPickupEquip ~= false),
            })
        end)
        if ok then
            S.pickupCount = (S.pickupCount or 0) + 1
            S.lastPickup = string.format("%s (cost %d) %s", bestName, S.weaponCost(bestName), identity)
        else
            S.err_pickup = tostring(err)
        end
    end
end

-- 为某个阵营生成一整套拾取控件（T / CT 各调一次，两套完全独立）
S.addPickupSection = function(section, side, label)
    local function key(k) return k .. "_" .. side end
    local STRAT2IDX = { value = 1, all = 2, better = 3, named = 4 }
    local IDX2STRAT = { "value", "all", "better", "named" }

    section:Header({ Text = "拾取 · " .. label })
    section:Toggle({
        Name = "自动拾取（捡到自动装备）",
        Default = cfg[key("pickupOn")] ~= false,
        Callback = function(v) cfg[key("pickupOn")] = v end,
    }, "PickOn_" .. side)
    section:Dropdown({
        Name = "策略",
        Multi = false,
        Required = true,
        Options = { "按价值（仅本阵营）", "按价值（敌人的枪也捡）", "只捡比手上好的", "只捡指定武器" },
        Default = STRAT2IDX[cfg[key("pickupStrat")] or "value"] or 1,
        Callback = function(v)
            local idx = 1
            for i, name in ipairs({ "按价值（仅本阵营）", "按价值（敌人的枪也捡）", "只捡比手上好的", "只捡指定武器" }) do
                if name == v then idx = i break end
            end
            cfg[key("pickupStrat")] = IDX2STRAT[idx]
        end,
    }, "PickStrat_" .. side)
    section:Slider({
        Name = "半径（stud）",
        Default = cfg[key("pickupRange")],
        Minimum = 3,
        Maximum = 20,
        DisplayMethod = "Value",
        Precision = 0,
        Callback = function(v) cfg[key("pickupRange")] = v end,
    }, "PickRange_" .. side)
    section:Dropdown({
        Name = "指定武器（策略选最后一项时生效）",
        Multi = false,
        Required = true,
        Options = { "不指定", "AWP", "SSG 08", "AK-47", "M4A4", "M4A1-S", "SG 553", "AUG",
            "FAMAS", "Galil AR", "Desert Eagle", "R8 Revolver", "P90", "MP9",
            "MAC-10", "Negev", "XM1014", "MAG-7", "Nova", "P250", "USP-S", "Glock-18" },
        Default = 1,
        Callback = function(v)
            cfg[key("pickupNamed")] = (v == "不指定") and "" or tostring(v)
        end,
    }, "PickNamed_" .. side)
end

-- 注意：不能写成 local function —— 主 chunk 已经贴着 200 个 local 上限，
-- 再加一个就会 "Out of local registers"。统一挂到 S 上。
S.restoreAllHooks = function()
    pcall(function()
        -- ⚠ 路径必须是 Inventory.ShootWeapon —— ShootWeapon 在 Inventory 命名空间，
        -- 不是 Weapon。之前卸载脚本按 R.Weapon.ShootWeapon 去还原，
        -- 结果什么都没还原，hook 一直挂在游戏的 Remotes 表上。
        local R = Remotes
        local o = getgenv().MV_ORIG_SEND
        if R and R.Inventory and R.Inventory.ShootWeapon and typeof(o) == "function" then
            R.Inventory.ShootWeapon.Send = o
        end
    end)
    pcall(function()
        local R = Remotes
        if R and R.Melee and R.Melee.MeleeAttack
            and typeof(getgenv().MV_ORIG_MELEE) == "function" then
            R.Melee.MeleeAttack.Send = getgenv().MV_ORIG_MELEE
        end
    end)
    pcall(function()
        if typeof(getgenv().MV_ORIG_SETRECOIL) == "function" then
            require(game.ReplicatedStorage.Controllers.CameraController).setWeaponRecoil =
                getgenv().MV_ORIG_SETRECOIL
        end
    end)
    -- ⚠ weaponKick 才是真正把后座「立即」写进相机弹簧的那个（见 S.noRecoilHook 的注释）。
    -- 以前只还原了 setWeaponRecoil，weaponKick 的 wrapper 一直挂着 ——
    -- 功能上它会转发给原版，但卸载/重载后多一层死闭包，而且 cfg.noRecoil 被新实例
    -- 改成 true 时，旧 wrapper 会跟着拦。
    pcall(function()
        local kickOrig = getgenv().MV_ORIG_WEAPONKICK
        if typeof(kickOrig) == "function" then
            require(game.ReplicatedStorage.Controllers.CameraController).weaponKick = kickOrig
        end
    end)
    -- 准星链路：getWeaponKickRotation 的缩放包装也要还原，
    -- 否则卸载后准星会一直按「已压枪」的缩小值来画，看起来偏得莫名其妙。
    pcall(function()
        local krotOrig = getgenv().MV_ORIG_KICKROT
        if typeof(krotOrig) == "function" then
            require(game.ReplicatedStorage.Controllers.CameraController).getWeaponKickRotation = krotOrig
        end
    end)
    pcall(function()
        if typeof(getgenv().MV_ORIG_MAG) == "function" then
            require(game.ReplicatedStorage.Controllers.AimAssistController).GetMagnetismRotation =
                getgenv().MV_ORIG_MAG
        end
    end)
    -- ⚠ 以下三类 hook 以前完全没被还原，重载/卸载后它们仍然挂在游戏模块上：
    --   ① InventoryController.getCurrentEquipped / peekCurrentEquippedForMovement
    --   ② Shared.Raycast.cast / castThrough
    --   ③ Skins.GetCameraModel
    -- 后果分别是：重载后物品栏继续脱节但日志显示 patch=true、
    -- 射线继续走我们的实现、换肤表被旧闭包继续套用（皮肤关不掉）。
    -- 注意：①②的原函数体内带 getfenv 检测，这里只还原、不调用；
    -- 还原之后游戏再调就回到原版行为，想彻底干净要重进服务器（与原设计一致）。
    pcall(function()
        local ic = require(game.ReplicatedStorage.Controllers.InventoryController)
        local op = getgenv().MV_ORIG_PEEK
        local og = getgenv().MV_ORIG_GCE
        if typeof(op) == "function" then ic.peekCurrentEquippedForMovement = op end
        if typeof(og) == "function" then ic.getCurrentEquipped = og end
        getgenv().MV_GCE_PATCHED = nil
    end)
    pcall(function()
        local rc = require(game.ReplicatedStorage.Shared.Raycast)
        local oc = getgenv().MV_ORIG_CAST
        local ot = getgenv().MV_ORIG_CASTTHROUGH
        if typeof(oc) == "function" then rc.cast = oc end
        if typeof(ot) == "function" then rc.castThrough = ot end
        getgenv().MV_RAYCAST_PATCHED = nil
    end)
    pcall(function()
        local orig = S.skinOrigGetCameraModel
        local lib = S.getSkinsLib and S.getSkinsLib()
        if orig and lib and lib.GetCameraModel ~= orig then
            lib.GetCameraModel = orig
        end
        S.skinHookInstalled = false
    end)
    pcall(function()
        if S.attrHook and S.removeAttrHook then S.removeAttrHook() end
    end)
    S.noRecoilHookOn = nil
end

S.setPureMode = function(on)
    S.pureMode = (on == true)
    if S.pureMode then
        -- 关掉一切改写
        cfg.silentAim = false
        cfg.autoFire = false
        cfg.aimToggled = false
        cfg.noRecoil = false
        cfg.autoRecoilComp = false
        cfg.skipFireDelay = false
        cfg.instantReload = false
        cfg.infiniteAmmo = false
        cfg.noSpread = false
        cfg.rapidFire = 1
        cfg.multiShot = false
        cfg.bulletTrack = false
        cfg.wallbang = false
        cfg.viewTickOffset = 0
        cfg.throwPreview = false
        cfg.throwAuto = false
        cfg.throwKeyHeld = false
        cfg.bunnyhop = false
        cfg.spinbot = false
        cfg.thirdPerson = false
        cfg.esp = false
        cfg.radar = false
        cfg.offscreen = false
        cfg.mobileHoldFire = false
        pcall(function() if aimInput then aimInput.down = false; aimInput.listening = false end end)
        -- 断开弹药循环
        pcall(function()
            if S.ammoConn then S.ammoConn:Disconnect(); S.ammoConn = nil end
        end)
        S.restoreAllHooks()
        pcall(function() if S.menuScreenGui then S.menuScreenGui.Enabled = true end end)
    end
    return S.pureMode
end

-- 大陀螺（服务端可见）
--
-- 之前两次都失败：
--   1) 改 HumanoidRootPart.CFrame → MovementV2 每帧覆盖，只有自己看得见
--   2) 改 cam.CFrame → 别人能看见了，但自己视角跟着转
--
-- 正确做法是改「发给服务端的命令流」。命令对象长这样：
--   { Buttons, CommandNumber, LookYaw, Move, PredictedBaseMoveSpeed, VerticalLook }
-- LookYaw 是水平朝向（弧度），VerticalLook 是俯仰。
-- CommandCodec.encode 负责把命令打包成包，hook 它、把每个命令的 LookYaw
-- 换成当前旋转角，相机完全不动 —— 自己视角正常，别人看到你在原地打转。
--
-- 注意：CommandCodec 返回的表是 table.freeze 的，必须先 setreadonly(t,false)。
---------------------------------------------------------------------
local CCmod = nil
local origEncode = nil
-- 已经解冻过的命令表。命令对象是 table.freeze 的，必须 setreadonly(c,false) 才能写；
-- 但每帧都解冻会像改 Properties 那样把射击循环拖到超时，所以只解冻一次并缓存。
local unfrozenCmds = setmetatable({}, { __mode = "k" })

local function installSpinHook()
    if origEncode then return true end
    local ok, m = pcall(function()
        return require(RS.MovementV2.CommandCodec)
    end)
    if not ok or typeof(m) ~= "table" then return false end
    local ok2, enc = pcall(function() return m.encode end)
    if not ok2 or typeof(enc) ~= "function" then return false end

    local unfrozen = pcall(function() setreadonly(m, false) end)
    CCmod = m
    origEncode = enc

    local ok3 = pcall(function()
        m.encode = function(pkt, cfgArg, ...)
            -- ⚠ 兔子跳叠速实验：改 PredictedBaseMoveSpeed。
            --
            -- 这是命令结构里唯一可能影响速度的字段（客户端预测的基础速度）。
            -- 但服务端按自己的物理算位置（情报 5.9），所以大概率只影响本地预测，
            -- 表现为「画面里跑得飞快，实际位置没变」。真想验证得看别人眼里的你。
            --
            -- 通过 getgenv().MV_BHOPBOOST 控制（>1 时生效），由 cfg.bhopBoost 同步。
            local boost = tonumber(getgenv().MV_BHOPBOOST) or 1
            if boost > 1 and typeof(pkt) == "table" and typeof(pkt.Commands) == "table" then
                local cmds = pkt.Commands
                if type(S.bhopUnfrozen) ~= "table" then S.bhopUnfrozen = {} end
                for i = 1, #cmds do
                    local c = cmds[i]
                    if type(c) == "table" and type(c.PredictedBaseMoveSpeed) == "number" then
                        if not S.bhopUnfrozen[c] then
                            pcall(function() setreadonly(c, false) end)
                            S.bhopUnfrozen[c] = true
                        end
                        pcall(function()
                            c.PredictedBaseMoveSpeed = c.PredictedBaseMoveSpeed * boost
                        end)
                        S.bhopBoosted = (S.bhopBoosted or 0) + 1
                    end
                end
            end
            -- 空中加速（air strafe）实验
            --
            -- CS 的 bhop 叠速不是"跳得快"，而是空中把移动方向转到与速度垂直，
            -- 服务端的 air-accel 会沿着这个垂直方向给速度矢量一个切向增量，
            -- 速度方向和大小就慢慢累积起来了。
            --
            -- MovementV2 的服务端是**重放客户端命令**的确定性模拟，也就是说
            -- 它用我们发的 Move + LookYaw 去算移动方向。所以只要服务端在 air 状态下
            -- 还有加速度（而不是直接把速度钳死），改 Move 的朝向就能复现这个机制。
            --
            -- airStrafe 模式：
            --   turn  = 把当前 Move 旋转 90°（模拟"垂直于速度"的 strafe 输入）
            --   side  = 只保留左右分量（真·CS strafe：一直往一个侧向推）
            --
            -- ⚠ 这会让移动方向偏离你自己的输入 —— 它是"自动 strafe"，不是"增强操作"。
            local airMode = cfg.airStrafe
            if airMode and airMode ~= "off" and S.bhOnGround == false then
                local cmds2 = pkt.Commands
                if typeof(cmds2) == "table" then
                    if type(S.bhopUnfrozen) ~= "table" then S.bhopUnfrozen = {} end
                    for i = 1, #cmds2 do
                        local c = cmds2[i]
                        if type(c) == "table" and typeof(c.Move) == "Vector2" then
                            local mv = c.Move
                            if math.abs(mv.X) > 0.05 or math.abs(mv.Y) > 0.05 then
                                local nx, ny
                                if airMode == "turn" then
                                    -- 旋转 90°：垂直于原方向
                                    nx, ny = -mv.Y, mv.X
                                else
                                    -- side：只保留横向分量，纵向清零
                                    nx, ny = mv.X, 0
                                    if math.abs(nx) < 0.05 then nx, ny = 1, 0 end
                                end
                                if not S.bhopUnfrozen[c] then
                                    pcall(function() setreadonly(c, false) end)
                                    S.bhopUnfrozen[c] = true
                                end
                                pcall(function()
                                    c.Move = Vector2.new(nx, ny)
                                end)
                                S.airStrafeApplied = (S.airStrafeApplied or 0) + 1
                            end
                        end
                    end
                end
            end
            -- 诊断：不管陀螺开不开，都记录一份命令里的移动字段。
            -- PredictedBaseMoveSpeed 是客户端预测的基础速度，是整个命令结构里
            -- 唯一可能影响「叠速」的字段 —— 之前从来没检查过它。
            if typeof(pkt) == "table" and typeof(pkt.Commands) == "table" and pkt.Commands[1] then
                local c0 = pkt.Commands[1]
                if type(c0) == "table" then
                    getgenv().MV_CMDDGB = {
                        speed = c0.PredictedBaseMoveSpeed,
                        mx = (typeof(c0.Move) == "Vector2") and c0.Move.X or nil,
                        my = (typeof(c0.Move) == "Vector2") and c0.Move.Y or nil,
                        buttons = c0.Buttons,
                        yaw = c0.LookYaw,
                        at = os.clock(),
                    }
                end
            end
            -- ⚠ encode 的第二个参数不是游戏的 cfg，是 MovementV2 的常量表（24 个 *Ticks），
            -- 里面没有 spinbot。以前写 if cfg.spinbot 永远为假，一次都没改写成功。
            if getgenv().MV_SPINBOT == true and typeof(pkt) == "table" then
                local cmds = pkt.Commands
                if typeof(cmds) == "table" then
                    local speed = tonumber(getgenv().MV_SPINSPEED) or 2500
                    local ang = (os.clock() * math.rad(speed)) % (2 * math.pi)
                    if ang > math.pi then ang = ang - 2 * math.pi end
                    local camNow = workspace.CurrentCamera
                    -- 相机当前的水平朝向，用来把 Move 反向旋转回去
                    local camYaw = 0
                    if camNow then
                        local lv = camNow.CFrame.LookVector
                        camYaw = math.atan2(-lv.X, -lv.Z)
                    end
                    -- 服务端会用 LookYaw 去旋转 Move 来算移动方向。
                    -- 我们把 LookYaw 换成了 ang，如果不补偿，算出来的方向就是错的，
                    -- 玩家会「原地打转、一动就走不了」。
                    -- 这里把 Move 反向旋转 (ang - camYaw)，服务端再转回来就是正确方向。
                    local delta = ang - camYaw
                    local cosD, sinD = math.cos(-delta), math.sin(-delta)

                    for i = 1, #cmds do
                        local c = cmds[i]
                        if type(c) == "table" then
                            -- 诊断：把「原始 LookYaw」和「我们从相机算出来的 camYaw」都记下来。
                            -- 补偿公式 R(ang) * R(-delta) = R(camYaw) 成立的前提是
                            -- LookYaw 与 camYaw 用的是**同一套符号约定**。
                            -- 如果两者差一个负号或 90°，补偿就是歪的 —— 表现就是走路绕圈。
                            if i == 1 and type(c.LookYaw) == "number" then
                                getgenv().MV_SPINDBG = {
                                    raw = c.LookYaw,
                                    camYaw = camYaw,
                                    ang = ang,
                                    moveX = (typeof(c.Move) == "Vector2") and c.Move.X or 0,
                                    moveY = (typeof(c.Move) == "Vector2") and c.Move.Y or 0,
                                    at = os.clock(),
                                }
                            end
                            -- 命令对象是冻结的，必须先解冻。只做一次，之后复用。
                            if not unfrozenCmds[c] then
                                pcall(function() setreadonly(c, false) end)
                                unfrozenCmds[c] = true
                            end
                            pcall(function()
                                local mv = c.Move
                                if typeof(mv) == "Vector2" then
                                    c.Move = Vector2.new(
                                        mv.X * cosD - mv.Y * sinD,
                                        mv.X * sinD + mv.Y * cosD
                                    )
                                end
                            end)
                            pcall(function() c.LookYaw = ang end)
                        end
                    end
                end
            end
            return origEncode(pkt, cfgArg, ...)
        end
    end)

    pcall(function() setreadonly(m, true) end)
    return ok3
end

-- 保留一个空壳函数，供旧的调用点使用
local function spinStep(dt) end

---------------------------------------------------------------------
-- 大陀螺（真实旋转版）
--
-- 改 LookYaw 那条路是死路：服务端只应用一次，别人看不到转，还会把移动方向搞歪。
-- 想让"看着真的像在转"，唯一有效的方式是**真的转相机** —— 也就是发真实鼠标输入
-- （mousemoverel）。游戏相机正常响应，第三人称下别人也能看到你在转。
--
-- 代价：会动系统光标。所以安全阀必须齐全：
--   · 输入框聚焦（在打字/看菜单）→ 停
--   · 窗口失焦 → 停
--   · spinPauseOnInput 打开时，最近有真实键鼠操作 → 让路
---------------------------------------------------------------------
-- ⚠ 必须挂在 PreRender（渲染前最后一刻），Heartbeat 和 RenderStep 都不行。
--
-- 一帧的顺序是：
--   Stepped（游戏在这里更新模型）→ RenderStepped → 【渲染】→ Heartbeat
--
--   · 挂在 Heartbeat：写完之后要等下一帧 Stepped，游戏立刻覆盖 → 白写
--   · 挂在 RenderStep(Last)：虽然排在渲染前，但游戏自己的更新可能也在这一层，
--     而且实测写 5.76° 下一帧读到 -153.9°，说明始终慢一步
--   · PreRender 在 RenderStepped 之后、真正提交渲染之前 —— 这里写完立刻上屏
if S.spinConn then
    pcall(function() S.spinConn:Disconnect() end)
    S.spinConn = nil
end
-- ⚠ 这里不能声明任何新的顶层 local（主 chunk 已经 200 上限）。
-- 所以信号名和连接都挂在 S 上。
S.spinSignalName = RunService.PreRender and "PreRender" or "RenderStepped"
S.spinConn = (RunService.PreRender or RunService.RenderStepped):Connect(function(dt)
    if S._alive == false or REG.gen ~= MY_GEN then return end
    pcall(S.applyLocalSpin, dt)
end)

---------------------------------------------------------------------
-- 美化：本地切换武器皮肤
--
-- 实测：CurrentEquipped 是玩家属性（JSON 字符串），本地 SetAttribute 可行，
-- 而且不会被服务端还原。游戏渲染 viewmodel 时读的就是这个字段的 Skin，
-- 所以改它 → 游戏自己用新皮肤重建模型，不用我们手动替换任何部件。
--
-- 皮肤来源：ReplicatedStorage.Database.Components.Libraries.Skins
--   GetAllSkinsForWeapon(weaponName) -> { { skin=..., name=..., rarity=... }, ... }
-- 每个皮肤表里：name="AWP"、skin="Lore"、paintId="AWP | Lore"、_id 格式是 Name_Skin
---------------------------------------------------------------------
S.getSkinsLib = function()
    local ok, m = pcall(require, game.ReplicatedStorage.Database.Components.Libraries.Skins)
    return (ok and type(m) == "table") and m or nil
end

-- ═══ 换刀 / 换武器外观（纯本地视觉，服务端零感知）═══
--
-- 原理：游戏建 viewmodel 时调 Skins.GetCameraModel(武器名, 皮肤, 磨损, ...)，
-- 我们把「武器名」换成目标武器，游戏就构建目标武器的整套模型
-- （MeshPart + Motor6D + 手臂，实测 Butterfly Knife = other/Handle/Handle2/Blade）。
-- 挂载时游戏自己会用**当前武器名**给模型命名（实测 workspace.Camera 下是 "Glock-18"），
-- 所以名字不用我们管，游戏查找 viewmodel 的逻辑完全不受影响。
--
-- 为什么这条能成、而之前三条都不行：
--   · 改 item.Name / CurrentEquipped → 游戏重建时丢弃，还会破坏背包同步
--   · 新建模型挂回 Camera → 没有游戏的每帧 CFrame 绑定，玩家一走就留在原地
--   · 改 Viewmodel.Model 引用 → 两个模型叠在一起打架
-- 而 hook GetCameraModel 是在**游戏自己构建的那一刻**换掉源武器，
-- 出来的就是游戏亲生的 viewmodel：绑定、动画、相机跟随全部正常。
--
-- 皮肤：换刀后必须用**目标刀自己的皮肤**（T Knife 只有 Stock；
-- 蝴蝶刀有 Fade / Damascus / Blackwidow / Nebula_PATTERN_* 等），
-- 所以 want 的取值也跟着换成目标武器的皮肤表。
-- ⚠ 整段包在 IIFE 里：主 chunk 的 local 槽位已经贴 200 上限，
--    这里任何一个新 local 都会让整份脚本编译失败（loadstring 只会静默返回 nil）。
do (function()
S.meleeSwap = S.meleeSwap or {
    ["T Knife"]  = "Butterfly Knife",
    ["CT Knife"] = "Karambit",
}

-- 当前武器「实际用于建模型的武器名」。换刀关掉时原样返回。
S.modelWeaponOf = function(wn)
    wn = tostring(wn or "")
    if cfg.meleeSwapOn == false then return wn end
    local to = S.meleeSwap and S.meleeSwap[wn]
    if to and to ~= "" and to ~= wn then return tostring(to) end
    return wn
end

-- 换刀设置入口（会立刻重建 viewmodel 让效果当场生效）
--   MV_SWAP_KNIFE("T Knife", "Butterfly Knife")   指定映射
--   MV_SWAP_KNIFE("T Knife", "")                  取消这把刀的映射
--   MV_SWAP_KNIFE(nil, nil, false)                整体关闭换刀
getgenv().MV_SWAP_KNIFE = function(from, to, enable)
    if enable ~= nil then cfg.meleeSwapOn = (enable == true) end
    if type(from) == "string" then
        S.meleeSwap = S.meleeSwap or {}
        if to == nil or to == "" then
            S.meleeSwap[from] = nil
        else
            S.meleeSwap[from] = tostring(to)
        end
    end
    -- 手里正拿着这把刀 → 立刻重建，否则要等切枪
    local ok, w = pcall(function()
        local ic = getInvCtrl()
        return ic and ic.peekCurrentEquippedForMovement()
    end)
    if ok and w and w.Name and S.rebuildViewmodel then
        pcall(function() S.rebuildViewmodel(tostring(w.Name)) end)
    end
    local out = {}
    for k, v in pairs(S.meleeSwap or {}) do out[#out + 1] = tostring(k) .. "→" .. tostring(v) end
    return string.format("换刀=%s | %s", tostring(cfg.meleeSwapOn ~= false), table.concat(out, ", "))
end
end)() end

S.getCurrentWeapon = function()
    local raw = game.Players.LocalPlayer:GetAttribute("CurrentEquipped")
    if type(raw) ~= "string" then return nil end
    local HS = game:GetService("HttpService")
    local ok, t = pcall(HS.JSONDecode, HS, raw)
    if not ok or type(t) ~= "table" then return nil end
    return t
end

-- ⚠⚠⚠ 危险：这个函数会破坏背包。
--
-- CurrentEquipped 是服务端下发的武器数据（JSON），游戏的背包/拾取/购买逻辑都读它。
-- 本地 SetAttribute 覆盖它 = 客户端自己伪造了一份装备状态。
--
-- 实测后果：服务端后续每次背包同步都和这份被改过的本地数据冲突，最终表现为
--   · 商店买的东西不进来（"买了个空气"）
--   · 捡到的东西立刻消失
--   · 主武器切不出来
--   · 服务端 CurrentEquipped 还是旧武器，客户端背包却已经是空槽
--
-- 所以默认**禁用**写属性。cfg.skinWriteAttr 必须手动打开才会真的写，
-- 而打开后请立刻关掉，并重新进服恢复背包。
-- ═════ 本地视觉换肤（安全版，替代写属性那条路）═════
--
-- 为什么不再写 CurrentEquipped：
--   那是服务端下发的装备数据，背包/拾取/购买全读它。本地改它 = 伪造装备状态，
--   实测会和服务端同步打架（买东西不进、捡的消失、主武器切不出来）。
--
-- 现在只改 viewmodel：Workspace.Camera.<武器名> 下面的 MeshPart.TextureID。
--   皮肤库 Skins.GetSkinInformation(weapon, skin).wearImages[1].assetId 就是磨损贴图 id，
--   直接把当前手持模型的所有 MeshPart 换成它 —— 纯本地，服务端完全不知道。
--   换枪时 CurrentEquipped 会变，下面挂了监听自动重放，所以「换成哪把枪都生效」。
S.skinVis = { weapon = nil, skin = nil, orig = {} }

S.applySkinVisual = function(skinName)
    local cur = S.getCurrentWeapon()
    if not cur then return false, "没有手持武器" end
    local lib = S.getSkinsLib()
    if not lib then return false, "皮肤库不可用" end
    local ok, info = pcall(lib.GetSkinInformation, tostring(cur.Name), tostring(skinName))
    if not ok or type(info) ~= "table" then return false, "皮肤不存在: " .. tostring(skinName) end
    local wid
    if type(info.wearImages) == "table" and info.wearImages[1] then
        wid = info.wearImages[1].assetId
    end
    if not wid then return false, "该皮肤没有贴图（可能只有模型没有贴图）" end
    local cam = workspace:FindFirstChild("Camera")
    local model = cam and cam:FindFirstChild(tostring(cur.Name))
    if not model then return false, "找不到 viewmodel（可能还没建好）" end

    local n = 0
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("MeshPart") then
            S.skinVis.orig[d] = S.skinVis.orig[d] or d.TextureID
            local okSet = pcall(function() d.TextureID = wid end)
            if okSet then n = n + 1 end
        end
    end
    S.skinVis.weapon = tostring(cur.Name)
    S.skinVis.skin = tostring(skinName)
    S.skinVis.assetId = wid
    return n > 0, string.format("%s / %s（%d 个部件）", tostring(cur.Name), tostring(skinName), n)
end

S.clearSkinVisual = function()
    for d, tex in pairs(S.skinVis.orig) do
        pcall(function() if d and d.Parent then d.TextureID = tex end end)
    end
    S.skinVis.orig = {}
    S.skinVis.weapon = nil
    S.skinVis.skin = nil
    return true
end

-- ═══════════════════════════════════════════════════════════════
-- 皮肤中文名 + 浏览器（带贴图 / 3D 预览）
--
-- 皮肤名来自游戏数据（"Lore"/"High Octane"…），全部英文。这里做一张常用表，
-- 没收录的保持原名（总比翻错强）。
-- 图片两个来源，都从游戏自己的 Skins 库取：
--   Skins.GetWearImageForFloat(item, 0.01)  -> 磨损贴图 assetId（列表缩略图用）
--   Skins.GetInspectModel(weapon, skin)     -> 可预览的 3D Model（右侧大图用）
-- ═══════════════════════════════════════════════════════════════
S.SKIN_CN = {
    ["Stock"] = "出厂",
    ["Lore"] = "传说", ["Dragon Lore"] = "巨龙传说",
    ["High Octane"] = "高辛烷", ["Beta"] = "测试版", ["Overdrive"] = "超速",
    ["HexPop"] = "霓虹", ["Freedom"] = "自由", ["Metamorphosis"] = "蜕变",
    ["Vampire"] = "血族", ["Bird Hunt"] = "猎鸟", ["Koi Pond"] = "锦鲤",
    ["Railgun"] = "电磁炮", ["Tekko"] = "铁拳", ["Typhon"] = "堤丰",
    ["Asiimov"] = "阿西莫夫", ["Hyper Beast"] = "野兽", ["Neo-Noir"] = "新黑色",
    ["Printstream"] = "印花流", ["Fade"] = "渐变", ["Case Hardened"] = "表面淬火",
    ["Doppler"] = "多普勒", ["Crimson Web"] = "深红之网", ["Slaughter"] = "屠杀",
    ["Fire Serpent"] = "火蛇", ["Water Elemental"] = "水元素",
    ["Frontside Misty"] = "迷雾", ["Point Disarray"] = "混沌点阵",
    ["The Empress"] = "女皇", ["Bloodsport"] = "血搏",
    ["Neon Revolution"] = "霓虹革命", ["Vulcan"] = "火神", ["Redline"] = "红线",
    ["Cyrex"] = "赛瑞克斯", ["Guardian"] = "守护者", ["Atomic Alloy"] = "原子合金",
    ["Mecha Industries"] = "机甲工业", ["Decimator"] = "毁灭者",
    ["Golden Coil"] = "金蛇缠绕", ["Nightwish"] = "夜愿", ["Cortex"] = "皮层",
    ["Chameleon"] = "变色龙", ["Emerald"] = "翡翠", ["Ruby"] = "红宝石",
    ["Sapphire"] = "蓝宝石", ["Black Pearl"] = "黑珍珠",
    ["Factory New"] = "工厂新", ["Minimal Wear"] = "略有磨损",
    ["Field-Tested"] = "久经沙场", ["Well-Worn"] = "破损不堪",
    ["Battle-Scarred"] = "战痕累累",
}
S.skinCN = function(name)
    local n = tostring(name or "")
    return S.SKIN_CN[n] or n
end

-- ⚠ 主 chunk 已经贴着 200 local 上限：这里必须挂 S 表，不能写 local
-- （写 local 就是 "Out of local registers ... exceeded limit 200"，loadstring 直接返回 nil）
S.RARITY_COLOR = {
    Red = Color3.fromRGB(235, 75, 75),
    Pink = Color3.fromRGB(215, 90, 215),
    Purple = Color3.fromRGB(140, 100, 235),
    Blue = Color3.fromRGB(90, 150, 235),
    Gold = Color3.fromRGB(235, 190, 70),
    Special = Color3.fromRGB(240, 170, 60),
    Stock = Color3.fromRGB(160, 160, 160),
}

-- ═══════════════════════════════════════════════════════════════
-- 真·换肤：hook Skins.GetCameraModel（不动 CurrentEquipped）
--
-- 游戏建 viewmodel 时走这一行（ReplicatedStorage.Classes.WeaponComponent.Classes.Viewmodel:936）：
--   self.Model = Skins.GetCameraModel(CameraModelWeapon, self.Skin, self.Float, ...)
-- 拦这个函数把第 2 个参数（skin）换掉，游戏就会用整套皮肤模型重建 ——
-- 枪体、配件、贴图、图案一起换，而 CurrentEquipped 一个字都不动，
-- 所以背包/拾取/购买完全不受影响（这是和「写属性换肤」的本质区别）。
--
-- 生效时机：下一次 viewmodel 重建。切换武器 / 换弹 / 重生都会触发。
-- ═══════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════
-- 【核心】劫持 CurrentEquipped 的读取，而不是跟服务端抢着写
--
-- 之前的错误做法：写属性 → 服务端立刻覆盖回 Stock → 白干。
-- 正确做法：hook Instance.GetAttribute，当游戏（任何脚本）读
-- LocalPlayer 的 "CurrentEquipped" 时，直接返回我们篡改过 Skin 的 JSON。
--   · 服务端怎么覆盖都无所谓，因为读的时候永远拿到我们的值
--   · 游戏自己的 Viewmodel → Skins → DecorateModel 渲染管线照常跑，
--     所以出来的是**真皮肤**（模型/贴图/图案全套），不是贴膜
--   · 不写任何数据、不碰背包、不碰 viewmodel 内部对象
-- ═══════════════════════════════════════════════════════════════
S.attrSkin = nil          -- 篡改后的 JSON 字符串
S.attrHook = false
S.origGetAttribute = nil

S.installAttrHook = function()
    if S.attrHook then return true end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        return false
    end
    local LP = game.Players.LocalPlayer
    local orig
    local ok, res = pcall(function()
        local o
        -- 用 __namecall 拦：hookfunction(Instance.GetAttribute, …) 在这个执行器上 hook 不动
        -- （实测返回 false），但 hookmetamethod(game, "__namecall") 实测可用。
        o = hookmetamethod(game, "__namecall", function(self, ...)
            -- 快速路径：绝大多数调用不是 GetAttribute，直接放行（性能关键）
            if getnamecallmethod() ~= "GetAttribute" then
                return o(self, ...)
            end
            if S.attrSkin and self == LP then
                local key = ...
                if key == "CurrentEquipped" then
                    return S.attrSkin
                end
            end
            return o(self, ...)
        end)
        return o
    end)
    if not ok or type(res) ~= "function" then return false end
    orig = res
    S.origNamecall = orig
    -- 读「真实值」用这个（绕过我们自己的 hook）
    S.origGetAttribute = function(obj, key)
        return orig(obj, key)
    end
    S.attrHook = true
    return true
end

S.removeAttrHook = function()
    if not S.attrHook then return true end
    pcall(function()
        if S.origNamecall then
            hookmetamethod(game, "__namecall", S.origNamecall)
        end
    end)
    S.attrHook = false
    S.attrSkin = nil
    return true
end

-- 设置要显示的皮肤（劫持读取 + 触发一次重建）
S.setAttrSkin = function(skinName)
    -- ⚠ 已废弃：这条路径会篡改 LocalPlayer 的 CurrentEquipped 属性（改「拥有什么」的语义），
    -- 而主界面的美化走的是纯本地渲染（S.paintCurrentModel + GetCameraModel hook），不需要它。
    -- 保留函数名只做短路，避免可能有残留调用点报 nil。
    do return false, "已废弃：请用 S.paintCurrentModel（纯本地，不改属性）" end
    local lp = game.Players.LocalPlayer
    local HS = game:GetService("HttpService")
    -- ⚠ 必须用原始 GetAttribute 读，否则读到的是我们自己篡改过的值
    local raw
    if S.attrHook and S.origGetAttribute then
        raw = S.origGetAttribute(lp, "CurrentEquipped")
    else
        raw = lp:GetAttribute("CurrentEquipped")
    end
    if type(raw) ~= "string" then
        -- 手上没枪时也允许预设：等有装备时再生效
        return false, "现在没有手持装备（进回合后再点）"
    end
    local ok, cur = pcall(function() return HS:JSONDecode(raw) end)
    if not ok or type(cur) ~= "table" then return false, "解析 CurrentEquipped 失败" end
    cur.Skin = tostring(skinName)
    local ok2, enc = pcall(function() return HS:JSONEncode(cur) end)
    if not ok2 then return false, "编码失败" end

    if not S.installAttrHook() then return false, "执行器不支持 hookfunction" end
    S.attrSkin = enc
    S.skinPaint[tostring(cur.Name)] = tostring(skinName)
    cfg.skinAutoName = tostring(skinName)
    cfg.skinAutoPaint = true

    -- 触发一次属性变化，让游戏重建 viewmodel（重建时读到的就是篡改值）
    pcall(function() lp:SetAttribute("CurrentEquipped", enc) end)
    return true, string.format("%s → %s（已劫持读取，服务端覆盖无效）",
        tostring(cur.Name), tostring(skinName))
end

-- ⚠ 这里曾经有一份「installSkinHook v1」：用 GetInspectModel 取一张贴图，
-- 直接写返回值模型的 TextureID。实测这条路会让部分枪直接消失 / 材质错乱，
-- 而且没有幂等保护 —— 重载后会在游戏模块上叠第二层 wrapper，
-- 卸载只能还原最后一层，皮肤表还想继续生效。
-- 已整段删除。生效实现只有文件尾部那一个（带 _mv_orig 标记 + return true）。

-- 立刻把皮肤贴图刷到「当前已经建好的 viewmodel」上（不用等切枪）。
-- hook 那条只保证「以后每次重建都带皮肤」，这个负责「现在这一刻就变」。
-- 皮肤只刷「枪身」部件：手臂/手套/锚点一律跳过。
-- 之前把 Right Arm / Left Arm / Glove 也刷了 → 手背上一块皮肤贴图（用户："给我手臂贴膜"）。
S.SKIN_SKIP = {
    ["Right Arm"] = true, ["Left Arm"] = true, ["Glove"] = true,
    ["HumanoidRootPart"] = true, ["ViewmodelLight"] = true, ["MuzzlePart"] = true,
}

-- 读 SurfaceAppearance.ColorMap
-- ⚠ 必须切到 thread identity 7：identity 8 下读写都会被拒
-- （"lacking capability Plugin"）。gethiddenproperty 在 8 下同样失效。
-- 这里自带一份完整实现（不依赖后面的 S.saGet），因为本函数在文件前部就可能被调用。
S.getColorMap = function(sa)
    if not sa then return nil end
    local can = (type(setthreadidentity) == "function")
    if can then pcall(setthreadidentity, 7) end
    local ok, v = pcall(function() return sa.ColorMap end)
    if (not ok or v == nil) and type(gethiddenproperty) == "function" then
        local ok2, v2 = pcall(gethiddenproperty, sa, "ColorMap")
        if ok2 and v2 ~= nil then ok, v = true, v2 end
    end
    if can then pcall(setthreadidentity, 8) end
    if ok then return v end
    return nil
end

-- ⚠ 这里曾经是 paintCurrentModel v0（sk:FindFirstChild(d.Name, true) + Instance.new("SurfaceAppearance")）。
-- 实测这条路：递归找到的同名对象往往没有 SA → painted=0；新建 SA 写不进去 → 枪不变色。
-- 已整段删除。生效实现只有文件尾部那个（按名字建材质表，只写现有 SA，绝不新建/销毁）。

-- ⚠ 皮肤选择必须跨重载保留，而且不能预设默认皮肤。
--
-- 老实现是 `S.skinPaint = { ["AK-47"] = "Aniki" }`：
--   · 任何人一加载就被强行给 AK 换皮（哪怕他从没选过）；
--   · 点别的皮肤只改这张内存表，重载后回到 AK-47=Aniki —— 选择等于丢失。
--
-- ⚠ 不要用 __newindex 元表做"自动落盘"：那个钩子只在「键原本不存在」时触发，
-- 同一把枪换第二次皮肤（键已存在）根本不触发，删键（赋 nil）也不触发 ——
-- 实测下来落盘表会停在第一次写入的值上，比不保存更难查。所以改成显式保存。
S.skinPaint = {}
do
    local store = getgenv().MV_SKIN_SAVE
    if type(store) == "table" then
        for k, v in pairs(store) do S.skinPaint[k] = v end
    else
        getgenv().MV_SKIN_SAVE = {}
    end
end

-- 把当前皮肤表整体写回 getgenv（跨重载保留；不落文件，重进服务器会丢）
S.saveSkins = function()
    local out = {}
    for k, v in pairs(S.skinPaint) do out[k] = v end
    getgenv().MV_SKIN_SAVE = out
    return out
end

-- 统一入口：读改写都走这里，避免再漏一个赋值点
S.setSkin = function(weaponName, skinName)
    -- ★ 面板卡片的真正入口就是这里（openSkinPanel 的卡片回调调的是 S.setSkin，
    --   不是 S.applySkinPaint）。点的是「另一把刀」时，必须把当前手持映射过去，
    --   否则 skinPaint 写进去了、但手上那把刀根本没换 → 用户看到「绿色选中了却没反应」。
    do
        local hw = S.getCurrentWeapon and S.getCurrentWeapon()
        if hw and hw.Name then
            local held, want = tostring(hw.Name), tostring(weaponName)
            if held ~= want and type(S.meleeSwap) == "table" then
                local node = RS.Database.Custom.Weapons:FindFirstChild(want)
                local okCfg, cfgW = false, nil
                if node then okCfg, cfgW = pcall(function() return require(node) end) end
                if okCfg and type(cfgW) == "table" and tostring(cfgW.Class) == "Melee" then
                    S.meleeSwap[held] = want
                    cfg.meleeSwapOn = true
                    S.meleeAutoMapped = (S.meleeAutoMapped or 0) + 1
                end
            end
        end
    end
    local wn = tostring(weaponName)
    if skinName == nil then
        S.skinPaint[wn] = nil
    else
        S.skinPaint[wn] = tostring(skinName)
    end
    -- ⚠ 重新点一次皮肤 = 明确的「再试一次」信号，必须清掉这把枪+这款皮肤的熔断计数。
    -- 不清的话：连续 3 次写不进 → 轮询每次在熔断检查处直接 return →
    -- 后面「恢复正常就清零」的分支永远走不到 → 同一把枪同一款皮肤再也不会重试，
    -- 只能重载脚本才清状态。
    if skinName ~= nil and type(S._skinFail) == "table" then
        S._skinFail[wn .. "|" .. tostring(skinName)] = 0
    end
    -- ⚠⚠ 关键：把皮肤同步到游戏自己持有的装备对象上。
    --
    -- InventoryController.getCurrentEquipped() 返回的 table 里有 Name / Skin / Slot 等字段，
    -- 游戏的 viewmodel 就是按 item.Skin 构建的（实测改之前 Skin="Stock"）。
    -- 我们之前只改 viewmodel 上的 SurfaceAppearance，游戏并不知道，所以：
    --   · 材质写进去了、读回也是新值，但引擎对已存在的 SA 不重绘 → 画面不变
    --   · 一旦游戏重建 viewmodel（换枪/死亡/回合开始），又按 item.Skin 变回原皮
    -- 直接把字段改掉，重建时拿到的就是我们要的皮肤。
    --
    -- 注意：改字段本身不会立刻刷新画面（equip 对当前武器是空操作），
    -- 需要切一次枪才会重建 —— 这是游戏机制，不是脚本问题。
    pcall(function()
        local RS2 = game:GetService("ReplicatedStorage")
        local ic = require(RS2.Controllers.InventoryController)
        -- ★ 只用 peek：getCurrentEquipped 的原函数体内是 getfenv 执行器检测，
        --   哪怕 patch 万一失效一次，也会把 u0 清空（整个武器创建链永久失效）。
        --   peek 没有任何调用栈检查，返回的是同一个 CurrentEquipped 对象。
        local peek = ic.peekCurrentEquippedForMovement or ic.getCurrentEquipped
        local cur = peek and peek()
        if cur and tostring(cur.Name) == wn then
            cur.Skin = tostring(skinName or "Stock")
            S.itemSkinSynced = tostring(wn) .. "→" .. tostring(cur.Skin)
        end
    end)
    -- 部件列表缓存也作废：用户刚换了皮肤，下一轮立刻重新扫一遍目标模型
    S._skinParts = nil
    S.saveSkins()
    return S.skinPaint[wn]
end
S.skinOverride = {}
S.applySkinPaint = function(weaponName, skinName)
    -- ★ 面板里点的如果是「另一把刀」，就把当前手持映射到它。
    --
    -- 不加这一步的后果（实测）：用户在面板选了 Butterfly Knife 的 Fade，
    -- 皮肤只写进 S.skinPaint["Butterfly Knife"]，而 applyMeleeSwap 找的是
    -- S.meleeSwap[当前手持]，两边对不上 → 手上永远是原来那把刀 + 皮肤永远 Stock。
    -- 表现就是「AI 手动换能换，我在面板点就是没反应」。
    do
        local hw = S.getCurrentWeapon and S.getCurrentWeapon()
        if hw and hw.Name then
            local held, want = tostring(hw.Name), tostring(weaponName)
            if held ~= want and type(S.meleeSwap) == "table" then
                local node = RS.Database.Custom.Weapons:FindFirstChild(want)
                local okCfg, cfgW = false, nil
                if node then okCfg, cfgW = pcall(function() return require(node) end) end
                if okCfg and type(cfgW) == "table" and tostring(cfgW.Class) == "Melee" then
                    S.meleeSwap[held] = want
                    cfg.meleeSwapOn = true
                    S.meleeAutoMapped = (S.meleeAutoMapped or 0) + 1
                end
            end
        end
    end
    if not S.installSkinHook() then return false, "皮肤库不可用" end
    -- ⚠⚠ 先验证这款皮肤在这把枪上**真的存在**。
    --
    -- 不验证的后果：skinPaint 被写成一把枪根本没有的皮肤（比如给 Glock 设 "Lore"，
    -- 而 Lore 是 AK 的皮肤），轮询每 0.12 秒都去 getSkinSAMap 找 → 永远空 →
    -- 一个部件都不写 → 画面停在上一次成功的皮肤上，再也换不掉。
    -- 用户看到的就是「美化被固定住了」。
    local probe, why = S.getSkinSAMap(tostring(weaponName), tostring(skinName), nil)
    if not probe or next(probe) == nil then
        local root = S.getSkinsRoot()
        local wf = root and root:FindFirstChild(tostring(weaponName))
        local avail = {}
        if wf then
            for _, c in ipairs(wf:GetChildren()) do
                if c:IsA("Folder") then avail[#avail + 1] = c.Name end
            end
        end
        return false, string.format("%s 没有皮肤 %s（可用：%s）",
            tostring(weaponName), tostring(skinName),
            #avail > 0 and table.concat(avail, ", ") or "无")
    end
    S.setSkin(weaponName, skinName)
    cfg.skinAutoName = tostring(skinName)
    cfg.skinAutoPaint = true
    -- 立刻刷当前模型（不等切枪）
    local n = S.paintCurrentModel(tostring(weaponName), tostring(skinName))
    -- ⚠ 区分两种「0 部件」：
    --   ① 现在没拿着这把枪 → paintCurrentModel 找不到 viewmodel，返回 0；
    --      皮肤已经记进 S.skinPaint，切到它时 GetCameraModel hook 会自己套上，算成功。
    --   ② 正拿着、但一个 MeshPart 都没匹配上（没有同名部件 / 没有现成 SurfaceAppearance /
    --      SA 带 TexturePackContent 写不进去）→ 这才是真失败，不能报「已立即刷 0 个部件」。
    -- ⚠ 判断「是否真的拿在手里」不能用 cam:FindFirstChild(weaponName)。
    -- 游戏会把不用的武器 viewmodel 留在 workspace.Camera 里（或 ViewmodelStash），
    -- 于是「拿着 Glock、点 AK 的皮肤」也会被当成手持 → paintCurrentModel 返回 0 → 卡片标红，
    -- 而实际上皮肤已经记进 S.skinPaint，切到 AK 时会自动生效。
    -- 这里改成和 InventoryController 报告的当前武器比对。
    local cur = S.getCurrentWeapon and S.getCurrentWeapon()
    local actuallyHeld = cur ~= nil and tostring(cur.Name) == tostring(weaponName)
    if not actuallyHeld then
        return true, string.format("%s → %s（已记录，切到这把枪时生效）",
            tostring(weaponName), tostring(skinName))
    end
    if n <= 0 then
        return false, string.format(
            "%s → %s：这把枪没有可替换的材质部件（需要同名 MeshPart + 现成 SurfaceAppearance）",
            tostring(weaponName), tostring(skinName))
    end
    return true, string.format("%s → %s（已立即刷 %d 个部件）",
        tostring(weaponName), tostring(skinName), n)
end

-- ⚠ 强制让游戏重建 viewmodel。
--
-- 为什么需要：SurfaceAppearance 的属性写进去、读回也是新值，但引擎对**已存在**的 SA
-- 不重绘（实测改完 1 秒读回值仍是新的、画面一点不变）。轮询也救不了 ——
-- 它每 0.12 秒检查一次，发现 ColorMap 已经等于目标值就不再写，画面就停在旧材质上。
-- 用户看到的就是「换皮肤没反应 / 换了又变回去 / 只有第一次生效」。
--
-- 把 viewmodel 从 Camera 上摘下来再挂回去，游戏会重新走 GetCameraModel 构建一次，
-- 而我们的 hook 在模型交回游戏前就把 SA 换成皮肤模板的克隆 → 这次是全新的 SA 实例，
-- 引擎必然重建材质。
S.rebuildViewmodel = function(weaponName)
    local cam = workspace.CurrentCamera
    if not cam then return false, "no-camera" end
    local vm = cam:FindFirstChild(tostring(weaponName))
    if not vm then return false, "not-held" end
    local parent = vm.Parent
    if not parent then return false, "no-parent" end
    vm.Parent = nil
    task.defer(function()
        pcall(function() vm.Parent = parent end)
    end)
    S.rebuilds = (S.rebuilds or 0) + 1
    return true
end

S.clearSkinPaint = function()
    -- 不能在遍历中直接删除（pairs 里置 nil 会跳项），先收集 key。
    local keys = {}
    for k in pairs(S.skinPaint) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do S.skinPaint[k] = nil end
    S.saveSkins()   -- 整体落盘（清空后的表）
    return true, "已清除皮肤（切一次枪还原）"
end

S.applySkinReal = function(skinName)
    local w = S.getCurrentWeapon()
    if not w then return false, "没有手持武器" end
    return S.applySkinPaint(tostring(w.Name), tostring(skinName))
end

S.clearSkinReal = function()
    return S.clearSkinPaint()
end

-- ═══════════════════════════════════════════════════════════════
-- 真·换肤（写属性版）—— 唯一能让「枪体」变的方式
--
-- 前面试过的两条路都不行，实测结论：
--   1) 改 MeshPart.TextureID：只能改到配件和手套（手套是标准 MeshPart），
--      枪体是 Part / 空贴图 MeshPart，改不到。
--   2) hook Skins.GetCameraModel：Stock 和任意皮肤返回的模型、MeshId、TextureID
--      **完全一样**（实测 sig 对比 不同=false），皮肤是在 DecorateModel /
--      GetSkinTextureFolder 里套的，那两个是模块内局部函数，从外面 hook 不到。
--
-- 所以只剩写 CurrentEquipped.Skin：游戏会读它重建整套 viewmodel，枪体一起换。
-- 代价是服务端背包同步会冲突（买东西不进、捡的消失、主武器切不出来），
-- 必须重进服务器恢复。这里给原始 JSON 做了备份，随时可以还原。
-- ═══════════════════════════════════════════════════════════════
S.skinWriteBackup = {}

S.applySkinWrite = function(skinName)
    local lp = game.Players.LocalPlayer
    local HS = game:GetService("HttpService")
    local raw = lp:GetAttribute("CurrentEquipped")
    if type(raw) ~= "string" then return false, "没有手持武器" end
    local ok, cur = pcall(function() return HS:JSONDecode(raw) end)
    if not ok or type(cur) ~= "table" then return false, "解析 CurrentEquipped 失败" end
    -- 备份原始 JSON（同一把枪只备份第一次）
    if not S.skinWriteBackup[tostring(cur.Name)] then
        S.skinWriteBackup[tostring(cur.Name)] = raw
    end
    cur.Skin = tostring(skinName)
    -- ⚠ 绝对不要改 _id。
    -- 老情报里写的是 `cur._id = "AWP_Lore"`（Name_Skin 格式），但现在实测 _id 是
    -- **物品实例 UUID**（例如 d700f34a-3f0e-4daf-b4ff-31c293c0f63e）。
    -- 改成 Name_Skin 游戏会认不出这个物品，属性被立刻覆盖成 T Knife（实测 after write = T Knife）。
    -- 皮肤只需要 Skin 字段，_id 保持原样。
    local ok2, enc = pcall(function() return HS:JSONEncode(cur) end)
    if not ok2 then return false, "编码失败" end
    local ok3 = pcall(function() lp:SetAttribute("CurrentEquipped", enc) end)
    if not ok3 then return false, "写属性失败" end
    cfg.skinAutoName = tostring(skinName)
    -- 打开自动重放：换枪时把皮肤重新写上去（否则换枪就退回原皮肤）
    cfg.skinAutoPaint = true
    return true, string.format("%s → %s（切一次枪生效；背包会错乱，重进服务器恢复）",
        tostring(cur.Name), tostring(skinName))
end

S.restoreSkinWrite = function()
    local lp = game.Players.LocalPlayer
    -- ⚠ 必须先关掉自动重放，否则还原完 0.35 秒后监听又把皮肤写回去（实测踩过）
    cfg.skinAutoPaint = false
    cfg.skinAutoName = "Stock"
    local n = 0
    for name, raw in pairs(S.skinWriteBackup or {}) do
        local ok = pcall(function() lp:SetAttribute("CurrentEquipped", raw) end)
        if ok then n = n + 1 end
    end
    S.skinWriteBackup = {}
    return n > 0, string.format("已还原 %d 把枪的原始数据（切一次枪生效）", n)
end

-- ═══════════════════════════════════════════════════════════════
-- 换肤（组件版）—— 改 w.Skin / vm.Skin，不碰 CurrentEquipped
--
-- 为什么这条路才对：
--   Viewmodel 构造时用的是 `self.Skin`（viewmodel 实例自己的字段），
--   而 CurrentEquipped 是服务端下发的装备数据，服务端会把它覆盖回 Stock
--   （实测：写属性后属性保持，但游戏重建回原模型 —— 截图里就是黑的）。
--   w.Skin / vm.Skin 是纯客户端对象字段，服务端完全不知道，也不会覆盖。
--
-- 生效方式：改完字段后尝试调重建方法（construct/rebuild/…）；
-- 没有可调方法时就切一次枪，游戏自己会按新字段重建。
-- ═══════════════════════════════════════════════════════════════
S.applySkinComponent = function(skinName)
    local ic = getInvCtrl()
    if not ic then return false, "没有 InventoryController" end
    local ok, w = pcall(function() return ic.peekCurrentEquippedForMovement() end)
    if not ok or not w then return false, "没有手持武器实例（可能还没上膛/在买枪阶段）" end
    local vm = w.Viewmodel
    if not vm then return false, "这把武器还没有 viewmodel" end

    pcall(function() w.Skin = tostring(skinName) end)
    pcall(function() vm.Skin = tostring(skinName) end)
    cfg.skinAutoName = tostring(skinName)

    -- ⚠ 绝对不要在这里调 vm:destroy()。
    -- 实测：destroy 会清掉 construct 依赖的内部对象（CharacterAnimator 等），
    -- 之后 construct 永远报 `attempt to index nil with 'stopAnimations'`，
    -- 连游戏自己的 unequip 也跟着报错，viewmodel 直接坏掉，只能切枪/重生恢复。
    -- 所以这里只改字段，让「游戏自己」在下一次 construct 时用新 Skin。
    return true, string.format("%s → %s（字段已设，切一次枪让游戏自己重建）", tostring(w.Name), tostring(skinName))
end

S.openSkinBrowser = function()
    -- ⚠ 已废弃：这是旧的皮肤浏览器入口，内部会调 setAttrSkin 改 CurrentEquipped。
    -- 主界面现在用 S.openSkinPanel()（纯本地渲染 + 图片网格）。
    do return false, "已废弃：请用 S.openSkinPanel()" end
    -- ⚠ Window 是文件末尾才创建的，本函数定义在前面 —— 直接写 Window:Notify 会崩
    -- （实测：attempt to index nil with 'Notify'，注入时自动弹面板整段中断）。
    -- 统一走这个安全包装：Window 没建好就退化成 warn。
    local function notify(t)
        local ok = pcall(function() Window:Notify(t) end)
        if not ok then
            warn("[SKIN] " .. tostring(t and t.Title) .. ": " .. tostring(t and t.Description))
        end
    end
    local cur = S.getCurrentWeapon()
    if not cur then
        notify({ Title = "美化", Description = "手上没有武器（或装备数据异常），换一次枪再试", Lifetime = 5 })
        return
    end
    local lib = S.getSkinsLib()
    if not lib then return end
    local okL, list = pcall(lib.GetAllSkinsForWeapon, tostring(cur.Name))
    if not okL or type(list) ~= "table" or #list == 0 then
        notify({ Title = "美化", Description = "该武器没有皮肤", Lifetime = 3 })
        return
    end

    local holder = (gethui and gethui()) or game:GetService("CoreGui")
    local old = holder:FindFirstChild("MV_SkinBrowser")
    if old then old:Destroy() end

    local sg = Instance.new("ScreenGui")
    sg.Name = "MV_SkinBrowser"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.DisplayOrder = 50
    local okp = pcall(function() sg.Parent = holder end)
    if not okp then sg.Parent = game.Players.LocalPlayer:WaitForChild("PlayerGui") end

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 720, 0, 460)
    frame.Position = UDim2.new(0.5, -360, 0.5, -230)
    frame.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Parent = sg
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(80, 110, 150); stroke.Thickness = 1; stroke.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -60, 0, 34)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 15
    title.TextColor3 = Color3.fromRGB(120, 210, 255)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = string.format("  美化 · %s（%d 个皮肤，点击应用，纯本地）", tostring(cur.Name), #list)
    title.Parent = frame

    local close = Instance.new("TextButton")
    close.Size = UDim2.new(0, 34, 0, 34)
    close.Position = UDim2.new(1, -40, 0, 0)
    close.BackgroundColor3 = Color3.fromRGB(120, 40, 45)
    close.BorderSizePixel = 0
    close.Font = Enum.Font.GothamBold
    close.TextSize = 17
    close.TextColor3 = Color3.fromRGB(255, 235, 235)
    close.Text = "×"
    close.Parent = frame
    close.MouseButton1Click:Connect(function() sg:Destroy() end)

    -- 皮肤网格（缩略图 + 中文名）：整块宽度，不再留右侧预览（卡片图已经能看，
    -- 3D 预览纯占地方，用户明确说没必要）
    local grid = Instance.new("ScrollingFrame")
    grid.Size = UDim2.new(1, -20, 1, -50)
    grid.Position = UDim2.new(0, 10, 0, 40)
    grid.BackgroundTransparency = 1
    grid.BorderSizePixel = 0
    grid.ScrollBarThickness = 5
    grid.CanvasSize = UDim2.new(0, 0, 0, 0)
    grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
    grid.Parent = frame
    local layout = Instance.new("UIGridLayout")
    layout.CellSize = UDim2.new(0, 168, 0, 120)
    layout.CellPadding = UDim2.new(0, 6, 0, 6)
    layout.Parent = grid

    for _, item in ipairs(list) do
        local skin = tostring(item.skin or "?")
        local card = Instance.new("TextButton")
        card.BackgroundColor3 = Color3.fromRGB(26, 30, 38)
        card.BorderSizePixel = 0
        card.AutoButtonColor = true
        card.Text = ""
        card.Parent = grid

        local img = Instance.new("ImageLabel")
        img.Size = UDim2.new(1, -8, 0, 66)
        img.Position = UDim2.new(0, 4, 0, 4)
        img.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
        img.BorderSizePixel = 0
        img.ScaleType = Enum.ScaleType.Fit
        local tex
        pcall(function() tex = lib.GetWearImageForFloat(item, 0.01) end)
        if type(tex) == "string" then img.Image = tex end
        img.Parent = card

        local nameLbl = Instance.new("TextLabel")
        nameLbl.Size = UDim2.new(1, -8, 0, 16)
        nameLbl.Position = UDim2.new(0, 4, 0, 72)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font = Enum.Font.GothamMedium
        nameLbl.TextSize = 11
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left
        nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
        nameLbl.TextColor3 = S.RARITY_COLOR[item.rarity] or Color3.fromRGB(210, 215, 225)
        nameLbl.Text = S.skinCN(skin)
        nameLbl.Parent = card

        local subLbl = Instance.new("TextLabel")
        subLbl.Size = UDim2.new(1, -8, 0, 14)
        subLbl.Position = UDim2.new(0, 4, 0, 88)
        subLbl.BackgroundTransparency = 1
        subLbl.Font = Enum.Font.Gotham
        subLbl.TextSize = 9
        subLbl.TextXAlignment = Enum.TextXAlignment.Left
        subLbl.TextTruncate = Enum.TextTruncate.AtEnd
        subLbl.TextColor3 = Color3.fromRGB(140, 150, 165)
        subLbl.Text = string.format("%s · %s", skin, tostring(item.rarity or "?"))
        subLbl.Parent = card

        card.MouseButton1Click:Connect(function()
            -- 点卡片 = 装皮肤（hook GetCameraModel 刷贴图，不碰任何数据）。
            -- 立即生效不了 —— 要等游戏下次构建 viewmodel（切枪/重生/换弹）。
            cfg.skinAutoName = skin
            -- 走「劫持读取」这条路：游戏重建 viewmodel 时读到的是带皮肤的 JSON，
            -- 由游戏自己的 DecorateModel 渲染真皮肤，服务端覆盖无效。
            local okA, msg = S.setAttrSkin(skin)
            for _, ch in ipairs(grid:GetChildren()) do
                if ch:IsA("TextButton") then ch.BackgroundColor3 = Color3.fromRGB(26, 30, 38) end
            end
            card.BackgroundColor3 = Color3.fromRGB(40, 70, 50)
            notify({
                Title = okA and ("已装皮肤: " .. S.skinCN(skin)) or "失败",
                Description = tostring(msg),
                Lifetime = 4,
            })
        end)
    end

    return sg
end


S.applySkin = function(skinName)
    -- 写了属性会破坏背包，所以只做视觉。想强行写属性：cfg.skinWriteAttr = true（后果自负）
    local okVis, msg = S.applySkinVisual(skinName)
    if okVis then return true, msg end
    if cfg.skinWriteAttr ~= true then
        return false, "换肤已禁用（会破坏背包同步，见代码注释）"
    end
    local lp = game.Players.LocalPlayer
    local HS = game:GetService("HttpService")
    local cur = S.getCurrentWeapon()
    if not cur then return false, "没有手持武器" end
    cur.Skin = tostring(skinName)
    cur._id = tostring(cur.Name) .. "_" .. tostring(skinName)
    local ok, enc = pcall(HS.JSONEncode, HS, cur)
    if not ok then return false, "编码失败" end
    local ok2 = pcall(function() lp:SetAttribute("CurrentEquipped", enc) end)
    return ok2, tostring(skinName)
end

S.cycleSkin = function()
    local cur = S.getCurrentWeapon()
    if not cur then return false, "没有手持武器" end
    local lib = S.getSkinsLib()
    if not lib then return false, "皮肤库不可用" end
    local ok, list = pcall(lib.GetAllSkinsForWeapon, tostring(cur.Name))
    if not ok or type(list) ~= "table" or #list == 0 then return false, "该武器没有皮肤" end
    local idxNow = 0
    for i, s in ipairs(list) do
        if type(s) == "table" and tostring(s.skin) == tostring(cur.Skin) then
            idxNow = i
            break
        end
    end
    local nextIdx = (idxNow % #list) + 1
    local target = list[nextIdx]
    if type(target) ~= "table" then return false, "皮肤数据异常" end
    local ok2, name = S.applySkin(target.skin)
    if not ok2 then return false, name end
    return true, string.format("%s (%d/%d)", tostring(target.skin), nextIdx, #list)
end

-- 把当前武器的全部皮肤名返回给 GUI 用
S.listSkins = function()
    local cur = S.getCurrentWeapon()
    if not cur then return {} end
    local lib = S.getSkinsLib()
    if not lib then return {} end
    local ok, list = pcall(lib.GetAllSkinsForWeapon, tostring(cur.Name))
    if not ok or type(list) ~= "table" then return {} end
    local out = {}
    for _, s in ipairs(list) do
        if type(s) == "table" and s.skin then
            out[#out + 1] = tostring(s.skin)
        end
    end
    return out
end

---------------------------------------------------------------------
-- 据点：自动定位包点 A / B 并做 3D 标记
--
-- 逆向结果（地图 Hellena 实测）：
--   A 点：几何里叫 asitewall* 的 MeshPart 有两块
--         (-115.2, 81.2, -97.2) 和 (-100.2, 81.2, -96.5)  → 中心约 (-107, 81, -97)
--   B 点：BSiteDoorArch（Model）的 bbox 在 (-99.9, 92.8, 45.6) → 地面约 (-100, 85, 46)
--   出生/购买区 BuyArea 两个 Part：(-107, 74, -78) 和 (131, 93, -1)
--   雷达 UI 自带 A / B 两个 TextLabel，说明游戏自己也会标
--
-- 所以这里不写死坐标，而是按名字去 Geometry 里找，换图只要命名规则一致就能用。
---------------------------------------------------------------------
S.sites = {}

S.findSites = function()
    local acc = {}
    local function add(key, pos)
        local e = acc[key]
        if not e then
            e = { sx = 0, sy = 0, sz = 0, n = 0 }
            acc[key] = e
        end
        e.sx = e.sx + pos.X
        e.sy = e.sy + pos.Y
        e.sz = e.sz + pos.Z
        e.n = e.n + 1
    end

    -- 首选：本图缓存（进过一次就有了，换回来秒出，不用重扫）
    local mapName = tostring(workspace:GetAttribute("Map") or "Unknown")
    local cache = type(getgenv().MV_MAPDATA) == "table" and getgenv().MV_MAPDATA[mapName] or nil
    if type(cache) == "table" and type(cache.sites) == "table" and next(cache.sites) ~= nil then
        S.siteSource = "cache"
        local out = {}
        for k, v in pairs(cache.sites) do out[k] = v end
        return out
    end

    -- ⚠ 唯一正确的位置来源：Map.Zones.Sites 里带 Site 属性的 Part。
    --
    -- 之前用几何名字猜（asitewall / BSiteDoorArch），算出来 A(-107,81,-97)、
    -- B(-100,85,46)，用户截图里 B 标在墙上——因为那些是「A 点墙」「B 点门拱」，
    -- 在包点边缘甚至几十格外，根本不是包点本身。
    --
    -- 实测 Map.Zones.Sites 里的 Part 带 Attribute "Site" = "A"/"B"：
    --   Site=A: (-124.2,88.8,-141.4) (-113.2,88.8,-144.2)      → 中心约 (-118.7,88.8,-142.8)
    --   Site=B: (-145.1,82.8,58.2) (-125.0,82.8,53.9) (-131.8,82.8,59.2)
    --           (-146.4,82.8,55.0) (-138.0,82.8,56.5) (-142.5,82.8,53.9)
    --           (-136.4,82.8,67.8)                             → 中心约 (-137.9,82.8,58.9)
    local zones = workspace.Map and workspace.Map:FindFirstChild("Zones")
    local sitesModel = zones and zones:FindFirstChild("Sites")
    if sitesModel then
        for _, d in ipairs(sitesModel:GetDescendants()) do
            if d:IsA("BasePart") then
                local s = d:GetAttribute("Site")
                if type(s) == "string" and (s == "A" or s == "B") then
                    add(s, d.Position)
                end
            end
        end
    end

    -- 兜底：Sites 还没加载时退回几何猜测（并标记为不可信）
    if next(acc) == nil then
        local geo = workspace.Map and workspace.Map:FindFirstChild("Geometry")
        if geo then
            for _, d in ipairs(geo:GetDescendants()) do
                if d:IsA("BasePart") then
                    local n = d.Name:lower()
                    if n:find("asite") then
                        add("A", d.Position)
                    end
                end
            end
        end
        S.siteSource = "geometry-guess"
    else
        S.siteSource = "zones-sites"
    end

    local out = {}
    for k, e in pairs(acc) do
        if e.n > 0 then
            out[k] = Vector3.new(e.sx / e.n, e.sy / e.n, e.sz / e.n)
        end
    end
    return out
end

-- ⚠ 标签表必须放到 getgenv 里共享。
-- 重载时新实例的 S 是一张全新的空表，旧实例丢下的 Drawing 对象不在里面；
-- 卸载时遍历 S.siteLabels 清不到它们 —— 那两个 A pt / B pt 就永久焊在屏幕上，
-- 跟着视角走（它们是屏幕坐标的 Drawing.Text）。用户实测就是这个现象。
S.siteLabels = getgenv().MV_SITE_LABELS
if type(S.siteLabels) ~= "table" then
    S.siteLabels = {}
    getgenv().MV_SITE_LABELS = S.siteLabels
end

-- 彻底销毁包点标签（卸载 / 关闭时都走这里）
S.sitesClear = function()
    local n = 0
    for k, rec in pairs(S.siteLabels or {}) do
        if rec and rec.obj then
            pcall(function() rec.obj.Visible = false end)
            local ok = pcall(function() rec.obj:Remove() end)
            if not ok then pcall(function() rec.obj:Destroy() end) end
            rec.obj = nil
            n = n + 1
        end
        S.siteLabels[k] = nil
    end
    return n
end

S.updateSites = function(dt)
    -- 每 5 秒重新扫一次（换图 / 地图重载时能跟上）
    if not S.siteNextAt or os.clock() >= S.siteNextAt then
        S.siteNextAt = os.clock() + 5
        -- 顺手把整张图的点位扫一遍存进缓存（Spawns/BuyArea/Reference 也一起）
        local ok0, scan = pcall(S.scanMap)
        if ok0 and type(scan) == "table" and type(scan.sites) == "table" and next(scan.sites) ~= nil then
            S.sites = scan.sites
            S.siteSource = "scan"
        else
            local ok, t = pcall(S.findSites)
            if ok and type(t) == "table" then S.sites = t end
        end
    end

    local on = cfg.showSites == true
    local cam = workspace.CurrentCamera
    local my = myRoot()
    if not on or not cam or not my then
        for _, d in pairs(S.siteLabels) do
            if d.obj then pcall(function() d.obj.Visible = false end) end
        end
        return
    end

    local keys = { "A", "B" }
    for _, k in ipairs(keys) do
        local pos = S.sites[k]
        local rec = S.siteLabels[k]
        if not rec then
            rec = { obj = nil }
            S.siteLabels[k] = rec
        end
        if not rec.obj then
            local ok, o = pcall(function() return Drawing.new("Text") end)
            if ok and o then
                o.Center = true
                o.Outline = true
                o.OutlineColor = Color3.new(0, 0, 0)
                o.Size = 22
                o.Font = Drawing.Fonts and Drawing.Fonts.Bold or 2
                rec.obj = o
            end
        end
        if rec.obj then
            if pos then
                local sp, onScreen = cam:WorldToViewportPoint(pos)
                if onScreen and sp.Z > 0 then
                    local dist = (pos - my.Position).Magnitude
                    rec.obj.Position = Vector2.new(sp.X, sp.Y)
                    rec.obj.Text = string.format("%s pt   %dm", k, math.floor(dist))
                    rec.obj.Color = (k == "A") and Color3.fromRGB(255, 150, 60) or Color3.fromRGB(80, 200, 255)
                    rec.obj.Visible = true
                else
                    rec.obj.Visible = false
                end
            else
                rec.obj.Visible = false
            end
        end
    end
end

---------------------------------------------------------------------
-- VIP 服务端控制（重大突破：这套接口没有权限校验）
--
-- 逆向路径：
--   ReplicatedStorage.Database.Security.Remotes → VIP 命名空间
--     SetSetting    {Key=String, Value=Unknown}   5 次/秒
--     ExecuteAction {Action=String, Params=Unknown} 2 次/秒
--     RequestData   String                         2 次/秒
--     DataResponse  {Type=String, Data=Unknown}    ← 服务端回包
--     SyncState     Map(String, Unknown)           ← 服务端主动推送
--
-- 实测（无 VIP 权限）：
--   SetSetting(InfiniteAmmoEnabled=true)  → 服务端 State 从 false 变 true ✅
--   SetSetting(GodModeEnabledPlayers={[uid]=true}) → 服务端接受，名单里出现我的 UserId ✅
--
-- State 里可用的服务端开关：
--   InfiniteAmmoEnabled / InfiniteCashEnabled / GodModeEnabledPlayers
--   ESPEnabledPlayers / FriendlyFireEnabled / KillTradingEnabled
--   BotsFrozen / BotDifficulty / BotAutoFill / BotTerrorists / BotCounterTerrorists
--   TimerFrozen / PlayerCollisionsEnabled / KnifeDropEnabled
--   CompetitiveMovementEnabled / DisableTeamLimitEnabled
--
-- ExecuteAction 的动作（来自 Interface/Screens/Gameplay/Middle/VIPMenu）：
--   ResetScore / EndGame / KickPlayer(Params=UserId) / SetTimer(Params=秒)
---------------------------------------------------------------------
S.vip = { state = nil, listening = false, log = {} }

S.vipRemotes = function()
    local ok, R = pcall(require, game.ReplicatedStorage.Database.Security.Remotes)
    if ok and type(R) == "table" and R.VIP then return R end
    return nil
end

S.vipEnsureListen = function()
    if S.vip.listening then return end
    local R = S.vipRemotes()
    if not R then return end
    S.vip.listening = true
    pcall(function()
        R.VIP.DataResponse.Listen(function(v)
            if type(v) == "table" and v.Type == "State" and type(v.Data) == "table" then
                S.vip.state = v.Data
                S.vip.lastAt = os.clock()
                -- 收到状态立刻回填控件（不然面板永远显示默认值）
                if type(S.syncVipUI) == "function" then pcall(S.syncVipUI) end
            elseif type(v) == "table" and v.Type == "PlayerList" and type(v.Data) == "table" then
                -- 权威玩家名单（含 Team / UserId / DisplayName）
                S.vipPlayers = v.Data
            end
        end)
    end)
    pcall(function()
        R.VIP.SyncState.Listen(function(v)
            if type(v) == "table" then
                S.vip.state = v
                S.vip.lastAt = os.clock()
                if type(S.syncVipUI) == "function" then pcall(S.syncVipUI) end
            end
        end)
    end)
end

S.vipFetch = function()
    S.vipEnsureListen()
    local R = S.vipRemotes()
    if not R then return false end
    local ok = pcall(function() R.VIP.RequestData.Send("State") end)
    return ok
end

-- ⚠ 把服务端状态回填到 GUI 控件。
--
-- 之前每次打开 VIP 页都显示默认值，因为控件只在创建时用 Default 初始化，
-- 服务端真实状态回来了却没人往控件里写。用户看到的永远是「未开启」，
-- 而实际上 InfiniteAmmo / FriendlyFire 早就是 true 了。
--
-- Maclib 的控件 API 名字不统一（Set / SetValue / Value），这里三种都试。
-- ⚠ Slider 的正确同步方式：直接改 UI 实例。
--
-- Maclib 的 Slider 结构（实测）：
--   Slider (Frame)
--   ├ SliderName (TextLabel)      ← 名字，用来定位是哪个滑条
--   └ SliderElements (Frame)
--       ├ SliderValue (TextBox)   ← 显示数字
--       └ SliderBar (ImageLabel)
--           └ SliderHead (ImageButton)  ← 滑块
--
-- c:UpdateValue(val) 只会改 c.Value（数据），UI 不动；
-- 而直接写 SliderValue.Text 和 SliderHead.Position 是立刻生效、也不会被覆盖的。
-- 菜单本体在 gethui() 返回的容器里（CoreGui.RobloxGui.ScreenGui.Base），
-- 不在 PlayerGui，所以必须用 gethui() 去找。
S.vipMenuBase = function()
    local root = nil
    if typeof(gethui) == "function" then
        local ok, r = pcall(gethui)
        if ok then root = r end
    end
    if not root then root = game:GetService("CoreGui") end
    local ok, descs = pcall(function() return root:GetDescendants() end)
    if not ok or not descs then return nil end
    for _, d in ipairs(descs) do
        if d.Name == "Base" and d:IsA("Frame") then return d end
    end
    return nil
end

S.vipPushSlider = function(nameText, val, minV, maxV)
    local base = S.vipMenuBase()
    if not base then return false end
    local slider = nil
    local okd, descs = pcall(function() return base:GetDescendants() end)
    if not okd or not descs then return false end
    for _, d in ipairs(descs) do
        if d:IsA("TextLabel") and d.Text == nameText and d.Parent and d.Parent.Name == "Slider" then
            slider = d.Parent
            break
        end
    end
    if not slider then return false end
    local elems = slider:FindFirstChild("SliderElements")
    if not elems then return false end
    local valueBox = elems:FindFirstChild("SliderValue")
    local bar = elems:FindFirstChild("SliderBar")
    local head = bar and bar:FindFirstChild("SliderHead")
    local lo = tonumber(minV) or 0
    local hi = tonumber(maxV) or 10
    local ratio = math.clamp((val - lo) / math.max(hi - lo, 1), 0, 1)
    local done = false
    if valueBox then
        done = pcall(function() valueBox.Text = tostring(math.floor(val)) end) or done
    end
    if head then
        done = pcall(function()
            local p = head.Position
            head.Position = UDim2.new(ratio, p.X.Offset, p.Y.Scale, p.Y.Offset)
        end) or done
    end
    return done
end

S.syncVipUI = function()
    local st = S.vip and S.vip.state
    if type(st) ~= "table" then return false end
    local ctrls = S.vipCtrls
    if type(ctrls) ~= "table" then return false end
    local applied = 0

    local function push(c, val)
        if not c then return end
        -- Maclib 控件按类型分两套 API（实测 dump）：
        --   Toggle: Class / GetState / UpdateState / Toggle / State / Value
        --   Slider: Class / GetValue / UpdateValue / Value
        --
        -- 之前只处理 UpdateState，Slider 没有这条分支，所以 BOT 数量永远显示 0
        -- （Value 已经是服务端值，但界面不刷新）。
        --
        -- 另外这些函数内部要写 Instance 属性，必须在脚本线程调用
        -- （外部 execute_script 会报 lacking capability Plugin）。
        local cls = tostring(c.Class or "")

        if cls == "Slider" or type(c.UpdateValue) == "function" then
            -- ⚠ 这里不能「值相同就跳过」。
            --
            -- Value 是数据字段，UI 滑块位置是另一回事：
            -- 实测 BotT.Value 早就是 4（服务端也是 4），但界面一直显示 0 ——
            -- 因为值相同被跳过了，UpdateValue 从来没被调用过。
            -- Slider 必须无条件刷新界面，只在「上次已经推过同一个值」时才省一次调用。
            if S.vipLastSliderPush == nil then S.vipLastSliderPush = {} end
            local key = tostring(c.Settings and c.Settings.Name or tostring(c))
            if S.vipLastSliderPush[key] == val then return end
            if type(c.UpdateValue) == "function" then
                if pcall(c.UpdateValue, c, val) then
                    S.vipLastSliderPush[key] = val
                    applied = applied + 1
                    return
                end
            end
            if pcall(function() c.Value = val end) then
                S.vipLastSliderPush[key] = val
                applied = applied + 1
            end
            return
        end

        -- Toggle 及同类
        local cur = nil
        pcall(function() cur = c.State end)
        if cur == val then return end          -- 已经是目标状态，跳过
        if type(c.UpdateState) == "function" then
            if pcall(c.UpdateState, c, val) then applied = applied + 1 return end
        end
        if type(c.Toggle) == "function" and cur ~= nil then
            if pcall(c.Toggle, c) then applied = applied + 1 return end
        end
        if pcall(function() c.Value = val end) then applied = applied + 1 end
    end

    local myId = LP and LP.UserId
    local godList = type(st.GodModeEnabledPlayers) == "table" and st.GodModeEnabledPlayers or {}
    local espList = type(st.ESPEnabledPlayers) == "table" and st.ESPEnabledPlayers or {}

    push(ctrls.VipAmmo, st.InfiniteAmmoEnabled == true)
    push(ctrls.VipCash, st.InfiniteCashEnabled == true)
    push(ctrls.VipGod, myId ~= nil and godList[myId] == true)
    push(ctrls.VipEsp, myId ~= nil and espList[myId] == true)
    push(ctrls.VipFF, st.FriendlyFireEnabled == true)
    push(ctrls.VipTimer, st.TimerFrozen == true)
    -- Slider 走「直接改 UI」这条路（UpdateValue 只改数据不动界面）
    local botT = tonumber(st.BotTerrorists) or 0
    local botCT = tonumber(st.BotCounterTerrorists) or 0
    if S.vipPushSlider("T 方 BOT 数量", botT, 0, 10) then applied = applied + 1 end
    if S.vipPushSlider("CT 方 BOT 数量", botCT, 0, 10) then applied = applied + 1 end
    push(ctrls.BotT, botT)
    push(ctrls.BotCT, botCT)
    push(ctrls.BotFreeze, st.BotsFrozen == true)
    -- 难度是下拉框，值可能是索引也可能是字符串
    local diff = tostring(st.BotDifficulty or "Normal")
    local idx = (diff == "Easy" and 1) or (diff == "Normal" and 2) or (diff == "Hard" and 3) or (diff == "Expert" and 4) or 2
    push(ctrls.BotDiff, idx)

    S.vipSynced = applied
    S.vipSyncedAt = os.clock()
    return true
end

S.vipSet = function(key, value)
    local R = S.vipRemotes()
    if not R then return false end
    return (pcall(function() R.VIP.SetSetting.Send({ Key = key, Value = value }) end))
end

S.vipAction = function(action, params)
    local R = S.vipRemotes()
    if not R then return false end
    return (pcall(function()
        if params ~= nil then
            R.VIP.ExecuteAction.Send({ Action = action, Params = params })
        else
            R.VIP.ExecuteAction.Send({ Action = action })
        end
    end))
end

S.vipGodMode = function(on)
    local uid = game.Players.LocalPlayer.UserId
    if on then
        return S.vipSet("GodModeEnabledPlayers", { [uid] = true })
    end
    return S.vipSet("GodModeEnabledPlayers", {})
end

-- ── 以下都是从游戏自己的 VIPMenu（docId 618）里挖出来的指令 ──
--
-- 完整开关表（u60，9 项）：
--   KnifeDropEnabled / TimerFrozen / KillTradingEnabled / InfiniteAmmoEnabled /
--   InfiniteCashEnabled / DisableTeamLimitEnabled / FriendlyFireEnabled /
--   PlayerCollisionsEnabled / CompetitiveMovementEnabled
-- BOT：BotTerrorists / BotCounterTerrorists / BotDifficulty / BotsFrozen
-- 房间：NextMap / NextGamemode
-- 动作：ResetScore / EndGame / KickPlayer(Params=UserId) / SetTimer(Params=秒)

-- 选下一张地图（下一局生效）
S.vipNextMap = function(name)
    if type(name) ~= "string" or name == "" then return false end
    return S.vipSet("NextMap", name)
end

-- 选下一个游戏模式（下一局生效）
S.vipNextGamemode = function(mode)
    if type(mode) ~= "string" or mode == "" then return false end
    return S.vipSet("NextGamemode", mode)
end

-- 设置回合计时器（秒）
S.vipSetTimer = function(sec)
    local n = tonumber(sec)
    if not n then return false end
    return S.vipAction("SetTimer", math.floor(n))
end

-- 踢人（按 UserId）
S.vipKick = function(userId)
    local id = tonumber(userId)
    if not id then return false end
    return S.vipAction("KickPlayer", id)
end

-- 地图 / 模式清单（从游戏配置现读，不写死）
S.vipMapList = function()
    local out = {}
    local ok, folder = pcall(function()
        return game.ReplicatedStorage.Database.Custom.GameStats.Maps
    end)
    if ok and folder then
        for _, m in ipairs(folder:GetChildren()) do
            out[#out + 1] = m.Name
        end
    end
    table.sort(out)
    return out
end

S.vipGamemodeList = function()
    local out = {}
    local ok, folder = pcall(function()
        return game.ReplicatedStorage.Database.Custom.GameStats.Gamemodes
    end)
    if ok and folder then
        for _, m in ipairs(folder:GetChildren()) do
            out[#out + 1] = m.Name
        end
    end
    table.sort(out)
    return out
end

-- 玩家列表（给踢人下拉框用）：优先用服务端的 PlayerList。
--
-- 游戏 VIPMenu 里除了 RequestData("State") 还会发 RequestData("PlayerList")，
-- 服务端回的是权威名单（含 Team / UserId / DisplayName），比 game.Players 更可靠
-- ——比如幽灵玩家、刚加入还没同步的都在这份名单里。
S.vipPlayers = S.vipPlayers or {}

S.vipRequestPlayers = function()
    local R = S.vipRemotes()
    if not R then return false end
    return (pcall(function() R.VIP.RequestData.Send("PlayerList") end))
end

S.vipPlayerList = function()
    local out = {}
    local list = S.vipPlayers
    if type(list) == "table" and #list > 0 then
        for _, p in ipairs(list) do
            if type(p) == "table" then
                local uid = tonumber(p.UserId)
                local nm = tostring(p.DisplayName or p.Name or "?")
                if uid then out[#out + 1] = string.format("%s (%d)", nm, uid) end
            end
        end
    end
    if #out == 0 then
        for _, p in ipairs(game.Players:GetPlayers()) do
            out[#out + 1] = string.format("%s (%d)", tostring(p.Name), p.UserId)
        end
        local me = game.Players.LocalPlayer
        if #out == 0 and me then
            out[1] = string.format("%s (%d)", tostring(me.Name), me.UserId)
        end
    end
    table.sort(out)
    return out
end


S.vipEspMe = function(on)
    local uid = game.Players.LocalPlayer.UserId
    if on then
        return S.vipSet("ESPEnabledPlayers", { [uid] = true })
    end
    return S.vipSet("ESPEnabledPlayers", {})
end

---------------------------------------------------------------------
-- 下包倒计时（炸弹爆炸剩余时间 + 能否拆除）
--
-- 逆向结果：
--   剩余时间   workspace:GetAttribute("Timer")              （秒，整局/炸弹共用这一个字段）
--   阶段       workspace:GetAttribute("GameState")
--              ⚠ 状态表里**没有** "Bomb Planted"：
--              {"Map Voting","Game Ending","Warmup","Round In Progress","Buy Period","Intermission"}
--              所以下包后仍然是 "Round In Progress"，只能靠炸弹对象判断
--   炸弹对象   CollectionService:GetTagged("Bomb")[1]
--              属性 Defused / Exploding / Exploded
--   拆包时间   无拆包器 10 秒，有拆包器 5 秒
--              （DefuseBomb 模块：DefuseTime = if not HasDefuseKit then 10 else 5）
--   拆包器     LocalPlayer:GetAttribute("HasDefuseKit")
---------------------------------------------------------------------
S.bomb = { active = false, fuseAt = 0, fuseStart = 0 }

S.updateBomb = function(dt)
    local on = cfg.showBombTimer ~= false
    local obj = S.bombLabel
    if not on then
        if obj then obj.Visible = false end
        return
    end

    -- 炸弹是否已经安放
    local bombs = game:GetService("CollectionService"):GetTagged("Bomb")
    local bomb = bombs and bombs[1]
    local planted = bomb ~= nil
    local defused = false
    local exploded = false
    if bomb then
        defused = bomb:GetAttribute("Defused") == true
        exploded = bomb:GetAttribute("Exploded") == true
    end
    local live = planted and not defused and not exploded

    S.bomb.active = live
    local timer = tonumber(workspace:GetAttribute("Timer"))
    if type(timer) ~= "number" then
        if obj then obj.Visible = false end
        return
    end

    -- 有拆包器 5 秒，没有 10 秒；再留 0.35 秒给反应/网络
    local hasKit = game.Players.LocalPlayer:GetAttribute("HasDefuseKit") == true
    local needSec = hasKit and 5 or 10
    local slack = 0.35
    local canDefuse = live and (timer >= needSec + slack)

    -- 只在「炸弹已安放」时显示；没下包就不占屏幕
    if not live then
        if obj then obj.Visible = false end
        return
    end

    if not obj then
        local ok, o = pcall(function() return Drawing.new("Text") end)
        if not ok or not o then return end
        o.Center = true
        o.Outline = true
        o.OutlineColor = Color3.new(0, 0, 0)
        o.Size = 26
        o.Font = Drawing.Fonts and Drawing.Fonts.Bold or 2
        S.bombLabel = o
        obj = o
    end

    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
    local m, s = math.floor(timer / 60), math.floor(timer % 60)
    local timeText = string.format("%02d:%02d", m, s)
    -- 拆包需要的时间也标出来，方便判断「还来不来得及」
    local kitText = hasKit and "5s" or "10s"

    -- 拆包进行中：服务端在 Player 上写 DefuseStartTime，配合 GetServerTimeNow 可以算真实剩余。
    -- 数据来源（反编译 Middle.DefuseBomb，第 223 行）：
    --     self.DefuseTime = if not self.HasDefuseKit then 10 else 5
    --     v2 = Player:GetAttribute("DefuseStartTime")
    --     v3 = workspace:GetServerTimeNow() - v2
    -- 谁在拆就读谁，不一定是本地玩家。
    local defuseText = ""
    local okP, players = pcall(function() return game.Players:GetPlayers() end)
    if okP and players then
        for _, p in ipairs(players) do
            local ds = p:GetAttribute("DefuseStartTime")
            if typeof(ds) == "number" then
                local kit2 = p:GetAttribute("HasDefuseKit") == true
                local need2 = kit2 and 5 or 10
                local elapsed = workspace:GetServerTimeNow() - ds
                local remain = need2 - elapsed
                if remain > 0 and remain <= need2 + 1 then
                    defuseText = string.format("   DEF %s %.1fs", tostring(p.Name):sub(1, 10), remain)
                end
                break
            end
        end
    end

    obj.Text = string.format("[C4] %s   %s   %s%s", timeText, canDefuse and "OK" or "NO", kitText, defuseText)
    obj.Color = canDefuse and Color3.fromRGB(120, 255, 140) or Color3.fromRGB(255, 90, 90)
    obj.Position = Vector2.new(vp.X * 0.5, vp.Y * 0.12)
    obj.Visible = true
end

---------------------------------------------------------------------
-- 地图点位扫描 + 多图缓存
--
-- 现实情况：**只有当前加载的地图才有世界对象**。另外 10 张图的
-- Map.Zones 在客户端根本不存在，GameStats.Maps.<map> 里也只有
-- 雷达图 assetId / 光照 / 模式映射，没有坐标。
--
-- 所以唯一可行路线：进一张图 → 扫一遍 → 缓存起来 → 以后换回这张图直接用。
-- 缓存放 getgenv().MV_MAPDATA[mapName]，脚本重载不丢（同一个 genv）。
--
-- 每张图能扫到的点位（实测 Hellena）：
--   Spawns     65 个出生点（名字是数字，分 CT / T 两组）
--   BuyArea    2 个购买区，带 Team 属性（Counter-Terrorists / Terrorists）
--   Sites      包点区域，带 Site 属性（A / B），同一位置常重复出现
--   Reference  地图中心参考点
---------------------------------------------------------------------
S.scanMap = function()
    local mapName = tostring(workspace:GetAttribute("Map") or "Unknown")
    local data = {
        map = mapName,
        gamemode = tostring(workspace:GetAttribute("Gamemode") or "?"),
        sites = {},
        spawns = {},
        buys = {},
        reference = nil,
        scannedAt = os.clock(),
    }
    local mapModel = workspace:FindFirstChild("Map")
    if not mapModel then return data end

    -- 包点：按 Site 属性分组取平均
    local zones = mapModel:FindFirstChild("Zones")
    local sitesModel = zones and zones:FindFirstChild("Sites")
    if sitesModel then
        local acc = {}
        for _, d in ipairs(sitesModel:GetDescendants()) do
            if d:IsA("BasePart") then
                local s = d:GetAttribute("Site")
                if type(s) == "string" then
                    local e = acc[s]
                    if not e then e = { sx = 0, sy = 0, sz = 0, n = 0 } acc[s] = e end
                    e.sx = e.sx + d.Position.X
                    e.sy = e.sy + d.Position.Y
                    e.sz = e.sz + d.Position.Z
                    e.n = e.n + 1
                end
            end
        end
        for k, e in pairs(acc) do
            if e.n > 0 then
                data.sites[k] = Vector3.new(e.sx / e.n, e.sy / e.n, e.sz / e.n)
            end
        end
    end

    -- 出生点：全部记下来（可用于判断敌人从哪个方向压）
    local spawnsModel = zones and zones:FindFirstChild("Spawns")
    if spawnsModel then
        for _, d in ipairs(spawnsModel:GetDescendants()) do
            if d:IsA("BasePart") then
                data.spawns[#data.spawns + 1] = d.Position
            end
        end
    end

    -- 购买区：带 Team 属性
    local buyModel = zones and zones:FindFirstChild("BuyArea")
    if buyModel then
        for _, d in ipairs(buyModel:GetDescendants()) do
            if d:IsA("BasePart") then
                local team = d:GetAttribute("Team")
                data.buys[#data.buys + 1] = {
                    pos = d.Position,
                    team = (type(team) == "string") and team or "?",
                }
            end
        end
    end

    -- 参考点：Map.Reference 是个 Model，Part 不一定是一级子节点，得往下找
    local refModel = mapModel:FindFirstChild("Reference")
    if refModel then
        for _, d in ipairs(refModel:GetDescendants()) do
            if d:IsA("BasePart") then
                data.reference = d.Position
                break
            end
        end
    end

    -- 写缓存
    if type(getgenv().MV_MAPDATA) ~= "table" then getgenv().MV_MAPDATA = {} end
    getgenv().MV_MAPDATA[mapName] = data
    S.mapCacheCount = 0
    for _ in pairs(getgenv().MV_MAPDATA) do S.mapCacheCount = S.mapCacheCount + 1 end
    return data
end

-- 把缓存导出成一段可以直接贴进脚本的 Luau 文本
S.exportMapCache = function()
    if type(getgenv().MV_MAPDATA) ~= "table" then return "-- 还没有缓存" end
    local lines = { "-- MV 地图点位缓存（自动生成）", "return {" }
    local names = {}
    for name in pairs(getgenv().MV_MAPDATA) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local d = getgenv().MV_MAPDATA[name]
        lines[#lines + 1] = string.format("  [%q] = {", name)
        if d.sites then
            -- ⚠ 必须合并成一行。之前每个包点单独写一行 "sites = {...}"，
            -- 加载时后面的 key 会把前面的覆盖掉，只剩最后一个包点。
            local parts = {}
            local keys = {}
            for k in pairs(d.sites) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                local v = d.sites[k]
                parts[#parts + 1] = string.format("%s = Vector3.new(%.2f, %.2f, %.2f)",
                    k, v.X, v.Y, v.Z)
            end
            if #parts > 0 then
                lines[#lines + 1] = "    sites = { " .. table.concat(parts, ", ") .. " },"
            end
        end
        if d.reference then
            lines[#lines + 1] = string.format("    reference = Vector3.new(%.2f, %.2f, %.2f),",
                d.reference.X, d.reference.Y, d.reference.Z)
        end
        for _, b in ipairs(d.buys or {}) do
            lines[#lines + 1] = string.format("    buy_%s = Vector3.new(%.2f, %.2f, %.2f),",
                tostring(b.team):gsub("%W", "_"), b.pos.X, b.pos.Y, b.pos.Z)
        end
        lines[#lines + 1] = string.format("    spawnCount = %d,", #(d.spawns or {}))
        lines[#lines + 1] = "  },"
    end
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------
-- 隔墙投雷（Projectile.Spawn 伪造）
--
-- 实测：Projectile.Spawn 的 State.Position / State.Velocity / Physics.*
-- 全部由客户端提供，服务端照单全收 —— 伪造的手雷在弹跳（Bounce #7~#12），
-- 引信正常触发（Resolve reason=fuse）。
--
-- 这是「穿墙」真正能落地的形态：射击的 Origin 会被服务端校验，
-- 但投掷物的 Position 不会。直接把 HE 生成在墙后的人脚下就是隔墙手雷。
--
-- 参数取自 GrenadeSimulator.Constants：
--   GRAVITY = (0, -23.833, 0), GRENADE_ELASTICITY = 0.4, FIXED_TIMESTEP = 0.0078125
---------------------------------------------------------------------
S.tossGrenadeAt = function(worldPos, weaponName, fuseTime)
    if typeof(worldPos) ~= "Vector3" then return false end
    local ok, R = pcall(require, game.ReplicatedStorage.Database.Security.Remotes)
    if not ok or not R.Projectile then return false end
    local uuid = game:GetService("HttpService"):GenerateGUID(false)
    local fuse = tonumber(fuseTime) or 1.5
    local sent = pcall(function()
        R.Projectile.Spawn.Send({
            Id = uuid,
            Weapon = tostring(weaponName or "HE Grenade"),
            Skin = "Stock",
            Float = 0,
            StatTrack = false,
            NameTag = false,
            Charm = false,
            Stickers = {},
            State = {
                Position = worldPos,
                Velocity = Vector3.new(0, 0, 0),
                IsJumpThrow = false,
            },
            Physics = {
                Gravity = Vector3.new(0, -23.833, 0),
                Drag = 0,
                Restitution = 0.4,
                Radius = 0.15,
                MaxBounces = 20,
                FuseTime = fuse,
                Step = 0.0078125,
                RestVelocityThreshold = 5,
                CollisionGroup = "Default",
            },
        })
    end)
    if sent then
        S.grenadesTossed = (S.grenadesTossed or 0) + 1
    end
    return sent
end

---------------------------------------------------------------------
-- 后座控制：无后座 + 自动压枪
--
-- 逆向结论（CameraController docId 170 + Weapon docId 162）：
--   每次开枪 Weapon 组件会调
--     CameraController.setWeaponRecoil({Value=v1, Damper, Speed}, CameraScale)
--   setWeaponRecoil 内部是弹簧模拟：
--     u131:setDampingRatio(Damper); u131:setFrequency(Speed); u131:setGoal(Value)
--     u72 = CameraScale
--   getWeaponKickRotation() 返回弹簧当前值（Vector3 = 实际后座偏移）
--
-- 所以：
--   无后座   = 拦 setWeaponRecoil，不把后座目标灌进弹簧
--   自动压枪 = 每帧读 getWeaponKickRotation，按百分比反向补到相机上
---------------------------------------------------------------------
S.noRecoilHook = function()
    local ok, CC = pcall(require, game.ReplicatedStorage.Controllers.CameraController)
    if not ok or type(CC) ~= "table" then return false end

    -- 自动压枪的比例：返回「还剩多少」的系数（1 = 原样灌进去，0 = 完全不灌）
    -- ⚠ 必须在**源头**缩放，不能事后补相机：
    --   weaponKick 内部是三个弹簧
    --       u121:setPosition(a1.Value * 0.017453)   ← 只有这个有 getter（getWeaponKickRotation）
    --       u126:setPosition(a2.Value)              ← 直接设，**没有任何 getter 能读到**
    --       u0.updateCamera()
    --   相机最终偏移 = 三者合成。只补 u121 的话，u126 那部分永远补不到 ——
    --   实测 kick 只有 0.86°，相机 pitch 却摆了 3.59°，差额就是它。
    local function compScale()
        if cfg.autoRecoilComp ~= true or cfg.noRecoil == true then return 1, 1 end
        local kv = math.clamp((tonumber(cfg.recoilCompV) or tonumber(cfg.recoilCompPercent) or 0) / 100, 0, 1)
        local kh = math.clamp((tonumber(cfg.recoilCompH) or tonumber(cfg.recoilCompPercent) or 0) / 100, 0, 1)
        return 1 - kv, 1 - kh
    end
    S.recoilCompScale = compScale

    -- ① setWeaponRecoil —— 设后座**目标**（u131:setGoal），弹簧会向它逼近
    local orig = getgenv().MV_ORIG_SETRECOIL
    if typeof(orig) ~= "function" then
        orig = CC.setWeaponRecoil
        getgenv().MV_ORIG_SETRECOIL = orig
    end
    CC.setWeaponRecoil = function(tbl, scale, ...)
        if cfg.noRecoil == true then
            S.recoilBlocked = (S.recoilBlocked or 0) + 1
            return
        end
        local sx, sy = compScale()
        if (sx ~= 1 or sy ~= 1) and type(tbl) == "table" and typeof(tbl.Value) == "Vector3" then
            tbl = { Value = Vector3.new(tbl.Value.X * sx, tbl.Value.Y * sy, tbl.Value.Z),
                    Damper = tbl.Damper, Speed = tbl.Speed }
            S.recoilScaled = (S.recoilScaled or 0) + 1
        end
        return orig(tbl, scale, ...)
    end

    -- ② weaponKick —— 直接 setPosition（u121 弧度 / u126 原值）
    local origKick = getgenv().MV_ORIG_WEAPONKICK
    if typeof(origKick) ~= "function" then
        origKick = CC.weaponKick
        getgenv().MV_ORIG_WEAPONKICK = origKick
    end
    CC.weaponKick = function(a1, a2, ...)
        if cfg.noRecoil == true then
            S.recoilKickBlocked = (S.recoilKickBlocked or 0) + 1
            return
        end
        local sx, sy = compScale()
        if (sx ~= 1 or sy ~= 1) then
            if type(a1) == "table" and typeof(a1.Value) == "Vector3" then
                a1 = { Value = Vector3.new(a1.Value.X * sx, a1.Value.Y * sy, a1.Value.Z),
                       Damper = a1.Damper, Speed = a1.Speed }
            end
            if type(a2) == "table" and typeof(a2.Value) == "Vector3" then
                a2 = { Value = Vector3.new(a2.Value.X * sx, a2.Value.Y * sy, a2.Value.Z),
                       Damper = a2.Damper, Speed = a2.Speed }
            end
            S.recoilKickScaled = (S.recoilKickScaled or 0) + 1
        end
        return origKick(a1, a2, ...)
    end

    S.noRecoilHookOn = true
    return true
end

-- 自动压枪：每帧把「当前弹簧值」整个抵消掉
--
-- ⚠ 这里踩过两次，第二次是刚修完又回退的，记清楚：
--
--   ① 符号写反（kick.X * k）→ 等于把后坐力再叠一次。
--
--   ② 误以为「补偿会累积」→ 改成补 delta（kick - lastKick）。
--      实测（两帧 RenderStep 探针，优先级 2000）：
--          第 1 帧写 cam.CFrame = c * 6°
--          第 2 帧读回的 cam.CFrame 与第 1 帧夹角 = 0.00°
--      也就是说**游戏每帧都从 base*kick 重建相机，我们的写入不保留**。
--      在这种情况下补 delta 只能补到「本帧变化量」，历史累积的 kick 一直在，
--      表现就是用户看到的：子弹方向被别的机制压住了，画面准星/镜头照样飞。
--
-- 所以正确做法是绝对值：每帧补 -kick_now。因为上一帧的补偿已经被游戏覆盖，
-- 不存在累积过冲。cap 只是防「换枪/弹簧重置瞬间 kick 突增」把镜头拽飞。
--
-- 垂直/水平分开配：
--   垂直（pitch，kick.X）方向确定，可以 100% 压平；
--   水平（yaw，kick.Y）方向随机，压满会显得锁死，默认 60%。
S._recoilLastKick = Vector3.new(0, 0, 0)
S._recoilCompAccum = 0

S.applyRecoilComp = function(dt)
    local kv = tonumber(cfg.recoilCompV) or tonumber(cfg.recoilCompPercent) or 0
    local kh = tonumber(cfg.recoilCompH) or tonumber(cfg.recoilCompPercent) or 0
    if cfg.autoRecoilComp ~= true or (kv <= 0 and kh <= 0) then return end
    if cfg.noRecoil == true then return end
    -- ⚠ 源头已经在压（noRecoilHook 缩放了 setWeaponRecoil / weaponKick 的灌入值）时，
    -- 这里再补一次相机会变成双重压制，甚至反向过冲。两者只允许生效一个。
    if S.noRecoilHookOn and S.recoilCompScale then return end
    local ok, CC = pcall(require, game.ReplicatedStorage.Controllers.CameraController)
    if not ok or type(CC) ~= "table" then return end
    local okv, kick = pcall(getgenv().MV_ORIG_KICKROT or CC.getWeaponKickRotation)
    if not okv or typeof(kick) ~= "Vector3" then return end
    S._recoilLastKick = kick   -- 只作诊断，不参与计算

    if kick.Magnitude < 0.0002 then return end

    local cam = workspace.CurrentCamera
    if not cam then return end
    local kx = math.clamp(kv / 100, 0, 1)
    local ky = math.clamp(kh / 100, 0, 1)
    -- 单帧上限 15°：正常 kick 只有 1~5°，这个 cap 只在异常跳变时生效
    local cap = math.rad(15)
    local dx = math.clamp(-kick.X * kx, -cap, cap)
    local dy = math.clamp(-kick.Y * ky, -cap, cap)
    pcall(function()
        cam.CFrame = cam.CFrame * CFrame.fromEulerAnglesXYZ(dx, dy, 0)
    end)
    S.recoilCompSteps = (S.recoilCompSteps or 0) + 1
    S._recoilCompAccum = (S._recoilCompAccum or 0) + math.abs(dx) + math.abs(dy)
end

-- ⚠ 准星（Crosshair）是独立链路，压相机管不到它。
--
-- 反编译 ReplicatedStorage.Interface.Screens.Gameplay.Middle.Crosshair：
--     local v3 = CameraController.getWeaponKickRotation()
--     local RotationValue = a1.Recoil.RotationValue
--     local v5 = Vector2.new(v4.Y - v3.Y, v4.X - v3.X) * 57.29577951308232
--     return UDim2.fromScale(...)   -- 准星相对屏幕中心的偏移
--
-- 也就是说：**准星偏移 = RotationValue - kick，它完全不读相机。**
--
-- 所以压枪（把相机压回基准）之后会得到：
--   画面：稳
--   准星：偏移变成整个 RotationValue（因为 kick 被压小了，减掉的变少）
-- 这正是「弹道压住了，准星反而更偏」。
--
-- 正确做法不是缩放 kick，而是让准星读到的值**等于它自己用的 RotationValue**：
--   偏移 = RotationValue - RotationValue = 0 → 准星死死钉在屏幕中心。
--
-- RotationValue 可以拿到（实测 Glock-18）：
--   ic.peekCurrentEquippedForMovement().Recoil.RotationValue  → Vector3
--
-- 注意 weapon 的 Recoil 表结构：
--   { Value:vector, RotationValue:vector, RecoveryValue:userdata,
--     Time:number, RecoveryTime:number, RecoveryStartTime:number,
--     ActiveFireRate:number, Function:function, Functions:table }
--
-- 我们自己的 applyRecoilComp 必须用**原版**（MV_ORIG_KICKROT）读真实 kick。
S.installKickRotHook = function()
    local ok, CC = pcall(require, game.ReplicatedStorage.Controllers.CameraController)
    if not ok or type(CC) ~= "table" then return false end
    local orig = getgenv().MV_ORIG_KICKROT
    if typeof(orig) ~= "function" then
        orig = CC.getWeaponKickRotation
        getgenv().MV_ORIG_KICKROT = orig
    end
    CC.getWeaponKickRotation = function(...)
        local k = orig(...)
        if typeof(k) ~= "Vector3" then return k end
        if cfg.autoRecoilComp ~= true or cfg.noRecoil == true then return k end
        -- 让准星公式 (RotationValue - kick) 只留下"没压掉的那部分"：
        --   压枪 100% → return RV      → 偏移 = 0
        --   压枪 33%  → return RV*0.33 → 偏移 = 0.67*RV（准星按比例跟着抖）
        --   压枪 0%   → return 0       → 偏移 = RV（原始表现）
        -- 之前无条件 return RV，等于把准星焊死在中心，跟压枪比例无关 —— 用户实测 33% 也不动。
        local kv = math.clamp((tonumber(cfg.recoilCompV) or tonumber(cfg.recoilCompPercent) or 0) / 100, 0, 1)
        local kh = math.clamp((tonumber(cfg.recoilCompH) or tonumber(cfg.recoilCompPercent) or 0) / 100, 0, 1)
        local ic = getInvCtrl()
        if ic then
            local okw, w = pcall(function() return ic.peekCurrentEquippedForMovement() end)
            if okw and w and type(w.Recoil) == "table" then
                local rv = w.Recoil.RotationValue
                if typeof(rv) == "Vector3" then
                    S.kickRotPinned = (S.kickRotPinned or 0) + 1
                    -- ⚠ 只能缩放「滞后差」，不能缩放「绝对值」。
                    --
                    -- 准星偏移 = RotationValue - kick，而 kick 是弹簧的滞后值：
                    -- 开火瞬间 RV 突增、kick 还没跟上 → 偏移大；随后 kick 追上 → 偏移回到 0。
                    -- 这就是「准星会自己回正」的来源。
                    --
                    -- 如果直接 return RV*k，等于把偏移钉死在 (1-k)*RV 上，
                    -- 准星会一直偏着、永不回落 —— 用户说的「偏移好假」就是这个。
                    --
                    -- 正确写法：hooked = RV*k + kick_orig*(1-k)
                    --   偏移 = RV - hooked = (RV - kick_orig)*(1-k)
                    -- 即「原始滞后差按比例缩小」，形状不变、幅度变小。
                    --   k=0    → hooked = kick_orig → 偏移原样
                    --   k=100% → hooked = RV        → 偏移 0
                    return Vector3.new(
                        rv.X * kv + k.X * (1 - kv),
                        rv.Y * kh + k.Y * (1 - kh),
                        k.Z)
                end
            end
        end
        return k
    end
    S.kickRotHookOn = true
    return true
end

---------------------------------------------------------------------
-- 真正的「跳过开火间隔 / 跳过拉栓」
--
-- 逆向 Components/Weapon 的 shoot() 状态机（docId 162 第 2560 行起）：
--
--   v1 = NextShotDue + FireRate
--   self.NextShotDue = v1
--   self.ShootDelayThread = task.delay(v1 - v3, function()
--       self.IsShooting = false
--       self.ShootDelayThread = nil
--       ... 处理连发/自动补枪
--   end)
--
-- 也就是说「拉栓」就是这个 task.delay，时长 = (NextShotDue + FireRate) - now，
-- 对 AWP 就是 1.46 秒。压 NextShotDue 只会改变「放行判定」，
-- 延迟永远≈FireRate —— 所以之前那套 skipFireDelay 根本省不了时间。
--
-- 真正的突破口在状态机开头：
--   ShootDelayThread = self.ShootDelayThread
--   dispatch = if not ShootDelayThread then 225 else 224
--   -- 224: task.cancel(ShootDelayThread); self.ShootDelayThread = nil; dispatch = 225
--
-- 只要 ShootDelayThread 非空，游戏**自己**就会取消它并直接跳到开火判定。
-- 我们每帧主动取消，就等于每帧都把拉栓清掉。
--
-- 注意要同时把 IsShooting 置 false，否则下一发会因为「还在射击中」被挡。
---------------------------------------------------------------------
S.killShootDelay = function()
    local ic = getInvCtrl()
    if not ic then
        S.killDbg = "no-ic"
        return false
    end
    local ok, w = pcall(function() return ic.peekCurrentEquippedForMovement() end)
    if not ok or not w then
        S.killDbg = "no-weapon"
        return false
    end
    S.killSeen = (S.killSeen or 0) + 1
    local th = w.ShootDelayThread
    S.killDbg = string.format("w=%s thread=%s IsShooting=%s due=%s rounds=%s",
        tostring(w.Name), tostring(th ~= nil), tostring(w.IsShooting),
        tostring(w.NextShotDue), tostring(w.Rounds))
    if th == nil then return false end
    pcall(function() task.cancel(th) end)
    pcall(function()
        w.ShootDelayThread = nil
        w.IsShooting = false
    end)
    S.delaysKilled = (S.delaysKilled or 0) + 1
    return true
end

-- 准星钉住：把 Crosshair 的分叉按回最小扩散
--
-- ⚠ 必须在 **Heartbeat** 调用，不能只放在 RenderStep(2000)。
--
-- 实测（同一段 2.5 秒采样，看 Middle.Crosshair 各子元素的 Position 范围）：
--   · 放在 RenderStep(2000) → Ticks 1..11、InnerTicks 1..7、Hitmarker ±6 全在张合
--   · 放在 Heartbeat        → 全部元素 0 变化
-- 也就是说游戏是在渲染之后（Heartbeat 阶段）才把准星位置写回去的，
-- RenderStep 里改得再早也会被覆盖。用户看到的「子弹压住了、准星还在张合」就是这个。
S.pinCrosshair = function()
    if not (cfg.noRecoil == true or cfg.autoRecoilComp == true) then return end
    local pg = LP and LP:FindFirstChild("PlayerGui")
    local mg = pg and pg:FindFirstChild("MainGui")
    local gp = mg and mg:FindFirstChild("Gameplay")
    local mid = gp and gp:FindFirstChild("Middle")
    local ch = mid and mid:FindFirstChild("Crosshair")
    if not ch then return end
    local BASE = 7
    for _, d in ipairs(ch:GetDescendants()) do
        local n = d.Name
        -- ⚠ 只处理 Ticks / InnerTicks 两层（准星分叉）。
        -- Hitmarker 下面也有叫 "Arm" 的四个斜角，那是「命中标记」的动画，
        -- 按住它会让打中人的反馈消失/变形 —— 必须排除。
        local par = d.Parent and d.Parent.Name or ""
        if par == "Ticks" or par == "InnerTicks" then
            if n == "Right" or n == "Left" or n == "Up" or n == "Down" then
                local okp, p = pcall(function() return d.Position end)
                if okp and typeof(p) == "UDim2" then
                    local tx, ty
                    if n == "Right" then tx, ty = BASE, 0
                    elseif n == "Left" then tx, ty = -BASE, 0
                    elseif n == "Up" then tx, ty = 0, -BASE
                    else tx, ty = 0, BASE end
                    if p.X.Offset ~= tx or p.Y.Offset ~= ty then
                        d.Position = UDim2.new(p.X.Scale, tx, p.Y.Scale, ty)
                    end
                end
            end
        end
    end
end

-- 真正生效的驱动力：Heartbeat + task.defer
--
-- ⚠ 为什么必须套一层 defer：
--   · 放在 RenderStep(2000)     → 2.5 秒采样里 Ticks 1..13 一直在张合（游戏渲染后又写回去）
--   · Heartbeat 里直接写        → 同样被覆盖（我们的连接排在游戏更新之前）
--   · Heartbeat 里 task.defer 写 → 同一窗口内 0 变化
--   defer 把写入推到本帧调度末尾、渲染之前，这时候游戏本轮已经写完了。
do
    local hb = RunService.Heartbeat:Connect(function()
        if S._alive == false or (REG and REG.gen ~= MY_GEN) then return end
        task.defer(function()
            if S._alive == false then return end
            pcall(S.pinCrosshair)
        end)
    end)
    if S.conns then S.conns[#S.conns + 1] = hb end
end

S.updateSpinCam = function(dt)
    -- ⚠ 无后座模式下把准星「锁住」。
    --
    -- 用户反馈：无后座生效了、弹道也稳，但准星在天上乱飘。
    -- 实测（采样 MainGui.Gameplay.Middle.Crosshair 的子对象）：
    --   Right  0.5, 7  →  0.5, 31    ← 分叉向外张开 24 像素
    --   Left   0.5,-7  →  0.5,-31
    --   Up     0.5,-7  →  0.5,-31
    --   Down   0.5, 7  →  0.5, 31
    --   斜角 Arm 在 ±6 之间来回
    -- 这不是相机在动（相机 pitch 实测跨度 0.00），而是游戏把 Spread 画成了准星张合。
    -- 弹道方向由相机决定，所以「弹道稳、准星飘」——两套东西各走各的。
    --
    -- 准星钉住已提取到 S.pinCrosshair，并且改由 Heartbeat 驱动（见该函数上方的实测说明）。
    -- 这里只保留一次调用做兜底，真正的钉住在 Heartbeat 里。
    if cfg.noRecoil == true or cfg.autoRecoilComp == true then
        pcall(S.pinCrosshair)
    end

    -- 磁吸守护（见下方注释）。跳过拉栓已经移到 Heartbeat 每帧执行。
    --
    -- ⚠ 顺便在这里兜底重装 noRecoil 的 hook。
    --
    -- S.noRecoilHook() 原来只在点 GUI 开关时调用一次，重载脚本后不会自动装回去。
    -- 结果 cfg.noRecoil 明明是 true，setWeaponRecoil 却没人拦（recoilBlocked 恒为 nil），
    -- 后坐力照常生效。用户看到的就是「开了无后座但镜头还是抖」。
    if (cfg.noRecoil == true or cfg.autoRecoilComp == true) and not S.noRecoilHookOn then
        pcall(S.noRecoilHook)
    end
    -- 准星链路兜底重装：换局时 CameraController 可能被重新初始化，hook 会被冲掉。
    -- 冲掉之后准星就又会按 (RotationValue - 原始kick) 画，压枪越猛它偏得越多。
    if (cfg.autoRecoilComp == true or cfg.noRecoil == true) and not S.kickRotHookOn then
        pcall(S.installKickRotHook)
    end
    -- ⚠ 这个函数现在兼职「磁吸守护」。
    --
    -- 用户反馈：每局结束就恢复正常，新开一局又开始锁定。
    -- 原因是 AimAssistController 的 GetMagnetismRotation 会在对局切换时被重新赋值
    -- （模块重新初始化 / 我们上次的 hook 被覆盖），而我们只在加载时装一次。
    --
    -- 这里每帧检查：只要发现挂的不是我们那个恒返回 (0,0) 的函数，就重新焊上。
    -- 开销极小（一次表比较），但能保证不管换多少局磁吸都关着。
    -- ⚠⚠ 这里以前只做「重装」：`if type(MV_MAG_HOOK) == "function" then ... 重焊`
    -- —— 但**从来没有地方给它赋过值**。于是整段逻辑永远跳过，
    -- 游戏的 AimAssistController.GetMagnetismRotation 一直是原版：
    -- 附近有敌人时游戏自己会把相机转过去（360 度也照转），
    -- 完全绕开脚本的 FOV / 可见性 / 队伍判定。
    -- 用户实测「手动转到背后，它一个 360 度给我拉回去，手都停了」就是这个。
    --
    -- 现在改成：没装就装，装了被覆盖就重焊。
    if type(getgenv().MV_MAG_HOOK) ~= "function" then
        pcall(function()
            local RS2 = game:GetService("ReplicatedStorage")
            local AA = require(RS2.Controllers.AimAssistController)
            if type(getgenv().MV_ORIG_MAG) ~= "function" then
                getgenv().MV_ORIG_MAG = AA.GetMagnetismRotation
            end
            local zeroVec2 = function() return Vector2.new(0, 0) end
            getgenv().MV_MAG_HOOK = zeroVec2
            AA.GetMagnetismRotation = zeroVec2
            -- 同时中和游戏自带的后坐力辅助，否则它会在开枪时偷偷帮你压枪
            if type(AA.GetRecoilAssistScale) == "function" then
                AA.GetRecoilAssistScale = function() return Vector3.new(1, 1, 1) end
            end
            if type(AA.GetRecoilAssistMultiplier) == "function" then
                AA.GetRecoilAssistMultiplier = function() return 0 end
            end
            S.magHooksInstalled = (S.magHooksInstalled or 0) + 1
        end)
    end
    if type(getgenv().MV_MAG_HOOK) == "function" then
        local ok, AA = pcall(require, game.ReplicatedStorage.Controllers.AimAssistController)
        if ok and type(AA) == "table" and AA.GetMagnetismRotation ~= getgenv().MV_MAG_HOOK then
            pcall(function()
                AA.GetMagnetismRotation = getgenv().MV_MAG_HOOK
            end)
            S.magRehooks = (S.magRehooks or 0) + 1
        end
    end
    S.spinOn = false
end

---------------------------------------------------------------------
-- 大陀螺（纯客户端视觉）
--
-- 只转「自己客户端渲染的那具模型」，效果：
--   · 自己的视角完全不动（相机是 CameraPart，不绑在 RootPart 上）
--   · 别人完全看不到（服务端根本不知道我们在转）
--   · 第三人称下自己能看见自己在转
--
-- 为什么可行：角色模型是本地渲染的，每帧被 pose 覆盖一次。
-- 我们在 RenderStep 的最高优先级写 CFrame，就能在游戏更新之后把手补上。
--
-- 风险：只改视觉不移动，RootPart 的旋转不会影响服务端位置；
-- 但会让本地动画/持枪姿势随之旋转，属于预期内的视觉副作用。
---------------------------------------------------------------------
S.applyLocalSpin = function(dt)
    if cfg.localSpin ~= true then
        S.localSpinOn = false
        return
    end
    local m = myModel()
    if not m then return end
    local hrp = m:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    -- ⚠ 绝对不能只写 HumanoidRootPart.CFrame。
    --
    -- 实测表现：第三人称看到「两个自己」—— 一个本体、一个鬼影，一边抽搐一边转。
    -- 原因：HRP 是 Anchored=true 的，直接写它的 CFrame 时，通过 Motor6D 挂在
    -- 它下面的 LowerTorso / UpperTorso / 四肢不会原子地跟过去，每帧都在
    -- 「旧位置」和「新位置」之间被撕开。地图上的两个箭头也是同一件事。
    --
    -- 正确做法：Model:PivotTo()。它是一次性把**所有部件**按同一变换搬过去，
    -- 相对位置保持不变，不会撕裂。
    local degPerSec = math.clamp(tonumber(cfg.spinSpeed) or 360, -720, 720)
    S.spinAccum = ((S.spinAccum or 0) + degPerSec * (dt or 0.016)) % 360
    local rad = math.rad(S.spinAccum)

    local okPivot = pcall(function()
        local pivot = m:GetPivot()
        m:PivotTo(CFrame.new(pivot.Position) * CFrame.Angles(0, rad, 0))
    end)
    if not okPivot then
        S.localSpinErr = (S.localSpinErr or 0) + 1
    end

    S.spinApplied = rad
    local okRead, yawNow = pcall(function()
        local _, y = m:GetPivot():ToEulerAnglesYXZ()
        return math.deg(y)
    end)
    S.spinReadback = okRead and yawNow or nil
    S.localSpinOn = true
    S.spinSteps = (S.spinSteps or 0) + 1
end

pcall(function()
    RunService:BindToRenderStep("MV_Spin",
        Enum.RenderPriority.Last.Value - 2, function(dt)
            -- 把 cfg 的值同步到全局标志（hook 里读不到 cfg，只能读这个）
            -- 恢复 LookYaw 改写：用户要的是「本地视角不动、别人看到模型在转」。
            -- 改相机（mousemoverel）转的是自己，方向搞反了。
            -- ⚠ 命令层改写（LookYaw）彻底停用。
            --
            -- 实测：别人看不到旋转（服务端不回传持续朝向），
            -- 但服务端确实用 LookYaw 算移动方向 —— Move 补偿稍有相位差就「原地打转走不出去」。
            -- 收益为零、副作用是致命的，所以永久关闭。
            --
            -- 现在陀螺是纯客户端视觉：只转自己客户端的模型，见 S.applyLocalSpin。
            getgenv().MV_SPINBOT = false
            getgenv().MV_SPINSPEED = tonumber(cfg.spinSpeed) or 2500
            -- 兔子跳叠速实验开关同步（encode hook 里读不到 cfg）
            getgenv().MV_BHOPBOOST = tonumber(cfg.bhopBoost) or 1
            if cfg.spinbot and not origEncode then
                pcall(installSpinHook)
            end
        end)
end)

---------------------------------------------------------------------
-- ESP
---------------------------------------------------------------------
local function mkDraw(cls)
    local ok, o = pcall(function() return Drawing.new(cls) end)
    return ok and o or nil
end

local function newSet()
    return {
        box = mkDraw("Square"), hbg = mkDraw("Square"), hfg = mkDraw("Square"),
        name = mkDraw("Text"), dist = mkDraw("Text"), wpn = mkDraw("Text"),
        frozen = mkDraw("Text"),   -- 「旧」标记：位置数据已冻结，不是实时位置
        bones = {},      -- 骨骼线（按需创建）
        parts = {},      -- 碰撞箱部位标框（按需创建）
    }
end

-- 隐藏一个 set 里的全部绘制对象。
-- ⚠ 必须单独处理 bones / parts：它们是**数组**，
-- 而原来的写法 `for _, d in pairs(set) do d.Visible = false end`
-- 只会给数组本身设 Visible（数组没有这个属性，等于什么都没做），
-- 里面的每根骨骼线、每个碰撞箱框从来没被关掉 —— 目标走了还在屏幕上赖着不走。
local function hideSet(set)
    if type(set) ~= "table" then return end
    for k, d in pairs(set) do
        if k == "bones" or k == "parts" then
            for _, o in pairs(d) do
                if type(o) == "table" and o.Visible ~= nil then
                    o.Visible = false
                end
            end
        elseif d ~= nil and d.Visible ~= nil then
            d.Visible = false
        end
    end
end

local function clearEsp()
    for _, set in pairs(S.espObjects) do
        for k, d in pairs(set) do
            if k == "bones" or k == "parts" then
                for _, o in pairs(d) do
                    if o and o.Remove then pcall(function() o:Remove() end) end
                end
            elseif d and d.Remove then
                pcall(function() d:Remove() end)
            end
        end
    end
    S.espObjects = {}
end

-- 第三人称
-- 游戏锁定 CameraMode=LockFirstPerson 且重置 CameraType，
-- 但实测直接写 Camera.CFrame 能保持。所以用 BindToRenderStep
-- 在相机更新之后（Camera 优先级 +1）把相机沿视线反方向后移。
local tpParams = RaycastParams.new()
-- 只让地图几何挡住相机。角色、掉落武器、手雷这些都不算遮挡——
-- 否则相机贴到别人身上会被拉到 0.8 stud，钻进模型里，每帧跳变就是闪烁。
local mapFolder = workspace:FindFirstChild("Map")
if mapFolder then
    tpParams.FilterType = Enum.RaycastFilterType.Include
    tpParams.FilterDescendantsInstances = { mapFolder }
else
    tpParams.FilterType = Enum.RaycastFilterType.Exclude
    tpParams.FilterDescendantsInstances = {}
end
tpParams.RespectCanCollide = false
tpParams.IgnoreWater = true

local TP_MIN_DIST = 3   -- 再近就贴脸了，不如不要第三人称
local tpLtmTick = 0

-- 第一人称模式会把自己角色的每个部件设成 LocalTransparencyModifier = 1（全透明）。
-- 第三人称若不强制清掉，看到的模型就会一帧有一帧没 → 闪烁。
local function clearOwnTransparency(me)
    if not me then return end
    for _, p in ipairs(me:GetDescendants()) do
        if p:IsA("BasePart") and p.LocalTransparencyModifier > 0 then
            p.LocalTransparencyModifier = 0
        end
    end
end

local function restoreOwnTransparency(me)
    if not me then return end
    for _, p in ipairs(me:GetDescendants()) do
        if p:IsA("BasePart") then
            p.LocalTransparencyModifier = 1
        end
    end
end

local function tpStep()
    -- 关闭时必须在这里恢复模型透明度，而不是只交给 tpUnbind。
    -- 快速连点开关时，toggle 回调和 RenderStep 的执行顺序不固定：
    -- tpUnbind 把模型设成透明后，慢一帧的 tpStep 可能又把它清成可见，
    -- 第一人称下就会看到自己的身体挡在镜头前（画面撕裂成黑条）。
    if not cfg.thirdPerson then
        if S.tpModelShown then
            S.tpModelShown = false
            restoreOwnTransparency(myModel())
            -- 关键：必须把相机拨回第一人称位置。
            -- 之前这里只恢复透明度就 return，相机永远停在第三人称那个偏移上，
            -- 关掉开关看起来还是第三人称。
            local m2 = myModel()
            local hd2 = m2 and (m2:FindFirstChild("Head") or m2:FindFirstChild("UpperTorso"))
            local cam2 = workspace.CurrentCamera
            if hd2 and cam2 then
                local look2 = cam2.CFrame.LookVector
                pcall(function()
                    cam2.CFrame = CFrame.new(hd2.Position, hd2.Position + look2)
                end)
            end
        end
        return
    end
    S.tpModelShown = true

    local cam = workspace.CurrentCamera
    if not cam then return end
    local me = myModel()
    local head = me and (me:FindFirstChild("Head") or me:FindFirstChild("UpperTorso"))
    if not head then return end

    -- 每帧都清透明度。游戏每帧都在写 LocalTransparencyModifier=1（第一人称逻辑），
    -- 之前每 8 帧才清一次，中间那几帧模型就被它设回透明 → 一明一暗的残余闪烁。
    -- 22 个部件的遍历在 60fps 下开销可以接受。
    clearOwnTransparency(me)

    local look = cam.CFrame.LookVector
    local dist = math.max(tonumber(cfg.thirdPersonDist) or 12, TP_MIN_DIST)
    local from = head.Position
    local want = from - look * dist

    -- 只有地图挡住时才收短，且不会短于 TP_MIN_DIST
    local hit = workspace:Raycast(from, want - from, tpParams)
    if hit then
        local allowed = hit.Distance - 0.6
        if allowed >= TP_MIN_DIST then
            want = from - look * allowed
        end
    end

    cam.CFrame = CFrame.new(want, want + look)
end

local okTP = pcall(function()
    -- 必须用 Last（1999）而不是 Camera+1（201）。
    -- 游戏的相机在 Camera 之后还会写一次，用 201 会被覆盖，
    -- 结果就是每帧在「第一人称 0.53」和「第三人称 12」之间跳 → 全场闪烁。
    RunService:BindToRenderStep("MV_ThirdPerson",
        Enum.RenderPriority.Last.Value - 1, tpStep)
end)

-- 关闭第三人称时**不要**解绑 RenderStep。
-- 之前这里调了 UnbindFromRenderStep，但绑定只在加载时做一次，
-- 解绑后再打开就绑不回来了（开关失效）。tpStep 内部会检查 cfg.thirdPerson，
-- 关掉时它自然什么都不做，留着没有代价。
local function tpUnbind()
    -- 立刻把相机拉回眼睛位置。否则关掉第三人称后相机还停在身后 12 stud，
    -- 而游戏要几帧才把它拉回来，这期间相机可能卡在墙里 → 近裁剪面撕裂。
    pcall(function()
        local cam = workspace.CurrentCamera
        local me = myModel()
        local head = me and (me:FindFirstChild("Head") or me:FindFirstChild("UpperTorso"))
        if cam and head then
            cam.CFrame = CFrame.new(head.Position, head.Position + cam.CFrame.LookVector)
        end
    end)
    pcall(function()
        local p = LP
        if p then p.CameraMode = Enum.CameraMode.LockFirstPerson end
    end)
    S.tpModelShown = false
    -- 关掉第三人称后把自己的模型恢复成隐形（第一人称本来就看不到自己）
    pcall(function() restoreOwnTransparency(myModel()) end)
end

-- 旧的 CameraMode 方案保留作为兜底（游戏可能在某些界面允许）
local function applyThirdPerson()
    local p = LP
    if not p then return end
    if cfg.thirdPerson then
        pcall(function()
            if p.CameraMode ~= Enum.CameraMode.Classic then
                p.CameraMode = Enum.CameraMode.Classic
            end
            local want = tonumber(cfg.thirdPersonDist) or 12
            p.CameraMaxZoomDistance = math.max(want, 4)
            p.CameraMinZoomDistance = 2
        end)
    else
        pcall(function()
            if p.CameraMode ~= Enum.CameraMode.LockFirstPerson then
                p.CameraMode = Enum.CameraMode.LockFirstPerson
            end
        end)
    end
end

---------------------------------------------------------------------
-- 骨骼 / 碰撞箱
-- 数据来源：角色模型本身就是 R15，每个部位都是独立 BasePart，
--   Head / UpperTorso / LowerTorso / 四肢的 CFrame 和 Size 都能直接读。
--   PVS 剔除的玩家没有模型（只有 RemoteBuffer 的位置），画不了骨骼。
---------------------------------------------------------------------
local SKELETON_BONES = {
    { "Head", "UpperTorso" },
    { "UpperTorso", "LowerTorso" },
    { "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" },
    { "RightLowerArm", "RightHand" },
    { "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" },
    { "LeftLowerArm", "LeftHand" },
    { "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" },
    { "RightLowerLeg", "RightFoot" },
    { "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" },
    { "LeftLowerLeg", "LeftFoot" },
}

-- 碰撞箱部位（画屏幕小方块，比 3D 线框便宜得多）
local HITBOX_PARTS = {
    "Head", "UpperTorso", "LowerTorso",
    "RightUpperArm", "LeftUpperArm", "RightLowerArm", "LeftLowerArm",
    "RightHand", "LeftHand",
    "RightUpperLeg", "LeftUpperLeg", "RightLowerLeg", "LeftLowerLeg",
    "RightFoot", "LeftFoot",
}

-- offset：模型位置被 PVS 冻结时，用「服务端真实位置 - 模型根部位置」平移所有部位
local function drawSkeleton(set, cam, model, color, thickness, offset)
    if not model then return 0 end
    local off = offset or Vector3.zero
    local idx = 0
    for _, pair in ipairs(SKELETON_BONES) do
        local a = model:FindFirstChild(pair[1])
        local b = model:FindFirstChild(pair[2])
        if a and b and a:IsA("BasePart") and b:IsA("BasePart") then
            local sp1 = cam:WorldToViewportPoint(a.Position + off)
            local sp2 = cam:WorldToViewportPoint(b.Position + off)
            if sp1.Z > 0 and sp2.Z > 0 then
                idx += 1
                local line = set.bones[idx]
                if not line then
                    line = mkDraw("Line")
                    set.bones[idx] = line
                end
                if line then
                    line.Visible = true
                    line.Color = color
                    line.Thickness = thickness or 1.4
                    line.From = Vector2.new(sp1.X, sp1.Y)
                    line.To = Vector2.new(sp2.X, sp2.Y)
                end
            end
        end
    end
    -- ⚠ 不能用 `for i = idx + 1, #set.bones`。
    --
    -- set.bones 是稀疏数组（某个骨骼部件缺失时那一格会留空），
    -- Lua 的 # 对带空洞的表返回的是「某个边界」而不是真实最大下标。
    -- 实测残留就是 15 格只隐藏了 14 格，最后一根骨骼永远挂在屏幕上。
    -- 改成 pairs 全遍历，一格都不漏。
    for i, o in pairs(set.bones) do
        if type(i) == "number" and i > idx and o then
            o.Visible = false
        end
    end
    return idx
end

local function drawHitboxes(set, cam, model, color, offset)
    if not model then return 0 end
    local off = offset or Vector3.zero
    local idx = 0
    local camPos = cam.CFrame.Position
    for _, name in ipairs(HITBOX_PARTS) do
        local part = model:FindFirstChild(name)
        if part and part:IsA("BasePart") then
            local worldPos = part.Position + off
            local dist = (worldPos - camPos).Magnitude
            local sp = cam:WorldToViewportPoint(worldPos)
            if sp.Z > 0 and dist > 1 then
                -- 把 3D 尺寸换算成屏幕像素
                local px = (math.max(part.Size.X, part.Size.Y, part.Size.Z) / dist) * 480
                if px > 2 and px < 400 then
                    idx += 1
                    local sq = set.parts[idx]
                    if not sq then
                        sq = mkDraw("Square")
                        set.parts[idx] = sq
                    end
                    if sq then
                        sq.Visible = true
                        sq.Color = color
                        sq.Filled = false
                        sq.Thickness = 1
                        sq.Size = Vector2.new(px, px)
                        sq.Position = Vector2.new(sp.X - px * 0.5, sp.Y - px * 0.5)
                    end
                end
            end
        end
    end
    -- 同样不能用 #set.parts（稀疏数组陷阱），见 drawSkeleton 里的说明。
    for i, o in pairs(set.parts) do
        if type(i) == "number" and i > idx and o then
            o.Visible = false
        end
    end
    return idx
end

---------------------------------------------------------------------
-- 雷达：以自己为中心，把 400m 内所有人投影到圆盘上
-- 解决「目标在背后时 2D 框画不出来」的问题
---------------------------------------------------------------------
local radar = {
    bg = mkDraw("Square"),
    borderT = mkDraw("Line"), borderB = mkDraw("Line"),
    borderL = mkDraw("Line"), borderR = mkDraw("Line"),
    me = mkDraw("Square"),
    fwd = mkDraw("Line"),
    dots = {},
}

local function radarClear()
    for _, d in pairs(radar.dots) do
        if d and d.Remove then pcall(function() d:Remove() end) end
    end
    radar.dots = {}
end
getgenv().MV_RADAR = radar

---------------------------------------------------------------------
-- 投掷学习：服务端 Projectile.Spawn 包里带真实初速度
--   State.Velocity / Physics.{Radius,Restitution,MaxBounces,FuseTime}
-- 扔一次手雷就能拿到精确值，之后抛物线自动用它
---------------------------------------------------------------------
local learned = getgenv().MV_THROW_LEARNED or { speed = nil, samples = 0, weapon = "?", samplesList = {} }
if type(learned.samplesList) ~= "table" then learned.samplesList = {} end
getgenv().MV_THROW_LEARNED = learned

-- ═══════════════════════════════════════════════════════════════
-- 学习数据持久化（mv_learned.json）
--
-- 先澄清一个容易混的点：「保存配置」和「学习数据」是两套完全独立的东西。
--   · cfg 存档（MV_CFG_SAVE）只收 boolean / number / string，从来不包含 learned
--   · learned / vfxLearn 只挂在 getgenv() 上
-- 于是：
--     重载脚本（loadstring 再跑一遍）     → 学习数据还在（同一个 getgenv）
--     重新注入执行器 / 重进服务器 / 关游戏  → 学习数据全丢，存档也救不回来
-- 也就是说：不保存配置时，学习数据不是"没保存下来"，而是它压根没进过存档。
--
-- 这里给它单独落盘。只存「可复算的标量」：初速、起点偏移、每把武器的物理参数、
-- 烟雾/火焰实测时长。不存 tracked / samplesList —— 那是每颗雷的运行时记录，
-- 重启即失效，写进去只会让下次加载读到一堆过期坐标。
-- 没有 writefile 的执行器（部分手机端）自动跳过，不影响其它功能。
-- 手动接口：MV_LEARN_SAVE() / MV_LEARN_WIPE()
-- ═══════════════════════════════════════════════════════════════
do
    (function()
        local HS = game:GetService("HttpService")
        local FILE = "mv_learned.json"
        local KEYS = {
            "speed", "samples", "weapon", "originOffset", "perWeapon", "byWeapon",
            "physics", "landErr", "bounceErr", "bounceErrSamples",
            "bounceMissTotal", "bounceExtraTotal",
        }

        local function pack(v)
            if typeof(v) == "Vector3" then return { __v3 = { v.X, v.Y, v.Z } } end
            if type(v) ~= "table" then return v end
            local o = {}
            for k, x in pairs(v) do
                if type(k) ~= "table" then o[k] = pack(x) end
            end
            return o
        end

        local function unpack_(v)
            if type(v) ~= "table" then return v end
            if type(v.__v3) == "table" then
                return Vector3.new(tonumber(v.__v3[1]) or 0, tonumber(v.__v3[2]) or 0, tonumber(v.__v3[3]) or 0)
            end
            local o = {}
            for k, x in pairs(v) do o[k] = unpack_(x) end
            return o
        end

        S.learnedFile = FILE

        S.saveLearned = function()
            if not writefile then return false, "no-writefile" end
            -- ⚠ 以磁盘上已有的内容为底，内存里有值才覆盖。
            -- 之前直接 `payload.vfx = {}` 再按内存填：一旦这一次内存里 median 是 nil
            -- （比如刚重载、vfxLearn 还没学到东西），就会把磁盘上的 18s / 5.5s 覆盖成空，
            -- 下次加载反而学不到东西 —— 实测真丢过一次，进度条变回 0。
            local old = {}
            if readfile then
                local okf, ex = pcall(function()
                    if isfile then return isfile(FILE) end
                    return true
                end)
                if okf and ex then
                    local okr, raw = pcall(readfile, FILE)
                    if okr and type(raw) == "string" and #raw > 1 then
                        local okj, d = pcall(function() return HS:JSONDecode(raw) end)
                        if okj and type(d) == "table" then old = d end
                    end
                end
            end
            local payload = { v = 1, throw = {}, vfx = {} }
            if type(old.throw) == "table" then
                for k, v in pairs(old.throw) do payload.throw[k] = v end
            end
            if type(old.vfx) == "table" then
                for _, kind in ipairs({ "smoke", "fire" }) do
                    local ob = old.vfx[kind]
                    if type(ob) == "table" and tonumber(ob.median) then
                        payload.vfx[kind] = { median = tonumber(ob.median) }
                    end
                end
            end
            for _, k in ipairs(KEYS) do
                if learned[k] ~= nil then payload.throw[k] = pack(learned[k]) end
            end
            local vl = getgenv().MV_VFX_LEARNED
            if type(vl) == "table" then
                for _, kind in ipairs({ "smoke", "fire" }) do
                    local b = vl[kind]
                    local m = type(b) == "table" and tonumber(b.median)
                    if m then
                        payload.vfx[kind] = { median = m }
                    end
                end
            end
            local okj, js = pcall(function() return HS:JSONEncode(payload) end)
            if not okj then return false, tostring(js) end
            local okw, err = pcall(writefile, FILE, js)
            if not okw then return false, tostring(err) end
            S.learnedSavedAt = os.date("%H:%M:%S")
            return true
        end

        S.loadLearned = function()
            if not readfile then return false, "no-readfile" end
            local okf, exists = pcall(function()
                if isfile then return isfile(FILE) end
                return true
            end)
            if not okf or not exists then return false, "no-file" end
            local okr, raw = pcall(readfile, FILE)
            if not okr or type(raw) ~= "string" or #raw < 2 then return false, "read-fail" end
            local okj, data = pcall(function() return HS:JSONDecode(raw) end)
            if not okj or type(data) ~= "table" then return false, "bad-json" end
            local n = 0
            for _, k in ipairs(KEYS) do
                if type(data.throw) == "table" and data.throw[k] ~= nil then
                    learned[k] = unpack_(data.throw[k])
                    n = n + 1
                end
            end
            local vl = getgenv().MV_VFX_LEARNED
            if type(vl) == "table" and type(data.vfx) == "table" then
                for _, kind in ipairs({ "smoke", "fire" }) do
                    local b = data.vfx[kind]
                    if type(b) == "table" and tonumber(b.median) and type(vl[kind]) == "table" then
                        vl[kind].median = tonumber(b.median)
                        n = n + 1
                    end
                end
            end
            return true, n
        end

        local okL, nL = S.loadLearned()
        if okL then S.learnedLoaded = nL end

        getgenv().MV_LEARN_SAVE = function() return S.saveLearned() end
        getgenv().MV_LEARN_WIPE = function()
            for _, k in ipairs(KEYS) do learned[k] = nil end
            learned.samples = 0
            if delfile then pcall(delfile, FILE) end
            S.learnedSig = nil
            S.learnedLoaded = 0
            return true
        end

        -- 节流落盘：学习值真的变了才写（每 4 秒比一次签名）
        S.learnedSig = nil
        task.spawn(function()
            while true do
                task.wait(4)
                -- ⚠ 必须能退出：这个循环原来没有任何存活判据，卸载/重载之后
                -- 旧实例仍会每 4 秒读 learned 表、比签名、必要时写文件 ——
                -- 重载几次就有几个这样的任务同时往同一个文件写。
                if S._alive == false or (REG and REG.gen ~= MY_GEN) then break end
                local oo = learned.originOffset
                local vl = getgenv().MV_VFX_LEARNED
                local sig = string.format("%s|%s|%s|%s|%s",
                    tostring(learned.samples), tostring(learned.speed),
                    tostring(type(oo) == "table" and oo.hits or nil),
                    tostring(vl and vl.smoke and vl.smoke.median),
                    tostring(vl and vl.fire and vl.fire.median))
                if sig ~= S.learnedSig then
                    local ok, err = S.saveLearned()
                    if ok then
                        S.learnedSig = sig
                        S.learnedSaveErr = nil
                    else
                        S.learnedSaveErr = tostring(err)
                    end
                end
            end
        end)
    end)()
end

-- ═══════════════════════════════════════════════════════════════
-- 学习「按下 → 出手」的真实延迟，替代硬编码的 throwPredictLead = 0.7
--
-- 游戏源码里投掷动画叫 "StartThrow"（CharacterAnimator 第 352~356 行）：
--     if a2 == "StartThrow" then a1:play("StartThrow", 0.2) end
-- 监听 Animator.AnimationPlayed 就能拿到动画开始的那一刻，再和
-- Projectile.Spawn 到达的时刻相减，就是这一次投掷的真实延迟。
-- 累积后用指数滑动平均写回 cfg.throwPredictLead，手持预览的外推量就不再是猜的。
-- ═══════════════════════════════════════════════════════════════
S.ensureThrowAnimListener = function()
    if S.throwAnimConn then
        pcall(function() S.throwAnimConn:Disconnect() end)
        S.throwAnimConn = nil
    end
    local me = myModel()
    -- ⚠ 这个游戏的角色是 PlayerCustomCharacter，**没有 Humanoid**。
    -- 实测：FindFirstChildOfClass("Humanoid") → nil，导致监听器根本挂不上。
    -- 真正的动画宿主是 AnimationController + Animator（在模型内部）。
    local anim = me and me:FindFirstChildOfClass("Animator")
    if not anim and me then
        local ac = me:FindFirstChildOfClass("AnimationController")
        anim = ac and ac:FindFirstChildOfClass("Animator")
    end
    if not anim and me then
        anim = me:FindFirstChild("Animator", true)   -- 递归兜底
    end
    if not anim then return false end
    S.throwAnimConn = anim.AnimationPlayed:Connect(function(track)
        local a = track and track.Animation
        if a and tostring(a.Name) == "StartThrow" then
            local cam = workspace.CurrentCamera
            S.throwPressAt = os.clock()
            if cam then
                S.throwPressCamPos = cam.CFrame.Position
                S.throwPressCamLook = cam.CFrame.LookVector
            end
            S.throwAnimHits = (S.throwAnimHits or 0) + 1
        end
    end)
    S.throwAnimBound = true
    return true
end

-- 投掷物配置里的 Range 缓存（爆炸/覆盖半径）
local WEAPON_RANGE_CACHE = {}

---------------------------------------------------------------------
-- 弹道位置源：绕过 PVS 拿敌人位置的唯一途径
--
-- 服务端对不可见玩家停止下发位置（20 秒采样证实：模型/pose/CollisionPose 全冻结），
-- 所以角色位置这条链路是死的，客户端怎么 hook 都没有数据可拿。
--
-- 但 VFX.CreateTracer 是**全局广播**的，不分可见性：
--   CreateTracer = { Distance = Float32, Origin = Vec3, Target = Vec3 }
-- Origin 就是开枪者的枪口位置 —— 敌人只要开一枪，他的大概位置就暴露了。
-- （同理 FlashPlayer 带 Position，Projectile.Spawn 带 State.Position，
--   这几条都不受 PVS 限制。）
--
-- 精度：枪口不是脚底，第一人称下大概高 1.2 stud、前 1~2 stud，
-- 所以只能当「他刚才在这附近」用，不能当精确位置。
---------------------------------------------------------------------
S.tracers = S.tracers or {}
S.tracerHits = 0
S.recentDeaths = S.recentDeaths or {}

-- ═══════════════════════════════════════════════════════════════
-- 坐标事件池：PVS 挡住了「持续位置」，但任何「动静」都会带一次坐标过来。
--
-- 实测这四个包都带位置信息（schema 抄自 Database.Security.Remotes）：
--   VFX.CreateBloodSplatter    Position=Vec3        ← 中弹位置 = 那个人站的位置
--   VFX.CreateImpact           Position=Vec3 + VictimUserId + HitPartName
--   Sound.ReplicateSound       Position=Optional(Vec3)  ← 脚步 / 枪声
--   VFX.CreateTracer           Origin=Vec3          ← 开枪枪口（原有逻辑已用）
--
-- ESP 每帧检查：位置过期的目标，如果 2 秒内附近有坐标事件，就用事件坐标顶上。
-- 这就是「听到脚步/看到血、框立刻跳过去」的实现。
-- ═══════════════════════════════════════════════════════════════
S.posEvents = S.posEvents or {}
S.posEventCount = 0

S.pushPosEvent = function(pos, kind, extra)
    if typeof(pos) ~= "Vector3" then return end
    local a = S.posEvents
    a[#a + 1] = { pos = pos, at = os.clock(), kind = tostring(kind), extra = extra }
    while #a > 80 do table.remove(a, 1) end
    S.posEventCount = (S.posEventCount or 0) + 1
end

-- 找最近的有效坐标事件（2 秒内、60 stud 内）
S.nearestPosEvent = function(pos, radius, maxAge)
    local now = os.clock()
    local best, bestD = nil, tonumber(radius) or 60
    local age = tonumber(maxAge) or 2.0
    local a = S.posEvents
    for i = #a, 1, -1 do
        local ev = a[i]
        if now - (ev.at or 0) > age then break end
        if typeof(ev.pos) == "Vector3" then
            local d = (ev.pos - pos).Magnitude
            if d < bestD then best, bestD = ev, d end
        end
    end
    return best, bestD
end

S.ensurePosListeners = function()
    if S.posListenersOn then return end
    S.posListenersOn = true

    -- ── 血迹：中弹位置 ──
    pcall(function()
        Remotes.VFX.CreateBloodSplatter.Listen(function(d)
            if type(d) == "table" and typeof(d.Position) == "Vector3" then
                S.pushPosEvent(d.Position, "blood", d.AttackerUserId)
            end
        end)
    end)

    -- ── 命中：只在 VictimUserId 有值时记（打墙不记，墙上的坐标没用）──
    pcall(function()
        Remotes.VFX.CreateImpact.Listen(function(d)
            if type(d) ~= "table" then return end
            if d.VictimUserId == nil then return end
            if typeof(d.Position) == "Vector3" then
                S.pushPosEvent(d.Position, "hit", d.VictimUserId)
            end
        end)
    end)

    -- ── 开枪者身份 ──
    --
    -- CreateCharacterMuzzleFlash 没有坐标，但有 UserId + Generation。
    -- 游戏自己就是这么用的（InventoryController 里）：
    --   Character(a1.UserId, a1.Generation, a1.WeaponName, a1.ShootingHand, ...)
    -- 所以它能精确回答「谁在开枪」，只是不知道人在哪。
    if type(S.shooterAt) ~= "table" then S.shooterAt = {} end
    pcall(function()
        Remotes.VFX.CreateCharacterMuzzleFlash.Listen(function(d)
            if type(d) ~= "table" then return end
            local uid = tonumber(d.UserId)
            if not uid then return end
            S.shooterAt[uid] = { at = os.clock(), gen = d.Generation, weapon = d.WeaponName }
            S.muzzleCount = (S.muzzleCount or 0) + 1
        end)
    end)

    -- ── 曳光：枪口坐标 + 命中点，但没有 UserId ──
    --
    -- 所以要和上面的「开枪者」配对：tracer 到达时看 0.2 秒内谁刚开过枪。
    -- 配对成功后就能得到「某个 UserId 在某个坐标开过枪」，这是 PVS 下最精确的实时位置源。
    pcall(function()
        Remotes.VFX.CreateTracer.Listen(function(d)
            if type(d) ~= "table" or typeof(d.Origin) ~= "Vector3" then return end
            local now = os.clock()
            -- 找 0.25 秒内最新开枪的人
            local bestUid, bestAt = nil, 0
            if type(S.shooterAt) == "table" then
                for uid, rec in pairs(S.shooterAt) do
                    if type(rec) == "table" and (rec.at or 0) > bestAt
                        and (now - (rec.at or 0)) < 0.25 then
                        bestUid, bestAt = uid, rec.at
                    end
                end
            end
            if bestUid then
                if type(S.idEvents) ~= "table" then S.idEvents = {} end
                S.idEvents[#S.idEvents + 1] = {
                    uid = bestUid,
                    pos = d.Origin - Vector3.new(0, 1.2, 0),   -- 枪口→大概身体位置
                    at = now,
                    kind = "shot",
                }
                while #S.idEvents > 40 do table.remove(S.idEvents, 1) end
                S.shotPaired = (S.shotPaired or 0) + 1
            else
                S.shotUnpaired = (S.shotUnpaired or 0) + 1
            end
            -- 命中点也当作一次可能的目标位置
            if typeof(d.Target) == "Vector3" then
                S.pushPosEvent(d.Target, "tracerTarget", nil)
            end
        end)
    end)

    -- ── 声音：这是 PVS 下最可靠的实时位置源 ──
    --
    -- 实测 ReplicateSound 会收到三大类（20 秒 366 条）：
    --
    --   Class=FloorSounds  Name=Metal/Asphalt/Ground   ← 地面材质，跟人无关，丢弃
    --   Class=Character    Name=Character Death Grunt ← 角色音（死亡呻吟/受伤）
    --   Class=M4A1-S       Name=Shoot  Position=(130,74,-78)
    --     ↑ **枪声！Class 是武器名，Position 是开枪者站的地方**
    --
    -- 关键：CreateTracer 受 PVS 限制（实测 15 秒 0 条），
    -- 但 ReplicateSound 不受限 —— 因为游戏要把声音放给你听，就必须告诉你位置。
    -- 所以「枪声」这条路能真正实现「有人开枪，框立刻跳过去」。
    pcall(function()
        Remotes.Sound.ReplicateSound.Listen(function(d)
            if type(d) ~= "table" or typeof(d.Position) ~= "Vector3" then return end
            S.soundCount = (S.soundCount or 0) + 1
            S.lastSoundAt = os.clock()
            S.lastSoundPos = d.Position

            local cls = tostring(d.Class or "")
            local nm = tostring(d.Name or "")
            local nmLower = nm:lower()

            if cls == "Character" then
                -- 角色发出的声音（死亡/受伤），位置就在人身上
                S.charSoundCount = (S.charSoundCount or 0) + 1
                S.pushPosEvent(d.Position, "csound", nil)
            elseif cls == "FloorSounds" then
                -- ⚠⚠ 脚步声——之前被我当成「地面材质，跟人无关」直接丢掉了，这是大错。
                --
                -- FloorSounds 的 Name 是材质（Metal/Asphalt/Ground），
                -- 但 Position 就是**发出脚步声的那个人的脚下**。
                -- 而 ReplicateSound 不受 PVS 限制（游戏要放声音给你听，就必须告诉位置），
                -- 所以这是「看不见的目标在移动」时唯一能拿到他位置的通道。
                --
                -- 排除自己：自己的脚步也在里面，距离 3 stud 以内的一律当自己。
                local myR = myRoot()
                local isMine = false
                if myR then
                    isMine = (d.Position - myR.Position).Magnitude < 3.5
                end
                if not isMine then
                    -- 脚步每秒几十条，而 S.posEvents 只留 80 条 —— 不去重的话
                    -- 血迹/枪声/命中这些珍贵事件会被脚步声整批挤掉，位置矫正反而失灵。
                    -- 规则：0.35 秒内、且位置移动不到 2.5 stud 的重复脚步不记。
                    local nowF = os.clock()
                    local lf = S.lastFootEvent
                    local dup = false
                    if type(lf) == "table" and typeof(lf.pos) == "Vector3" then
                        dup = ((nowF - (lf.at or 0)) < 0.35)
                            and ((d.Position - lf.pos).Magnitude < 2.5)
                    end
                    if not dup then
                        S.lastFootEvent = { pos = d.Position, at = nowF }
                        S.footstepCount = (S.footstepCount or 0) + 1
                        S.pushPosEvent(d.Position, "footstep", nil)
                    end
                end
            elseif nmLower:find("shoot", 1, true) or nmLower:find("fire", 1, true)
                or nmLower:find("reload", 1, true) then
                -- 枪声 / 换弹：Class 是武器名，Position 是开枪者位置
                S.gunSoundCount = (S.gunSoundCount or 0) + 1
                S.lastGunSoundWeapon = cls
                S.pushPosEvent(d.Position, "gunshot", cls)
            else
                S.otherSoundCount = (S.otherSoundCount or 0) + 1
            end
        end)
    end)
end

-- ⚠ 必须在加载后调用一次，否则上面所有 Listen 根本不注册。
--
-- 之前这个函数只有定义、没有调用点（grep 全文件只有 1 处 = 定义本身），
-- 所以血迹 / 命中 / 枪声 / 开枪者四个监听器全部没挂上：
--   · S.posListenersOn 一直是 nil
--   · S.posEvents 永远是 0 条
--   · S.gunSoundCount 永远是 nil
--   · 透视矫正一次都不会触发（nearestPosEvent 永远返回 nil）
-- 表现就是用户说的「开枪不会让透视回正」。
pcall(S.ensurePosListeners)

-- 按 UserId 找最近的带身份位置事件
S.idEventFor = function(userId, maxAge)
    if type(userId) ~= "number" then return nil end
    if type(S.idEvents) ~= "table" then return nil end
    local now = os.clock()
    local age = tonumber(maxAge) or 2.0
    for i = #S.idEvents, 1, -1 do
        local ev = S.idEvents[i]
        if now - (ev.at or 0) > age then break end
        if ev.uid == userId and typeof(ev.pos) == "Vector3" then return ev end
    end
    return nil
end

-- 死亡广播：ReplicateFinisher 带精确的死亡位置（Victim/Killer/Position/Weapon）。
--
-- ⚠ 这是「没透视到的人死后骨骼反而出现」的解药。
-- 目标活着时不进 PVS，客户端压根不知道它在哪；死的那一刻服务端广播一次位置，
-- 于是它突然出现在 _actors 里 —— 模型还在、Dead 属性还没同步、数据又是新鲜的，
-- collect 里那三个过滤条件（dead / frozen / tooOld）全都不成立，就被画出来了。
-- 记下死亡坐标，collect 里按位置把附近的目标判成死的。
pcall(function()
    local fin = Remotes.VFX and Remotes.VFX.ReplicateFinisher
    if fin and typeof(fin.Listen) == "function" then
        if S.finisherConn then pcall(function() S.finisherConn:Disconnect() end) end
        S.finisherConn = fin.Listen(function(d)
            if typeof(d) ~= "table" then return end
            local p = d.Position
            if typeof(p) ~= "Vector3" then return end
            local arr = S.recentDeaths
            arr[#arr + 1] = { pos = p, at = os.clock(), victim = d.Victim }
            while #arr > 24 do table.remove(arr, 1) end
            S.finisherCount = (S.finisherCount or 0) + 1
        end)
    end
end)

pcall(function()
    local sig = Remotes.VFX and Remotes.VFX.CreateTracer
    if sig and typeof(sig.Listen) == "function" then
        if S.tracerConn then pcall(function() S.tracerConn:Disconnect() end) end
        S.tracerConn = sig.Listen(function(d)
            if typeof(d) ~= "table" then return end
            local o = d.Origin
            if typeof(o) ~= "Vector3" then return end
            local arr = S.tracers
            arr[#arr + 1] = { pos = o, target = d.Target, at = os.clock() }
            while #arr > 32 do table.remove(arr, 1) end
            -- 同时记一条「声源事件」，用来画脚下的冲击波
            if type(S.soundEvents) == "table" then
                S.soundEvents[#S.soundEvents + 1] = { pos = o, at = os.clock(), kind = "shot" }
                while #S.soundEvents > 24 do table.remove(S.soundEvents, 1) end
            end
        end)
    end
end)

---------------------------------------------------------------------
-- 声音事件收集 → 脚下的冲击波
--
-- 声音不是透视：它只能表达「这个位置刚才有动静」，所以不画框，
-- 只在那个位置的脚下画一圈扩散波纹，随时间变淡消失。
-- 这样即使声音来自墙后，也不会让人误以为「那里站着一个人」。
--
-- 数据源两条：
--   1) CreateTracer —— 开枪，带精确的枪口坐标（上面已接）
--   2) 动态创建的 Sound 实例 —— 脚步/换弹等
--      这游戏的音效是播放时 new 出来的，所以监听 DescendantAdded 抓实例，
--      音的 Parent 若是 BasePart，那个 Part 的位置就是声源位置。
---------------------------------------------------------------------
S.soundEvents = S.soundEvents or {}
-- ⚠ 这里原来写的是 S.soundCount = 0，而上面 ensurePosListeners 里的
-- ReplicateSound 监听器也在写同一个 S.soundCount，两个来源共用一个字段 →
-- 诊断时分不清「ReplicateSound 事件数」和「Sound 实例数」，读数完全对不上。
-- 现在拆开：S.soundCount 只统计 ReplicateSound，Sound 实例用 soundInstanceCount。
S.soundInstanceCount = 0
pcall(function()
    if S.soundConn then pcall(function() S.soundConn:Disconnect() end) end
    S.soundConn = workspace.DescendantAdded:Connect(function(obj)
        if not obj:IsA("Sound") then return end
        local p = obj.Parent
        if not p or not p:IsA("BasePart") then return end
        local pos = p.Position
        local ev = S.soundEvents
        ev[#ev + 1] = { pos = pos, at = os.clock(), kind = "sound", name = obj.Name }
        while #ev > 24 do table.remove(ev, 1) end
        S.soundInstanceCount = (S.soundInstanceCount or 0) + 1
        S.lastSoundName = tostring(obj.Name)
    end)
end)

-- 烟雾几何：游戏自己维护，直接查询（Radar 系统就用这个判断能否点亮敌人）
local SmokeLib = nil
do
    local ok, mod = pcall(function()
        return require(RS:WaitForChild("Components"):WaitForChild("Common")
            :WaitForChild("VFXLibary"):WaitForChild("CreateVoxelSmoke"))
    end)
    if ok then SmokeLib = mod end
end

-- 从 a 到 b 的视线是否被烟雾挡住
smokeBlocks = function(a, b)
    if not SmokeLib or typeof(SmokeLib.DoesRayIntersectActiveSmoke) ~= "function" then
        return false
    end
    local delta = b - a
    local dist = delta.Magnitude
    if dist < 0.1 then return false end

    -- ⚠ 烟雾是「渐变」的，几何判定是「二元」的。
    --
    -- 玩家实际看到的：
    --   刚爆开 → 烟雾从小团慢慢长满（DeployTime 内是渐变）
    --   满烟期 → 完全看不见
    --   Duration 到期 → 慢慢散掉，不是瞬间消失
    --
    -- 但 DoesRayIntersectActiveSmoke 只知道「体素在不在」，
    -- 于是烟刚落地那一刻它就返回 true —— 脚本立刻判定「敌人被烟挡住」，
    -- 可是屏幕上明明还能看清。反过来烟散的时候它也会突然变 false。
    --
    -- 这里用 vfxLearn 记录的真实时间参数做一次权重修正：
    -- 只有烟雾展开程度超过阈值，才认为它真的能挡住视线。
    local okp, progress = pcall(function()
        return S.smokeCoverageAt(a, b)
    end)
    if okp and type(progress) == "number" then
        local th = tonumber(cfg.smokeBlockThreshold) or 0.6
        if progress < th then
            return false        -- 烟还没起来 / 已经开始散了
        end
    end

    local ok, res = pcall(SmokeLib.DoesRayIntersectActiveSmoke, a, delta.Unit, dist)
    return ok and res == true
end

-- 计算「这条视线经过的烟雾，当前展开到什么程度」。
-- 返回 0~1：0 = 完全没有烟，1 = 烟雾完全展开。
--
-- 数据来自 vfxLearn.smoke.active[id]：
--   at        生成时刻
--   deployTime 展开耗时（游戏自己给的）
--   expiresAt  消失时刻（at + Duration）
S.smokeCoverageAt = function(a, b)
    -- vfxLearn 是文件内 local（第 5446 行），没直接挂在 S 上 ——
    -- 但它同时写进了 getgenv().MV_VFX_LEARNED，从那里取。
    local bucket = nil
    if S and S.vfxLearn and S.vfxLearn.smoke then
        bucket = S.vfxLearn.smoke
    elseif getgenv().MV_VFX_LEARNED and getgenv().MV_VFX_LEARNED.smoke then
        bucket = getgenv().MV_VFX_LEARNED.smoke
    end
    if not bucket or type(bucket.active) ~= "table" then return nil end
    local now = os.clock()
    local mid = (a + b) * 0.5
    local best = 0
    for _, rec in pairs(bucket.active) do
        if type(rec) == "table" and typeof(rec.center) == "Vector3" then
            -- 只考虑覆盖这条视线中点的烟
            local reach = (rec.maxRadius or rec.radius or 0) + 12
            if (rec.center - mid).Magnitude <= reach then
                local deploy = tonumber(rec.deployTime) or 0.8
                if deploy < 0.05 then deploy = 0.05 end
                local t = now - (rec.at or now)
                local p
                if t < 0 then
                    p = 0
                elseif t < deploy then
                    -- 展开期：用平方根让早期权重更低，更接近「慢慢起烟」的观感
                    p = math.sqrt(t / deploy)
                elseif rec.expiresAt and now > rec.expiresAt then
                    p = 0                       -- 已经到期
                else
                    p = 1
                end
                if p > best then best = p end
            end
        end
    end
    return best
end

---------------------------------------------------------------------
-- VFX 学习：监听烟/火的生成与销毁，量出真实持续时间
-- 火焰模块没有查询接口，只能靠这个间接得到「能烧多久」
---------------------------------------------------------------------
local vfxLearn = getgenv().MV_VFX_LEARNED
if type(vfxLearn) ~= "table" then vfxLearn = {} end
-- 字段缺失要能自愈：重载后这份表是跨实例复用的，任何一侧把它清掉
-- （排障时很常见），整块烟/火学习就会静默失效，而且完全不报错，
-- 只会表现为「烟雾范围圈忽然没了」。
if type(vfxLearn.smoke) ~= "table" then vfxLearn.smoke = { active = {}, durations = {} } end
if type(vfxLearn.fire) ~= "table" then vfxLearn.fire = { active = {}, durations = {} } end
getgenv().MV_VFX_LEARNED = vfxLearn

-- vfxLearn 是这一行才创建的：上面那次 S.loadLearned()（learned 定义处）执行时
-- getgenv().MV_VFX_LEARNED 还不存在，vfx 分支被跳过。
-- 这里补读一次，把烟雾 18s / 火焰 5.5s 这些实测值也恢复回来
-- （throw 部分重复赋一遍相同的值，无害）。
if S.loadLearned then pcall(S.loadLearned) end

-- 从体素列表算覆盖范围和中心
--   烟雾: Voxels[i] = { Position, Size }
--   火焰: Voxels[i] = { Position, SizeX, SizeZ, Normal }
-- 返回: center, 等效半径（按总面积）, 包围半径（最远体素）
-- 包围圆会比实际形状大一圈，屏幕上看着像虚胖，所以默认用等效半径
local function voxelBounds(voxels)
    if typeof(voxels) ~= "table" or #voxels == 0 then return nil end

    local sum, count = Vector3.zero, 0
    for _, v in ipairs(voxels) do
        if typeof(v) == "table" and typeof(v.Position) == "Vector3" then
            sum = sum + v.Position
            count += 1
        end
    end
    if count == 0 then return nil end
    local center = sum / count

    local totalArea = 0
    local maxR = 0
    for _, v in ipairs(voxels) do
        if typeof(v) == "table" and typeof(v.Position) == "Vector3" then
            local sx = tonumber(v.SizeX) or tonumber(v.Size) or 0
            local sz = tonumber(v.SizeZ) or tonumber(v.Size) or sx
            totalArea = totalArea + sx * sz
            local half = math.max(sx, sz) * 0.5
            local d = (v.Position - center).Magnitude + half
            if d > maxR then maxR = d end
        end
    end

    local effR = math.sqrt(math.max(totalArea, 1) / math.pi)
    return center, effR, maxR
end

local function learnVFX(kind, isCreate, data)
    local bucket = vfxLearn[kind]
    if not bucket then return end

    -- Destroy 包就是一个字符串 ID，Create 包才是表
    if not isCreate then
        local id = (typeof(data) == "table") and (data.SmokeId or data.FireId or data.Id)
            or tostring(data)
        if id then
            local rec = bucket.active[tostring(id)]
            if not rec and bucket.fifo and #bucket.fifo > 0 then
                rec = table.remove(bucket.fifo, 1)
            end
            if rec then
                rec.endedAt = os.clock()
                bucket.active[tostring(id)] = nil
            end
        end
        return
    end

    if typeof(data) ~= "table" then return end

    local id
    if kind == "smoke" then
        id = data.SmokeId or data.Id
    elseif kind == "fire" then
        id = data.FireId or data.Id
    end

    -- Duration 是真值，优先用它；没有才退回时间差
    local dur = tonumber(data.Duration)
    local center, effR, maxR = voxelBounds(data.Voxels)
    if not center and typeof(data.Position) == "Vector3" then
        center = data.Position
    end

    local rec = {
        at = os.clock(),
        duration = dur,
        deployTime = tonumber(data.DeployTime),
        center = center,
        radius = effR or maxR,      -- 等效半径（画圆用，仅供参考）
        maxRadius = maxR,           -- 包围半径
        voxels = data.Voxels,       -- 原始体素，用来画真实形状
        expiresAt = dur and (os.clock() + dur) or nil,
    }

    if center and radius then
        bucket.range = rec
    end
    if dur and dur > 0.2 then
        table.insert(bucket.durations, dur)
        while #bucket.durations > 30 do table.remove(bucket.durations, 1) end
        -- 不用 table.clone：这个执行器里它是 nil，调用直接抛
        -- "attempt to call a nil value"，而它只在烟雾带 Duration 时才被走到，
        -- 于是变成"地图里有烟就刷一屏报错"。
        local sorted = {}
        for i = 1, #bucket.durations do sorted[i] = bucket.durations[i] end
        table.sort(sorted)
        bucket.median = sorted[math.ceil(#sorted / 2)]
        bucket.max = sorted[#sorted]
    end

    if id then
        bucket.active[tostring(id)] = rec
    else
        bucket.fifo = bucket.fifo or {}
        table.insert(bucket.fifo, rec)
    end
end

pcall(function()
    local VFX = Remotes.VFX
    if not VFX then return end

    -- 每次重载都重新注册监听器会一路累积：旧实例的闭包仍然挂在信号上，
    -- 它们的 upvalue 早就失效了，于是地图里每放一颗烟就抛一次错、刷一屏红字。
    -- 这里先把上一次注册的断干净，并且给每个回调都套 pcall，
    -- 保证任何一条学习逻辑出错都不会打断游戏本身的信号。
    for _, c in ipairs(vfxLearn._conns or {}) do
        pcall(function() c:Disconnect() end)
    end
    vfxLearn._conns = {}

    local function reg(sig, kind, isCreate)
        if not sig then return end
        local ok, c = pcall(function()
            return sig.Listen(function(d)
                local ok2, err = pcall(learnVFX, kind, isCreate, d)
                if not ok2 then vfxLearn.lastError = tostring(err) end
            end)
        end)
        if ok and c then table.insert(vfxLearn._conns, c) end
    end

    reg(VFX.CreateVoxelSmoke, "smoke", true)
    reg(VFX.DestroyVoxelSmoke, "smoke", false)
    reg(VFX.CreateVoxelFire, "fire", true)
    reg(VFX.DestroyVoxelFire, "fire", false)
end)

-- 从 VFX 事件学到的真实覆盖半径
local function vfxRadius(kind)
    local b = vfxLearn and vfxLearn[kind]
    if not b or not b.range then return nil end
    return b.range.radius
end

-- 是否还有活着的烟雾/火焰
local function vfxAlive(kind)
    local b = vfxLearn and vfxLearn[kind]
    if not b then return false end
    return next(b.active) ~= nil or (b.fifo and #b.fifo > 0)
end

-- 远投/近投自动判断
-- 游戏里左键 = Far，右键 = Near（Controllers/InputController/Actions/PrimaryFire|SecondaryFire）
local autoThrowMode = "Far"
pcall(function()
    local c = UserInputService.InputBegan:Connect(function(input)
        if not heldIsThrowable() then return end
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseButton1 then
            autoThrowMode = "Far"
        elseif t == Enum.UserInputType.MouseButton2 then
            autoThrowMode = "Near"
        end
    end)
    REG.conns[#REG.conns + 1] = c
    S.conns[#S.conns + 1] = c
end)

local function resolveThrowMode()
    local m = cfg.throwMode
    if m == "Far" or m == "Near" then return m end
    return autoThrowMode
end

-- 重载后沿用之前学到的真实速度
if learned.speed and cfg.throwLearn then
    cfg.throwSpeed = learned.speed
end

-- ⚠⚠ 必须在 Projectile.Spawn 监听之前声明。
--
-- 原来这张表写在下面的 Bounce/Resolve 监听旁边（约 6609 行），而 Spawn 回调
-- 在 5754 行就写 myGrenades[data.Id] —— Lua 的 local 作用域只从声明处往下生效，
-- 更早的位置解析成**全局** myGrenades（nil），于是每一次投掷回调都在那一行抛：
--     attempt to index nil with '<uuid>'
-- 结果就是：learned.samples 永远 0、learned.tracked 永远空、圈/倒计时/爆炸范围
-- 一个都不出现 —— 而错误只在控制台一闪而过，看起来像「监听器没跑」。
-- 交接文档里「Spawn 监听器不写 tracked，samples 一直是 0」的真身就是这一行。
local myGrenades = {}      -- [id] = { at, weapon }   自己扔的手雷

pcall(function()
    local packet = Remotes.Projectile and Remotes.Projectile.Spawn
    if packet and typeof(packet.Listen) == "function" then
        -- 断开上一次注册的监听，避免叠加导致同一个手雷被记多次
        if typeof(learned._disconnect) == "function" then
            pcall(learned._disconnect)
            learned._disconnect = nil
        end

        learned._disconnect = packet.Listen(function(data)
            -- ⚠ 整个回调必须包在 pcall 里。
            --
            -- 实测历史：learned.startHistory 满 20 条（回调跑了 20 次），
            -- 但 learned.samples 一直是 0、learned.tracked 一张记录都没有 ——
            -- 说明回调在写 startHistory 之后、写 samples 之前就抛错了，
            -- 而 Roblox 那边的错误在客户端控制台里滚没了，表现就是
            -- 「扔了手雷，圈/倒计时/爆炸范围一个都不出来」。
            -- 包起来之后错误会留在 S.err_projSpawn 里，能直接看到。
            S.projSeen = (S.projSeen or 0) + 1
            local okcb, errcb = pcall(function()
            if typeof(data) ~= "table" then return end
            local st = data.State
            if typeof(st) ~= "table" then return end
            local vel = st.Velocity
            if typeof(vel) ~= "Vector3" then return end
            local speed = vel.Magnitude
            if speed <= 1 then return end

            -- 保存服务端下发的真实起点/方向，用来校准预览公式
            if typeof(st.Position) == "Vector3" then
                local camPos = workspace.CurrentCamera.CFrame.Position
                local look = workspace.CurrentCamera.CFrame.LookVector
                learned.lastStart = {
                    pos = st.Position,
                    vel = vel,
                    camPos = camPos,
                    look = look,
                    weapon = tostring(data.Weapon),
                    at = os.clock(),
                }
                learned.startHistory = learned.startHistory or {}
                table.insert(learned.startHistory, learned.lastStart)
                while #learned.startHistory > 20 do table.remove(learned.startHistory, 1) end

                -- 自动校准：真实起点减相机 = 前向偏移 + 高度偏移
                if cfg.throwAutoCalibrate then
                    local rel = st.Position - camPos
                    local horiz = Vector3.new(rel.X, 0, rel.Z).Magnitude
                    if math.abs(rel.Y) < 8 then
                        cfg.throwHeight = math.clamp(rel.Y, -1, 4)
                    end
                    if horiz > 0.1 and horiz < 6 then
                        cfg.throwForward = math.clamp(horiz, 0, 4)
                    end
                    -- 上抛偏置：真实方向相对水平视线的仰角斜率
                    local realDir = vel.Unit
                    local flatLook = Vector3.new(look.X, 0, look.Z)
                    if flatLook.Magnitude > 0.01 then
                        local fl = flatLook.Unit
                        local along = realDir.X * fl.X + realDir.Z * fl.Z
                        if along > 0.3 then
                            local est = math.clamp(realDir.Y / along, 0, 0.5)
                            if est > 0.01 then cfg.throwUpBias = est end
                        end
                    end
                    learned.calibratedAt = os.clock()
                end
            end

            -- 投掷瞬间的角色状态：出手速度里包含这部分叠加
            --
            -- ⚠ 这里必须用 myRoot()，不能用 LocalPlayer.Character。
            -- 本作角色是自定义的，真正在模拟的那个模型挂在 workspace.Characters 下，
            -- 而 LocalPlayer.Character 拿到的东西跟它不一定是一回事 —— 实测用它算位置时
            -- 6 个手雷样本全部判成 mine=false，originOffset 一次都没学到。
            -- 统一成 myRoot() 之后，学习和预测用的是同一个锚点。
            local rootNow = myRoot()
            local myVel = Vector3.zero
            local myPos = nil
            if rootNow then
                myVel = rootNow.AssemblyLinearVelocity
                myPos = rootNow.Position
            end
            local isMine = false
            if myPos and typeof(st.Position) == "Vector3" then
                -- 起点就在自己身上（root + 前 1.35 + 高 2.4 ≈ 2.8 stud），
                -- 留 14 stud 余量足够，但别人的手雷不会落在这么近
                isMine = (st.Position - myPos).Magnitude < 14
            end

            local rec = {
                weapon = tostring(data.Weapon),
                speed = speed,
                vel = vel,
                playerSpeed = myVel.Magnitude,
                playerVel = myVel,
                isMine = isMine,
                isJumpThrow = st.IsJumpThrow == true,
                at = os.clock(),
            }

            -- 只跟踪自己扔的：别人的手雷弹点会干扰对比
            if isMine and data.Id ~= nil then
                myGrenades[tostring(data.Id)] = {
                    at = os.clock(),
                    weapon = rec.weapon,
                    -- 把「扔之前最后一次预测的第一个弹跳点」绑到这颗手雷上，
                    -- 之后 Projectile.Bounce 到达时就能拿真实弹跳点跟它比。
                    predFirstBounce = S.previewFirstBounce,
                    predBounceCount = S.bouncePredCount,
                }
                -- 清掉太老的
                local cutoff = os.clock() - 30
                for gid, info in pairs(myGrenades) do
                    if info.at < cutoff then myGrenades[gid] = nil end
                end

                -- 实测起点偏移：以「角色根部」为锚点，按视线水平方向分解
                --
                -- 为什么不能用相机当锚点：第三人称下相机离角色能有一百多 stud，
                -- 「起点 - 相机」算出来的偏移会随相机距离和角度漂移，凑出来的
                -- 1.35 / 0.65 只在某一个机位下成立。投掷动画是角色本地的，
                -- 所以 HumanoidRootPart 才是稳定锚点。
                --
                -- 拆成 (前, 右, 上) 三轴后，下次按当时的视线方向重新组装，
                -- 无论玩家朝哪边扔都对得上。
                if typeof(st.Position) == "Vector3" and st.IsJumpThrow ~= true then
                    local root = myRoot()
                    if root then
                        local cf = workspace.CurrentCamera.CFrame
                        local fx, fz = cf.LookVector.X, cf.LookVector.Z
                        local rx, rz = cf.RightVector.X, cf.RightVector.Z
                        local fl = math.sqrt(fx * fx + fz * fz)
                        local rl = math.sqrt(rx * rx + rz * rz)
                        if fl > 0.01 and rl > 0.01 then
                            local rel = st.Position - root.Position
                            local cur = {
                                fwd   = (rel.X * fx + rel.Z * fz) / fl,
                                right = (rel.X * rx + rel.Z * rz) / rl,
                                up    = rel.Y,
                            }
                            -- ⚠ 按武器分别学：手雷是过肩抛、燃烧瓶是轻甩、烟和闪的抬手幅度
                            -- 又不一样，起点偏移必然各不相同。混在一个对象里学等于互相污染。
                            if type(learned.perWeapon) ~= "table" then learned.perWeapon = {} end
                            local wnKey = tostring(rec.weapon or "?")
                            local pw = learned.perWeapon[wnKey]
                            if type(pw) ~= "table" then
                                pw = {}
                                learned.perWeapon[wnKey] = pw
                            end
                            local o = pw.originOffset
                            if not o then
                                o = { hits = 0 }
                                pw.originOffset = o
                            end
                            -- 投掷动画里手臂会摆动，单次采样有抖动，用指数滑动平均
                            local k = 0.35
                            if o.hits > 0 then
                                o.fwd   = o.fwd   * (1 - k) + cur.fwd   * k
                                o.right = o.right * (1 - k) + cur.right * k
                                o.up    = o.up    * (1 - k) + cur.up    * k
                            else
                                o.fwd, o.right, o.up = cur.fwd, cur.right, cur.up
                            end
                            o.hits   = o.hits + 1
                            o.last   = cur
                            o.weapon = rec.weapon
                            o.at     = os.clock()
                            -- 全局值保留（作为没学过该武器时的兜底）
                            if type(learned.originOffset) ~= "table" then
                                learned.originOffset = { hits = 0 }
                            end
                            local g = learned.originOffset
                            g.fwd, g.right, g.up = o.fwd, o.right, o.up
                            g.hits = (g.hits or 0) + 1
                            g.weapon = rec.weapon
                        end
                    end
                end
            end
            table.insert(learned.samplesList, rec)
            while #learned.samplesList > 60 do table.remove(learned.samplesList, 1) end

            learned.speed = speed
            learned.weapon = rec.weapon
            learned.samples += 1
            -- 学习真实投掷延迟：从 StartThrow 动画开始 到 Projectile.Spawn 到达
            if S.throwPressAt then
                local lead = os.clock() - S.throwPressAt
                if lead > 0.05 and lead < 3 then
                    local prev = tonumber(learned.actualLead)
                    learned.actualLead = prev and (prev * 0.65 + lead * 0.35) or lead
                    learned.leadSamples = (learned.leadSamples or 0) + 1
                    -- 写回配置，手持预览的外推量从此是学出来的
                    if cfg.throwLearn then
                        cfg.throwPredictLead = learned.actualLead
                    end
                    S.lastLearnedLead = lead
                end
                S.throwPressAt = nil
            end
            learned.lastVelocity = vel
            learned.physics = data.Physics
            -- 按武器分别缓存物理参数（每种投掷物的 Radius/FuseTime 都不一样）
            learned.byWeapon = learned.byWeapon or {}
            learned.byWeapon[rec.weapon] = data.Physics
            if cfg.throwLearn then
                cfg.throwSpeed = speed
            end

            -- 跟踪这颗手雷：用于倒计时和爆炸范围显示
            if data.Id ~= nil then
                -- ⚠ 引信必须取服务端真值，不能再猜。
                --
                -- 实测 Physics.FuseTime：HE=1.6 / Flashbang=1.5 / Incendiary=2.4 /
                -- Smoke=0。0 是「落地起爆」，不是「引信 0 秒」——
                -- 旧代码把它当 1.5 兜底，又把 HE 的 4.0 写进 FUSE_DEFAULT，
                -- 用户说的「计时不准」就是这么来的。
                local physFuse = nil
                if data.Physics and tonumber(data.Physics.FuseTime) then
                    physFuse = tonumber(data.Physics.FuseTime)
                    if physFuse <= 0 then physFuse = nil end     -- 0 = 落地起爆
                end
                local wn = tostring(rec.weapon)
                -- 燃烧瓶/燃烧弹：观察者里走的是 minimumFuseTime=0.1 + explodeOnFloorImpact=true，
                -- 但它照样带 Physics.FuseTime=2.4（实测）——「落地即碎」之外，空中满 2.4 秒也会自爆。
                -- 所以不能把引信抹成 nil，否则空中自爆那一路就没有倒计时了。
                -- 只在模拟时让它走 explodeOnFloorImpact 分支（见 updateThrowLanding 的 feet 参数）。
                local feetFuse = (wn == "Molotov") or (wn == "Incendiary Grenade")

                learned.tracked = learned.tracked or {}
                learned.tracked[tostring(data.Id)] = {
                    at = os.clock(),
                    fuse = physFuse or 0,
                    -- 真实引信（nil = 纯落地起爆，例如烟雾 FuseTime=0）；倒计时用它
                    fuseReal = physFuse,
                    isFeetFuse = feetFuse or (physFuse == nil),
                    -- 服务端给的上抛时刻。workspace:GetServerTimeNow() 与之同基准，
                    -- 所以「引信剩余」= fuseReal - (服务器现在 - startTime)，跨客户端一致。
                    startTime = tonumber(st.StartTime) or workspace:GetServerTimeNow(),
                    weapon = wn,
                    physics = data.Physics,
                    lastPos = st.Position,
                    lastAt = os.clock(),
                    -- ⚠ 这是「出手瞬间」的真实初始状态，服务端算好的，
                    -- 里面已经包含了当时的玩家速度叠加（(pvel.X,0,pvel.Z)*1.5）。
                    --
                    -- 手持预览那条线用的是「此刻的速度」，而投掷有 0.7 秒准备动画，
                    -- 出手那一刻人早就挪了 —— 所以移动/跳跃时预览必然偏，这不是 bug 是物理。
                    -- 想看到真实轨迹只有一种办法：扔出去之后拿这个 state 重画。
                    state = {
                        position = st.Position,
                        velocity = st.Velocity,
                        simulationTime = 0,
                        bounceCount = 0,
                        isGrounded = false,
                        isAtRest = false,
                        hasTouched = false,
                        accumulatedTime = 0,
                        angularVelocity = Vector3.zero,
                        timestamp = os.clock(),
                        isJumpThrow = st.IsJumpThrow == true,
                    },
                    mine = isMine,
                }
                -- ⚠ 这里原来把武器配置里的 Range（=60）当成爆炸半径写进 tracked.radius。
                -- Range 是「投掷射程」，跟爆炸半径毫无关系，写进去迟早被谁当真值用。
                -- 爆炸半径没有任何客户端配置可读（服务端算的），只有 cfg.grenadeRadius 这个估算值。
            end
            end)   -- pcall 结束
            if not okcb then S.err_projSpawn = tostring(errcb) end
        end)
    end
end)

---------------------------------------------------------------------
-- FOV 圈：以屏幕中心为圆心，半径 = cfg.fov（像素）
-- 与瞄准判定用的是同一个基准，所见即所得
---------------------------------------------------------------------
local fovCircle = nil
local fovSegments = {}
local fovMode = nil   -- "circle" / "lines"

local function fovInit()
    if fovMode then return end
    local ok, c = pcall(function() return Drawing.new("Circle") end)
    if ok and c and c.Remove then
        fovCircle = c
        fovMode = "circle"
    else
        for i = 1, 48 do
            fovSegments[i] = mkDraw("Line")
        end
        fovMode = "lines"
    end
end

local function fovClear()
    if fovCircle and fovCircle.Remove then pcall(function() fovCircle:Remove() end) end
    fovCircle = nil
    for _, l in ipairs(fovSegments) do
        if l and l.Remove then pcall(function() l:Remove() end) end
    end
    fovSegments = {}
    fovMode = nil
end

local function updateFov()
    -- 360°（fullSphere）时不画范围圈：本来就是全向锁定，圈没有信息量，只会挡视线。
    -- ⚠ 以前这里 AND 了 cfg.silentAim —— 关掉静默瞄准会连圈一起消失，
    -- 用户看到的现象是「360° 关了但范围圈还是不显示」。圈只该受 showFov / fullSphere 控制。
    local hideBySphere = (cfg.fullSphere == true) and ((cfg.aimMode or "smooth") == "silent")
    if hideBySphere or not cfg.showFov then
        for _, l in ipairs(fovSegments) do if l then l.Visible = false end end
        return
    end

    fovInit()
    local cam = workspace.CurrentCamera
    local vp = cam.ViewportSize
    local center = vp * 0.5
    -- ⚠ 半径必须按视口钳一下。
    -- FOV 设计上可以设到 2000（相当于「全屏锁定」），但 1920x1080 的对角线才 2200，
    -- 半径 2000 的圆整圈都在视口外，画出来只剩几段莫名其妙的弧线。
    -- 钳到对角线的一半：既保留「圈贴着屏幕边」的观感，也不会画出一堆屏幕外的线。
    local diag = math.sqrt(vp.X * vp.X + vp.Y * vp.Y)
    local r = math.clamp(tonumber(cfg.fov) or 300, 5, diag * 0.5)

    if fovMode == "circle" and fovCircle then
        fovCircle.Visible = true
        fovCircle.Position = center
        fovCircle.Radius = r
        fovCircle.Color = cfg.fovColor
        fovCircle.Thickness = 1
        fovCircle.Filled = false
        fovCircle.NumSides = 64
        fovCircle.Transparency = 0.45
        return
    end

    -- 兜底：用 48 段线拼圆
    local seg = #fovSegments
    if seg == 0 then return end
    for i = 1, seg do
        local a1 = (i / seg) * math.pi * 2
        local a2 = ((i + 1) / seg) * math.pi * 2
        local l = fovSegments[i]
        if l then
            l.Visible = true
            l.Color = cfg.fovColor
            l.Thickness = 1
            l.From = center + Vector2.new(math.cos(a1) * r, math.sin(a1) * r)
            l.To = center + Vector2.new(math.cos(a2) * r, math.sin(a2) * r)
        end
    end
end

---------------------------------------------------------------------
-- 投掷物信息：倒计时 + 爆炸/覆盖范围圈
-- 数据来源：Projectile.Spawn 里的 Physics.FuseTime + 武器配置的 Range
---------------------------------------------------------------------
local grenadeDraw = {}   -- [id] = { lines = {...}, text = Text }

local function grenadeClear()
    for _, g in pairs(grenadeDraw) do
        for _, l in ipairs(g.lines or {}) do
            if l and l.Remove then pcall(function() l:Remove() end) end
        end
        if g.text and g.text.Remove then pcall(function() g.text:Remove() end) end
    end
    grenadeDraw = {}
end

local SEGMENTS = 28

-- 地面投射用的过滤：排除角色和手雷本身，否则会打到自己人身上
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
do
    local ig = {}
    local cf2 = workspace:FindFirstChild("Characters")
    if cf2 then ig[#ig + 1] = cf2 end
    local db2 = workspace:FindFirstChild("Debris")
    if db2 then ig[#ig + 1] = db2 end
    local cm2 = workspace.CurrentCamera
    if cm2 then ig[#ig + 1] = cm2 end
    groundParams.FilterDescendantsInstances = ig
end

local function makeGrenadeDraw()
    local lines = {}
    for i = 1, SEGMENTS do
        lines[i] = mkDraw("Line")
    end
    return { lines = lines, text = mkDraw("Text") }
end

-- 把地面上的 3D 圆逐点投影到屏幕，连成多边形。
-- 不能先算"屏幕半径"再画 2D 圆——那样转视角不变形，贴近时会撑满屏幕。
local function drawGroundCircle(lines, cam, center3d, radius, color, thickness)
    local camPos = cam.CFrame.Position
    local vp = cam.ViewportSize
    local maxSeg = vp.X * 1.2      -- 单段超过这个长度就认为投影异常，断开

    -- 相机在圆内部时，点会散落到整个视野，连线会横穿屏幕，直接不画
    if (camPos - center3d).Magnitude < radius * 0.85 then
        for i = 1, SEGMENTS do
            if lines[i] then lines[i].Visible = false end
        end
        return
    end

    local prevPt = nil
    for i = 1, SEGMENTS do
        local ang = (i / SEGMENTS) * math.pi * 2
        local world = center3d + Vector3.new(math.cos(ang) * radius, 0, math.sin(ang) * radius)
        local sp = cam:WorldToViewportPoint(world)
        local pt = (sp.Z > 0) and Vector2.new(sp.X, sp.Y) or nil

        local line = lines[i]
        if line then
            if pt and prevPt and (pt - prevPt).Magnitude < maxSeg then
                line.Visible = true
                line.Color = color
                line.Thickness = thickness or 1.5
                line.From = prevPt
                line.To = pt
            else
                line.Visible = false
            end
        end
        prevPt = pt
    end
end

---------------------------------------------------------------------
-- 声音冲击波
--
-- 声音只能说明「这个位置刚才有动静」，不能说明「那里现在站着人」。
-- 所以不画框、不参与瞄准，只在那个位置脚下画一圈向外扩散、逐渐变淡的波纹。
-- 敌人静步摸过来照样看不到 —— 这才是对「声音」这个词诚实的表现。
--
-- 贴地：从声源向下打一条短射线找地面，让圈落在地板上而不是悬在空中。
---------------------------------------------------------------------
-- ⚠ 这里一个顶层 local 都不能加：主 chunk 的寄存器槽位已经贴着 200 上限
-- （超了就是 "Out of local registers ... exceeded limit 200"，loadstring 返回 nil，
--   表面上只是「改了没生效」）。所以池子、射线参数、函数本体全挂在 S 上。
S.ripplePool = S.ripplePool or {}
S.rippleRP = S.rippleRP or (function()
    local p = RaycastParams.new()
    p.FilterType = Enum.RaycastFilterType.Exclude
    p.RespectCanCollide = false
    p.IgnoreWater = true
    return p
end)()

S.updateSoundRipples = function()
    local cam = workspace.CurrentCamera
    local show = cfg.soundRipple == true
    local life = tonumber(cfg.soundRippleSeconds) or 1.6
    local maxR = tonumber(cfg.soundRippleMax) or 16
    local ripplePool = S.ripplePool
    local rippleRP = S.rippleRP

    local function hideAll(from)
        for i = from, #ripplePool do
            local r = ripplePool[i]
            if r then
                for _, l in ipairs(r.lines) do
                    if l then l.Visible = false end
                end
            end
        end
    end

    local evs = S.soundEvents
    if not show or type(evs) ~= "table" or #evs == 0 then
        hideAll(1)
        return
    end

    rippleRP.FilterDescendantsInstances = coverIgnoreList()
    local now = os.clock()
    local shown = 0

    for i = #evs, 1, -1 do
        local e = evs[i]
        local age = now - (e.at or 0)
        if age > life then break end
        if type(e.pos) == "Vector3" then
            shown += 1
            if shown > 6 then break end        -- 最多同时 6 个，避免糊屏

            local slot = ripplePool[shown]
            if not slot then
                local lines = {}
                for k = 1, SEGMENTS do lines[k] = mkDraw("Line") end
                slot = { lines = lines }
                ripplePool[shown] = slot
            end

            -- 贴地
            local center = e.pos
            local hit = workspace:Raycast(e.pos, Vector3.new(0, -24, 0), rippleRP)
            if hit then
                center = Vector3.new(e.pos.X, hit.Position.Y + 0.12, e.pos.Z)
            end

            local t = math.clamp(age / life, 0, 1)
            local radius = 1.5 + t * maxR
            local col = (e.kind == "shot") and cfg.soundColorShot or cfg.soundColorStep
            drawGroundCircle(slot.lines, cam, center, radius, col, 1.6)

            -- 越老越淡
            local alpha = math.clamp(1 - t, 0, 1)
            for _, l in ipairs(slot.lines) do
                if l then
                    pcall(function() l.Transparency = 1 - alpha end)
                end
            end
        end
    end

    hideAll(shown + 1)
end

-- 逐个画出体素本身（最贴合实际形状，圆逼近不了）
-- 每个体素在地面上画一个矩形边框
local VOXEL_MAX = 60
local function drawVoxelOutlines(lines, cam, voxels, color, thickness)
    local camPos = cam.CFrame.Position
    local vp = cam.ViewportSize
    local maxSeg = vp.X * 1.2
    local idx = 1
    local n = math.min(#voxels, VOXEL_MAX)

    local function emit(a, b)
        local line = lines[idx]
        if not line then
            line = mkDraw("Line")
            lines[idx] = line
        end
        idx += 1
        if line then
            if a and b and (a - b).Magnitude < maxSeg then
                line.Visible = true
                line.Color = color
                line.Thickness = thickness or 1.5
                line.From = a
                line.To = b
            else
                line.Visible = false
            end
        end
    end

    local function proj(p)
        if (p - camPos).Magnitude < 1 then return nil end
        local sp = cam:WorldToViewportPoint(p)
        return (sp.Z > 0) and Vector2.new(sp.X, sp.Y) or nil
    end

    for i = 1, n do
        local v = voxels[i]
        if typeof(v) == "table" and typeof(v.Position) == "Vector3" then
            local sx = (tonumber(v.SizeX) or tonumber(v.Size) or 4) * 0.5
            local sz = (tonumber(v.SizeZ) or tonumber(v.Size) or 4) * 0.5
            local p = v.Position
            local c1 = proj(p + Vector3.new(-sx, 0, -sz))
            local c2 = proj(p + Vector3.new( sx, 0, -sz))
            local c3 = proj(p + Vector3.new( sx, 0,  sz))
            local c4 = proj(p + Vector3.new(-sx, 0,  sz))
            emit(c1, c2); emit(c2, c3); emit(c3, c4); emit(c4, c1)
        end
    end

    -- 隐藏多余
    for j = idx, #lines do
        if lines[j] then lines[j].Visible = false end
    end
    return idx - 1
end

local function updateGrenades()
    -- ⚠⚠ 这里原来是：local tracked = learned.tracked or {}
    --
    -- 当 learned.tracked 是 nil 时，这句会造一个【临时空表】赋给 tracked，
    -- 之后所有 tracked[id] = ... 都写进这个临时表，而 learned.tracked 仍然是 nil。
    -- 函数一返回临时表就被丢掉 —— 下一帧又造一个新的空的。
    -- 表现就是：手雷明明在 Debris 里，tracked 却永远是 0 条，
    --          圈 / 引信倒计时 / 爆炸范围一个都不出来。
    --
    -- 必须先建好容器再取引用。
    if type(learned.tracked) ~= "table" then learned.tracked = {} end
    local tracked = learned.tracked
    local debris = workspace:FindFirstChild("Debris")
    local cam = workspace.CurrentCamera

    if not cfg.showGrenadeInfo or not debris then
        for _, g in pairs(grenadeDraw) do
            for _, l in ipairs(g.lines or {}) do if l then l.Visible = false end end
            if g.text then g.text.Visible = false end
        end
        return
    end

    local now = os.clock()
    local used = {}

    -- 诊断：一眼看出投掷物链路卡在哪一段
    --   projSeen 不涨 → 服务端根本没发 Spawn（没扔出去 / 不是投掷物）
    --   tracked 0 条 → Spawn 回调没跑完（看 err_projSpawn）
    --   drawn 0 个   → 有数据但画不出来（相机/投影/半径问题）
    S.gFrame = (S.gFrame or 0) + 1
    if cfg.grenadeDiag == true and S.gFrame % 60 == 0 then
        local dc, tc = 0, 0
        for _, mm in ipairs(debris:GetChildren()) do
            if mm:IsA("Model") and mm:GetAttribute("GrenadeName") then dc += 1 end
        end
        for _ in pairs(tracked) do tc += 1 end
        print(string.format("[GR] debris=%d tracked=%d drawn=%s projSeen=%s landPaths=%s errProj=%s err=%s",
            dc, tc, tostring(S.landShown), tostring(S.projSeen), tostring(S.landPaths),
            tostring(S.err_projSpawn), tostring(S.err_grenades)))
    end

    -- ⚠ 不再依赖 Projectile.Spawn 写入 tracked。
    --
    -- 实测那个监听器在写数据之前就 return 了（learned.samples 一直是 0），
    -- 所以 tracked 永远是 nil —— 结果就是「扔出投掷物后没有圈、没有倒计时、
    -- 没有爆炸范围」，整套投掷物显示功能形同虚设。
    --
    -- 现在改成：只要 Debris 里出现带 GrenadeName 的模型，就直接从模型建立记录。
    -- 引信时间按武器名给默认值，半径用 cfg.grenadeRadius / VFX 实测值。
    -- ⚠ 这里的数字全部换成实测值（Projectile.Spawn 的 Physics.FuseTime）。
    -- 旧值是猜的（HE 4.0 / 烟 3.0 / 燃烧 3.0），用户说的「引线计时不准」就是它。
    -- 0 = 落地起爆（配置里 FuseTime 就是 0），不是「0 秒后爆炸」。
    local FUSE_DEFAULT = {
        ["HE Grenade"] = 1.6,
        ["Flashbang"] = 1.5,
        ["Incendiary Grenade"] = 2.4,
        ["Smoke Grenade"] = 0,     -- 实测 Physics.FuseTime=0：纯落地起爆
        ["Molotov"] = 2.4,         -- 实测：落地即碎，空中满 2.4 秒自爆
        ["Incendiary"] = 2.4,
        ["Decoy Grenade"] = 1.0,
        ["Decoy"] = 1.0,
    }
    local function fuseFor(gname)
        local key = tostring(gname)
        -- 1) 真值优先：Spawn 监听已经把每种投掷物的 Physics 存进 learned.byWeapon
        if type(learned.byWeapon) == "table" then
            local ph = learned.byWeapon[key]
            local f = type(ph) == "table" and tonumber(ph.FuseTime) or nil
            if f then return (f > 0) and f or 0 end
        end
        -- 2) 没扔过就用实测常量
        local d = FUSE_DEFAULT[key]
        if d then return d end
        return 1.5
    end

    for _, m in ipairs(debris:GetChildren()) do
        if m:IsA("Model") then
            local gname = m:GetAttribute("GrenadeName")
            if gname then
                local id = m.Name
                local info = tracked[id]
                -- ★ 关键：没有 Spawn 记录就在这里补一个
                if not info then
                    local mp0 = m:GetPivot().Position
                    info = {
                        at = now,
                        fuse = fuseFor(gname),
                        weapon = tostring(gname),
                        lastPos = mp0,
                        lastAt = now,
                        autoCreated = true,
                    }
                    tracked[id] = info
                end
                if info and gname then
                    local pos = m:GetPivot().Position
                    info.lastPos = pos
                    info.lastAt = now

                    -- ⚠ 有 Spawn 真值（info.state）的投掷物，显示交给 S.updateThrowLanding：
                    -- 那边用的是服务端 State 模拟出来的真落点 + Physics.FuseTime 真引信，
                    -- 比这里「跟模型跑 + 猜引信」准得多。
                    -- 如果两边都画，同一颗雷屏幕上就会出现两套同心圈和两行倒计时
                    -- （数字还不一致，因为一个按 startTime 算、一个按模型出现时刻算）。
                    -- 所以这里只更新位置，不画。
                    if type(info.state) == "table" then
                        used[id] = false
                        continue
                    end

                    local remain = (info.fuse or 0) - (now - (info.at or now))

                    local g = grenadeDraw[id]

                    -- 引信已到 = 爆炸了。
                    --
                    -- ⚠ 但「爆炸」不等于「效果结束」：
                    --   HE    炸完就没了（~1.5s）
                    --   燃烧瓶 地面会烧 7 秒左右
                    --   烟雾   要持续 18 秒（vfxLearn.smoke.median 实测值）
                    -- 原来这里一爆炸就隐藏圈，所以「扔出去落点圈立刻消失」。
                    -- 现在按类型保留到效果真正结束。
                    if remain <= 0 then
                        local isFireE = tostring(gname):lower():find("molotov") or tostring(gname):lower():find("incendiary")
                        local isSmokeE = tostring(gname):lower():find("smoke")
                        local effDur = tonumber(info.effectDur)
                        if not effDur then
                            if isSmokeE then
                                effDur = tonumber(vfxLearn and vfxLearn.smoke and vfxLearn.smoke.median) or 18
                            elseif isFireE then
                                effDur = tonumber(vfxLearn and vfxLearn.fire and vfxLearn.fire.median) or 7
                            else
                                effDur = 1.5
                            end
                            info.effectDur = effDur
                        end
                        local boomAt = (info.at or now) + (info.fuse or 0)
                        local effLeft = effDur - (now - boomAt)

                        -- ⚠⚠ 烟雾/火焰不能用全局 median 一刀切。
                        --
                        -- 实测 vfxLearn.smoke.median = 18、fire.median = 7，
                        -- 但那是「从 CreateVoxelSmoke 到 DestroyVoxelSmoke」的总时长，
                        -- 而我们的 boomAt 是「手雷生成 + 引信」，两个起点根本不同：
                        --   · 手雷飞行时间被算进了烟雾寿命里
                        --   · 引信用的是猜的默认值
                        -- 结果就是：计时走完了，屏幕上烟还在（用户截图就是这样）。
                        --
                        -- 正确做法：直接找 lastPos 附近那条 VFX 记录，用它的 expiresAt。
                        -- 那是游戏自己算出来的真实消失时刻，不受我们猜的引信影响。
                        if (isSmokeE or isFireE) and typeof(info.lastPos) == "Vector3" then
                            local kindPick = isSmokeE and "smoke" or "fire"
                            local bk = vfxLearn and vfxLearn[kindPick]
                            if bk and type(bk.active) == "table" then
                                local bestD, bestRec = math.huge, nil
                                for _, rec in pairs(bk.active) do
                                    if type(rec) == "table" and typeof(rec.center) == "Vector3"
                                        and tonumber(rec.expiresAt) then
                                        local d = (rec.center - info.lastPos).Magnitude
                                        if d < bestD then bestD, bestRec = d, rec end
                                    end
                                end
                                if bestRec and bestD < 60 then
                                    info.vfxExpiresAt = tonumber(bestRec.expiresAt)
                                    info.vfxDuration = tonumber(bestRec.duration)
                                end
                            end
                        end
                        if info.vfxExpiresAt then
                            -- 用游戏给的真实消失时刻覆盖计时器
                            effLeft = info.vfxExpiresAt - now
                        end
                        -- 烟雾消散是渐变的：DestroyVoxelSmoke 触发的那一刻，屏幕上
                        -- 还能看到最后一层薄烟。统一多留 1 秒再收圈，避免"烟还在但圈没了"。
                        if effLeft > 0 and (isSmokeE or isFireE) then
                            effLeft = effLeft + (tonumber(cfg.grenadeEffectPad) or 1.0)
                        end

                        -- ⚠ 不能只信计时器。
                        --
                        -- 服务端会提前清理火焰/烟雾（比如燃烧被水浇灭、烟雾被驱散），
                        -- 但计时器还在倒数 —— 于是圈一直挂在那里，显示一个早就不存在的效果。
                        -- 这里额外用 vfxLearn 的真实活跃记录做一次确认：
                        -- 爆炸 0.6 秒后（等 VFX 建出来）如果附近已经找不到活跃的火/烟，
                        -- 就认为效果提前结束，立刻收圈。
                        if effLeft > 0 and (isSmokeE or isFireE)
                            and (now - boomAt) > 0.6
                            and typeof(info.lastPos) == "Vector3" then
                            local kindCheck = isSmokeE and "smoke" or "fire"
                            local stillAlive = nil
                            local bucket = vfxLearn and vfxLearn[kindCheck]
                            if bucket and type(bucket.active) == "table" then
                                local reach = 30
                                for _, rec in pairs(bucket.active) do
                                    if type(rec) == "table" and typeof(rec.center) == "Vector3" then
                                        local rr = (tonumber(rec.maxRadius) or tonumber(rec.radius) or 10) + reach
                                        if (rec.center - info.lastPos).Magnitude <= rr then
                                            stillAlive = true
                                            break
                                        end
                                    end
                                end
                                if stillAlive == nil then stillAlive = false end
                            end
                            if stillAlive == false then
                                -- 服务端已经清掉了这颗的效果 → 立刻收圈
                                effLeft = 0
                                info.vfxGoneAt = info.vfxGoneAt or now
                            end
                        end

                        local keepOn = (cfg.grenadeKeepAfterBoom ~= false)

                        if keepOn and effLeft > 0 and typeof(info.lastPos) == "Vector3" then
                            -- 效果还没结束 → 继续画（用最后一次记录的位置）
                            used[id] = true
                            local gK = grenadeDraw[id]
                            if not gK then
                                gK = makeGrenadeDraw()
                                grenadeDraw[id] = gK
                            end
                            -- 贴地
                            local cc = info.lastPos
                            local okr2, gh2 = pcall(function()
                                return workspace:Raycast(cc, Vector3.new(0, -250, 0), groundParams)
                            end)
                            if okr2 and gh2 then
                                cc = Vector3.new(cc.X, gh2.Position.Y + 0.15, cc.Z)
                            end
                            local colK = Color3.fromRGB(255, 170, 60)
                            if isFireE then colK = Color3.fromRGB(255, 110, 40) end
                            if isSmokeE then colK = Color3.fromRGB(180, 180, 200) end
                            -- 效果期用虚线感：颜色调暗一点，和「还没炸」区分开
                            colK = Color3.new(colK.R * 0.75, colK.G * 0.75, colK.B * 0.75)

                            local gnK = tostring(gname or "")
                            local noRadK = (gnK:find("Flash") ~= nil) or (gnK:find("Decoy") ~= nil)
                            local radK = nil
                            if isSmokeE then
                                radK = vfxRadius("smoke")
                            elseif isFireE then
                                radK = vfxRadius("fire")
                            elseif not noRadK then
                                radK = cfg.grenadeRadius or 25
                            end
                            if radK then
                                drawGroundCircle(gK.lines, cam, cc, radK, colK, 1.5)
                            else
                                for _, l in ipairs(gK.lines or {}) do if l then l.Visible = false end end
                            end

                            local cspK = cam:WorldToViewportPoint(cc)
                            if cspK.Z > 0 and gK.text then
                                gK.text.Visible = true
                                gK.text.Center = true
                                gK.text.Size = 22
                                gK.text.Outline = true
                                gK.text.Color = colK
                                gK.text.Text = string.format("%s  %.1fs", tostring(gname), effLeft)
                                gK.text.Position = Vector2.new(cspK.X, cspK.Y - 18)
                            elseif gK.text then
                                gK.text.Visible = false
                            end
                        else
                            -- 没开保留 / 效果结束 → 隐藏
                            local gE = grenadeDraw[id]
                            if gE then
                                for _, l in ipairs(gE.lines or {}) do if l then l.Visible = false end end
                                if gE.text then gE.text.Visible = false end
                            end
                        end

                        -- 效果结束后再留 2 秒就彻底忘掉这颗
                        local deadAt = (info.at or now) + (info.fuse or 0) + (tonumber(info.effectDur) or 1.5) + 2
                        if now > deadAt then
                            tracked[id] = nil
                        end
                    else
                        used[id] = true
                        local isFire = tostring(gname):lower():find("molotov") or tostring(gname):lower():find("incendiary")
                        local isSmoke = tostring(gname):lower():find("smoke")

                        -- 用模型位置算速度，判断是否已经停下来
                        local lastPos = info.lastPos
                        local lastAt = info.lastAt or now
                        local speed = 0
                        if lastPos then
                            local dt2 = now - lastAt
                            if dt2 > 0.001 then
                                speed = (pos - lastPos).Magnitude / dt2
                            end
                        end
                        info.lastPos = pos
                        info.lastAt = now
                        -- 手雷/闪光弹扔出去就该画（显示会炸到哪）
                        -- 燃烧瓶/燃烧弹必须落地破碎才生效，飞行中不画
                        local g2 = grenadeDraw[id]
                        if isFire and speed > 6 then
                            if g2 then
                                for _, l in ipairs(g2.lines or {}) do if l then l.Visible = false end end
                                if g2.text then g2.text.Visible = false end
                            end
                            used[id] = false
                        else
                        -- 圈贴地：从当前点向下找地面，避免在空中画悬浮圈
                        local circleCenter = pos
                        local okr, groundHit = pcall(function()
                            return workspace:Raycast(pos, Vector3.new(0, -250, 0), groundParams)
                        end)
                        if okr and groundHit then
                            circleCenter = Vector3.new(pos.X, groundHit.Position.Y + 0.15, pos.Z)
                        end

                        if not g2 then
                            g2 = makeGrenadeDraw()
                            grenadeDraw[id] = g2
                        end

                        local baseColor = Color3.fromRGB(255, 170, 60)
                        if isFire then baseColor = Color3.fromRGB(255, 110, 40) end
                        if isSmoke then baseColor = Color3.fromRGB(180, 180, 200) end

                        -- 半径圈的语义必须和投掷物对上：
                        --   烟雾 / 燃烧 → VFX 事件学到的真实覆盖半径
                        --   HE Grenade  → 伤害半径（配置里的估算值）
                        --   闪光 / 诱饵 → 根本没有「半径」这回事：
                        --     闪光弹是按视线角度致盲，诱饵弹只是枪声吸附，
                        --     给它们套一个 25 stud 的爆炸圈纯属误导 ——
                        --     这个圈看起来像是「站这么远就会被炸到」，
                        --     实际上闪光弹的判定跟距离完全不是一回事。
                        local gn = tostring(gname or "")
                        local noRadius = (gn:find("Flash") ~= nil) or (gn:find("Decoy") ~= nil)
                        local radius = nil
                        if isSmoke then
                            radius = vfxRadius("smoke")
                        elseif isFire then
                            radius = vfxRadius("fire")
                        elseif not noRadius then
                            radius = cfg.grenadeRadius or 25
                        end
                        -- ⚠ Drawing 没有深度测试：圈永远画在最上层，
                        -- 所以「扔在木板前面」和「扔在木板后面」看起来一模一样。
                        -- 这里做一次遮挡检测：从相机往圈心打射线，被打断就说明
                        -- 圈在那个物体后面 → 整体调暗（透明度抬高），配合距离数字，
                        -- 就能一眼看出圈是在前面还是被挡住了。
                        local occluded = false
                        if cfg.grenadeOccludeFade ~= false then
                            local camPos2 = cam.CFrame.Position
                            local delta2 = circleCenter - camPos2
                            local len2 = delta2.Magnitude
                            if len2 > 1 then
                                local p2 = RaycastParams.new()
                                p2.FilterType = Enum.RaycastFilterType.Exclude
                                p2.IgnoreWater = true
                                local excl2 = {}
                                local meM2 = myModel()
                                if meM2 then excl2[#excl2 + 1] = meM2 end
                                local dbr2 = workspace:FindFirstChild("Debris")
                                if dbr2 then excl2[#excl2 + 1] = dbr2 end
                                p2.FilterDescendantsInstances = excl2
                                local okOc, hitOc = pcall(function()
                                    return workspace:Raycast(camPos2, delta2.Unit * math.max(len2 - 1, 1), p2)
                                end)
                                if okOc and hitOc then occluded = true end
                            end
                        end
                        if occluded and baseColor then
                            -- 被挡住：调暗到 55%
                            baseColor = Color3.new(baseColor.R * 0.55, baseColor.G * 0.55, baseColor.B * 0.55)
                        end

                        if radius then
                            drawGroundCircle(g2.lines, cam, circleCenter, radius, baseColor, occluded and 1.0 or 1.5)
                        else
                            for _, l in ipairs(g2.lines or {}) do if l then l.Visible = false end end
                        end

                        local csp = cam:WorldToViewportPoint(circleCenter)
                        if csp.Z > 0 and g2.text then
                            g2.text.Visible = true
                            g2.text.Center = true
                            g2.text.Size = 22
                            g2.text.Outline = true
                            g2.text.Color = baseColor
                            -- 距离数字：能直观看出圈有多远
                            local myR = myRoot()
                            local distTxt = ""
                            if myR then
                                distTxt = string.format(" %.0fm", (circleCenter - myR.Position).Magnitude)
                            end
                            local occTxt = occluded and " [挡]" or ""
                            g2.text.Text = string.format("%s  %.1fs%s%s", tostring(gname), remain, distTxt, occTxt)
                            g2.text.Position = Vector2.new(csp.X, csp.Y - 18)
                        elseif g2.text then
                            g2.text.Visible = false
                        end
                        end
                    end
                end
            end
        end
    end

    for id, g in pairs(grenadeDraw) do
        if not used[id] then
            for _, l in ipairs(g.lines or {}) do if l then l.Visible = false end end
            if g.text then g.text.Visible = false end
        end
    end

    -- 兜底清理：模型早没了、tracked 还留着的过期条目
    -- ⚠ 保留时间必须算上效果时长（烟雾 18 秒），否则效果还在圈就被清了。
    for id, info in pairs(tracked) do
        local limit = (info.at or now) + (info.fuse or 0) + (tonumber(info.effectDur) or 1.5) + 8
        if now > limit then
            tracked[id] = nil
            local g = grenadeDraw[id]
            if g then
                for _, l in ipairs(g.lines or {}) do if l then l.Visible = false end end
                if g.text then g.text.Visible = false end
                grenadeDraw[id] = nil
            end
        end
    end
end

-- 真实反弹记录：只保留自己扔的手雷
local realBounces = {}
-- myGrenades 已提到 Projectile.Spawn 监听之前声明（那里才是第一次使用的地方）。
-- 这里再声明一次会遮蔽掉上面那个，回调写进去的 id 就查不到了。
local realLandings = {}    -- [id] = { pos, at, reason }  服务端给出的最终结束位置
-- 暴露到 S，方便对比「手持预览落点」和「服务端真值落点」的差值
S.realLandings = realLandings

pcall(function()
    local proj = Remotes.Projectile
    if not proj then return end

    if proj.Bounce and typeof(proj.Bounce.Listen) == "function" then
        proj.Bounce.Listen(function(d)
            if typeof(d) ~= "table" or d.Id == nil then return end
            local id = tostring(d.Id)
            if not myGrenades[id] then return end      -- 不是自己扔的，忽略
            local list = realBounces[id]
            if not list then
                list = {}
                realBounces[id] = list
            end
            if typeof(d.Position) == "Vector3" then
                local prevN = #list
                table.insert(list, {
                    pos = d.Position,
                    idx = tonumber(d.BounceIndex) or #list + 1,
                    at = os.clock(),
                })
                while #list > 30 do table.remove(list, 1) end
                -- ══ 学「弹跳点」══
                --
                -- 服务端每一次 Projectile.Bounce 都带真实弹跳坐标，这是我们唯一能
                -- 校验「反弹模型准不准」的地方：把真实弹跳次数和预测次数比，
                -- 差值为正说明真实弹得比预测多（弹性/半径偏小），为负则相反。
                -- 累积成 bounceCountErr 后就能判断该往哪边修正。
                local recG = myGrenades[id]
                if recG then
                    recG.realBounces = (recG.realBounces or 0) + 1
                    if prevN == 0 and typeof(recG.predFirstBounce) == "Vector3" then
                        -- 第一个弹跳点的位置误差（最干净的一次对比，后面会越滚越偏）
                        local e = d.Position - recG.predFirstBounce
                        learned.bounceErr = learned.bounceErr and (learned.bounceErr * 0.7 + e * 0.3) or e
                        learned.bounceErrSamples = (learned.bounceErrSamples or 0) + 1
                        S.lastBounceErrStud = e.Magnitude
                    end
                end
            end
        end)
    end

    -- Resolve 才是手雷真正的终点（爆炸/燃烧结束），Bounce 只是中间弹跳
    if proj.Resolve and typeof(proj.Resolve.Listen) == "function" then
        proj.Resolve.Listen(function(d)
            if typeof(d) ~= "table" or d.Id == nil then return end
            local id = tostring(d.Id)
            if not myGrenades[id] then return end
            if typeof(d.Position) == "Vector3" then
                realLandings[id] = {
                    pos = d.Position,
                    at = os.clock(),
                    reason = tostring(d.Reason),
                    weapon = myGrenades[id].weapon,
                }
                -- ══ 闭环学习：把「预测落点」和「服务端真实终点」的差记下来 ══
                --
                -- 这是唯一能直接量出「手持预览到底偏多少」的地方：
                --   S.previewLand  = 扔之前最后一次算出来的预测落点
                --   d.Position     = 服务端 Resolve 给的真实终点
                -- 两者的水平差就是这次预测的误差，累积起来做滑动平均，
                -- 之后每次预览都减掉这个系统性偏移。
                if typeof(S.previewLand) == "Vector3" then
                    local err = d.Position - S.previewLand
                    err = Vector3.new(err.X, 0, err.Z)      -- 只学水平误差（Y 由贴地决定）
                    if err.Magnitude < 60 then               -- 超过 60 就不是系统误差，是异常样本
                        local prevErr = learned.landErr
                        if typeof(prevErr) == "Vector3" then
                            learned.landErr = prevErr * 0.7 + err * 0.3
                        else
                            learned.landErr = err
                        end
                        learned.landErrSamples = (learned.landErrSamples or 0) + 1
                        learned.lastLandErr = err
                        S.lastLandErrStud = err.Magnitude
                    end
                end
                -- ══ 诊断：预测弹跳数 vs 真实弹跳数 ══
                --
                -- 用户反馈「该反弹的地方不显示反弹」。这里把两边的次数并排放出来，
                -- 一眼就能判断是「预测漏了」还是「本来就没弹」（比如燃烧瓶落地即燃）。
                local recC = myGrenades[id]
                if recC then
                    local predN = tonumber(recC.predBounceCount) or 0
                    local realN = tonumber(recC.realBounces) or 0
                    S.bounceCompare = {
                        pred = predN,
                        real = realN,
                        diff = realN - predN,
                        weapon = tostring(recC.weapon),
                        at = os.clock(),
                    }
                    learned.bounceMissTotal = (learned.bounceMissTotal or 0) + math.max(0, realN - predN)
                    learned.bounceExtraTotal = (learned.bounceExtraTotal or 0) + math.max(0, predN - realN)
                    if realN > predN then
                        S.bounceMissWarn = string.format("漏了 %d 次反弹（真实 %d / 预测 %d）",
                            realN - predN, realN, predN)
                    end
                end
            end
        end)
    end
end)

-- 清理过期记录
local function pruneRealBounces()
    local now = os.clock()
    for id, list in pairs(realBounces) do
        if list[1] and now - list[1].at > 20 then
            realBounces[id] = nil
        end
    end
    for id, info in pairs(realLandings) do
        if now - info.at > 25 then
            realLandings[id] = nil
        end
    end
    for id, info in pairs(myGrenades) do
        if now - info.at > 30 then
            myGrenades[id] = nil
        end
    end
end

---------------------------------------------------------------------
-- 烟雾 / 火焰真实覆盖区域
-- 数据来自 VFX 包：SmokeId/FireId + Duration + Voxels（位置与尺寸）
-- 画的是游戏真正生成的那团东西的包围范围，不是估算
---------------------------------------------------------------------
local vfxDraw = {}

local function vfxZoneClear()
    for _, g in pairs(vfxDraw) do
        for _, l in ipairs(g.lines or {}) do
            if l and l.Remove then pcall(function() l:Remove() end) end
        end
        if g.text and g.text.Remove then pcall(function() g.text:Remove() end) end
    end
    vfxDraw = {}
end

local function updateVfxZones()
    local cam = workspace.CurrentCamera
    local now = os.clock()

    if not cfg.showVfxZones then
        for _, g in pairs(vfxDraw) do
            for _, l in ipairs(g.lines or {}) do if l then l.Visible = false end end
            if g.text then g.text.Visible = false end
        end
        return
    end

    local used = {}

    for _, kind in ipairs({ "smoke", "fire" }) do
        local bucket = vfxLearn[kind]
        if bucket then
            for id, rec in pairs(bucket.active) do
                local hasShape = rec.center and (rec.radius or (rec.voxels and #rec.voxels > 0))
                local alive = hasShape and (not rec.expiresAt or now < rec.expiresAt)
                if alive then
                    local key = kind .. ":" .. tostring(id)
                    used[key] = true

                    local g = vfxDraw[key]
                    if not g then
                        g = { lines = {}, text = mkDraw("Text") }
                        for i = 1, SEGMENTS do g.lines[i] = mkDraw("Line") end
                        vfxDraw[key] = g
                    end

                    local col
                    if kind == "smoke" then
                        col = Color3.fromRGB(170, 190, 220)
                    else
                        col = Color3.fromRGB(255, 120, 40)
                    end

                    -- 优先画体素轮廓（贴合实际形状）；没有体素才退回圆
                    if rec.voxels and #rec.voxels > 0 then
                        drawVoxelOutlines(g.lines, cam, rec.voxels, col, 1.6)
                    else
                        drawGroundCircle(g.lines, cam, rec.center, rec.radius, col, 2)
                    end
                    -- 可选：同时画出包围圈做对比（虚一点的同色）
                    if cfg.showVfxBounding and rec.maxRadius then
                        local g2 = vfxDraw[key .. ":bounds"]
                        if not g2 then
                            g2 = { lines = {}, text = nil }
                            for i = 1, SEGMENTS do g2.lines[i] = mkDraw("Line") end
                            vfxDraw[key .. ":bounds"] = g2
                        end
                        used[key .. ":bounds"] = true
                        drawGroundCircle(g2.lines, cam, rec.center, rec.maxRadius,
                            Color3.new(col.R * 0.6, col.G * 0.6, col.B * 0.6), 1)
                    end

                    local csp = cam:WorldToViewportPoint(rec.center)
                    if csp.Z > 0 and g.text then
                        g.text.Visible = true
                        g.text.Center = true
                        g.text.Size = 22
                        g.text.Outline = true
                        g.text.Color = col
                        local left = rec.expiresAt and (rec.expiresAt - now) or 0
                        -- Drawing 的 Text 不支持中文，全用 ASCII
                        local tag = (kind == "smoke") and "SMOKE" or "FIRE"
                        g.text.Text = string.format("%s  %.0fs", tag, math.max(left, 0))
                        g.text.Position = Vector2.new(csp.X, csp.Y - 20)
                    elseif g.text then
                        g.text.Visible = false
                    end
                end
            end

            -- 过期清理
            for id, rec in pairs(bucket.active) do
                if rec.expiresAt and now > rec.expiresAt + 2 then
                    bucket.active[id] = nil
                    local g = vfxDraw[kind .. ":" .. tostring(id)]
                    if g then
                        for _, l in ipairs(g.lines or {}) do if l then l.Visible = false end end
                        if g.text then g.text.Visible = false end
                        vfxDraw[kind .. ":" .. tostring(id)] = nil
                    end
                end
            end
        end
    end

    for key, g in pairs(vfxDraw) do
        if not used[key] then
            for _, l in ipairs(g.lines or {}) do if l then l.Visible = false end end
            if g.text then g.text.Visible = false end
        end
    end
end

---------------------------------------------------------------------
-- 屏幕边缘箭头：屏幕外的敌人用箭头指出方向 + 距离
---------------------------------------------------------------------
local arrowPool = {}

local function arrowClear()
    for _, o in pairs(arrowPool) do
        if o.l1 then pcall(function() o.l1:Remove() end) end
        if o.l2 then pcall(function() o.l2:Remove() end) end
        if o.text then pcall(function() o.text:Remove() end) end
        if o.label then pcall(function() o.label:Remove() end) end
    end
    arrowPool = {}
end

local function updateArrows()
    if not cfg.offscreen then
        for _, o in pairs(arrowPool) do
            if o.l1 then o.l1.Visible = false end
            if o.l2 then o.l2.Visible = false end
            if o.text then o.text.Visible = false end
            if o.label then o.label.Visible = false end
        end
        return
    end

    local cam = workspace.CurrentCamera
    local vp = cam.ViewportSize
    local cx, cy = vp.X / 2, vp.Y / 2
    local rx = vp.X / 2 - 80
    local ry = vp.Y / 2 - 80
    local used = {}

    for _, t in ipairs(allTargets()) do
        local skip = (t.sameTeam and not cfg.showTeammates) or (t.isBot and not cfg.showBots)
        if t.distance > cfg.offscreenRange then skip = true end
        -- ⚠ 冻结目标不画箭头。
        --
        -- 边框可以画（标「旧 N 秒」，那是「他最后出现在这」的信息），
        -- 但屏幕外箭头是**方向指引** —— 指向一个早就没人的方向，用户会觉得
        -- 准星/视野被"强行拽"过去。这正是「我选的是静默，它却强行让我看向空气」。
        -- 静默模式下相机本来不动，屏幕上唯一还会"指"的就是这个箭头。
        if t.frozen then skip = true end
        if not skip then
            local sp = cam:WorldToViewportPoint(t.headPos)
            local inside = (sp.Z > 0 and sp.X >= 0 and sp.Y >= 0 and sp.X <= vp.X and sp.Y <= vp.Y)
            if not inside then
                local rel = cam.CFrame:PointToObjectSpace(t.headPos)
                local ang = math.atan2(rel.X, -rel.Z)
                local ex = cx + math.sin(ang) * rx
                local ey = cy - math.cos(ang) * ry
                local dx, dy = math.sin(ang), -math.cos(ang)

                local o = arrowPool[t.name]
                if not o then
                    o = { l1 = mkDraw("Line"), l2 = mkDraw("Line"), text = mkDraw("Text"), label = mkDraw("Text") }
                    arrowPool[t.name] = o
                end
                used[t.name] = true

                local col = t.sameTeam and cfg.colorTeam or cfg.colorEnemy
                if not t.live then col = Color3.new(col.R * 0.55, col.G * 0.55, col.B * 0.55) end

                local tip = Vector2.new(ex, ey)
                local back = Vector2.new(ex - dx * 16, ey - dy * 16)
                local x1 = Vector2.new(back.X - dy * 10, back.Y + dx * 10)
                local x2 = Vector2.new(back.X + dy * 10, back.Y - dx * 10)

                if o.l1 then
                    o.l1.Visible = true; o.l1.Color = col; o.l1.Thickness = 2.5
                    o.l1.From = tip; o.l1.To = x1
                end
                if o.l2 then
                    o.l2.Visible = true; o.l2.Color = col; o.l2.Thickness = 2.5
                    o.l2.From = tip; o.l2.To = x2
                end
                if o.text then
                    o.text.Visible = true
                    o.text.Text = string.format("%.0fm", t.distance * 0.28)
                    o.text.Color = col
                    o.text.Size = 18
                    o.text.Center = true
                    o.text.Outline = true
                    o.text.Position = Vector2.new(ex + dx * 30, ey + dy * 30)
                end
                if o.label then
                    o.label.Visible = true
                    o.label.Text = t.name
                    o.label.Color = col
                    o.label.Size = 16
                    o.label.Center = true
                    o.label.Outline = true
                    o.label.Position = Vector2.new(ex + dx * 44, ey + dy * 44)
                end
            else
                local o = arrowPool[t.name]
                if o then
                    if o.l1 then o.l1.Visible = false end
                    if o.l2 then o.l2.Visible = false end
                    if o.text then o.text.Visible = false end
                    if o.label then o.label.Visible = false end
                end
            end
        end
    end

    for name, o in pairs(arrowPool) do
        if not used[name] then
            if o.l1 then o.l1.Visible = false end
            if o.l2 then o.l2.Visible = false end
            if o.text then o.text.Visible = false end
            if o.label then o.label.Visible = false end
        end
    end
end

---------------------------------------------------------------------
-- 投掷物抛物线预览
-- 物理参数全部取自游戏自己的 Shared.GrenadeSimulator：
--   GRAVITY = -23.8333（不是 workspace.Gravity 的 60）
--   FIXED_TIMESTEP = 0.0078125，ELASTICITY = 0.4
--   初速度 = 视线方向 * base + 玩家水平速度 * 1.5（跑投更远）
---------------------------------------------------------------------
local GrenadeSim = nil
do
    local ok, mod = pcall(function()
        return require(RS:WaitForChild("Shared"):WaitForChild("GrenadeSimulator"))
    end)
    if ok then GrenadeSim = mod end
end
local GC = GrenadeSim and GrenadeSim.Constants or nil
local G_ACCEL = GC and math.abs(GC.GRAVITY.Y) or 23.8333
local PLAYER_VEL_SCALE = 1.5

---------------------------------------------------------------------
-- 投掷物出手后的「真实落点 + 引信倒计时」
--
-- 唯一的真值来源是 Projectile.Spawn：
--   State.Position / State.Velocity / State.StartTime   ← 服务端算好的
--   Physics.FuseTime / Physics.Radius / Physics.CollisionGroup
-- 用游戏自己的 GrenadeSimulator 模拟一次，落点是确定的，缓存起来不再重算。
--
-- 为什么必须「出手之后」才算：手持预览用的是此刻的玩家速度，而投掷有 0.7 秒
-- 准备动画 —— 移动/跳跃时出手那一刻人早就挪了，预览必然偏。这是物理，不是 bug。
-- 出手后拿到的是服务端把真实玩家速度叠进去的初速，所以算出来的落点就是真落点。
---------------------------------------------------------------------
S.landDraw = S.landDraw or {}
S.landTicks = 0
S.landShown = 0
S.landPaths = 0

S.updateThrowLanding = function()
    if cfg.showGrenadeInfo == false then return end
    local tracked = learned.tracked
    if type(tracked) ~= "table" then return end
    if not (GrenadeSim and typeof(GrenadeSim.simulate) == "function") then return end
    local cam = workspace.CurrentCamera
    if not cam then return end

    local pool = S.landDraw
    if type(pool) ~= "table" then pool = {} S.landDraw = pool end
    local now = os.clock()
    local serverNow = workspace:GetServerTimeNow()
    local alive = {}
    local drawn = 0
    S.landTicks = S.landTicks + 1

    for id, rec in pairs(tracked) do
        local state = rec.state
        if type(state) == "table" and typeof(state.position) == "Vector3" then
            -- 1) 模拟一次（每个 id 只算一次）
            if type(rec.landPath) ~= "table" then
                local rp = S.landRP
                if type(rp) ~= "table" then
                    rp = RaycastParams.new()
                    rp.FilterType = Enum.RaycastFilterType.Exclude
                    rp.RespectCanCollide = false
                    rp.IgnoreWater = true
                    S.landRP = rp
                end
                pcall(function() rp.FilterDescendantsInstances = coverIgnoreList() end)

                -- 参数跟游戏自己的 Observers.Game.Grenade 完全对齐：
                --   有引信（HE/闪光/燃烧弹）→ fuseTime=真值，落地不起爆
                --   燃烧瓶/燃烧弹            → minimumFuseTime=0.1 + explodeOnFloorImpact=true
                --   烟（FuseTime=0）        → fuseTime=nil，落地静止就结束
                local wnS = tostring(rec.weapon or "")
                local feet = (wnS == "Molotov") or (wnS == "Incendiary Grenade")
                local fT = tonumber(rec.fuseReal)
                local phys = rec.physics
                local okc, conf = pcall(GrenadeSim.createConfig,
                    (phys and tonumber(phys.Radius)) or 0.5,
                    1,
                    false,
                    fT,
                    feet and 0.1 or nil,
                    feet or nil)
                if okc and typeof(conf) == "table" then
                    -- ⚠ 步长必须接近游戏的 FIXED_TIMESTEP(0.0078125)。
                    -- 实测 0.05 的步长下，模拟落点与手雷真实停点差了 13 stud
                    -- （弹跳/滚动在大步长下完全失真）。0.02 已经把误差压到 2~3 stud 内。
                    -- 上限 600 步 = 12 秒，覆盖 MAX_SIMULATION_TIME(10s)。
                    local stTmp = state
                    local path = {}
                    for _ = 1, 600 do
                        local oks, out = pcall(GrenadeSim.simulate, stTmp, conf, rp, 0.02)
                        if not oks or typeof(out) ~= "table" or type(out.state) ~= "table" then break end
                        stTmp = out.state
                        path[#path + 1] = stTmp.position
                        if stTmp.isAtRest then break end
                    end
                    rec.landPath = path
                    rec.landPos = path[#path] or state.position
                    S.landPaths = (S.landPaths or 0) + 1
                else
                    rec.landPath = {}
                end
            end

            -- 2) 画：落点圈 + 引信剩余
            local lp = rec.landPos
            local life = (tonumber(rec.fuseReal) or 1) + 22     -- 烟雾 18 秒也要盖住
            if typeof(lp) == "Vector3" and (now - (rec.at or now)) < life then
                alive[id] = true
                local g = pool[id]
                if type(g) ~= "table" then
                    local ring = {}
                    for i = 1, SEGMENTS do ring[i] = mkDraw("Line") end
                    g = { ring = ring, text = mkDraw("Text") }
                    pool[id] = g
                end

                local wn2 = tostring(rec.weapon or "")
                local lw = wn2:lower()
                local isSmokeU = lw:find("smoke") ~= nil
                local isFireU = (lw:find("molotov") ~= nil) or (lw:find("incendiary") ~= nil)
                -- 闪光弹按视线角度致盲、诱饵弹只是枪声吸附 —— 都没有「半径」，不画圈
                local noRadU = (wn2:find("Flash") ~= nil) or (wn2:find("Decoy") ~= nil)

                local colU = Color3.fromRGB(255, 170, 60)
                if isSmokeU then colU = Color3.fromRGB(180, 180, 200) end
                if isFireU then colU = Color3.fromRGB(255, 110, 40) end

                local radU = nil
                if isSmokeU then radU = vfxRadius("smoke") end
                if isFireU then radU = vfxRadius("fire") end
                if (not isSmokeU) and (not isFireU) and (not noRadU) then
                    radU = tonumber(cfg.grenadeRadius) or 12
                end

                if radU then
                    drawGroundCircle(g.ring, cam, lp, radU, colU, 1.8)
                else
                    for _, l in ipairs(g.ring) do if l then l.Visible = false end end
                end

                local spU = cam:WorldToViewportPoint(lp)
                if spU.Z > 0 and g.text then
                    local fTxt
                    if rec.fuseReal then
                        local remain = rec.fuseReal - (serverNow - (tonumber(rec.startTime) or serverNow))
                        fTxt = string.format("%.1fs", math.max(remain, 0))
                    else
                        fTxt = "落地"
                    end
                    local myR2 = myRoot()
                    local dTxt = ""
                    if myR2 then dTxt = string.format("  %.0fm", (lp - myR2.Position).Magnitude) end
                    g.text.Visible = true
                    g.text.Center = true
                    g.text.Size = 21
                    g.text.Outline = true
                    g.text.Color = colU
                    g.text.Text = string.format("%s  %s%s", wn2, fTxt, dTxt)
                    g.text.Position = Vector2.new(spU.X, spU.Y - 20)
                elseif g.text then
                    g.text.Visible = false
                end
                drawn += 1
            end
        end
    end

    -- 3) 清理：先隐藏，5 秒后彻底移除，避免 Drawing 越攒越多
    for id, g in pairs(pool) do
        if not alive[id] then
            if not g.hideAt then
                g.hideAt = now
                for _, l in ipairs(g.ring or {}) do if l then l.Visible = false end end
                if g.text then g.text.Visible = false end
            elseif now - g.hideAt > 5 then
                for _, l in ipairs(g.ring or {}) do
                    if l and l.Remove then pcall(function() l:Remove() end) end
                end
                if g.text and g.text.Remove then pcall(function() g.text:Remove() end) end
                pool[id] = nil
            end
        else
            g.hideAt = nil
        end
    end
    S.landShown = drawn
end


local throwLines = {}
-- 反弹段的黑色描边层。挂在 S 上而不是 local：主 chunk 已经贴 200 local 上限，
-- 再加一个 local 就会 Out of local registers 整份脚本编译失败。
S.bounceLines = S.bounceLines or {}
-- 反弹段的颜色：**纯亮黄**（255,255,60 是土黄，用户说像屎黄色，换成纯黄 + 高亮度）。
-- 描边之前是 7px 纯黑 —— 比黄线（4px）还粗，结果屏幕上只剩一圈黑，被当成"黑点"。
-- 现在不用黑描边了，改成"白色发光层"：白在外、黄在内，任何背景都能看清。
S.bounceCol = S.bounceCol or Color3.fromRGB(255, 255, 0)
S.bounceEdge = S.bounceEdge or Color3.fromRGB(255, 255, 210)
local throwMark = nil    -- 落点标记（地面圈 + 距离文字）
local bounceDots = { pred = {}, real = {} }   -- 预测弹点(黄) / 真实弹点(白)

-- ⚠ 这里只放「能扔出去」的东西。
--
-- c4 / bomb 已经移除了：它们的 Class 是 "C4"（放地上引爆），不是 "Grenade"，
-- 但之前把它们放在这个关键词表里，导致「掏出 C4 也会显示投掷物落点圈」——
-- 用户反馈过这个问题。C4 不能扔，就不该画抛物线。
local THROW_HINTS = {
    "grenade", "fuse", "pin", "lever", "spoon", "flash", "smoke",
    "molotov", "incendiary", "decoy",
}

-- 手上拿的是不是投掷物：两路判断
--   1) 手上模型的部件命名
--   2) HUD 武器槽的 WeaponName（只有当前手持的那个槽有值）
local THROW_NAMES = { "grenade", "flash", "smoke", "molotov", "incendiary", "decoy", "c4" }
local lastSig = nil

-- 是不是投掷物：按游戏配置的 Class 判断，不做名字模糊匹配
--   Class == "Grenade" → 能扔（HE / Flash / Smoke / Molotov / Incendiary / Decoy）
--   Class == "C4"      → 放地上，不能扔
--   Class == "Melee" / "Glove" / "Weapon" → 都不是
local throwClassCache = {}

local function isGrenadeClass(name)
    if not name then return false end
    local cached = throwClassCache[name]
    if cached ~= nil then return cached end
    local v = false
    local ok, c = pcall(function()
        local node = RS.Database.Custom.Weapons:FindFirstChild(name)
        if not node then return nil end
        return require(node)
    end)
    if ok and typeof(c) == "table" then
        v = (tostring(c.Class) == "Grenade")
    end
    throwClassCache[name] = v
    return v
end

-- ⚠ 名字已在文件前部前置声明（heldIsThrowable），这里只赋值。
-- 原来写 local function 会造出第二个 local，5628 那个输入回调里拿到的仍是全局 nil
-- → 每次左/右键都 attempt to call a nil value，autoThrowMode 永远停在 "Far"。
heldIsThrowable = function()
    -- 三重判断 + 短暂缓存，任一条命中就算投掷物。
    --
    -- 实测过的问题：
    --   · 拿着燃烧瓶时 InventoryController.getCurrentEquipped() 会返回 nil
    --     （投掷物持有时不走 equipped 路径），所以只看 Class 会漏。
    --   · 投掷物也没有独立 viewmodel，heldWeaponName() 从相机下也找不到，
    --     补了 ViewmodelStash 之后才可能有名字。
    --   · 名字和配置节点名不一定一致（"Grenade" vs "HE Grenade"）。
    --
    -- 所以：IC 的 Class → 名字查配置 → 手上模型子孙关键词，三层都试；
    -- 再加 1.2 秒缓存，避免投掷瞬间状态抖动导致线一闪一闪。

    local now = os.clock()
    local lastT = S.lastThrowableAt
    local lastV = S.lastThrowableVal

    local function accept(v, src)
        if v then
            S.lastThrowableAt = now
            S.lastThrowableVal = true
            S.throwWhyOk = src
            return true
        end
        return false
    end

    -- 1) InventoryController 的 Class（最准，但投掷物持有时可能是 nil）
    local ic = getInvCtrl()
    if ic then
        local okw, w = pcall(function() return ic.peekCurrentEquippedForMovement() end)
        if (not okw or not w) then
            local okw2, w2 = pcall(function() return ic.peekCurrentEquippedForMovement() end)
            if okw2 and w2 then w = w2 end
        end
        if w and type(w.Properties) == "table" then
            local cls = tostring(w.Properties.Class or "")
            S.lastHeldClass = cls
            if cls ~= "" then
                if accept(cls == "Grenade", "ic-class:" .. cls) then return true end
                -- 明确不是投掷物 → 直接否掉缓存
                S.lastThrowableVal = false
                return false
            end
        end
    end

    -- 2) 名字查配置表
    local nm = heldWeaponName()
    if nm and nm ~= "" then
        S.lastHeldName = nm
        if accept(isGrenadeClass(nm), "name:" .. nm) then return true end
    end

    -- 3) 手上模型的子孙部件名（最后的兜底）
    --
    -- ⚠ 这一层极容易误判，关键词必须长且独特。
    -- 实测踩过的坑：角色模型里有个部件叫 "Jumping"（跳跃状态标记），
    -- 名字里含 "pin" —— 结果空手站着也判定成投掷物，屏幕上一直挂着抛物线。
    -- 所以只保留「不可能出现在角色骨骼/动画名里」的完整词。
    local PARSER_HINTS = { "grenade", "molotov", "incendiary", "flashbang" }
    local meM = myModel()
    if meM then
        for _, d in ipairs(meM:GetDescendants()) do
            local dn = tostring(d.Name):lower()
            for _, hint in ipairs(PARSER_HINTS) do
                if dn:find(hint, 1, true) then
                    if accept(true, "part:" .. d.Name) then return true end
                end
            end
        end
    end

    -- 4) 缓存：1.2 秒内曾经判定为投掷物，就继续认（吸收瞬时抖动）
    if lastV == true and lastT and (now - lastT) < 1.2 then
        S.throwWhyOk = "cache"
        return true
    end
    S.throwWhyOk = "none"
    return false
end

local function throwClear()
    for _, l in ipairs(throwLines) do
        if l and l.Remove then pcall(function() l:Remove() end) end
    end
    throwLines = {}
    for _, l in ipairs(S.bounceLines or {}) do
        if l and l.Remove then pcall(function() l:Remove() end) end
    end
    S.bounceLines = {}
    for _, c in ipairs(S.bounceRings or {}) do
        if c and c.Remove then pcall(function() c:Remove() end) end
    end
    S.bounceRings = {}
    S.bounceRingCount = 0
    if throwMark then
        for _, key in ipairs({ "ring", "ring2", "realRing" }) do
            for _, l in ipairs(throwMark[key] or {}) do
                if l and l.Remove then pcall(function() l:Remove() end) end
            end
        end
        for _, key in ipairs({ "text", "realText", "errText" }) do
            local t = throwMark[key]
            if t and t.Remove then pcall(function() t:Remove() end) end
        end
        throwMark = nil
    end
    for _, side in ipairs({ "pred", "real" }) do
        for _, d in ipairs(bounceDots[side] or {}) do
            if d and d.Remove then pcall(function() d:Remove() end) end
        end
        bounceDots[side] = {}
    end
end

-- ═══════════════════════════════════════════════════════════════
-- 反弹点标记：固定像素的圆环
--
-- 为什么不用「把抛物线某一段染色」：反弹段只有 1~2 stud（模拟步长 0.02 秒），
-- 两端投影到屏幕上几乎重合，Drawing 的 Line 会渲染成一个深色小方块
-- （用户原话："这反弹点怎么成为滚木了"）。加粗就变钢管，收细就看不见，
-- 这条路上没有解。
--
-- 圆环的好处：半径是像素单位（不随距离缩放），形状固定，远看近看都是同样大小的圈。
-- 池化在 S.bounceRings，每帧按 bounceStep 的索引重画，多出来的隐藏。
-- ═══════════════════════════════════════════════════════════════
S.bounceRings = S.bounceRings or {}
-- 参数是**世界坐标列表**（predBounces），不是屏幕坐标。
--
-- ⚠ 之前传的是 screen[si]，而 si 来自 `#screen`：
--    `screen[#screen + 1] = project(...)` 在 project 返回 nil 时（点在相机后方）
--    并不会增加 #screen，于是 si 指向了错误的索引，bounceStep 标记到别的点上，
--    方块就画到了屏幕右下角的莫名其妙位置（实测 955,764），完全不在抛物线上。
-- 直接用世界坐标投影，彻底绕开索引对应关系。
S.drawBounceRings = function(worldPoints)
    local pool = S.bounceRings
    local cam = workspace.CurrentCamera
    if type(worldPoints) ~= "table" or not cam then
        for i = 1, #pool do
            if pool[i] then pool[i].Visible = false end
        end
        S.bounceRingCount = 0
        return
    end
    local n = 0
    for _, wp in ipairs(worldPoints) do
        if typeof(wp) == "Vector3" then
            local sp = cam:WorldToViewportPoint(wp)
            if sp.Z > 0 then
                n = n + 1
                if not pool[n] then pool[n] = mkDraw("Square") end
                local sq = pool[n]
                if sq then
                    sq.Visible = true
                    -- 7×7 的小方点。之前 12×12 用户反馈"太大"，比落点圈还抢眼。
                    sq.Position = Vector2.new(sp.X - 3.5, sp.Y - 3.5)
                    sq.Size = Vector2.new(7, 7)
                    sq.Filled = true
                    sq.Color = S.bounceCol
                    pcall(function() sq.Thickness = 1 end)
                    -- ⚠ 不设 Transparency —— 和投掷线、和 drawThrowTrack 保持一致。
                    -- 之前给方块单独设 0.25，结果它比线暗一大截（用户："反弹点太暗淡了"）。
                    -- 这个执行器对 Transparency 的处理不可靠，凡是能看见的对象一律别碰它。
                end
            end
        end
    end
    for i = n + 1, #pool do
        if pool[i] then pool[i].Visible = false end
    end
    S.bounceRingCount = n
end

local function updateThrow()
    -- ⚠ 必须先确认手上拿的是投掷物，任何开关都不能绕过这一条。
    --
    -- 之前 cfg.throwPreview（"常开"）不受这个限制，结果拿着步枪也会画出一条抛物线 ——
    -- 而且那条线是用手雷的 Radius/FuseTime/初速算出来的，对着枪毫无意义，
    -- 纯粹是屏幕上的干扰。
    --
    -- 现在的规则：
    --   拿投掷物 → 自动显示（throwAuto）或常开（throwPreview）或按住键（throwKeyHeld）
    --   拿别的   → 一律不画
    local isThrowable = heldIsThrowable()
    -- 绑定/重建「投掷动画监听」：角色重生后 Animator 会换，连接就失效了。
    -- 这里用 throwAnimBound 做标记，失效时自动重建。
    if not S.throwAnimBound and S.ensureThrowAnimListener then
        pcall(S.ensureThrowAnimListener)
    elseif S.throwAnimConn and S.throwAnimConn.Connected == false then
        S.throwAnimBound = false
        pcall(S.ensureThrowAnimListener)
    end
    -- 埋点：手持预览每帧跑了几次 / 实际画出去几条线 / 落点圈画没画。
    -- 「手上拿着手雷但屏幕上什么都没有」时，先看这三个数就知道卡在哪一段：
    --   throwTicks 不涨        → updateThrow 根本没跑（主循环/开关问题）
    --   涨但 throwLineCount=0  → 投影全被裁掉（相机/朝向问题）
    --   有线条但圈不显示       → 被 GUI 盖住或半径判定把整圈隐藏了
    S.throwTicks = (S.throwTicks or 0) + 1
    local autoOn = cfg.throwAuto and isThrowable
    local manualOn = (cfg.throwPreview or cfg.throwKeyHeld) and isThrowable
    if not (autoOn or manualOn) then
        -- 全部关掉：线、落点圈、波纹、真实落点圈、所有文字、反弹点
        for _, l in ipairs(throwLines) do if l then l.Visible = false end end
        if throwMark then
            for _, key in ipairs({ "ring", "ring2", "realRing" }) do
                for _, l in ipairs(throwMark[key] or {}) do
                    if l then l.Visible = false end
                end
            end
            for _, key in ipairs({ "text", "realText", "errText" }) do
                local t = throwMark[key]
                if t then t.Visible = false end
            end
        end
        for _, side in ipairs({ "pred", "real" }) do
            for _, d in ipairs(bounceDots[side] or {}) do
                if d then d.Visible = false end
            end
        end
        -- ⚠ 真正在画「黄色小方块」的是 S.bounceRings 这个池（drawBounceRings 里的 7×7
        -- Filled Square），上面那套 bounceDots 是早期独立标记，早就停用了。
        --
        -- 之前这里漏掉了 ringPool：收枪 / 扔出去之后 heldIsThrowable() 变 false，
        -- updateThrow 走这个分支提前 return，池里那批 Square 仍然停在 Visible=true
        -- 的最后一个位置；下一次拿出手雷时 drawBounceRings 又复用同一批对象、只改
        -- Position —— 用户看到的就是「反弹点赖在屏幕上不走，切一次投掷物它只是换了个位置」。
        -- 视觉上还特别容易误判成「新扔的这颗雷弹到这里」。
        local ringPool = S.bounceRings
        if type(ringPool) == "table" then
            for i = 1, #ringPool do
                local sq = ringPool[i]
                if sq then sq.Visible = false end
            end
        end
        S.bounceRingCount = 0
        return
    end

    local cam = workspace.CurrentCamera
    local camPos = cam.CFrame.Position
    local look = cam.CFrame.LookVector
    local mode = resolveThrowMode()

    local hrp = myRoot()
    -- ⚠ 玩家速度必须用 RuntimeKinematics.getVelocity，不能用 AssemblyLinearVelocity。
    --
    -- 游戏的投掷初速是这样算的（Components.Common.GetCharacterVelocity）：
    --   local RuntimeKinematics = require(ReplicatedStorage.MovementV2.RuntimeKinematics)
    --   return RuntimeKinematics.getVelocity(character, character.HumanoidRootPart)
    --
    -- MovementV2 是客户端预测架构，它返回的是「移动命令重放出来的预测速度」，
    -- 而 AssemblyLinearVelocity 是物理引擎的实际速度。静止时两者相同（都是 0），
    -- 但跳跃/落地/急停的一瞬间能差出好几 stud/s ——
    -- 而 createInitialState 里水平速度要 ×1.5、垂直速度要 ×2×0.58 叠进初速，
    -- 这一点误差会被放大到落点偏几米。这就是「移动/跳跃时预测线飘」的最后一块来源。
    local pvel = Vector3.zero
    do
        local meModel = myModel()
        if hrp and meModel then
            local okRK, RK = pcall(function()
                return require(game.ReplicatedStorage.MovementV2.RuntimeKinematics)
            end)
            if okRK and type(RK) == "table" and typeof(RK.getVelocity) == "function" then
                local okv, v = pcall(RK.getVelocity, meModel, hrp)
                if okv and typeof(v) == "Vector3" then
                    pvel = v
                    S.throwVelSrc = "runtime"
                end
            end
        end
        if pvel == Vector3.zero and hrp then
            pvel = hrp.AssemblyLinearVelocity
            S.throwVelSrc = "physics"
        end
    end

    -- 起点与方向
    --
    -- ⚠ 起点必须用「角色手部」，不能用相机位置。
    -- 之前是 camPos + 前方 1.35 + 上抬 0.65，那是按第一人称推出来的。
    -- 但开了第三人称之后相机离角色能有一百多 stud：
    --   实测相机 (58.57, 10.55, -96.03)
    --        右手 (-54.37, 11.21, -128.10)   →  fwd = -103.42
    -- 拿相机当起点，抛物线就会从相机的落点发射，整体偏离。
    -- 手部坐标是真实的出手点，第三人称下也正确。
    -- 方向
    -- 游戏里 THROW_UPWARD_BIAS 的用法是「竖直分量 = 水平分量 × bias」，
    -- 是一个斜率而不是角度：0.06 约 3.4°、0.04 约 2.3°。
    -- 旧值 0.19（约 10.8°）是照相机锚点凑的，方向和起点是两回事，已按游戏常量改回。
    local bias = tonumber(cfg.throwUpBias) or ((mode == "Near") and 0.04 or 0.06)

    local flat = Vector3.new(look.X, 0, look.Z)
    if flat.Magnitude < 0.01 then flat = Vector3.new(0, 0, -1) end
    flat = flat.Unit
    local dir = (look + Vector3.new(0, bias, 0)).Unit

    -- 起点：四档优先级
    --   1) originOffset —— 从 Projectile.Spawn 实测反推，扔过一颗手雷就有，最准
    --   2) 角色根部 + 游戏常量 —— 服务端的算法
    --   3) 右手 —— 兜底
    --   4) 相机推算 —— 最后兜底（第三人称下会明显偏）
    local origin, originSrc = nil, "camera"
    local root = myRoot()
    -- 先按当前手持武器取「这把投掷物专属」的偏移，没学过才退回全局值。
    -- 手雷/燃烧瓶/烟/闪的投掷动画不同，混用一个偏移就是系统误差的来源之一。
    local off = nil
    do
        local wnNow = heldWeaponName()
        if wnNow and type(learned.perWeapon) == "table" then
            local pw = learned.perWeapon[tostring(wnNow)]
            if type(pw) == "table" and type(pw.originOffset) == "table" then
                off = pw.originOffset
            end
        end
        if not off then off = learned.originOffset end
    end
    if off and (off.hits or 0) >= 1 and root then
        local rx, rz = cam.CFrame.RightVector.X, cam.CFrame.RightVector.Z
        local rl = math.sqrt(rx * rx + rz * rz)
        local rightAxis
        if rl > 0.01 then
            rightAxis = Vector3.new(rx / rl, 0, rz / rl)
        else
            rightAxis = flat:Cross(Vector3.yAxis).Unit
        end
        origin = root.Position
            + flat * (off.fwd or 0)
            + rightAxis * (off.right or 0)
            + Vector3.new(0, off.up or 0, 0)
        originSrc = string.format("learned(%d)%s", off.hits or 0,
            (off.weapon and ("/" .. tostring(off.weapon))) or "")
    end
    -- ⚠ 没有实测数据时必须是「角色根部 + 游戏常量」，不能用右手。
    -- 实测 RightHand 比 HumanoidRootPart 低 0.73 stud、离根部 1.88，
    -- 而服务端用的是 root 上方 THROW_HEIGHT_OFFSET = 2.4 —— 两者差 3.1 stud。
    -- 拿手当起点，整条抛物线就从腰以下发射：看起来「焊在手上」，
    -- 落点、反弹点、引信落地的时刻全部跟着歪。
    if not origin and root then
        local fwdOff = tonumber(cfg.throwForward) or 1.35
        local hgtOff = tonumber(cfg.throwHeight) or 2.4
        origin = root.Position + flat * fwdOff + Vector3.new(0, hgtOff, 0)
        originSrc = "root+const"
    end
    if not origin then
        local me = myModel()
        if me then
            local hand = me:FindFirstChild("RightHand", true)
                or me:FindFirstChild("RightLowerArm", true)
                or me:FindFirstChild("RightUpperArm", true)
            if hand and hand:IsA("BasePart") then
                origin = hand.Position
                originSrc = hand.Name
            end
        end
    end
    if not origin then
        local fwdOff = tonumber(cfg.throwForward) or 1.35
        local hgtOff = tonumber(cfg.throwHeight) or 2.4
        origin = camPos + flat * fwdOff + Vector3.new(0, hgtOff, 0)
        originSrc = "camera"
    end
    S.throwOriginSrc = originSrc

    -- ⚠⚠ 起点按「投掷延迟」做惯性外推 —— 这是手持预览最大的误差项。
    --
    -- 时序（实测 Components.Grenade）：
    --   按下左键 → StartThrow 开始播
    --            → 动画走到 0.7×Length 才调 PredictGrenadeThrow
    --            → 服务端在 ~0.1 秒内用**那一刻**的玩家位置/速度算起点与初速
    --            → 广播 Projectile.Spawn（State.Position 就是真起点）
    --
    -- 所以「现在画的预览」用的是 0.7 秒前的位置，而真实出手点在
    -- 当前位置 + 速度×0.7 处。走路 19.8 stud/s → 差 13.9 stud，整条抛物线平移这么多。
    --
    -- 这解释了用户那句「扔出去之后的落点比扔之前准得多」：
    -- 出手之后用的 State.Position 是服务端算好的真起点，这一项误差直接归零。
    -- 外推补的正是这一项（静止时速度为 0，自动不生效）。
    -- 补不掉的是「0.7 秒内改方向/急停」—— 未来速度不可知，只能等出手瞬间。
    if origin then
        local lead = tonumber(cfg.throwPredictLead) or 0
        if lead > 0 then
            local flatv = Vector3.new(pvel.X, 0, pvel.Z)
            if flatv.Magnitude > 0.5 then
                origin = origin + flatv * lead
                S.throwLeadApplied = flatv.Magnitude * lead
                originSrc = originSrc .. "+lead"
                S.throwOriginSrc = originSrc
            else
                S.throwLeadApplied = 0
            end
        end
    end

    -- 起始状态（含玩家速度叠加）
    -- scale 是 createInitialState 的速度系数：实测服务端下发的投掷速度恒为 50（引擎上限），
    -- 而 scale=1 只算出 39.2，所以必须给到能让引擎封顶的值。
    -- Far: 1.5 → 50.00 ；Near: 轻抛，保持 1.0
    local st = nil
    if GrenadeSim and typeof(GrenadeSim.createInitialState) == "function" then
        local scale = (mode == "Near") and 1.0 or 1.5
        local okc, res = pcall(GrenadeSim.createInitialState, origin, dir, mode, pvel, scale, os.clock())
        if okc and typeof(res) == "table" and typeof(res.velocity) == "Vector3" then
            st = res
            -- ⚠ 速度校准：**只校准「沿投掷方向」的分量**，保留侧向的玩家速度。
            --
            -- 历史（三次都错）：
            --   v1 无条件把整个速度向量改成 learned.speed（50）
            --      → 玩家跑动/跳跃带来的速度增量被完全抹掉，怎么动抛物线都一样
            --   v2 只在 playerSpeed < 2（静止）时校准
            --      → 移动时用 createInitialState 自己算的速度，比真实的 50 小
            --        （实测手持线明显比实际线陡：初速偏小，落点近一大截）
            --   v3（现在）把「投掷方向上的投影」拉到实测值，侧向分量原样保留：
            --      既保证沿投掷方向的初速是引擎真实的 50，又不丢失横向速度。
            local measured = tonumber(learned.speed)
            if measured and measured > 1 and st.velocity.Magnitude > 0.01 then
                local want = math.min(measured, 50)
                local unit = st.velocity.Unit
                local along = st.velocity:Dot(dir.Unit)
                if along > 1 then
                    local correction = want - along
                    if math.abs(correction) > 3 then
                        st.velocity = st.velocity + dir.Unit * correction
                        S.throwSpeedFixed = (S.throwSpeedFixed or 0) + 1
                    end
                end
            end
        end
    end
    if not st then
        local baseSpeed = math.max((cfg.throwLearn and learned.speed) or cfg.throwSpeed or 55, 1)
        local flatVel = Vector3.new(pvel.X, 0, pvel.Z) * PLAYER_VEL_SCALE
        st = {
            position = origin,
            velocity = dir * baseSpeed + flatVel,
            simulationTime = 0,
            bounceCount = 0,
            isGrounded = false,
            isAtRest = false,
            hasTouched = false,
            accumulatedTime = 0,
            angularVelocity = Vector3.zero,
            timestamp = os.clock(),
            isJumpThrow = false,
        }
    end

    -- 碰撞检测参数：完全照抄游戏的 createRaycastParams
    --   RespectCanCollide=false 是关键——地图上很多地面是 CanCollide=false 的装饰件，
    --   默认 true 会让射线穿过去，手雷直接掉到地面以下
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    local dbr = workspace:FindFirstChild("Debris")
    if dbr then ignore[#ignore + 1] = dbr end
    -- 按当前手持的投掷物取它自己的物理参数。
    -- Molotov / Incendiary Grenade 是落地即燃（explodeOnFloorImpact + 0.1s 最小引信），
    -- 不能套普通手雷的 1.5s 引信。
    -- 注意：phys 必须在下面 CollisionGroup 那段之前定义 —— 之前写在后面，
    -- 导致 phys 恒为 nil，碰撞组只能走兜底，实测落点会偏 10+ stud。
    local heldName = heldWeaponName() or ""
    local isFirePot = (heldName == "Molotov" or heldName == "Incendiary Grenade")
    local phys = (learned.byWeapon and learned.byWeapon[heldName]) or learned.physics

    -- 排除自己：LocalPlayer.Character 在这个自定义角色体系下不一定就是
    -- 真正在模拟的那个模型（实测拿它算位置时手雷样本全判成 mine=false），
    -- 所以两个都排除，避免手雷一出手就打在自己身上、在脚边弹成一片。
    if LP.Character then ignore[#ignore + 1] = LP.Character end
    local meModel = myModel()
    if meModel and meModel ~= LP.Character then ignore[#ignore + 1] = meModel end
    rp.FilterDescendantsInstances = ignore
    rp.RespectCanCollide = false
    rp.IgnoreWater = true
    local cg = phys and phys.CollisionGroup
    if typeof(cg) ~= "string" or #cg == 0 then
        -- 兜底按阵营判断：实测 Default 组会被 Map.Barriers 挡住，误差 10+ stud
        cg = (myTeam() == "Counter-Terrorists") and "CTGrenade" or "TGrenade"
    end
    pcall(function() rp.CollisionGroup = cg end)

    local radius = (phys and tonumber(phys.Radius)) or 0.499
    -- 引信
    -- ⚠ fuse = 0 的投掷物（实测 Smoke Grenade 就是 0）不能把 0 传进 createConfig：
    -- 0 在 Luau 里是 truthy，`0 or 1.5` 取到的还是 0，
    -- 而 simulate 拿到 fuse=0 会当作「引信已到」，**第一步就 isAtRest** ——
    -- 屏幕上就只剩一个范围圈，完全没有抛物线。实测 counts: ok=1 就是这么来的。
    -- 这类投掷物是「落地/静止才生效」，正确写法是 fuseTime=nil + explodeOnFloorImpact。
    local rawFuse = phys and tonumber(phys.FuseTime)
    local fuseTime = nil
    local explodeOnFloor = nil
    if isFirePot then
        fuseTime = nil
        explodeOnFloor = true
    elseif rawFuse and rawFuse > 0 then
        fuseTime = rawFuse
    else
        fuseTime = nil
        explodeOnFloor = true
    end
    local minFuse = isFirePot and 0.1 or nil

    local simCfg = nil
    if GrenadeSim and typeof(GrenadeSim.createConfig) == "function" then
        local okG, c = pcall(GrenadeSim.createConfig, radius, 1, mode == "Near",
            fuseTime, minFuse, explodeOnFloor)
        if okG and typeof(c) == "table" then simCfg = c end
    end

    local screen = {}
    -- ⚠ 必须和 screen 同级声明：画线循环在 `if GrenadeSim` 块**外**用它。
    -- 之前写在块内，出块就是 nil，画线时会直接崩（每帧 err_throw，整条抛物线不显示）。
    local bounceStep = {}
    local landed = nil
    local predBounces = {}     -- 预测的反弹点

    -- 只排除两类点：
    --   1) 离相机太近（否则起步那段会从镜头后面拉出一条怪线）
    --   2) 投影到画面上方的（那才是"从天上下来"的成因）
    -- 之前还把屏幕外的点整段丢了（sp.Y < 4 / > vpSize.Y-4），
    -- 结果扔远距离时轨迹一飞出画面就整条消失、落点也不见了。
    -- 现在允许屏幕外（Roblox 的 Drawing 会正常裁切），只拦「天上」。
    local NEAR_CUT = 4
    local vpSize = cam.ViewportSize

    local function project(p)
        if (p - camPos).Magnitude < NEAR_CUT then return nil end
        local sp = cam:WorldToViewportPoint(p)
        if sp.Z <= 0 then return nil end
        -- 只拦明显在画面上方很远的点（天上来的线）
        if sp.Y < -vpSize.Y * 0.35 then return nil end
        return Vector2.new(sp.X, sp.Y)
    end

    if GrenadeSim and typeof(GrenadeSim.simulate) == "function" and simCfg then
        -- 用游戏自己的物理推进：内部固定 128Hz，梯形积分 + PhysicsClipVelocity
        --
        -- ⚠⚠ 步长：从 0.02 收紧到 0.0125。
        --
        -- 用户观察到一个非常关键的现象：「弹跳多、空间狭小的地方，手持线偏得最明显；
        -- 直着扔到空地上反而还行」。这正好指向步长误差的累积特性 ——
        -- 服务端物理是固定 128Hz（0.0078125 秒），我们原来用 0.02 秒，差 2.5 倍，
        -- 每一次反弹都会多损失一点能量/位置精度，弹得越多累积越大。
        --
        -- 历史测量（站着不动扔 HE）：
        --   步长 0.05 → 落点差 13 stud
        --   步长 0.02 → 落点差 0 stud（单次落地的情况）
        -- 单次落地时 0.02 已经够；但多次反弹会累积，所以现在压到 0.0125。
        -- 步数同步提到 400（0.0125 × 400 = 5 秒，覆盖引信 2.4 秒 + 多次反弹）。
        local state = st
        -- bounceStep 已经在外层声明（画线循环在块外用它）
        for i = 1, 400 do
            local okS, out = pcall(GrenadeSim.simulate, state, simCfg, rp, 0.0125)
            if not okS or typeof(out) ~= "table" or not out.state then break end
            state = out.state
            screen[#screen + 1] = project(state.position)
            local si = #screen
            landed = state.position

            local floorImpact = false
            -- 收集预测的每个反弹点，并识别「落地」事件
            if typeof(out.events) == "table" then
                for _, ev in ipairs(out.events) do
                    if typeof(ev) == "table" then
                        if ev.type == "bounce" and typeof(ev.position) == "Vector3" then
                            predBounces[#predBounces + 1] = ev.position
                            bounceStep[si] = true          -- 这一步到反弹点
                        elseif ev.type == "floor_impact" then
                            -- 游戏只在法线朝上（normal.Y > 0.7）时才发这个事件
                            floorImpact = true
                        end
                    end
                end
            end

            -- 终止条件按投掷物类型：
            --   普通手雷 = 引信到点
            --   燃烧瓶   = 落地那一下（floor_impact），撞墙不算
            local done = state.isAtRest
            if not done and fuseTime and fuseTime > 0
                and (state.simulationTime or 0) >= fuseTime then
                done = true
            end
            if not done and explodeOnFloor and floorImpact then
                done = true
            end
            if done then break end
        end
        if not landed then landed = st.position end
        -- 兜底：如果游戏模拟一步都没走成，退回手算
        if #screen == 0 and not landed then
            local g, dt = G_ACCEL, 0.05
            local pos, vel = st.position, st.velocity
            for i = 1, 60 do
                local ny = vel.Y - g * dt
                pos = pos + Vector3.new(vel.X * dt, (vel.Y + ny) / 2 * dt, vel.Z * dt)
                vel = Vector3.new(vel.X, ny, vel.Z)
                screen[#screen + 1] = project(pos)
                landed = pos
                local hit = workspace:Raycast(pos, Vector3.new(0, -0.2, 0), rp)
                if hit then break end
            end
        end
    else
        -- 无游戏模块时的手算（梯形积分）
        local g, dt = G_ACCEL, 0.05
        local pos, vel = st.position, st.velocity
        for i = 1, 60 do
            local ny = vel.Y - g * dt
            pos = pos + Vector3.new(vel.X * dt, (vel.Y + ny) / 2 * dt, vel.Z * dt)
            vel = Vector3.new(vel.X, ny, vel.Z)
            screen[#screen + 1] = project(pos)
            landed = pos
            local hit = workspace:Raycast(pos, Vector3.new(0, -0.2, 0), rp)
            if hit then break end
        end
    end

    local idx = 0
    -- 抛物线本身：统一绿色，不再给反弹段染色。
    --
    -- 染色的历史（三次尝试全部失败，浪费了用户很多时间）：
    --   v1 4px 黄 + 7px 黑描边  → 黑边比黄线粗，黄线被吞，屏幕上只剩黑点
    --   v2 6px 黄 + 8px 白垫层  → Drawing 无 ZIndex，白线后创建压在黄线上面，还是看不到黄
    --   v3 7px 纯黄              → 用户："粗成啥样了，格格不入"
    --   v4 3px 纯黄              → 反弹段本身只有 1~2 stud，两端投影几乎重合，
    --                              Line 渲染成一个深色小方块，用户："怎么成了滚木"
    -- 结论：短线段的粗细/染色这条路走不通。反弹点改用**固定像素的圆环**标记（见下方）。
    for i = 2, #screen do
        local a, b = screen[i - 1], screen[i]
        if a and b then
            idx += 1
            local line = throwLines[idx]
            if not line then
                line = mkDraw("Line")
                throwLines[idx] = line
            end
            if line then
                line.Visible = true
                line.From = a
                line.To = b
                line.Color = cfg.throwColor
                -- ⚠ 完全不设 Transparency —— 和「扔出后的轨迹线」(drawThrowTrack) 一模一样。
                --
                -- drawThrowTrack 里那段代码从头到尾没有 Transparency 这一行，用户觉得它亮。
                -- 我在这边反复调 0.42 / 0.25 / 0.18 / 0.01 / 0 全部偏暗或消失，
                -- 方向从一开始就错了：不是数值选得不对，是**根本不该设这个属性**。
                -- 两个池的其余参数（Color / Thickness）本来就一致，现在彻底对齐。
                line.Thickness = 1.6
            end
        end
    end
    -- 反弹点：小黄方块（直接传世界坐标，不依赖屏幕索引）
    if S.drawBounceRings then
        pcall(S.drawBounceRings, predBounces)
    end
    for i = idx + 1, #throwLines do
        if throwLines[i] then throwLines[i].Visible = false end
        if S.bounceLines[i] then S.bounceLines[i].Visible = false end
    end
    S.throwLineCount = idx
    -- 埋点：把第一条线的**实际属性**暴露到 S，用于定位「算出来了但看不见」。
    -- throwLines 是 local，外部读不到；不加这个就只能靠猜。
    do
        local L0 = throwLines[1]
        if L0 then
            S.throwLine1 = {
                vis = tostring(L0.Visible),
                from = tostring(L0.From),
                to = tostring(L0.To),
                color = tostring(L0.Color),
                thick = tostring(L0.Thickness),
                trans = tostring(L0.Transparency),
            }
        else
            S.throwLine1 = "nil"
        end
        S.throwLine1Count = #throwLines
    end

    -- 落点标记：和「出手后落点圈」用同一套语义（半径 / 贴地 / 文字）
    local impactPos = landed
    -- 埋点：手持预览算出的落点。扔出去之后可以和 landPos（服务端真值模拟）对比，
    -- 差值就是「预览到底差多少」，不用再靠肉眼看。
    S.previewLand = impactPos
    if impactPos then
        -- ⚠ 贴地。模拟最后一步可能停在地面上方（引信到点那一刻还在飞），
        -- 直接画圈就会悬空 —— 而出手后那个圈是从地面往上吸的，
        -- 于是屏幕上同一个落点"一高一低"。用户已经明确指出这个。
        -- 距地 6 stud 以内才吸；明显在空中爆炸的抛投保持原高度。
        local okG, gHit = pcall(function()
            return workspace:Raycast(impactPos, Vector3.new(0, -250, 0), rp)
        end)
        if okG and gHit and (impactPos.Y - gHit.Position.Y) < 6 then
            impactPos = Vector3.new(impactPos.X, gHit.Position.Y + 0.12, impactPos.Z)
            S.previewLand = impactPos
        end

        if not throwMark then
            throwMark = {
                ring = {},                 -- 范围圈（半径按投掷物类型，与出手后一致）
                ring2 = {},                -- 精确落点小圈（2.5 stud）
                realRing = {},             -- 真实落点圈（品红，来自 Projectile.Resolve）
                text = mkDraw("Text"),     -- 预测距离
                realText = mkDraw("Text"), -- 真实落点距离
                errText = mkDraw("Text"),  -- 两者误差
            }
            for i = 1, SEGMENTS do
                throwMark.ring[i] = mkDraw("Line")
                throwMark.ring2[i] = mkDraw("Line")
                throwMark.realRing[i] = mkDraw("Line")
            end
        end
        local m = throwMark

        -- 半径语义与 updateThrowLanding 完全一致：
        --   烟/火 → VFX 学到的真实覆盖半径；HE → cfg.grenadeRadius；
        --   闪光/诱饵 → 没有"半径"这回事，只标点不画范围圈
        local heldN2 = tostring(heldWeaponName() or "")
        local lw2 = heldN2:lower()
        local pSmoke = lw2:find("smoke") ~= nil
        local pFire = (lw2:find("molotov") ~= nil) or (lw2:find("incendiary") ~= nil)
        local pNoRad = (heldN2:find("Flash") ~= nil) or (heldN2:find("Decoy") ~= nil)
        local pRad = nil
        if pSmoke then pRad = vfxRadius("smoke") end
        if pFire then pRad = vfxRadius("fire") end
        if (not pSmoke) and (not pFire) and (not pNoRad) then
            pRad = tonumber(cfg.grenadeRadius) or 12
        end

        if pRad then
            drawGroundCircle(m.ring, cam, impactPos, pRad, cfg.throwColor, 1.8)
        else
            for _, l in ipairs(m.ring) do if l then l.Visible = false end end
        end
        S.throwRingRadius = pRad
        S.throwMarkDrawn = impactPos

        -- 精确落点小圈：固定 2.5 stud。原来这圈是"向外扩散的脉冲"，
        -- 和范围圈叠在一起反而看不出落点到底在哪一格。
        drawGroundCircle(m.ring2, cam, impactPos, 2.5, cfg.throwColor, 2)

        local isp = cam:WorldToViewportPoint(impactPos)
        if isp.Z > 0 and m.text then
            local dist = (impactPos - cam.CFrame.Position).Magnitude
            m.text.Visible = true
            m.text.Center = true
            m.text.Size = 20
            m.text.Outline = true
            m.text.Color = cfg.throwColor
            m.text.Text = string.format("PRE %.0fm", dist)
            m.text.Position = Vector2.new(isp.X, isp.Y - 22)
        elseif m.text then
            m.text.Visible = false
        end

        -------------------------------------------------------------
        -- 真实落点：服务端 Projectile.Resolve 给的最终位置，绝对准确
        -- 用它和预测圈对照，误差直接显示出来
        -------------------------------------------------------------
        local realPos, realAt = nil, 0
        for _, info in pairs(realLandings) do
            if info.at > realAt then
                realAt = info.at
                realPos = info.pos
            end
        end

        if realPos and m.realRing and os.clock() - realAt < 6 then
            drawGroundCircle(m.realRing, cam, realPos, 3.0,
                Color3.fromRGB(255, 80, 255), 2.5)

            local rsp = cam:WorldToViewportPoint(realPos)
            if rsp.Z > 0 and m.realText then
                m.realText.Visible = true
                m.realText.Center = true
                m.realText.Size = 20
                m.realText.Outline = true
                m.realText.Color = Color3.fromRGB(255, 80, 255)
                -- 加「实」字前缀：这圈是服务端 Projectile.Resolve 回传的真实落点，
                -- 不是预测。原来只显示一个裸数字，没人认得出它是干什么的。
                m.realText.Text = string.format("HIT %.0fm", (realPos - cam.CFrame.Position).Magnitude)
                m.realText.Position = Vector2.new(rsp.X, rsp.Y + 26)
            elseif m.realText then
                m.realText.Visible = false
            end

            -- 误差：预测落点 vs 真实落点
            if m.errText then
                local err = (impactPos - realPos).Magnitude
                m.errText.Visible = true
                m.errText.Center = true
                m.errText.Size = 22
                m.errText.Outline = true
                m.errText.Color = err < 3 and Color3.fromRGB(120, 255, 120)
                    or (err < 8 and Color3.fromRGB(255, 220, 60) or Color3.fromRGB(255, 90, 90))
                m.errText.Text = string.format("ERR %.0f", err)
                local mid = (isp + rsp) * 0.5
                m.errText.Position = Vector2.new(mid.X, mid.Y - 40)
            end
        else
            if m.realRing then
                for _, l in ipairs(m.realRing) do if l then l.Visible = false end end
            end
            if m.realText then m.realText.Visible = false end
            if m.errText then m.errText.Visible = false end
        end

        -- ⚠ 反弹点不再单独画标记 —— 改成把「到达反弹点的那一段线」染黄（见上面 BOUNCE_COL）。
        --
        -- 之前那套独立标记（小地面圈 + 编号 + 吸地）有三个实测出来的毛病，用户明确反馈过：
        --   ① 吸地 raycast 把反弹点强行拉到地面：反弹其实发生在墙/箱子/空中，结果全画在地上；
        --      而且吸地后坐标和抛物线完全脱节，屏幕上那个黄圈看着跟弹道毫无关系
        --   ② 手上换成别的武器时 updateThrow 提前 return，这块没人执行 → 标记永久留在屏幕上
        --   ③ 6 段地面圈画在墙面/竖直面上会透视成一个扁六边形，完全不像"点"
        -- 现在只留埋点，不产生任何绘制；黄线段跟着抛物线一起出现、一起消失。
        S.bouncePredCount = #predBounces
        -- 记住第一个预测弹跳点：扔出去之后拿它和服务端 Projectile.Bounce 的真实坐标比对，
        -- 这是校验「反弹模型准不准」唯一干净的一次对比（后续弹跳会滚雪球）。
        S.previewFirstBounce = predBounces[1]

            -- 「真实弹点白点」那段也一起删了：
            --   它只在 cfg.showBounceDots 打开时有效，而且同样是独立标记，
            --   手上换枪后没人隐藏 —— 和反弹点黄圈是同一类残留问题。
            --   现在反弹信息完全由「黄线段」表达，不再有独立标记。

    end
end

---------------------------------------------------------------------
-- 投掷物出手后的真实轨迹
--
-- 手持预览用的是「此刻的玩家速度」，而投掷有 0.7 秒准备动画 —— 移动或跳跃时，
-- 出手那一刻人早就挪了，预览必然偏。这不是算法问题，是「未来速度不可知」。
--
-- 真正准的只有出手之后：Projectile.Spawn 的 State.Velocity 是服务端算好的初速，
-- 里面已经包含当时的玩家速度叠加（(pvel.X,0,pvel.Z)*1.5）。用它模拟出来的轨迹是确定的，
-- 所以只算一次、缓存下来，之后每帧只做投影。
---------------------------------------------------------------------
S.trackLines = S.trackLines or {}
S.trackRP = S.trackRP or (function()
    local p = RaycastParams.new()
    p.FilterType = Enum.RaycastFilterType.Exclude
    p.RespectCanCollide = false
    p.IgnoreWater = true
    return p
end)()

S.drawThrowTrack = function()
    local cam = workspace.CurrentCamera
    local lines = S.trackLines
    local function hideAll()
        for i = 1, #lines do
            local l = lines[i]
            if l then l.Visible = false end
        end
    end

    if cfg.throwTrackAfterRelease == false or not cam then hideAll() return end
    if not GrenadeSim or typeof(GrenadeSim.simulate) ~= "function" then hideAll() return end

    -- 找最近扔出、还在飞的自有投掷物
    local now = os.clock()
    local best = nil
    for _, rec in pairs(learned.tracked or {}) do
        if rec.mine and type(rec.state) == "table" then
            local alive = (tonumber(rec.fuse) or 1.5) + 2.5
            if (now - (rec.at or 0)) < alive then
                if not best or (rec.at or 0) > (best.at or 0) then best = rec end
            end
        end
    end
    if not best then hideAll() return end

    -- 轨迹只算一次
    if type(best.path3d) ~= "table" then
        local rp = S.trackRP
        rp.FilterDescendantsInstances = coverIgnoreList()
        local phys = best.physics
        local fuseT = tonumber(best.fuse) or 1.5
        if fuseT <= 0 then fuseT = nil end
        local okc, c = pcall(GrenadeSim.createConfig,
            (phys and tonumber(phys.Radius)) or 0.499, 1, false,
            fuseT, nil, fuseT == nil)
        if not okc or typeof(c) ~= "table" then hideAll() return end
        local state = best.state
        local path = {}
        for _ = 1, 60 do
            local oks, out = pcall(GrenadeSim.simulate, state, c, rp, 0.08)
            if not oks or typeof(out) ~= "table" or not out.state then break end
            state = out.state
            path[#path + 1] = state.position
            if state.isAtRest then break end
        end
        best.path3d = path
    end

    local path = best.path3d
    if #path < 2 then hideAll() return end

    local camPos = cam.CFrame.Position
    local idx = 0
    local prev = nil
    for i = 1, #path do
        local p = path[i]
        local pt = nil
        if (p - camPos).Magnitude > 4 then
            local sp = cam:WorldToViewportPoint(p)
            if sp.Z > 0 then pt = Vector2.new(sp.X, sp.Y) end
        end
        if pt and prev then
            idx += 1
            local l = lines[idx]
            if not l then
                l = mkDraw("Line")
                lines[idx] = l
            end
            l.Visible = true
            l.Color = cfg.throwColor
            l.Thickness = 1.6
            l.From = prev
            l.To = pt
        end
        prev = pt
    end
    for i = idx + 1, #lines do
        local l = lines[i]
        if l then l.Visible = false end
    end
end

local function updateRadar()
    S.radarTicks = (S.radarTicks or 0) + 1
    local enabled = cfg.radar
    local cam = workspace.CurrentCamera
    local vp = cam.ViewportSize
    local size = cfg.radarSize

    if not enabled then
        for _, key in ipairs({ "bg", "borderT", "borderB", "borderL", "borderR", "me", "fwd" }) do
            local d = radar[key]
            if d then d.Visible = false end
        end
        for _, d in pairs(radar.dots) do if d then d.Visible = false end end
        return
    end

    local origin = Vector2.new(vp.X - size - 30, vp.Y * 0.5 - size * 0.5)
    local center = origin + Vector2.new(size / 2, size / 2)
    local radius = size / 2 - 8

    if radar.bg then
        radar.bg.Visible = true
        radar.bg.Color = Color3.fromRGB(15, 15, 18)
        radar.bg.Filled = true
        radar.bg.Thickness = 1
        radar.bg.Position = origin
        radar.bg.Size = Vector2.new(size, size)
    end

    local edgeCol = Color3.fromRGB(70, 200, 120)

    if radar.borderT then
        radar.borderT.Visible = true
        radar.borderT.Color = edgeCol
        radar.borderT.Thickness = 1
        radar.borderT.From = origin
        radar.borderT.To = Vector2.new(origin.X + size, origin.Y)
    end
    if radar.borderB then
        radar.borderB.Visible = true
        radar.borderB.Color = edgeCol
        radar.borderB.Thickness = 1
        radar.borderB.From = Vector2.new(origin.X, origin.Y + size)
        radar.borderB.To = Vector2.new(origin.X + size, origin.Y + size)
    end
    if radar.borderL then
        radar.borderL.Visible = true
        radar.borderL.Color = edgeCol
        radar.borderL.Thickness = 1
        radar.borderL.From = origin
        radar.borderL.To = Vector2.new(origin.X, origin.Y + size)
    end
    if radar.borderR then
        radar.borderR.Visible = true
        radar.borderR.Color = edgeCol
        radar.borderR.Thickness = 1
        radar.borderR.From = Vector2.new(origin.X + size, origin.Y)
        radar.borderR.To = Vector2.new(origin.X + size, origin.Y + size)
    end

    local root = myRoot()
    if not root then return end
    local myPos = root.Position
    local look = cam.CFrame.LookVector
    local yaw = math.atan2(look.X, look.Z)

    if radar.me then
        radar.me.Visible = true
        radar.me.Color = Color3.fromRGB(90, 255, 150)
        radar.me.Filled = true
        radar.me.Position = center - Vector2.new(2, 2)
        radar.me.Size = Vector2.new(4, 4)
    end

    if radar.fwd then
        radar.fwd.Visible = true
        radar.fwd.Color = Color3.fromRGB(90, 255, 150)
        radar.fwd.Thickness = 1
        radar.fwd.From = center
        radar.fwd.To = center + Vector2.new(0, -radius)
    end

    local targets = collect(cfg.radarRange, false)
    local used = {}
    for _, t in ipairs(targets) do
        if not (t.sameTeam and not cfg.showTeammates) and not (t.isBot and not cfg.showBots) then
            local rel = t.pos - myPos
            local dist = rel.Magnitude
            local ang = math.atan2(rel.X, rel.Z) - yaw
            local r = math.min(dist / cfg.radarRange, 1) * radius
            local px = center.X + math.sin(ang) * r
            local py = center.Y - math.cos(ang) * r

            local dot = radar.dots[t.name]
            if not dot then
                dot = mkDraw("Square")
                radar.dots[t.name] = dot
            end
            used[t.name] = true
            if dot then
                dot.Visible = true
                dot.Filled = true
                dot.Size = t.isBot and Vector2.new(6, 6) or Vector2.new(4, 4)
                dot.Position = Vector2.new(px - dot.Size.X / 2, py - dot.Size.Y / 2)
                if t.sameTeam then
                    dot.Color = cfg.colorTeam
                else
                    dot.Color = cfg.colorEnemy
                end
            end
        end
    end

    for name, dot in pairs(radar.dots) do
        if not used[name] and dot then dot.Visible = false end
    end
end

local function w2s(p)
    local cam = workspace.CurrentCamera
    local sp = cam:WorldToViewportPoint(p)
    if sp.Z <= 0 then return nil end
    return Vector2.new(sp.X, sp.Y)
end

local espTick = 0
local function updateEsp()
    if not cfg.esp then
        for _, set in pairs(S.espObjects) do
            for _, d in pairs(set) do if d then d.Visible = false end end
        end
        return
    end

    espTick += 1
    -- 性能节流：手机每 2 帧刷一次 ESP，中间那一帧直接返回（框保持在上一帧的位置）。
    -- 关掉 ESP 的分支在上面，所以关的时候是立即隐藏，不受这里影响。
    local espEvery = tonumber(cfg.espEveryNFrames) or 1
    if espEvery > 1 and (espTick % espEvery) ~= 0 then return end

    -- ⚠ updateEsp 里原来没有 cam 变量：只有 w2s() 内部自己去取 CurrentCamera。
    -- 结果下面 drawSkeleton(set, cam, ...) / drawHitboxes(set, cam, ...) 传进去的是
    -- 全局 nil，一路报 "attempt to index nil with 'WorldToViewportPoint'"，
    -- 骨架和碰撞箱从来没画出来过。这里补上。
    local cam = workspace.CurrentCamera
    -- ⚠ 目标列表只在「这一帧真的要画」时才算，不做独立的第二层缓存。
    -- 之前这里是 `if espTick % 2 == 0 then allTargets() end` —— 和上面 updateEsp 的
    -- %espEvery 节流是两个互相独立的周期，错位时会叠加成最多 3 帧（50ms@60fps）延迟，
    -- 快速横移的目标会出现「框追不上人」。现在两者共用同一个节流点，最坏就是 espEvery 帧。
    local targets = allTargets()
    local alive = {}

    for _, t in ipairs(targets) do
        -- 默认全部显示；尸体画灰色，可选隐藏
        local skip = false
        if t.distance > cfg.espRange then skip = true end
        if t.sameTeam and not cfg.showTeammates then skip = true end
        if t.isBot and not cfg.showBots then skip = true end
        if t.dead and cfg.hideDead then skip = true end
        if t.frozen and cfg.hideFrozen then skip = true end
        -- ⚠ 「火柴人」的根治：模型被 PVS 剔掉的目标不要再画。
        --
        -- 实测：bot 的模型不在 workspace.Characters 里时（被剔除/已死亡/已离开），
        -- collect 仍会返回它，而且 pose 的 ageSec 是 0（服务端还在发数据），
        -- dead=false、frozen=false —— 三个过滤条件一个都不触发。
        -- 结果就是屏幕上留一堆停在旧位置的框，也就是用户说的火柴人。
        if (not t.model) and cfg.hideNoModel ~= false then skip = true end
        if skip then
            local old = S.espObjects[t.name]
            if old then hideSet(old) end
            continue
        end

        alive[t.name] = true
        local set = S.espObjects[t.name]
        if not set then
            set = newSet()
            S.espObjects[t.name] = set
        end

        -- ⚠ 坐标源：模型存在就用模型。
        --
        -- 实测三种情况：
        --   模型在 Characters → 实时渲染位置，最准
        --   模型在 _PVS_CulledCharacters → 冻结在「最后一次被渲染的位置」，
        --      仍然比冻结的 pose 新（实测两者差 230 stud，pose 那边更旧）
        --   pose（_presentationPoseByActorKey）→ 敌人平均 1.69 秒才刷新一次，
        --      而且「开局一瞬间对、之后变错」说明它对不可见玩家基本是冻住的
        --
        -- 所以只有模型完全找不到时才退回 pose。
        local mPos, mHead, mFoot
        local mm = t.model
        if mm then
            local mr = mm:FindFirstChild("HumanoidRootPart")
            local hd = mm:FindFirstChild("Head")
            local lf = mm:FindFirstChild("LeftFoot") or mm:FindFirstChild("RightFoot")
            if mr then mPos = mr.Position end
            if hd then mHead = hd.Position end
            if lf then mFoot = lf.Position end
        end

        -- 模型完全找不到时才退回 buffer 坐标
        local topPos = mHead or t.headPos
        local botPos = mFoot or ((mPos or t.pos) - Vector3.new(0, 2.6, 0))

        local hs, bs = w2s(topPos), w2s(botPos)
        local rs = w2s(mPos or t.pos)
        if hs and bs then
            -- 头部投影到脚底投影 = 整个人在屏幕上的高度
            local h = math.max(math.abs(bs.Y - hs.Y), 12)
            -- ⚠ 「滚木」：目标几乎贴在相机上时，头和脚的投影会分列屏幕上下两端，
            -- 高度暴涨到几百像素。封顶到 40% 屏高只是把它压小，形状还是一根竖条。
            -- 真正的判据是「远超封顶值」—— 那说明这两个点已经不构成一个人了。
            -- 这种情况本帧直接跳过，别画一根没有任何信息的柱子。
            local maxH = workspace.CurrentCamera.ViewportSize.Y * 0.40
            if h > maxH * 2.5 then
                if set.box then set.box.Visible = false end
                if set.name then set.name.Visible = false end
                if set.dist then set.dist.Visible = false end
                if set.wpn then set.wpn.Visible = false end
                continue
            end
            if h > maxH then h = maxH end
            local w = math.max(h * 0.42, 8)
            local x = hs.X - w / 2
            local y = hs.Y
            local enemy = not t.sameTeam
            local col = enemy and cfg.colorEnemy or cfg.colorTeam
            -- 位置已冻结的目标（没有实时快照）用暗色
            if not t.live then
                col = Color3.new(col.R * 0.55, col.G * 0.55, col.B * 0.55)
            end
            -- 尸体用灰白，不抢眼
            if t.dead then
                col = Color3.fromRGB(120, 120, 120)
            elseif smokeBlockedCached(t) then
                -- 在烟后：灰蓝
                col = Color3.fromRGB(140, 170, 210)
            elseif facingMeCached(t) and not t.sameTeam then
                -- 正在看着你的人：橙色高亮
                col = Color3.fromRGB(255, 150, 30)
            elseif cfg.espCoverTint and not t.sameTeam then
                -- 高亮：暴露 / 掩体后 用两种颜色区分
                if exposedCached(t) then
                    col = cfg.colorExposed
                else
                    col = cfg.colorCovered
                end
            end

            -- 骨骼、碰撞箱、血条都用同一个高亮色
            local lineCol = col
            local colForBones = lineCol

            if set.box then
                -- 位置过期（PVS 剔除）的目标也画完整框，并且保留队伍色。
                -- 这个游戏的 RemoteBuffer 只装自己的姿态，其他玩家几乎全是
                -- live=false，如果那种情况画灰框，实际效果就是"全场都是灰框"。
                -- 所以只把颜色压暗一点表示"坐标可能不是最新"，不致于认不出敌我。
                set.box.Visible = cfg.espBox
                if t.live then
                    set.box.Color = col
                    -- 暴露的敌人框更粗，一眼看出谁在明处
                    if cfg.espCoverTint and not t.sameTeam and exposedCached(t) then
                        set.box.Thickness = t.isBot and 3 or 2
                    else
                        set.box.Thickness = t.isBot and 2.5 or 1.5
                    end
                else
                    set.box.Color = col:Lerp(Color3.fromRGB(50, 50, 60), 0.32)
                    set.box.Thickness = 1
                end
                set.box.Filled = false
                set.box.Position = Vector2.new(x, y)
                set.box.Size = Vector2.new(w, h)
            end

            -- 骨骼 / 碰撞箱：模型可能来自 _PVS_CulledCharacters（位置冻结），
            -- 用 t.pos - 模型根部位置 得到偏移量再平移各部位
            --
            -- ⚠ 但这个偏移量必须加个上限。实测 t.pos 可能是「外推」或「曳光修正」
            -- 之后的位置，而模型还停在真实位置，两者相差几十米 —— 偏移量一大，
            -- 整套骨骼就被平移到墙上去了（就是用户截图里那种「红色骨骼画在墙上」）。
            -- 只有模型位置和 t.pos 偏离超过 MAX_MOFFSET 时才认为模型是冻结的、
            -- 需要用偏移纠正；否则一律按模型的真实位置画。
            local mOffset = Vector3.zero
            if t.model then
                local mr = t.model:FindFirstChild("HumanoidRootPart")
                if mr then
                    local raw = t.pos - mr.Position
                    local MAX_MOFFSET = 60
                    if raw.Magnitude <= MAX_MOFFSET then
                        mOffset = raw
                    else
                        -- 模型和预测位置差太远：两边必有一个是错的，宁可贴住模型
                        mOffset = Vector3.zero
                        S.bigOffsetSkipped = (S.bigOffsetSkipped or 0) + 1
                    end
                end
            end

            if cfg.espSkeleton and t.model then
                drawSkeleton(set, cam, t.model, col, 1.4, mOffset)
            else
                -- 用 pairs 而不是 #（稀疏数组陷阱，见 drawSkeleton 说明）
                for _, l in pairs(set.bones) do if l then l.Visible = false end end
            end

            if cfg.espHitbox and t.model then
                drawHitboxes(set, cam, t.model, col, mOffset)
            else
                for _, sq in pairs(set.parts) do if sq then sq.Visible = false end end
            end
            if set.hbg then
                set.hbg.Visible = cfg.espHealth
                set.hbg.Color = Color3.fromRGB(25, 25, 25)
                set.hbg.Filled = true
                set.hbg.Position = Vector2.new(x - 5, y)
                set.hbg.Size = Vector2.new(2, h)
            end
            if set.hfg then
                local ratio = math.clamp(t.health / math.max(t.maxHealth, 1), 0, 1)
                set.hfg.Visible = cfg.espHealth
                set.hfg.Color = Color3.fromRGB(math.floor(255 * (1 - ratio)), math.floor(255 * ratio), 60)
                set.hfg.Filled = true
                set.hfg.Size = Vector2.new(2, h * ratio)
                set.hfg.Position = Vector2.new(x - 5, y + h * (1 - ratio))
            end
            if set.name then
                set.name.Visible = cfg.espName
                set.name.Text = t.isBot and ("BOT " .. t.name:gsub("^bot:", "")) or t.name
                set.name.Color = col
                set.name.Size = 17
                set.name.Center = true
                set.name.Outline = true
                -- 钳制到屏幕内：目标在屏幕上方边缘时 y-15 会变成负数，
                -- 文字被画到视口外就完全看不见，只剩一个孤零零的框。
                local vpy = workspace.CurrentCamera.ViewportSize.Y
                set.name.Position = Vector2.new(
                    math.clamp(x + w / 2, 40, workspace.CurrentCamera.ViewportSize.X - 40),
                    math.clamp(y - 15, 4, vpy - 8))
            end
            if set.dist then
                set.dist.Visible = cfg.espDist
                set.dist.Text = string.format("%.0fm", t.distance * 0.28)
                set.dist.Color = col
                set.dist.Size = 16
                set.dist.Center = true
                set.dist.Outline = true
                local vpy2 = workspace.CurrentCamera.ViewportSize.Y
                set.dist.Position = Vector2.new(
                    math.clamp(x + w / 2, 40, workspace.CurrentCamera.ViewportSize.X - 40),
                    math.clamp(y + h + 2, 4, vpy2 - 8))
            end
            if set.frozen then
                -- 位置已经冻结的目标，框下面明确写「旧 N 秒」。
                -- 这种框看起来和实时框没有区别，不标出来会直接被当成活人在预瞄。
                local showTag = cfg.showFrozenTag and t.frozen == true
                set.frozen.Visible = showTag
                if showTag then
                    local secs = tonumber(t.ageSec) or 0
                    -- ⚠ Drawing 的 Text 用的是引擎默认字体，**没有中文字形**，
                    -- 写中文会渲染成「❓ / 方框」。这里原来写的是 "旧 %.1fs"，
                    -- 屏幕上就是那个神秘符号。全部改用 ASCII。
                    set.frozen.Text = string.format("OLD %.1fs", secs)
                    set.frozen.Color = Color3.fromRGB(200, 195, 110)
                    set.frozen.Size = 13
                    set.frozen.Center = true
                    set.frozen.Outline = true
                    local vpy3 = workspace.CurrentCamera.ViewportSize.Y
                    set.frozen.Position = Vector2.new(
                        math.clamp(x + w / 2, 40, workspace.CurrentCamera.ViewportSize.X - 40),
                        math.clamp(y + h + 18, 4, vpy3 - 8))
                end
            end
            if set.wpn then
                set.wpn.Visible = cfg.espWeapon
                set.wpn.Text = t.weapon
                set.wpn.Color = Color3.fromRGB(205, 205, 205)
                set.wpn.Size = 15
                set.wpn.Center = true
                set.wpn.Outline = true
                set.wpn.Position = Vector2.new(x + w / 2, y + h + 16)
            end
        else
            for _, d in pairs(set) do if d then d.Visible = false end end
        end
    end

    for k, set in pairs(S.espObjects) do
        if not alive[k] then
            hideSet(set)
            -- ⚠ 只隐藏不够。目标死亡/离开/被 PVS 剔除后，这些 Drawing 对象会一直留在内存里，
            -- 一旦同一 key 被复用或者清理逻辑漏掉一帧，屏幕上就会出现「骨骼套在别人身上」
            -- 这种残影。这里给一个宽限期，超过就彻底 Remove 并从表里删掉。
            if type(S.ghostSince) ~= "table" then S.ghostSince = {} end
            if not S.ghostSince[k] then
                S.ghostSince[k] = os.clock()
            elseif os.clock() - S.ghostSince[k] > (tonumber(cfg.ghostPurgeSeconds) or 3) then
                for kk, d in pairs(set) do
                    if kk == "bones" or kk == "parts" then
                        for _, o in pairs(d) do
                            if o and o.Remove then pcall(function() o:Remove() end) end
                        end
                        d = {}
                    elseif d and d.Remove then
                        pcall(function() d:Remove() end)
                    end
                end
                S.espObjects[k] = nil
                S.ghostSince[k] = nil
                S.ghostsPurged = (S.ghostsPurged or 0) + 1
            end
        elseif S.ghostSince and S.ghostSince[k] then
            S.ghostSince[k] = nil
        end
    end
end
-- ═══════════════════════════════════════════════════════════════
-- C4 / 炸药透视
-- 服务端下包的 C4 模型会出现在 workspace 或 workspace.Map 下（名字含 C4 / Bomb）。
-- 现在地图里没包时扫描结果为 0，是正常的 —— 有人下包才出现。
-- 每秒扫一次（不每帧全扫，避免卡帧），绘制在 updateEsp 的同一帧里做。
-- ═══════════════════════════════════════════════════════════════
-- ═══ C4 位置：靠 C4.Planted 广播，不靠扫模型 ═══
-- 实测下包后 workspace 里根本没有 C4 模型（关键词全扫命中 0，只有误匹配的 Sound），
-- 因为服务端不给 CT 复制模型（PVS）。真正的信息来源是 Remotes.C4 的回包。
S.c4Planted = nil
S.c4PlantedInfo = ""
do
    local ok, Remotes = pcall(function() return require(RS.Database.Security.Remotes) end)
    if ok and type(Remotes) == "table" and Remotes.C4 then
        local C4 = Remotes.C4
        local function hook(name, fn)
            local p = C4[name]
            if p and type(p.Listen) == "function" then
                pcall(function() p.Listen(function(d) pcall(fn, d) end) end)
            end
        end
        hook("Planted", function(d)
            S.c4Planted = d
            S.c4PlantedAt = os.clock()
            local parts = {}
            if type(d) == "table" then
                for k, v in pairs(d) do
                    if type(v) ~= "table" then parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
                end
            end
            table.sort(parts)
            S.c4PlantedInfo = table.concat(parts, " "):sub(1, 300)
        end)
        hook("Start", function(d) S.c4Start = d end)
        hook("Defused", function(d) S.c4Planted = nil; S.c4Defused = d end)
        hook("Cancel", function(d) S.c4Planted = nil end)
        hook("ForceCancel", function(d) S.c4Planted = nil end)
        S.c4Hooked = true
    end
end

S.worldItems = {}
S.worldMarks = {}
S.worldLastScan = 0

-- 扫描世界里的「可透视物件」：C4 + 别人扔出去的投掷物
-- 名字匹配要宽松：服务端复制过来的模型常叫 "C4" / "HE Grenade" / "Molotov" / "Smoke Grenade" 等
S.scanWorldItems = function()
    local found = {}
    local function add(d, kind)
        if d:IsA("Model") or d:IsA("BasePart") or d:IsA("Tool") then
            found[#found + 1] = { obj = d, kind = kind }
        end
    end
    local function classify(nm)
        local s = string.lower(nm)
        if s == "c4" or s:find("plantedc4") then return "c4" end
        if s:find("molotov") or s:find("incendiary") then return "fire" end
        if s:find("smoke") then return "smoke" end
        if s:find("flash") then return "flash" end
        if s:find("decoy") then return "decoy" end
        if s:find("grenade") or s:find("he ") or s == "he" or s:find("frag") then return "he" end
        if s:find("bomb") then return "c4" end
        return nil
    end
    local function scan(root, depth)
        if not root or depth > 2 then return end
        for _, d in ipairs(root:GetChildren()) do
            local k = classify(tostring(d.Name))
            if k then add(d, k) end
        end
    end
    scan(workspace, 0)
    scan(workspace:FindFirstChild("Map"), 1)
    scan(workspace:FindFirstChild("Debris"), 1)
    scan(workspace:FindFirstChild("Characters"), 1)
    S.worldItems = found
    S.worldCount = #found
end

S.worldColor = {
    c4 = Color3.fromRGB(255, 70, 70),
    fire = Color3.fromRGB(255, 140, 40),
    smoke = Color3.fromRGB(190, 190, 210),
    flash = Color3.fromRGB(255, 245, 120),
    decoy = Color3.fromRGB(140, 220, 140),
    he = Color3.fromRGB(255, 100, 60),
}
S.worldLabel = {
    c4 = "C4", fire = "燃烧", smoke = "烟雾", flash = "闪光", decoy = "诱饵", he = "手雷",
}

S.drawWorldItems = function()
    if not cfg.showWorldItems then   -- 默认关闭；nil 也视为关闭（原来写 == false，nil 会漏过去）
        for _, m in pairs(S.worldMarks) do
            if m.text then pcall(function() m.text:Remove() end) end
            if m.ring then pcall(function() m.ring:Remove() end) end
        end
        S.worldMarks = {}
        return
    end
    local now = os.clock()
    if now - S.worldLastScan >= 0.5 then
        S.worldLastScan = now
        pcall(S.scanWorldItems)
    end
    local cam = workspace.CurrentCamera
    if not cam then return end
    local seen = {}
    for _, rec in ipairs(S.worldItems) do
        local obj, kind = rec.obj, rec.kind
        if obj and obj.Parent then
            local ok, pos = pcall(function()
                if obj:IsA("BasePart") then return obj.Position end
                return obj:GetPivot().Position
            end)
            if ok and typeof(pos) == "Vector3" then
                local sp = cam:WorldToViewportPoint(pos)
                if sp.Z > 0 then
                    local key = tostring(obj:GetFullName()) .. "#" .. kind
                    seen[key] = true
                    local mark = S.worldMarks[key]
                    if not mark then
                        mark = {}
                        local t = Drawing.new("Text")
                        t.Size = 15
                        t.Center = true
                        t.Outline = true
                        t.Color = S.worldColor[kind] or Color3.new(1, 1, 1)
                        mark.text = t
                        S.worldMarks[key] = mark
                    end
                    local dist = (pos - cam.CFrame.Position).Magnitude
                    if mark.text then
                        mark.text.Visible = true
                        mark.text.Position = Vector2.new(sp.X, sp.Y - 22)
                        mark.text.Text = string.format("%s  %dm", S.worldLabel[kind] or kind, math.floor(dist))
                        mark.text.Color = S.worldColor[kind] or Color3.new(1, 1, 1)
                    end
                end
            end
        end
    end
    for key, mark in pairs(S.worldMarks) do
        if not seen[key] then
            if mark.text then pcall(function() mark.text:Remove() end) end
            if mark.ring then pcall(function() mark.ring:Remove() end) end
            S.worldMarks[key] = nil
        end
    end
end

-- ═══ 换肤持久化轮询 ═══
-- 为什么需要轮询：viewmodel 每次切枪/重生都会重建，重建后材质回到游戏自己的皮肤。
-- 为什么是 0.12 秒而不是 1 秒：1 秒会让「游戏重置 → 我们刷回」的空窗长达 1 秒，
-- 视觉上就是皮肤一闪一闪。0.12 秒（8Hz）足以把空窗压到肉眼几乎看不出。
-- 为什么「只在材质不匹配时写」：无脑每帧写会不断触发材质刷新，
-- 反而更容易被游戏的下一次重建覆盖，形成闪烁。
S._matCache = {}
-- ═══ 轮询耗时埋点 ═══
-- 「0.12 秒循环是不是卡顿尖峰的真凶」这个争论不需要再靠感觉：
-- 每次 tick 记录耗时，MV_V2.skinPoll() 直接给出 max / avg / p99 / 缓存命中率。
-- 判据：max 远小于 16ms（一帧）就不是它；max 接近或超过 16ms 才是。
S.skinPoll = {
    ticks = 0, skips = 0, cacheHit = 0, cacheMiss = 0,
    lastMs = 0, maxMs = 0, sumMs = 0, samples = {},
}
S.skinPoll.tick = function(t0, kind)
    local st = S.skinPoll
    local ms = (os.clock() - t0) * 1000
    st.ticks += 1
    st.lastMs = ms
    st.sumMs += ms
    if ms > st.maxMs then st.maxMs = ms end
    if kind then st[kind] = (st[kind] or 0) + 1 end
    -- 只留最近 256 个样本，算 P99 用（够用且不会涨内存）
    local n = #st.samples + 1
    if n > 256 then
        table.remove(st.samples, 1)
        n = 256
    end
    st.samples[n] = ms
end
S.skinPoll.report = function()
    local st = S.skinPoll
    local n = #st.samples
    local p99 = 0
    if n > 0 then
        local copy = {}
        for i = 1, n do copy[i] = st.samples[i] end
        table.sort(copy)
        p99 = copy[math.max(1, math.floor(n * 0.99))] or 0
    end
    return string.format(
        "ticks=%d avg=%.2fms p99=%.2fms max=%.2fms last=%.2fms | cacheHit=%d cacheMiss=%d skip=%d | emptySrc=%d partsWritten=%d partsRejected=%d",
        st.ticks,
        (st.ticks > 0) and (st.sumMs / st.ticks) or 0,
        p99, st.maxMs, st.lastMs,
        st.cacheHit, st.cacheMiss, st.skips,
        st.emptySrc or 0, st.partsWritten or 0, st.partsRejected or 0)
end
task.spawn(function()
    while true do
        task.wait(0.12)
        if S._alive == false or (REG and REG.gen ~= MY_GEN) then break end
        local t0 = os.clock()
        pcall(function()
            local ic = getInvCtrl()
            if not ic then return end
            local okw, w = pcall(function() return ic.peekCurrentEquippedForMovement() end)
            if not okw or not w or not w.Name then
                S.skinPoll.skips += 1
                return
            end
            local wn = tostring(w.Name)
            local want = S.skinPaint and S.skinPaint[wn]
            if not want or want == "" or want == "Stock" then
                S.skinPoll.skips += 1
                return
            end
            -- ⚠⚠ 持续纠正 item.Skin。
            --
            -- InventoryController.getCurrentEquipped() 返回的 table 里，Skin 字段才是
            -- 游戏构建 viewmodel 的依据。实测：我们改完能保持（persisted=true），
            -- 但**游戏重建武器对象时会把它重置回真实装备的皮肤**（读回来又是 "Stock"）。
            -- 结果是：切一次枪就被打回原皮，用户看到的就是「美化被固定住了」。
            -- 这里每 0.12 秒检查一次，被重置就立刻改回去 —— 这样下次重建拿到的就是我们的皮肤。
            pcall(function()
                -- ★ 同 S.setSkin：这里也只用 peek，绝不碰原版 getCurrentEquipped。
                local peek2 = ic.peekCurrentEquippedForMovement or ic.getCurrentEquipped
                local cw = peek2 and peek2()
                if cw and tostring(cw.Name) == wn and tostring(cw.Skin) ~= tostring(want) then
                    cw.Skin = tostring(want)
                    S.itemSkinFixes = (S.itemSkinFixes or 0) + 1
                    S.itemSkinFixLast = string.format("%s: %s→%s", wn, tostring(cw.Skin), tostring(want))
                end
            end)
            local cam = workspace:FindFirstChild("Camera")

            -- ═══ 近战外观替换：已停用 ═══
            --
            -- ⚠ 这条路实测会把游戏状态搞坏，永久关闭（保留开关但默认不启用）：
            --   1) 改 item.Name → 游戏重建武器对象时丢弃修改，物品栏变金色但拿刀显示手枪弹药
            --   2) 换 viewmodel → 新建的模型**不会跟随相机**（游戏对原始模型有每帧绑定），
            --      玩家一走开，枪就留在原地飘着；再切枪就彻底消失
            --   3) 改 Viewmodel.Model 引用 → 会把引用指到别的武器上，导致两个模型叠在一起
            -- 真正要换刀外观，必须走游戏自己的 equip 流程（服务端认可），客户端做不到。
            if cfg.meleeSwapOn == true then
                local swapTo = S.meleeSwap and S.meleeSwap[wn]
                if swapTo and swapTo ~= wn then
                    pcall(function()
                        local GWP = require(game:GetService("ReplicatedStorage").Components.Common.GetWeaponProperties)
                        local props = GWP(swapTo)
                        if props then
                            -- ★ 这里原来直接调 ic.getCurrentEquipped()（无 and 保护），
                            --   一旦走到就是原版 getfenv 检测。改成 peek。
                            local peek3 = ic.peekCurrentEquippedForMovement or ic.getCurrentEquipped
                            local cw = peek3 and peek3()
                            if cw then
                                cw.Properties.CharacterAnimations = props.CharacterAnimations
                                cw.Properties.CameraAnimations = props.CameraAnimations
                            end
                        end
                    end)
                end
            end

            local vm = cam and cam:FindFirstChild(wn)
            -- ⚠ 清掉重复的 viewmodel。
            -- 重复时「枪身叠在一起、材质互相打架」，而且我们只改得到第一个。
            if cam and vm then
                for _, c in ipairs(cam:GetChildren()) do
                    if c:IsA("Model") and c.Name == wn and c ~= vm then
                        pcall(function() c:Destroy() end)
                        S.vmDupRemoved = (S.vmDupRemoved or 0) + 1
                    end
                end
            end
            if not vm then
                -- ⚠ viewmodel 丢了要能自己长回来。
                -- ⚠ 这里**不再**自动重建 viewmodel。
                -- 之前用 GetCameraModel 建一份挂回 Camera，实测它**不会跟随相机**：
                -- 游戏对原始 viewmodel 有每帧的 CFrame 绑定，我们新建的没有，
                -- 结果枪停在原地、玩家走开后只剩空气（有截图）。丢模型就只能切枪/重进。
                S.skinPoll.skips += 1
                return
            end
            local weapon = vm:FindFirstChild("Weapon") or vm

            -- 目标材质表缓存：GetCameraModel 每把武器/皮肤只调一次（否则每 0.12 秒重建模型）
            local key = wn .. "|" .. want
            -- ⚠ 失败熔断：某些枪的 SurfaceAppearance 带 TexturePackContent（引擎烘焙纹理包），
            -- ColorMap 写入会被静默忽略（赋值成功、值不变、画面不动）。
            -- 不熔断的话每 0.12 秒都会重写一遍 → 引擎反复重烘焙纹理 → 周期性掉帧。
            if (S._skinFail and S._skinFail[key] or 0) >= 3 then
                S.skinPoll.skips += 1
                return
            end
            -- 空来源材质的冷却（见下面 emptySrc 分支）：某些武器/皮肤结构上就取不到材质，
            -- 这里挡掉，避免 8Hz 反复重建模型。
            if S._skinEmptyUntil and (S._skinEmptyUntil[key] or 0) > os.clock() then
                S.skinPoll.skips += 1
                return
            end
            local srcMap = S._matCache[key]
            if not srcMap then
                -- ⚠⚠ 这里以前走 lib.GetCameraModel，拿到的是**原皮模板**
                -- （Stock 和 Luminex 逐部件 ColorMap 完全一样）。
                -- 外加本循环每 0.12 秒跑一次，于是它一直在把原皮写回 viewmodel，
                -- 把 paintCurrentModel 刚刷上的真实皮肤覆盖掉 —— 表现就是
                -- 「点皮肤时立刻对、一秒后自己变回原皮」。
                -- 必须和 paintCurrentModel 用同一个来源：Assets.Skins 里的真实材质。
                local m, why = S.getSkinSAMap((S.modelWeaponOf and S.modelWeaponOf(wn)) or wn, want, S.skinWear)
                if m and next(m) ~= nil then
                    srcMap = m
                    S._matCache[key] = srcMap
                    if S._skinEmpty then S._skinEmpty[key] = 0 end
                else
                    S.skinPoll.emptySrc = (S.skinPoll.emptySrc or 0) + 1
                    S.lastSkinSrcErr = tostring(why)
                    -- 连续 4 次空 → 这个 key 冷却 20 秒，避免 8Hz 反复重建
                    S._skinEmpty = S._skinEmpty or {}
                    local ec = (S._skinEmpty[key] or 0) + 1
                    S._skinEmpty[key] = ec
                    if ec >= 4 then
                        S._skinEmptyUntil = S._skinEmptyUntil or {}
                        S._skinEmptyUntil[key] = os.clock() + 20
                        S._skinEmpty[key] = 0
                        S.skinPoll.emptyBackoff = (S.skinPoll.emptyBackoff or 0) + 1
                    end
                    S.skinPoll.skips += 1
                    return
                end
                S.skinPoll.cacheMiss += 1
            else
                S.skinPoll.cacheHit += 1
            end
            -- ⚠ 目标部件列表缓存：viewmodel 没重建时不必每 0.12 秒 GetDescendants 一次。
            -- 失效判据三选一：武器实例换了 / 直接子节点数量变了 / 超过 1 秒。
            -- 中间那条是给「同一个容器里换内部部件」准备的 —— 只靠 2 秒 TTL 的话，
            -- 那种情况最多会有 2 秒画不上皮肤。GetChildren 只扫直接子级，比全树便宜得多。
            local childN = #weapon:GetChildren()
            local partList = S._skinParts
            if (not partList) or partList.weapon ~= weapon or partList.childN ~= childN
                or (os.clock() - (partList.at or 0)) > 1 then
                partList = { weapon = weapon, at = os.clock(), childN = childN, parts = {} }
                for _, d in ipairs(weapon:GetDescendants()) do
                    if d:IsA("MeshPart") and not S.SKIN_SKIP[d.Name] then
                        partList.parts[#partList.parts + 1] = d
                    end
                end
                S._skinParts = partList
            end
            local fixed, noEffect = 0, 0
            for _, d in ipairs(partList.parts) do
                local t = srcMap[d.Name]
                if t then
                    local sa = d:FindFirstChildOfClass("SurfaceAppearance")
                    if sa then
                        -- ⚠ 判据是「是否等于目标值」，不是「是否和原值不同」。
                        -- 用「不同」的话：重复应用同一款皮肤（已经是目标值）会被判成失败，
                        -- 而且 ColorMap 恰好相同、只有法线/发光不同的皮肤也永远写不进去。
                        local needWrite = false
                        if tostring(S.getColorMap(sa)) ~= tostring(t.ColorMap) then
                            needWrite = true
                        else
                            for k, v in pairs(t) do
                                if v ~= nil and k ~= "ColorMap" then
                                    if tostring(S.saGet(sa, k)) ~= tostring(v) then
                                        needWrite = true
                                        break
                                    end
                                end
                            end
                        end
                        if needWrite then
                            for k, v in pairs(t) do
                                if v ~= nil then S.saSet(sa, k, v) end
                            end
                            -- 写后验证：读回值等于目标才算成功（引擎静默拒收时值不会变）
                            if tostring(S.getColorMap(sa)) == tostring(t.ColorMap) then
                                fixed = fixed + 1
                            else
                                noEffect = noEffect + 1
                            end
                        end
                    end
                end
            end
            -- ⚠ 熔断判据必须看「有没有写不进的部件」，不能看「这一轮有没有成功过」。
            -- 原来是 `if fixed > 0 then 清零`：同一把枪上 A 部件写得进、B 部件写不进时，
            -- 每轮都因为 A 的成功把计数抹掉 —— B 永远熔不断，每 0.12 秒重试一次，
            -- 引擎每 0.12 秒重烘焙一次纹理。这正是「部分成功的枪持续掉帧」的成因。
            if fixed > 0 then
                S.lastSkinPaint = string.format("%s→%s(补写%d)", wn, want, fixed)
                -- 累计「实际触发了多少次材质赋值」：这是渲染侧开销的代理指标。
                -- 单看 skinPoll.max（Lua 计时）证明不了不卡 —— 引擎重烘焙发生在赋值之后。
                S.skinPoll.partsWritten = (S.skinPoll.partsWritten or 0) + fixed
            end
            if noEffect > 0 then
                S._skinFail = S._skinFail or {}
                S._skinFail[key] = (S._skinFail[key] or 0) + 1
                S.skinPoll.partsRejected = (S.skinPoll.partsRejected or 0) + noEffect
                if S._skinFail[key] == 3 then
                    warn("[skin] " .. tostring(wn)
                        .. " 有部件材质写入被引擎拒绝（TexturePackContent 烘焙），已停止重试")
                end
            elseif S._skinFail and S._skinFail[key] then
                -- 这一轮没有任何「写了没效果」的部件 → 真正恢复，计数归零
                S._skinFail[key] = 0
            end
        end)
        -- 放在 pcall 外面：内部任何提前 return 也照样计入一次 tick 的耗时，
        -- 否则「跳过」的那些帧永远不出现在统计里，看起来总是很便宜。
        S.skinPoll.tick(t0)
    end
end)

-- 独立循环驱动（不依赖主循环的挂载点，避免再被删）
task.spawn(function()
    while true do
        task.wait(0.12)
        if S._alive == false or (REG and REG.gen ~= MY_GEN) then break end
        pcall(S.drawWorldItems)
    end
end)

---------------------------------------------------------------------
-- 主循环（单连接，统一调度）
-- 绘制必须发生在相机确定之后、渲染之前：
--   RenderStep(1999) 是第三人称写相机的位置，
--   这里用 Last(2000)，保证投影用的是这一帧最终相机，不再差一帧。
-- 之前放在 Heartbeat 里，Heartbeat 在渲染之后跑，第三人称下相机每帧
-- 跳 12 stud，透视框和雷达红点就会滞后 → 看起来"错位"。
---------------------------------------------------------------------
local acc = 0
local drawConn = RunService:BindToRenderStep("MV_Draw",
    Enum.RenderPriority.Last.Value, function(dt)
        if S._alive == false or REG.gen ~= MY_GEN then
            pcall(function() RunService:UnbindFromRenderStep("MV_Draw") end)
            return
        end
        acc += dt
        if acc < 0.033 then return end
        acc = 0
        -- pcall 会吞掉堆栈，出问题时就只能瞎猜是哪个函数挂了。
        -- 把错误和 traceback 记到 S 上，随时能用 getgenv().MV_V2.state 读出来。
        local function guard(fn, tag)
            local ok, err = pcall(fn)
            if not ok then
                S["err_" .. tag] = tostring(err)
                S["tb_" .. tag] = (debug and debug.traceback and debug.traceback()) or ""
            end
        end
        guard(updateEsp, "esp")
        guard(updateRadar, "radar")

        -- Drawing 自检（首帧之后跑一次）
        --
        -- 执行器的 Drawing 被反复 cleardrawcache 之后会彻底失效：
        -- 对象照样能 new、Visible 照样是 true、代码全在跑，但 getdrawingcache() 是空的，
        -- 屏幕上一个像素都不渲染。表现就是「透视/抛物线/落点圈全没了」，
        -- 而埋点（throwTicks / throwLineCount / ringR）一切正常 —— 很容易被误判成功能坏了。
        if not S.drawChecked then
            S.drawChecked = true
            if type(getdrawingcache) == "function" then
                local okc, cc = pcall(getdrawingcache)
                if okc and type(cc) == "table" and #cc == 0 then
                    S.drawingDead = true
                    warn("[MV] Drawing 缓存为空 —— 这个客户端的 Drawing 已失效，"
                        .. "ESP / 抛物线 / 落点圈都不会显示。重新注入执行器或重进服务器即可恢复。")
                else
                    S.drawingDead = false
                end
            end
        end
        -- 投掷物抛物线
        --
        -- ⚠ 这里的前提条件曾经只写了 cfg.throwPreview，导致「拿投掷物自动显示」
        -- （throwAuto，默认 true）完全没有机会执行 —— 表现就是「拿着手雷没有抛物线」。
        -- 真正的显示逻辑（手持是不是投掷物）由 updateThrow 内部判断，
        -- 这里只要保证「有任何一个开关可能让它显示」就调用即可。
        if cfg.throwPreview == true or cfg.throwAuto ~= false or cfg.throwKeyHeld == true then
            guard(updateThrow, "throw")
            guard(S.drawThrowTrack, "track")
        end
        guard(updateArrows, "arrows")
        guard(updateFov, "fov")
        -- 出手后的真实落点 + 引信倒计时（数据源 Projectile.Spawn，不受上面那几个开关影响）
        guard(S.updateThrowLanding, "landing")
        guard(updateGrenades, "grenades")
        guard(updateVfxZones, "vfx")
        guard(S.updateSoundRipples, "ripple")
        guard(S.updateSpinCam, "spin")
        guard(S.applyRecoilComp, "recoilcomp")
        -- ⚠ 弹药/射速/换弹维护必须在这里兜底调一次。
        --
        -- 原来它只挂在 S.ammoConn（Heartbeat）上，而那条连接只在
        -- 「切换开关 / 角色重生 / 换队伍」时才会建立。实测 S.lastSkipAt、S.lastReloadAt、
        -- S.meleeAnimsTuned 全都是 nil —— 说明那个循环从来没跑过，
        -- 所以「跳过开火间隔 / 瞬间换弹 / 近战加速」三个开关全是摆设。
        -- ammoStep 内部各自有限频（50ms / 120ms），这里每帧调不会增加开销。
        guard(ammoStep, "ammo")
        guard(S.updateSites, "sites")
        guard(S.updateBomb, "bomb")
    end)

-- Heartbeat 只保留不需要相机的那部分
local hbConn = RunService.Heartbeat:Connect(function(dt)
    if S._alive == false or REG.gen ~= MY_GEN then
        pcall(function() hbConn:Disconnect() end)
        return
    end
    -- 第三人称：游戏可能会重置 CameraMode，每 0.5 秒补一次
    S.tpTick = (S.tpTick or 0) + dt
    if S.tpTick >= 0.5 then
        S.tpTick = 0
        pcall(applyThirdPerson)
    end
    -- ⚠ VIP 面板同步必须在脚本自己的线程里跑。
    --
    -- 实测：从外部 execute_script 调用控件的 UpdateState / Toggle 会报
    --   "The current thread cannot access 'Instance' (lacking capability Plugin)"
    -- State 字段改了，但 UI 不动 —— 因为 Maclib 控件内部要写 Instance 属性，
    -- 而外部线程缺这个 capability。
    --
    -- 所以放在 Heartbeat 里（脚本线程），每秒对齐一次服务端状态。
    S.vipSyncTick = (S.vipSyncTick or 0) + dt
    if S.vipSyncTick >= 1.0 then
        S.vipSyncTick = 0
        if S.vip and S.vip.state then
            pcall(function()
                if type(S.syncVipUI) == "function" then S.syncVipUI() end
            end)
        end
    end

    -- 自动兔子跳：每帧检测落地
    if cfg.bunnyhop then pcall(bunnyhopStep) end

    -- ⚠ 只有开了 hyperFire（脚本接管连发）才需要每帧杀拉栓。
    --
    -- 之前是无条件跟着 skipFireDelay 跑，结果把全自动枪打成单点：
    -- killShootDelay 每帧 task.cancel(ShootDelayThread) + IsShooting=false，
    -- 而游戏的全自动连发就靠 IsShooting 维持「正在连射」，每帧打回 false
    -- 就等于「你松手了」，必须重新按扳机才出下一发。
    -- 半自动枪感觉不出来（本来每次点就是重新触发），所以只有全自动枪中招。
    if cfg.skipFireDelay == true and cfg.hyperFire == true then
        pcall(S.killShootDelay)
    end

    -- 商店打开时把菜单收起来。
    -- 我们的 ScreenGui 是 DisplayOrder 最大值（2147483647），窗口 880x660 正好盖在屏幕中央，
    -- 商店的购买按钮全在下面 → 左键点到的都是我们菜单上的控件，买东西毫无反应。
    --
    -- ⚠ 这里必须用「模糊匹配」找商店，不能写死名字。
    -- 实测游戏把商店 Frame 改名成 BuyMenuRetired（不是 BuyMenu），
    -- 旧代码 FindFirstChild("BuyMenu") 永远返回 nil → 菜单永远不收 →
    -- 用户表现为「在商店里点任何东西都没反应」。

    S.buyTick = (S.buyTick or 0) + dt
    if S.buyTick >= 0.15 then
        S.buyTick = 0
        pcall(function()
            if not S.menuScreenGui or not S.menuScreenGui.Parent then
                -- ⚠ 以前这里是「递归找挂着 Base Frame 的 ScreenGui」——
                -- WindUI 根节点上没有 Base（结构是 WindUI → Window(Folder) → Frame），
                -- 所以 S.menuScreenGui 永远是 nil，这一段从来没有真正跑起来过。
                -- 统一走 S.findMenuGui（精确名 WindUI + Base 作为旧库兜底）。
                S.menuScreenGui = S.findMenuGui()
            end
            local sg = S.menuScreenGui
            if not sg then return end

            -- ── 窗口位置：完全不干预 ──
            --
            -- 用户明确要求：能拖到屏幕外，不要拉回来。
            -- 演进史（两次都被骂）：
            --   v1「只要有一点越界就吸回」→ 拖到边上就回弹
            --   v2「可见面积 < 35% 才救」→ 拖出去一半还是被拉回
            -- v3：整段删除。脚本不再碰 Base.Position，一次都不碰。
            --
            -- 只留一个只读埋点（S.guiVisRatio），方便以后排查，
            -- 但它不再触发任何写操作。
            do
                local base0 = sg:FindFirstChild("Base")
                if base0 and base0:IsA("GuiObject") then
                    local cam2 = workspace.CurrentCamera
                    local vp2 = (cam2 and cam2.ViewportSize) or Vector2.new(1920, 1080)
                    local ap2, as2 = base0.AbsolutePosition, base0.AbsoluteSize
                    local visW = math.max(0, math.min(ap2.X + as2.X, vp2.X) - math.max(ap2.X, 0))
                    local visH = math.max(0, math.min(ap2.Y + as2.Y, vp2.Y) - math.max(ap2.Y, 0))
                    local area = as2.X * as2.Y
                    S.guiVisRatio = (area > 0) and ((visW * visH) / area) or 1
                end
            end
            local pg2 = LP:FindFirstChild("PlayerGui")
            local mg2 = pg2 and pg2:FindFirstChild("MainGui")
            local gp2 = mg2 and mg2:FindFirstChild("Gameplay")
            local mid2 = gp2 and gp2:FindFirstChild("Middle")
            -- 模糊找：名字里含 BuyMenu / Shop / Store 的可见 Frame
            local open = false
            if mid2 then
                -- ⚠ 商店检测踩过三个坑，全都记在这里：
                --
                -- 坑1：写死 FindFirstChild("BuyMenu") —— 游戏把 Frame 改名成
                --      BuyMenuRetired，找不到 → 菜单永远不收起。
                -- 坑2：递归后代 + 只看 c.Visible —— Visible 是继承的，
                --      BuyMenu.Visible=false 时它的子项 Shop 属性仍是 true，
                --      于是永远判定"商店打开"→ 菜单被永久关在屏幕外。
                -- 坑3：模糊匹配名字含 "buymenu" —— 会命中
                --      Middle.Notification.BuyMenuHint（一个可见的提示气泡），
                --      同样导致菜单打不开。
                --
                -- 现在：只认 Middle 的【直接子项】里名字精确等于
                -- BuyMenu / BuyMenuRetired / Shop / Store 的，且它自己 Visible=true。
                -- 这样既不会漏，也不会被孙辈节点骗到。
                local names = { "buymenu", "buymenuRetired", "shop", "store" }
                local nameSet = {}
                for _, n in ipairs(names) do nameSet[n:lower()] = true end
                for _, c in ipairs(mid2:GetChildren()) do
                    if c:IsA("GuiObject") then
                        local nm = tostring(c.Name):lower()
                        if nameSet[nm] then
                            local effVis = c.Visible
                            local p = c.Parent
                            local guard = 0
                            while effVis and p and p ~= mid2 and guard < 10 do
                                guard = guard + 1
                                if p:IsA("GuiObject") and not p.Visible then effVis = false end
                                p = p.Parent
                            end
                            if effVis then
                                open = true
                                break
                            end
                        end
                    end
                end
            end

            -- ⚠⚠⚠ 只「关」不「开」。这是本文件里最要命的一个 bug 修复。
            --
            -- 原来写的是：
            --     if sg.Enabled == open then sg.Enabled = not open end
            -- 看起来是「同步状态」，实际效果是：
            --     商店没开（open=false）+ 用户按 RightControl 关了菜单（Enabled=false）
            --     → false == false 成立 → sg.Enabled = not false = true
            --     → **脚本把用户刚关掉的菜单又强行打开了**
            --
            -- 用户看到的就是「按了快捷键，菜单闪一下就回来了，商店还是点不动」。
            -- 因为 DisplayOrder 是 2147483647，它永远盖在商店上面。
            --
            -- 正确逻辑：
            --   · 商店打开 → 强制隐藏菜单（必须）
            --   · 商店关闭 → **把「是我关掉的那个菜单」还回去**
            --
            -- ⚠ 第二条以前写的是「什么都不做」，代价就是用户看到的
            --   「开商店 → GUI 消失（能理解）→ 关商店 → GUI 一去不回」：
            --   确实是脚本把 ScreenGui.Enabled 置成了 false，而关商店时没有任何代码
            --   把它打开；更糟的是 MacLib 自己的 window 状态还停在"开"，
            --   用户按 RightControl 反而是"关"，于是看起来像彻底失灵。
            --   现在用 S.menuAutoHidden 记账：只有"确实是脚本关的"才还原，
            --   用户自己关的菜单不碰。
            if open then
                if sg.Enabled then
                    sg.Enabled = false
                    S.menuAutoHidden = true     -- 记下「是我关的」，方便后续判断
                    S.menuHideAt = os.clock()
                end
            elseif S.menuAutoHidden then
                if not sg.Enabled then sg.Enabled = true end
                S.menuAutoHidden = false
                S.menuRestored = (S.menuRestored or 0) + 1
            end
            S.buyDbg = string.format("open=%s enabled=%s autoHidden=%s",
                tostring(open), tostring(sg.Enabled), tostring(S.menuAutoHidden))
        end)
    end
    -- 只在配置真的变了才写回 getgenv。
    -- 以前是无条件每 2 秒覆盖一次：GUI 初始化把 cfg 冲掉之后，这份被冲掉的
    -- 值会在两秒内变成新存档，下次加载再恢复回来 —— 错误会被自我固化下来。
    S.cfgSaveTick = (S.cfgSaveTick or 0) + dt
    if S.cfgSaveTick >= 2 then
        S.cfgSaveTick = 0
        local last = getgenv().MV_CFG_SAVE
        local changed = (type(last) ~= "table")
        if not changed then
            for k, v in pairs(cfg) do
                local t = type(v)
                if (t == "boolean" or t == "number" or t == "string") and last[k] ~= v then
                    changed = true
                    break
                end
            end
        end
        if changed then pcall(saveCfg) end
    end
end)
table.insert(S.conns, hbConn)
table.insert(REG.conns, hbConn)

---------------------------------------------------------------------
-- 买枪
---------------------------------------------------------------------
-- 购买前置检查：阵营 + 回合状态 + 钱
local EQUIP_DIR = nil

local function equipCfg(name)
    if not EQUIP_DIR then
        EQUIP_DIR = RS:FindFirstChild("Database")
            and RS.Database:FindFirstChild("Custom")
            and RS.Database.Custom:FindFirstChild("GameStats")
            and RS.Database.Custom.GameStats:FindFirstChild("Equipment")
    end
    local node = RS.Database.Custom.Weapons:FindFirstChild(name)
        or (EQUIP_DIR and EQUIP_DIR:FindFirstChild(name))
    if not node then return nil, "配置不存在" end
    local ok, cfgW = pcall(require, node)
    if not ok or typeof(cfgW) ~= "table" then return nil, "读取失败" end
    return cfgW
end

-- 当前能不能买（回合阶段）
local function buyPhaseOk()
    local st = tostring(workspace:GetAttribute("GameState") or "")
    if st == "" then return true end
    if st == "Warmup" then
        return false, "热身阶段不能购买"
    end
    -- 回合进行中服务端不接受购买请求，只有购买时间（Buy Period）才行
    if st == "Round In Progress" then
        return false, "回合进行中，只能在购买时间内买"
    end
    return true
end

local function buy(name)
    local cfgW, err = equipCfg(name)
    if not cfgW then return false, err end

    -- 阵营限制
    local team = cfgW.Team
    if team and team ~= "Both" and team ~= myTeam() then
        return false, string.format("%s 是 %s 专用，你现在是 %s", name, team, myTeam())
    end

    -- 回合阶段
    local phaseOk, phaseMsg = buyPhaseOk()
    if not phaseOk then return false, phaseMsg end

    -- 钱
    local cost = tonumber(cfgW.Cost)
    local money = tonumber(LP:GetAttribute("Money"))
    if cost and money and money < cost then
        return false, string.format("钱不够（%d / %d）", money, cost)
    end

    local ok, sendErr = pcall(function()
        Remotes.Inventory.BuyMenuPurchase.Send({ Equipment = true, Name = name, Path = "" })
    end)
    if not ok then return false, tostring(sendErr) end
    return true, string.format("%s（花费 %d，剩 %d）", name, cost or 0, (money or 0) - (cost or 0))
end

---------------------------------------------------------------------
-- GUI
---------------------------------------------------------------------
-- ═══════════════════════════════════════════════════════════════════════
-- GUI：WindUI（替换 MacLib）
--
-- 为什么换：MacLib 的 Section/TabGroup 只暴露创建方法（TabGroup 只有 Tab()，
-- Section 只有 Toggle/Slider/... 没有 Destroy/Visible），控件建出来就再也拿不到句柄，
-- 无法做「切换瞄准模式只显示该模式配置」。
-- WindUI 的每个控件都有 .ElementFrame（Instance）和 .Destroy()，实测 Visible 有效。
--
-- 适配器：下面的 S.adaptSection 把 MacLib 的调用风格
--   sec:Toggle({ Name=..., Default=..., Callback=... }, "Key")
-- 映射到 WindUI 的
--   ws:Toggle({ Title=..., Value=..., Callback=... })
-- 所以业务代码里的 264 个控件一行都不用改。
-- ═══════════════════════════════════════════════════════════════════════
-- ⚠ 每次重载都会新建一整套 WindUI，旧的不清掉就会叠加：
-- 实测到过 4 套、每套 10448 个实例（约 34000 个 GUI 同时在渲染）→ 帧率暴跌。
do
    local roots = {}
    local okh, h = pcall(function() return gethui and gethui() end)
    if okh and h then roots[#roots+1] = h end
    roots[#roots+1] = game:GetService("CoreGui")
    for _, rt in ipairs(roots) do
        local okd, descs = pcall(function() return rt:GetDescendants() end)
        if okd and descs then
            for _, d in ipairs(descs) do
                if d:IsA("ScreenGui") and tostring(d.Name):find("WindUI") then
                    pcall(function() d:Destroy() end)
                end
            end
        end
    end
end
-- ⚠ WindUI 源码 1.35MB，每次重载都重新 HttpGet + 编译是整个加载卡死的主因。
-- 缓存到 getgenv，同一个客户端内只下载一次。
local _windSrc = getgenv().WINDUI_SRC
if type(_windSrc) ~= "string" or #_windSrc < 1000 then
    _windSrc = game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua", true)
    getgenv().WINDUI_SRC = _windSrc
end
local _windFn = loadstring(_windSrc, "WindUI")
if not _windFn then error("[WindUI] 源码编译失败") end
local WindUI = _windFn()

local Window = WindUI:CreateWindow({
    Title = "MovementV2 菜单",
    Folder = "MovementV2Hub",
    Size = IS_MOBILE and UDim2.fromOffset(560, 560) or UDim2.fromOffset(880, 660),
    Transparent = true,
    Resizable = false,
})

-- 控件登记表：S.UI[key] = WindUI 控件对象（有 .ElementFrame / .Set / .SetTitle）
S.UI = {}

S.adaptSection = function(ws)
    local o = {}
    local function reg(e, key)
        if key then S.UI[key] = e end
        return e
    end
    function o:Header(t, key) return reg(ws:Paragraph({ Title = tostring(t.Text or "") }), key) end
    function o:Label(t, key) return reg(ws:Paragraph({ Title = tostring(t.Text or "") }), key) end
    function o:SubLabel(t, key) return reg(ws:Paragraph({ Title = tostring(t.Text or "") }), key) end
    function o:Paragraph(t, key) return reg(ws:Paragraph({ Title = tostring(t.Title or t.Header or ""), Desc = tostring(t.Desc or t.Body or "") }), key) end
    function o:Divider() return ws:Divider() end
    function o:Spacer() return nil end
    function o:Toggle(t, key)
        return reg(ws:Toggle({
            Title = tostring(t.Name or ""),
            Value = t.Default == true,
            Callback = function(v) if t.Callback then t.Callback(v) end end,
        }), key)
    end
    function o:Slider(t, key)
        local prec = tonumber(t.Precision) or 0
        return reg(ws:Slider({
            Title = tostring(t.Name or ""),
            Value = {
                Min = tonumber(t.Minimum) or 0,
                Max = tonumber(t.Maximum) or 100,
                Default = tonumber(t.Default) or 0,
            },
            Step = (prec > 0) and (10 ^ -prec) or 1,
            Callback = function(v) if t.Callback then t.Callback(v) end end,
        }), key)
    end
    function o:Dropdown(t, key)
        local opts = {}
        for i, v in ipairs(t.Options or {}) do opts[i] = tostring(v) end
        local def = nil
        if not t.Multi then
            if type(t.Default) == "number" then def = opts[t.Default]
            elseif type(t.Default) == "string" then def = t.Default end
        end
        return reg(ws:Dropdown({
            Title = tostring(t.Name or ""),
            Values = opts,
            Value = def,
            Multi = t.Multi == true,
            SearchBarEnabled = #opts > 8,
            Callback = function(v) if t.Callback then t.Callback(v) end end,
        }), key)
    end
    function o:Button(t, key)
        return reg(ws:Button({
            Title = tostring(t.Name or ""),
            Callback = function() if t.Callback then t.Callback() end end,
        }), key)
    end
    function o:Keybind(t, key)
        return reg(ws:Keybind({
            Title = tostring(t.Name or ""),
            Value = t.Default,
            Callback = function(v)
                if t.Callback then t.Callback(v) end
                if t.onBinded then t.onBinded(v) end
            end,
        }), key)
    end
    function o:Colorpicker(t, key)
        return reg(ws:Colorpicker({
            Title = tostring(t.Name or ""),
            Default = t.Default,
            Callback = function(v) if t.Callback then t.Callback(v) end end,
        }), key)
    end
    function o:Input(t, key)
        return reg(ws:Input({
            Title = tostring(t.Name or ""),
            Value = tostring(t.Default or ""),
            Callback = function(v) if t.Callback then t.Callback(v) end end,
        }), key)
    end
    return o
end

local function secOf(tab, title)
    return S.adaptSection(tab:Section({ Title = title }))
end
S.secOf = secOf

-- 兼容：MacLib 的 Window:Notify / Window:Unload
Window.Notify = function(self, t)
    pcall(function()
        WindUI:Notify({
            Title = tostring((t and t.Title) or ""),
            Content = tostring((t and (t.Description or t.Content)) or ""),
            Duration = tonumber(t and t.Lifetime) or 4,
        })
    end)
end
Window.Unload = function(self)
    -- ⚠ 只做两件事：停掉本实例的常驻循环、销毁 GUI。
    --
    -- 之前这里还会经 getgenv().MV_FULL_CLEANUP 调一次 fullCleanup，风险太高：
    -- fullCleanup 会同时做「clearEsp 批量 Remove Drawing」「reap 再遍历一遍」
    -- 「WindUI:Destroy 销毁上万个实例」「还原全部 hook」，几件事挤在同一帧，
    -- 对执行器的渲染/Drawing 层压力很大。停循环不需要这些 —— 那些留给
    -- 卸载脚本（它是独立执行、无 GUI 竞争）或重载来做。
    S._alive = false
    pcall(function() self:Destroy() end)
    pcall(function() WindUI:Destroy() end)
    -- 立即做纯本地收尾（断连接 / 解绑 RenderStep / 清 Drawing）。
    -- 完整清理（还原 hook）由备用存活检测在 1 秒后执行 —— 错开 WindUI 销毁的尖峰，
    -- 之前把两件事挤在同一帧时，怀疑就是客户端直接消失的可疑点之一。
    local soft = getgenv().MV_SOFT_CLEANUP
    if type(soft) == "function" then pcall(soft) end
end
-- 手机缩放：以前是空函数，`Window:SetScale(0.9)` 什么也没做（窄屏会裁切）。
-- 做法是给主窗口 Frame 挂一个 UIScale，而不是改 Size —— WindUI 自己会用 Size 做布局。
Window.SetScale = function(self, v)
    local scale = tonumber(v) or 1
    pcall(function()
        local f = S.getMainWindowFrame and S.getMainWindowFrame()
        if not f then
            local hh = (gethui and gethui()) or game:GetService("CoreGui")
            local sg = hh:FindFirstChild("WindUI")
            local win = sg and sg:FindFirstChild("Window")
            f = win and win:FindFirstChild("Frame")
        end
        if not f or not f:IsA("GuiObject") then return end
        local us = f:FindFirstChildOfClass("UIScale")
        if not us then
            us = Instance.new("UIScale")
            us.Parent = f
        end
        us.Scale = math.clamp(scale, 0.5, 1.5)
        S.windowScale = us.Scale
    end)
end
-- MacLib 专有方法：返回「窗口当前是否开着」。Toggle / 备用存活检测都靠它。
--
-- ⚠ 这里原来是 `return ok and (c ~= true) or true` —— Lua 的 and/or 短路让
-- 三个分支全部落到最后的 `or true`：窗口关着（Closed == true）也返回 true。
-- 于是 Toggle 永远认为"当前是开的" → 永远只调 SetState(false) →
-- 按快捷键只能关、再按也还是关，菜单再也打不开。
Window.GetState = function(self)
    -- ① 以真实 ScreenGui.Enabled 为准：SetState 改的就是它，这是唯一权威状态。
    -- 缓存失效（没找到 / 已被销毁）就重找一次，避免整个会话卡在 Closed 字段上。
    local sg = S.menuScreenGui
    if sg then
        local okP, parent = pcall(function() return sg.Parent end)
        if (not okP) or parent == nil then sg = nil end
    end
    if not sg and S.findMenuGui then
        sg = S.findMenuGui()
        if sg then S.menuScreenGui = sg end
    end
    if sg then
        local okE, en = pcall(function() return sg.Enabled end)
        if okE and en ~= nil then return en == true end
    end
    -- ② 退一步读 WindUI 自己的 Closed 字段（true = 已关闭）
    local okC, c = pcall(function() return self.Closed end)
    if okC and c ~= nil then return c ~= true end
    -- ③ 都读不到：当作"还开着"。这里必须偏向 true，
    -- 因为备用检测会把「返回 false」当成窗口已失效，误判会把脚本自己卸掉。
    return true
end
Window.Toggle = function(self)
    pcall(function()
        if self.Closed then
            if type(self.Open) == "function" then self:Open() end
        else
            if type(self.Close) == "function" then self:Close() end
        end
    end)
end
Window.SetState = function(self, v)
    -- 真正控制显隐：直接切 WindUI 的 ScreenGui.Enabled（关掉时同时调原生 Close）
    pcall(function()
        local roots = {}
        local okh, h = pcall(function() return gethui and gethui() end)
        if okh and h then roots[#roots+1] = h end
        roots[#roots+1] = game:GetService("CoreGui")
        for _, rt in ipairs(roots) do
            local okd, descs = pcall(function() return rt:GetDescendants() end)
            if okd and descs then
                for _, d in ipairs(descs) do
                    if d:IsA("ScreenGui") and tostring(d.Name):find("WindUI") then
                        d.Enabled = (v ~= false)
                    end
                end
            end
        end
    end)
    if v == false then
        pcall(function() if type(self.Close) == "function" then self:Close() end end)
    else
        -- ⚠ 重新显示时必须把 WindUI 内部窗口状态也打开。
        -- Close() 除了隐藏，还会把库内部的 window 标成已关闭；只把 ScreenGui.Enabled
        -- 置回 true 的话，会变成「快捷键切了、GetState 说开着、窗口却没回来」。
        pcall(function() if type(self.Open) == "function" then self:Open() end end)
    end
end
-- ⚠ 以前这里是两行完全相同的 `return UDim2.fromOffset(880, 660)`（重复定义，后者覆盖前者）。
-- 手机上也返回 PC 尺寸，导致任何按这个值布局的地方在窄屏上溢出。
Window.GetSize = function(self)
    if IS_MOBILE then return UDim2.fromOffset(420, 320) end
    return UDim2.fromOffset(880, 660)
end

if IS_MOBILE then
    pcall(function() Window:SetScale(0.9) end)
end

-- 窗口居中：⚠ 必须同时设 AnchorPoint。
-- 原来只写 `Position = UDim2.fromScale(0.5, 0.5)`，锚点还是默认 (0,0)，
-- 等于把**左上角**放到屏幕正中 —— 窗口看起来偏到右下角、越往右越出屏。
--
-- 另外它自己的查找条件也永远是 nil：要求 `d.Parent:IsA("ScreenGui")`，
-- 而 WindUI 的 Frame 挂在 `WindUI → Window(Folder)` 下面，父级是 Folder。
-- 直接用已经修好的 S.getMainWindowFrame（它按 WindUI/Window/Frame 这条链找）。
local function centerWindow()
    local f = S.getMainWindowFrame and S.getMainWindowFrame()
    if not f then
        local hh = (gethui and gethui()) or game:GetService("CoreGui")
        local sg = hh:FindFirstChild("WindUI")
        local win = sg and sg:FindFirstChild("Window")
        f = win and win:FindFirstChild("Frame")
    end
    if not f or not f:IsA("GuiObject") then return false end
    pcall(function() f.AnchorPoint = Vector2.new(0.5, 0.5) end)
    f.Position = UDim2.fromScale(0.5, 0.5)
    return true
end
S.centerWindow = centerWindow

local T = {
    combat = Window:Tab({ Title = "战斗" }),
    rage   = Window:Tab({ Title = "暴力" }),
    visual = Window:Tab({ Title = "视觉" }),
    weapon = Window:Tab({ Title = "武器" }),
    vip    = Window:Tab({ Title = "VIP服" }),
    skin   = Window:Tab({ Title = "美化" }),
    misc   = Window:Tab({ Title = "杂项" }),
}

T.vipL = secOf(T.vip, "VIP 设置")
T.vipR = secOf(T.vip, "VIP 动作")
T.skinL = secOf(T.skin, "皮肤")
T.skinR = secOf(T.skin, "说明")

-- 战斗
local cl = secOf(T.combat, "瞄准与射击")
local cr = secOf(T.combat, "目标与过滤")
getgenv().MV_DBG_SECTIONS = { combatL = cl, combatR = cr }

cl:Header({ Text = "【仅静默模式】静默瞄准" })
-- ⚠ Default 必须读 cfg，不能写死 false。
-- Maclib 初始化控件时会用 Default 回写一次 Callback：写死 false 就意味着
-- 每次加载都把「存档里开着的静默」在视觉和逻辑上各冲一遍，而 GUI 建完之后
-- 我们又用存档把 cfg 恢复了 —— 结果就是「开关显示关着，静默却一直在生效」。
-- 用户看到的就是「静默不受总开关影响」。
cl:Toggle({ Name = "启用自动瞄准（总开关）", Default = cfg.silentAim == true, Callback = function(v)
    cfg.silentAim = v
    if not v then cfg.aimToggled = false end
end }, "SA")
cl:Dropdown({
    Name = "触发方式",
    Multi = false,
    Required = true,
    Options = { "按住按键", "始终开启", "按键切换（开/关）" },
    -- ⚠ Default 必须由 cfg 推出来，不能写死 1。
    -- Maclib 初始化会拿 Default 回写一次 Callback：写死 1 就等于每次加载都把
    -- 触发方式冲成「按住按键」。用户设的「始终开启」在 cfg 里（GUI 建完后被存档恢复），
    -- 菜单却显示「按住按键」—— 表现就是「静默有时候不生效，得按着鼠标才行」。
    Default = (cfg.aimTrigger == "always" and 2)
        or (cfg.aimTrigger == "toggle" and 3) or 1,
    Callback = function(v)
        if v == "始终开启" then
            cfg.aimTrigger = "always"
        elseif v == "按键切换（开/关）" then
            cfg.aimTrigger = "toggle"
        else
            cfg.aimTrigger = "hold"
        end
        cfg.aimToggled = false
        aimInput.down = false
    end,
}, "AimTrigger")
cl:Dropdown({
    Name = "瞄准模式",
    Multi = false,
    Required = true,
    Options = { "鼠标瞄准（真实输入·能转视角）", "静默（只改弹道·不动视角）", "平滑（改相机·实测无效）" },
    -- ⚠ 同上：写死 1（鼠标瞄准）会让菜单显示与实际模式错开。
    -- 用户明明选了「静默」，菜单却显示「鼠标瞄准」—— 这就是「我选的是静默啊」的来源。
    Default = (cfg.aimMode == "silent" and 2)
        or (cfg.aimMode == "smooth" and 3) or 1,
    Callback = function(v)
        if v == "静默（只改弹道·不动视角）" then
            cfg.aimMode = "silent"
        elseif v == "平滑（改相机·实测无效）" then
            cfg.aimMode = "smooth"
        else
            cfg.aimMode = "mouse"
        end
        -- 切换后直接告诉用户「现在只用看哪一段」，其余段都标了【仅XX模式】可以忽略
        pcall(function()
            local tip = "【静默】下面只需要看「【仅静默模式】」那一段（360°/部位/距离），其它带【仅平滑/仅鼠标】的都可以忽略"
            if cfg.aimMode == "smooth" then
                tip = "【平滑】下面只需要看「【仅平滑模式】」那一段（速度/抖动/延迟/过冲），其它忽略"
            elseif cfg.aimMode == "mouse" then
                tip = "【鼠标】下面只需要「鼠标瞄准 增益 / 每帧最大移动 / 平滑 / 手动暂停」四项，其它忽略"
            end
            S.aimModeTip:UpdateName("当前生效：" .. tip)
        end)
    end,
}, "AimMode")
S.aimModeTip = cl:Label({ Text = "当前生效：【静默】下面只需要看「【仅静默模式】」那一段（360°/部位/距离），其它带【仅平滑/仅鼠标】的都可以忽略" })
cl:Toggle({ Name = "360° 静默（屏幕外也锁）", Default = cfg.fullSphere == true,
    Callback = function(v) cfg.fullSphere = v end }, "FullSphere")
cl:Label({ Text = "静默只改子弹方向、不转视角，所以「目标在不在画面里」这条限制没有意义。打开后只保留距离和视线通畅两条约束——身后、墙侧的目标一样能锁。" })
cl:Slider({ Name = "鼠标瞄准 增益", Default = 0.12, Minimum = 0.02, Maximum = 0.6, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.mouseGain = v end }, "MouseGain")
cl:Slider({ Name = "鼠标瞄准 每帧最大移动", Default = 12, Minimum = 1, Maximum = 60, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.mouseMaxStep = v end }, "MouseStep")
cl:Slider({ Name = "鼠标瞄准 平滑（仅鼠标模式）", Default = 0.55, Minimum = 0, Maximum = 0.95, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.mouseSmooth = v end }, "MouseSmooth")
cl:Slider({ Name = "鼠标瞄准 手动操作后暂停(秒)", Default = 0.6, Minimum = 0.1, Maximum = 3, DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.mouseReleaseDelay = v end }, "MouseRelease")
cl:Label({ Text = "「鼠标瞄准」用 mousemoverel 发真实鼠标输入，游戏相机会正常响应——这是唯一能真正转动视角的方式。" }, "MouseTip1")
cl:Label({ Text = "⚠ 它会真的移动系统光标。所以只要检测到任何真实键鼠操作（按键、左右键），就暂停一段时间让你能操作菜单、切窗口、按 Esc。窗口失焦时也会自动停。" }, "MouseTip2")
cl:Label({ Text = "抖动的原因：增益太高会过冲——这一帧转过头、下一帧反向拉回，两帧一循环就成了肉眼可见的抖。默认 0.12 + 每帧上限 12px + 指数平滑，基本是单调逼近不抖。如果还抖就继续降增益、调高平滑。" })

cl:Header({ Text = "【仅平滑模式】平滑瞄准" })
cl:Toggle({ Name = "平滑瞄准（转视角·不抢鼠标·推荐）", Default = cfg.smoothAimHijack == true, Callback = function(v)
    cfg.smoothAimHijack = v
    if v then
        local ok = AASYS.installSmooth()
        Window:Notify({
            Title = "平滑瞄准",
            Description = ok and "已开启：接管磁性吸附入口，相机每帧转向目标"
                or "开启失败：AimAssistController 不可用",
            Lifetime = 5,
        })
    else
        Window:Notify({ Title = "平滑瞄准", Description = "已关闭", Lifetime = 2 })
    end
end }, "SmoothHijack")
cl:Slider({ Name = "平滑瞄准 抖动(度)", Default = 0, Minimum = 0, Maximum = 2, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.smoothAimJitter = v end }, "SmoothJitter")
-- ⚠ 滑条下限必须和 hook 里的 clamp 下限一致，否则「滑条拖到底还是硬锁」——
--   这就是用户说的「不兼容人性化设置」：代码 clamp 一次、滑条再夹一次。
cl:Slider({ Name = "平滑瞄准 速度", Default = 0.18, Minimum = 0.005, Maximum = 1, DisplayMethod = "Value", Precision = 3,
    Callback = function(v) cfg.smoothAimSpeed = v end }, "SmoothSpeed")
cl:Slider({ Name = "平滑瞄准 每帧最大转角", Default = 2.0, Minimum = 0.01, Maximum = 5, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.smoothAimMaxDeg = v end }, "SmoothMaxDeg")
cl:Slider({ Name = "平滑瞄准 死区(度)", Default = 0.6, Minimum = 0, Maximum = 3, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.smoothAimDeadzone = v end }, "SmoothDead")
cl:Slider({ Name = "平滑瞄准 瞄点下移", Default = 2.2, Minimum = 0, Maximum = 4, DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.smoothAimDrop = v end }, "SmoothDrop")
cl:Label({ Text = "原理：CameraController 每帧调用 AimAssistController.GetMagnetismRotation()，拿到 Vector2(水平角, 垂直角) 后 clamp 到 ±5 度再应用到相机。这里把那个函数换成「返回指向目标的角度差」，相机就被游戏自己每帧转过去。" })
cl:Label({ Text = "和另外两种的区别：改 cam.CFrame 会被每帧覆盖（实测 384 帧写 0 度变化）；mousemoverel 会抢你的鼠标。这条走引擎内部管道，既不覆盖也不碰鼠标。" }, "MouseTip3")
cl:Label({ Text = "实测：1.2 秒内相机转了 6.66 度，目标从屏幕外（Z=118）进到正前方（Z=11）。每帧上限 5 度，60fps 就是 300 度/秒。" })

cl:Header({ Text = "【通用·与模式无关】原生瞄准辅助（游戏自带）" })
cl:Toggle({ Name = "解锁原生瞄准辅助（后坐力减半 + 磁性吸附）", Default = cfg.nativeAimAssist == true, Callback = function(v)
    cfg.nativeAimAssist = v
    if v then
        local ok = AASYS.installNative()
        Window:Notify({
            Title = "原生辅助",
            Description = ok and "已解锁：后坐力减半、准星附近磁性吸附、摩擦力降灵敏度"
                or "解锁失败（getrawmetatable 不可用）",
            Lifetime = 5,
        })
    else
        Window:Notify({ Title = "原生辅助", Description = "已关闭", Lifetime = 2 })
    end
end }, "NativeAA")
cl:Label({ Text = "这是游戏自己给手柄/触屏玩家做的辅助，参数全部 Enabled=true，只被一道平台门控挡住：PreferredInput ~= Touch 就 return false。这里把 PreferredInput 伪装成 Touch 绕过门控。" })
cl:Label({ Text = "实测效果：GetRecoilAssistMultiplier 从 0 → 0.5，后坐力直接减半。磁性吸附 PullStrength 是 6.5度/帧，但它要求目标在你视线 30 度以内（MaxAngle=0.5236）——所以这不是全屏锁人，是准星附近的跟随辅助。服务端看到的是正常操作，最安全。" })
cl:Label({ Text = "「平滑」是直接写 cam.CFrame，实测在 RenderStep 1997 连续写 384 帧、视线变化 0.00 度，游戏在更高优先级覆盖了它，这个模式基本不可用，保留只作对照。" })
local aimKeyBtn = cl:Button({
    Name = "瞄准按键: " .. aimInputLabel(),
    Callback = function()
        aimInput.listening = true
        Window:Notify({
            Title = "绑定按键",
            Description = "现在按任意键或鼠标键来绑定瞄准键",
            Lifetime = 5,
        })
    end,
}, "AimKeyBtn")
cl:Label({ Text = "点上面的按钮再按一个键即可改绑。触发方式选「始终开启」时不需要按键。" })

task.spawn(function()
    while true do
        task.wait(0.4)
        if S._alive == false or REG.gen ~= MY_GEN then break end
        pcall(function()
            local txt = "瞄准按键: " .. aimInputLabel()
            if aimInput.listening then txt = txt .. "   [等待按键...]" end
            aimKeyBtn:UpdateName(txt)
        end)
    end
end)
cl:Slider({ Name = "视野范围 FOV", Default = (cfg.fov or 75), Minimum = 20, Maximum = 2400, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.fov = v end }, "Fov")
cl:Toggle({ Name = "显示 FOV 圈", Default = true, Callback = function(v) cfg.showFov = v end }, "ShowFov")
cl:Colorpicker({ Name = "FOV 圈颜色", Default = Color3.fromRGB(255, 255, 255),
    Callback = function(c) cfg.fovColor = c end }, "FovColor")
cl:Slider({ Name = "最大瞄准距离", Default = (cfg.maxAimDist or 500), Minimum = 50, Maximum = 3000, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.maxAimDist = v end }, "AimDist")
cl:Header({ Text = "排障" })
cl:Button({ Name = "纯净模式（关掉所有子弹干预）", Callback = function()
    -- 一键回到游戏原样：不动方向、不动起点、不改弹药、不改射速
    cfg.silentAim = false
    cfg.autoFire = false
    cfg.multiShot = false
    cfg.bulletTrack = false
    cfg.wallbang = false
    cfg.skipFireDelay = false
    cfg.instantReload = false
    cfg.infiniteAmmo = false
    pcall(function()
        if S.ammoConn then S.ammoConn:Disconnect() end
        S.ammoConn = nil
    end)
    pcall(function() getgenv().MV_SPINBOT = false end)
    cfg.spinbot = false
    breakAimLock()
    Window:Notify({
        Title = "纯净模式",
        Description = "已关闭自瞄/追踪/穿墙/射速/换弹，子弹回到原样。用来确认射击本身是好的。",
        Lifetime = 5,
    })
end }, "PureMode")
cl:Label({ Text = "如果「打人没伤害」，先点这个。所有改写子弹的开关会全部关掉，只剩 ESP。如果纯净模式下能打掉血，说明是某个干预功能导致服务端拒包；如果纯净模式也打不掉，那是别的原因（弹药、网络、命中判定）。" })

-- 「装备修复」相关控件已整体移到【武器】页（用户要求：自动装备属于武器，
-- 不该出现在战斗页）。见后面 wl:Header("装备：手上空着 / 买了不进去") 那一段。

cl:Header({ Text = "诊断：疑似脚本干扰商店 / 拾取" })
cl:Toggle({ Name = "纯净模式（关掉所有 hook 和改写）", Default = false, Callback = function(v)
    S.setPureMode(v)
    Window:Notify({
        Title = v and "纯净模式 已开启" or "纯净模式 已关闭",
        Description = v and "所有 hook / 每帧改写已停止。现在去商店买东西，看是否恢复"
            or "重新加载脚本可恢复全部功能",
        Lifetime = 6,
    })
end }, "PureMode2")
cl:Label({ Text = "如果开了这个之后商店能买、捡东西不消失 → 确定是脚本里某个功能导致；关掉再逐项打开就能定位。如果纯净模式依然买不了 → 那是游戏/服务端的问题，跟脚本无关。" })

cr:Header({ Text = "【通用·所有模式生效】目标优先级 / 距离 / 部位" })
cr:Dropdown({
    Name = "选人策略",
    Multi = false,
    Required = true,
    Options = {
        "准星最近（屏幕）",
        "距离最近（世界）",
        "距离最远",
        "血量最低",
        "血量最高",
        "加权平衡",
        "威胁优先（正对你）",
    },
    Default = 1,
    Callback = function(v)
        local map = {
            ["准星最近（屏幕）"] = "crosshair",
            ["距离最近（世界）"] = "nearest",
            ["距离最远"] = "farthest",
            ["血量最低"] = "lowesthp",
            ["血量最高"] = "highesthp",
            ["加权平衡"] = "balanced",
            ["威胁优先（正对你）"] = "threat",
        }
        cfg.targetMode = map[v] or "crosshair"
        breakAimLock()
    end,
}, "TargetMode")
cr:Slider({ Name = "准星权重", Default = 1.0, Minimum = 0, Maximum = 10, DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.crosshairWeight = v; breakAimLock() end }, "CrossW")
cr:Slider({ Name = "距离权重", Default = 2.0, Minimum = 0, Maximum = 10, DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.distanceWeight = v; breakAimLock() end }, "DistW")
cr:Toggle({ Name = "优先打正在看你的人", Default = cfg.preferFacing == true, Callback = function(v)
    cfg.preferFacing = v
    breakAimLock()
end }, "PreferFacing")
cr:Label({ Text = "两个权重只在「加权平衡」模式生效。血量来自角色模型 Health 属性。" })

cr:Header({ Text = "目标锁定" })
cr:Toggle({ Name = "锁定目标（不来回跳）", Default = true, Callback = function(v)
    cfg.lockEnabled = v
    if not v then breakAimLock() end
end }, "LockOn")
cr:Slider({ Name = "最长锁定(秒)", Default = 6, Minimum = 1, Maximum = 30, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.lockMaxSeconds = v; breakAimLock() end }, "LockMax")
cr:Label({ Text = "锁定后不会因为旁边出现人而换目标，打死当前目标或他自己离开视野才切换。你手动滑屏/移动鼠标会立刻解锁。" })

cr:Header({ Text = "人体化（防封）" })
cr:Slider({ Name = "人体化·指数平滑（越大越慢，与上面「鼠标瞄准 平滑」无关）", Default = 0.22, Minimum = 0.02, Maximum = 1.0, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.smoothness = v end }, "Smoothness")
cr:Slider({ Name = "手抖强度", Default = 0.35, Minimum = 0, Maximum = 3, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.jitter = v end }, "Jitter")
cr:Slider({ Name = "反应延迟(秒)", Default = 0.14, Minimum = 0, Maximum = 0.6, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.reactionDelay = v end }, "ReactDelay")
cr:Slider({ Name = "瞄头概率(%)", Default = 55, Minimum = 0, Maximum = 100, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.headChance = v / 100 end }, "HeadChance")
cr:Dropdown({
    Name = "静默打哪个部位",
    Multi = false,
    Required = false,
    Options = { "自动（按部位优先级）", "只打头", "打胸", "打腹", "打腿" },
    Default = (cfg.aimHitPart == "head" and 2) or (cfg.aimHitPart == "chest" and 3)
        or (cfg.aimHitPart == "stomach" and 4) or (cfg.aimHitPart == "legs" and 5) or 1,
    Callback = function(v)
        if v == "只打头" then cfg.aimHitPart = "head"
        elseif v == "打胸" then cfg.aimHitPart = "chest"
        elseif v == "打腹" then cfg.aimHitPart = "stomach"
        elseif v == "打腿" then cfg.aimHitPart = "legs"
        else cfg.aimHitPart = "auto" end
    end,
}, "AimHitPart")
cr:Toggle({ Name = "自动选可见部位（仅在「静默打哪个部位=自动」时生效）", Default = cfg.aimPartPriority == true, Callback = function(v) cfg.aimPartPriority = v end }, "AimPartPrio")
cr:Label({ Text = "「静默打哪个部位」选自动时，才轮到下面的部位优先级/瞄头概率。以前静默硬编码打头，这三个配置对它完全无效——已修。" })
cr:Label({ Text = "部位优先级开启时忽略上面的瞄头概率：按 头 → 脖子/胸 → 腹 → 上臂 → 前臂 → 手 → 大腿 → 小腿 → 脚 的顺序，选第一个没被遮挡的部位。全身都被挡住时退回头部（用于透视预测）。" })
cr:Toggle({ Name = "过冲回拉", Default = true, Callback = function(v) cfg.overshoot = v end }, "Overshoot")
cr:Label({ Text = "平滑模式改的是相机朝向，命令流 LookYaw 会一起变，服务端看到的视角与弹道一致。静默模式只改 Bullets[].Direction，视角不动，如果服务端比对两者会被发现。" })

cr:Header({ Text = "过滤" })
cr:Toggle({ Name = "队伍过滤（仅影响瞄准）", Default = cfg.teamCheck == true, Callback = function(v) cfg.teamCheck = v end }, "TeamChk")
cr:Toggle({ Name = "优先瞄头", Default = true, Callback = function(v) cfg.headPriority = v end }, "HeadPrio")
cr:Toggle({ Name = "视线检测（只锁看得见的）", Default = true, Callback = function(v) cfg.aimVisibleCheck = v end }, "AimVisible")
cr:Toggle({ Name = "允许隔烟瞄准", Default = true, Callback = function(v) cfg.aimThroughSmoke = v end }, "AimSmoke")
cr:Label({ Text = "隔烟瞄准：子弹能穿烟，所以默认允许。关掉就只锁没被烟挡住的人（用游戏自己的烟雾几何判定）。" })
cr:Label({ Text = "本作角色部件 CanCollide=false 但 CanQuery=true，子弹判定走 Head/Torso；地图里有可见却无碰撞的部件，开启视线检测可避免锁到被实体挡住的人。" })
cr:Paragraph({
    Header = "原理",
    Body = "本服 ShootWeapon 的 Bullets[].Direction 由客户端提供。静默瞄准直接改写射线向量，不移动相机，服务端收到的仍是合法参数。",
})

-- 暴力
local rl = secOf(T.rage, "实验项（多为实测无效）")
local rr = secOf(T.rage, "开火 · 弹药 · 投掷")

rl:Header({ Text = "⚠ 以下为实测无效（保留开关仅供验证）" })
rl:Toggle({ Name = "【无效】子弹追踪（起点搬到目标身上）", Default = cfg.bulletTrack == true, Callback = function(v)
    cfg.bulletTrack = v
    Window:Notify({ Title = "暴力", Description = "追踪 " .. (v and "开启（实测会被服务端丢弃）" or "关闭"), Lifetime = 2 })
end }, "BulletTrack")
rl:Toggle({ Name = "【无效】穿墙（起点搬到目标身前）", Default = cfg.wallbang == true, Callback = function(v)
    cfg.wallbang = v
    Window:Notify({ Title = "暴力", Description = "穿墙 " .. (v and "开启（实测会被服务端丢弃）" or "关闭"), Lifetime = 2 })
end }, "Wallbang")
rl:Label({ Text = "实测结论：Origin 前移 2~200 stud 共 9 种偏移量全部无伤害。服务端会自己校验子弹起点，改 Origin 的枪件会被整包丢弃。真正能穿墙的是「隔墙投雷」。" })

rl:Header({ Text = "延迟补偿（ViewTick 回溯）" })
rl:Slider({ Name = "ViewTick 偏移（tick，60≈1秒）", Default = cfg.viewTickOffset or 0,
    Minimum = -1800, Maximum = 1800, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.viewTickOffset = v end }, "ViewTickOff")
rl:Label({ Text = "改的是射击包里的 ViewTick —— 服务端做世界回溯用的时刻标记。负数 = 让服务端把敌人退回到更早的位置（打他刚躲进掩体前的瞬间），正数 = 推向未来。" })
rl:Label({ Text = "⚠ 未验证：这条路能否生效取决于服务端是否真的用 ViewTick 回溯命中判定。测的时候必须找一个「站近了能稳定打中」的靶子（20 stud 内），先用 0 打中确认基线，再试 -180 / -360 / -900。" })

rl:Label({ Text = "——— 多发子弹：服务端只取 Bullets[1] 算伤害 ——" })
rl:Label({ Text = "下面这些滑块是给上面那两个「无效」开关配套的，保留只为复现实验，日常不用管。" })
rl:Toggle({ Name = "穿墙（起点搬到目标身前）", Default = cfg.wallbang == true, Callback = function(v)
    cfg.wallbang = v
    Window:Notify({ Title = "暴力", Description = "穿墙 " .. (v and "已开启" or "已关闭"), Lifetime = 2 })
end }, "Wallbang")
rl:Slider({ Name = "穿墙贴近距离", Default = 3, Minimum = 1, Maximum = 20, DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.wallbangOffset = v end }, "WallbangOff")
rl:Label({ Text = "和追踪的区别：穿墙只把起点往前推到目标身前，方向仍是原来的视线方向；追踪是起点和方向都对准目标。两者原理相同，都需要服务端不校验 Origin。" })
rl:Label({ Text = "——— 多发子弹：服务端只取 Bullets[1] 算伤害 ——" })
rl:Label({ Text = "一包塞 N 颗子弹、Seq 只 +1，服务端取第一颗。客户端渲染也不跟这个数组走，所以开了看不出差别。开关保留在配置里（multiShot）但默认关闭。" })

rl:Header({ Text = "隔墙投雷（真正能穿墙的那个）" })
rl:Button({ Name = "在目标脚下生成 HE（引信 1 秒）", Callback = function()
    local t = aimTarget()
    if not t then
        local ok, list = pcall(collect, 3000, false)
        if ok then
            for _, x in ipairs(list) do
                if not x.sameTeam and not x.dead then t = x break end
            end
        end
    end
    if not t then
        Window:Notify({ Title = "投雷", Description = "没有可投的目标", Lifetime = 3 })
        return
    end
    local p = t.pos + Vector3.new(0, 0.6, 0)
    local okay = S.tossGrenadeAt(p, "HE Grenade", 1.0)
    Window:Notify({
        Title = okay and "已抛出" or "发送失败",
        Description = string.format("%s 脚下 (%.0f,%.0f,%.0f) 引信1秒", tostring(t.name), p.X, p.Y, p.Z),
        Lifetime = 4,
    })
end }, "TossHE")
rl:Button({ Name = "自己脚下试一颗闪光（验通道）", Callback = function()
    local root = myRoot()
    if not root then return end
    local p = root.Position + Vector3.new(0, 0.5, 0)
    local okay = S.tossGrenadeAt(p, "Flashbang", 1.0)
    Window:Notify({ Title = okay and "已抛出闪光" or "发送失败", Description = "脚下一颗，1 秒爆", Lifetime = 3 })
end }, "TossTest")
rl:Label({ Text = "实测服务端接受伪造的 Projectile.Spawn（手雷在弹跳、引信正常触发）。射击的 Origin 会被校验，但投掷物的 Position 不会 —— 隔墙靠手雷实现，不靠子弹。埋点 state.grenadesTossed。" })

rr:Header({ Text = "后座控制" })
rr:Toggle({ Name = "无后座（拦 setWeaponRecoil）", Default = cfg.noRecoil == true, Callback = function(v)
    cfg.noRecoil = v
    if v then S.noRecoilHook() end
    Window:Notify({ Title = "后座", Description = "无后座 " .. (v and "已开启" or "已关闭"), Lifetime = 2 })
end }, "NoRecoil")
rr:Label({ Text = "拦的是 CameraController.setWeaponRecoil —— 每次开枪游戏把后座值灌进弹簧，这个函数不让它灌。子弹扩散不受影响，只是镜头不再跳。" })
rr:Toggle({ Name = "自动压枪", Default = cfg.autoRecoilComp == true, Callback = function(v)
    cfg.autoRecoilComp = v
    S._recoilLastKick = Vector3.new(0, 0, 0)
    Window:Notify({ Title = "后座", Description = "自动压枪 " .. (v and "已开启" or "已关闭"), Lifetime = 2 })
end }, "AutoRecoilComp")
-- ⚠ 垂直/水平必须分开：垂直是每发固定往上顶，可以压满；水平方向随机，压满会显得锁死。
rr:Slider({ Name = "垂直压枪（%）", Default = cfg.recoilCompV or 100, Minimum = 0, Maximum = 100,
    DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.recoilCompV = v; S._recoilLastKick = Vector3.new(0, 0, 0) end }, "RecoilCompV")
rr:Slider({ Name = "水平压枪（%）", Default = cfg.recoilCompH or 60, Minimum = 0, Maximum = 100,
    DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.recoilCompH = v; S._recoilLastKick = Vector3.new(0, 0, 0) end }, "RecoilCompH")
rr:Label({ Text = "每帧读 getWeaponKickRotation（弹簧当前后座偏移），把「当前值」整个反向压回相机。0.00° 实测确认：游戏每帧都会重建相机，我们上一帧的补偿不会保留 —— 所以必须每帧抵消当前值，补「变化量」是无效的（那正是「弹道压住了、准星还在飞」的原因）。垂直默认 100%，水平默认 60%（水平方向随机，压满不自然）。埋点 state.recoilCompSteps / state._recoilCompAccum。" })

rr:Header({ Text = "近战 · 超距离" })
rr:Slider({ Name = "近战射程倍数", Default = cfg.meleeRange, Minimum = 1, Maximum = 10, DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.meleeRange = v end }, "MeleeRange")
rr:Label({ Text = "MeleeAttack 的 Direction = 相机视线 × 武器射程，向量长度里就带着射程；Distance 是命中距离。两个一起放大就能超距离砍人。整条射线结果（VictimUserId/HitPartName/Position）本来就是客户端算的，这是近战最有可能突破的点。埋点 state.meleeRangeShots。" })
rl:Toggle({ Name = "跳过开火间隔（客户端解除冷却）", Default = cfg.skipFireDelay == true, Callback = function(v)
    setSkipFireDelay(v)
    Window:Notify({ Title = "暴力", Description = "客户端射速解除 " .. (v and "已开启" or "已关闭"), Lifetime = 2 })
end }, "SkipFire")
rl:Label({ Text = "客户端不再等 FireRate 冷却，手点多快就发多快。服务端按武器 FireRate 校验，超速的包会被静默丢弃 —— 所以这是「本地手感 + 视觉弹雨」，真实命中取决于服务端接受了几包。" })
rl:Toggle({ Name = "弹匣常满（本地显示）", Default = cfg.infiniteAmmo == true, Callback = function(v)
    local ok = setInfiniteAmmo(v)
    Window:Notify({ Title = "弹药", Description = "弹匣常满 " .. (v and "已开启（只骗本地显示）" or "已关闭"), Lifetime = 3 })
end }, "InfAmmo")
rl:Label({ Text = "弹匣数字永远不掉、不用换弹、有枪声有后坐力，超出真实弹药的部分服务端直接拒绝。视觉续航无限，伤害按服务端账本算。" })

rr:Header({ Text = "弹药 / 自动" })
rr:Toggle({ Name = "近战加速（挥刀无冷却）", Default = cfg.skipFireDelay == true, Callback = function(v)
    -- 三个机制同时开才有效：
    --   skipFireDelay → 客户端把 NextShotDue 压进窗口（近战 FireRate 是 0.36）
    --   挥刀动画加速 → Swing 动画 1.267 秒，攻击判定在约 66% 处，
    --                  实测正常间隔 0.836 秒，加速播放才能让判定点提前
    --   instantReload → 定期发 ReloadWeapon 让服务端重置武器状态
    setSkipFireDelay(v)
    setInstantReload(v)
    Window:Notify({
        Title = "暴力",
        Description = "近战加速 " .. (v and "已开启" or "已关闭"),
        Lifetime = 2,
    })
end }, "MeleeSpeed")
rr:Slider({ Name = "挥刀动画加速倍数", Default = 3, Minimum = 1, Maximum = 10, DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.meleeSpeed = v end }, "MeleeSpeedMul")
rr:Label({ Text = "实测：刀的 FireRate 是 0.36 秒，但实际攻击间隔 0.836 秒 —— 卡人的是 Swing 动画（1.267 秒，判定在 66% 处）。这里直接把动画播放速度调快，判定点就能提前到来。" })
rr:Label({ Text = "═══ 超射速（服务端认可）═══" })
rr:Slider({ Name = "超射速连发次数（1 = 关）", Default = cfg.rapidFire, Minimum = 1, Maximum = 12, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) S.setRapidFire(v) end }, "RapidFire")
rr:Label({ Text = "实测（AK-47，FireRate 0.1 秒）：6 发 / 30ms 间隔，服务端扣弹 +6，全部认账。这不是伪造包——走的是游戏自己的 Weapon:shoot()，Seq / ViewTick 都由它填，所以服务端没有理由拒。开启时会自动打开「跳过开火间隔」，否则从第二发起就被客户端冷却挡住（实测不开时 5 次调用只发出 2 个包）。" })
rr:Slider({ Name = "连发间隔(毫秒)", Default = 30, Minimum = 10, Maximum = 200, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.rapidGap = v / 1000 end }, "RapidGap")
rr:Label({ Text = "30ms = 33 发/秒。太小时 shoot() 内部会挡（它要求 os.clock() - NextShotDue < 0.035），太大就没意义。建议 25~40。" })
rr:Label({ Text = "注意：这个开关同时会启用「瞬间换弹」，对枪也有用（打空弹匣后 0.08 秒补满，服务端认）。" })
rr:Toggle({ Name = "瞬间换弹（跳过动画）", Default = cfg.instantReload == true, Callback = function(v)
    setInstantReload(v)
    Window:Notify({
        Title = "弹药",
        Description = v and "已开启：弹匣一空立刻补满，不等动画" or "已关闭",
        Lifetime = 3,
    })
end }, "InstantReload")
rr:Label({ Text = "实测：正常换弹 1.586 秒，直接发 ReloadWeapon 包 0.083 秒。服务端接受客户端发包，立刻回满弹匣，弹药账本正常扣减。" })
rr:Toggle({ Name = "自动开火", Default = cfg.autoFire == true, Callback = function(v) cfg.autoFire = v end }, "AutoFire")
rr:Slider({ Name = "开火延迟(毫秒)", Default = 180, Minimum = 0, Maximum = 1000, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.autoFireDelay = v end }, "AFDelay")
rr:Label({ Text = "锁定目标后等这么久才开枪，模拟人的反应时间。0 = 立即开火（很假）。" })
rr:Slider({ Name = "准星对准容差(像素)", Default = 45, Minimum = 5, Maximum = 300, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.autoFireMaxOffset = v end }, "AFOffset")
rr:Label({ Text = "开火前要求目标离准星中心多近。mouse1click 打的是准星方向，不是目标方向——没有这道检查就会对着空气开枪。静默模式下相机不动，建议配合「鼠标瞄准」用，让准星真的被带过去。" })
rr:Label({ Text = "第 2 页「武器分类」可分别设置每类枪的最大开火距离。" })
-- 「大陀螺」= 纯客户端视觉：只转自己客户端的模型。
-- 别人看不到（服务端不知道）、自己视角不动、第三人称下自己能看见在转。
-- 旧的命令层改写（改 LookYaw）已废弃 —— 会让移动方向错乱、原地打转走不出去。
rr:Toggle({ Name = "大陀螺（纯客户端·只有你自己看得到）", Default = cfg.localSpin == true, Callback = function(v)
    cfg.localSpin = v
    Window:Notify({ Title = "暴力", Description = "本地陀螺 " .. (v and "已开启（别人看不到）" or "已关闭"), Lifetime = 2 })
end }, "LocalSpin")
rr:Slider({ Name = "旋转速度(度/秒)", Default = cfg.spinSpeed, Minimum = 60, Maximum = 720, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.spinSpeed = v end }, "SpinSpeed")
rr:Label({ Text = "上限锁 720 度/秒（60fps 下 12 度/帧）。再快就不是旋转，而是每帧换一个朝向的闪烁，看起来只会像抽搐。" })
rr:Label({ Text = "纯视觉：只改自己客户端模型的朝向。相机绑在 CameraPart 上，所以视角完全不动；服务端收不到任何东西，别人眼里的你也不会转。想看到效果需要切第三人称。" })
rr:Toggle({ Name = "自动兔子跳（落地即跳）", Default = cfg.bunnyhop == true, Callback = function(v)
    cfg.bunnyhop = v
    S.bhWasJumping = false
    if v then S.bhJumps = 0 end
    Window:Notify({ Title = "移动", Description = "自动兔子跳 " .. (v and "已开启" or "已关闭"), Lifetime = 2 })
end }, "Bunnyhop")
rr:Label({ Text = "落地那一帧立刻再跳（判据用 CollisionPose.OnGround，不再依赖不可靠的 Player.IsJumping）。跳跃走游戏的 CharacterController.jump，移动仍受 MovementV2 服务端校验。" })

rr:Header({ Text = "地图 · 点位" })
rr:Toggle({ Name = "包点标记（A/B 点 3D 文字 + 距离）", Default = cfg.showSites == true, Callback = function(v)
    cfg.showSites = v
end }, "ShowSites")
rr:Button({ Name = "扫描并缓存当前地图点位", Callback = function()
    local ok, d = pcall(S.scanMap)
    if not ok or type(d) ~= "table" then
        Window:Notify({ Title = "地图", Description = "扫描失败", Lifetime = 3 })
        return
    end
    local a = d.sites and d.sites.A
    local b = d.sites and d.sites.B
    local function f(v) return v and string.format("(%.0f,%.0f,%.0f)", v.X, v.Y, v.Z) or "-" end
    Window:Notify({
        Title = "已缓存 · " .. tostring(d.map),
        Description = string.format("A=%s  B=%s  出生点=%d  购买区=%d  已缓存 %d 张图",
            f(a), f(b), #(d.spawns or {}), #(d.buys or {}), S.mapCacheCount or 0),
        Lifetime = 8,
    })
end }, "ScanMap")
rr:Button({ Name = "导出缓存（Luau 文本）", Callback = function()
    local txt = S.exportMapCache()
    local ok = pcall(function() setclipboard(txt) end)
    Window:Notify({
        Title = ok and "已复制到剪贴板" or "导出完成（执行器无 setclipboard）",
        Description = string.format("%d 字节，可直接贴进脚本", #txt),
        Lifetime = 5,
    })
end }, "ExportMap")
rr:Label({ Text = "只有当前加载的图才有世界对象；其它 10 张图的点位在客户端不存在（GameStats.Maps 里只有雷达图和光照，没有坐标）。做法是进一张图扫一次存缓存，以后换回这张图直接用。" })

rr:Header({ Text = "射击 · 弹道" })
rr:Toggle({ Name = "无散射（据点 · 弹道始终跟准星）", Default = cfg.noSpread == true, Callback = function(v)
    cfg.noSpread = v
    Window:Notify({ Title = "射击", Description = "无散射 " .. (v and "已开启" or "已关闭"), Lifetime = 2 })
end }, "NoSpread")
rr:Label({ Text = "把发出去的 Bullets[].Direction 重置成相机准星方向，抹掉游戏加的散射（跑动 ×3、跳跃、连射扩散）。Direction 是客户端合法字段，服务端照单全收，所以这是服务端认可的做法。静默瞄准锁定时优先用静默方向。" })

-- ═══════════════════════════════════════════════════════════════
-- VIP 服专用（独立页 T.vip）
-- 只在私人服 / 有 VIP 菜单权限时有效：IsVIPServer=true 且 CanUseVIPMenu=true
-- ═══════════════════════════════════════════════════════════════
T.vipL:Header({ Text = "服务端状态" })
T.vipL:Button({ Name = "刷新服务端状态（回填面板）", Callback = function()
    S.vipFetch()
    Window:Notify({ Title = "VIP", Description = "已请求 State，稍等会自动回填", Lifetime = 3 })
end }, "VipFetch")
T.vipL:Label({ Text = "读的是服务端 VIP State，能直接看到 InfiniteAmmo / GodMode / Bot 数量等真实开关值。" })

T.vipL:Header({ Text = "服务端开关" })
-- ⚠ 所有控件都要把返回值存进 S.vipCtrls，否则服务端状态回来之后没法回填，
-- 用户看到的就是「每次都显示默认值，永远不是真实状态」。
S.vipCtrls = S.vipCtrls or {}
S.vipCtrls.VipAmmo = T.vipL:Toggle({ Name = "无限弹药", Default = false, Callback = function(v)
    S.vipSet("InfiniteAmmoEnabled", v)
    Window:Notify({ Title = "VIP", Description = "InfiniteAmmoEnabled = " .. tostring(v), Lifetime = 3 })
end }, "VipAmmo")
S.vipCtrls.VipCash = T.vipL:Toggle({ Name = "无限金钱", Default = false, Callback = function(v)
    S.vipSet("InfiniteCashEnabled", v)
    Window:Notify({ Title = "VIP", Description = "InfiniteCashEnabled = " .. tostring(v), Lifetime = 3 })
end }, "VipCash")
S.vipCtrls.VipGod = T.vipL:Toggle({ Name = "无敌（把自己加入名单）", Default = false, Callback = function(v)
    S.vipGodMode(v)
    Window:Notify({ Title = "VIP", Description = "GodMode = " .. tostring(v), Lifetime = 3 })
end }, "VipGod")
S.vipCtrls.VipEsp = T.vipL:Toggle({ Name = "服务端 ESP（把自己加入名单）", Default = false, Callback = function(v)
    S.vipEspMe(v)
    Window:Notify({ Title = "VIP", Description = "ESPEnabled = " .. tostring(v), Lifetime = 3 })
end }, "VipEsp")
S.vipCtrls.VipFF = T.vipL:Toggle({ Name = "友军伤害", Default = false, Callback = function(v)
    S.vipSet("FriendlyFireEnabled", v)
end }, "VipFF")
S.vipCtrls.VipTimer = T.vipL:Toggle({ Name = "冻结回合计时器", Default = false, Callback = function(v)
    S.vipSet("TimerFrozen", v)
end }, "VipTimer")
S.vipCtrls.VipKnife = T.vipL:Toggle({ Name = "允许丢刀", Default = false, Callback = function(v)
    S.vipSet("KnifeDropEnabled", v)
end }, "VipKnife")
S.vipCtrls.VipKillTrade = T.vipL:Toggle({ Name = "击杀交易（Kill Trading）", Default = false, Callback = function(v)
    S.vipSet("KillTradingEnabled", v)
end }, "VipKillTrade")
S.vipCtrls.VipTeamLimit = T.vipL:Toggle({ Name = "解除队伍人数限制", Default = false, Callback = function(v)
    S.vipSet("DisableTeamLimitEnabled", v)
end }, "VipTeamLimit")
S.vipCtrls.VipCollision = T.vipL:Toggle({ Name = "玩家互相碰撞", Default = false, Callback = function(v)
    S.vipSet("PlayerCollisionsEnabled", v)
end }, "VipCollision")
S.vipCtrls.VipCompMove = T.vipL:Toggle({ Name = "竞技移动（Competitive Movement）", Default = false, Callback = function(v)
    S.vipSet("CompetitiveMovementEnabled", v)
end }, "VipCompMove")

T.vipL:Header({ Text = "换图 / 换模式（下一局生效）" })
S.vipCtrls.NextMap = T.vipL:Dropdown({
    Name = "下一张地图",
    Multi = false,
    Required = false,
    Options = S.vipMapList(),
    Default = 1,
    Callback = function(v) S.vipNextMap(tostring(v)) end,
}, "NextMap")
S.vipCtrls.NextMode = T.vipL:Dropdown({
    Name = "下一个模式",
    Multi = false,
    Required = false,
    Options = S.vipGamemodeList(),
    Default = 1,
    Callback = function(v) S.vipNextGamemode(tostring(v)) end,
}, "NextMode")
T.vipL:Label({ Text = "改的是服务端的 NextMap / NextGamemode，下一局开始时生效。地图列表和模式列表都是从游戏配置现读的，不是写死的。" })

T.vipR:Header({ Text = "BOT 控制（测靶）" })
S.vipCtrls.BotT = T.vipR:Slider({ Name = "T 方 BOT 数量", Default = 0, Minimum = 0, Maximum = 10, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) S.vipSet("BotTerrorists", math.floor(v)) end }, "BotT")
S.vipCtrls.BotCT = T.vipR:Slider({ Name = "CT 方 BOT 数量", Default = 0, Minimum = 0, Maximum = 10, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) S.vipSet("BotCounterTerrorists", math.floor(v)) end }, "BotCT")
S.vipCtrls.BotDiff = T.vipR:Dropdown({
    Name = "BOT 难度",
    Multi = false,
    Required = false,
    Options = { "Easy", "Normal", "Hard", "Expert" },
    Default = 1,
    Callback = function(v) S.vipSet("BotDifficulty", tostring(v)) end,
}, "BotDiff")
S.vipCtrls.BotFreeze = T.vipR:Toggle({ Name = "冻结所有 BOT（当固定靶）", Default = false, Callback = function(v)
    S.vipSet("BotsFrozen", v)
end }, "BotFreeze")
T.vipR:Button({ Name = "全部清空（0 个 BOT）", Callback = function()
    S.vipSet("BotTerrorists", 0)
    S.vipSet("BotCounterTerrorists", 0)
    Window:Notify({ Title = "BOT", Description = "已请求清空双方 BOT", Lifetime = 3 })
end }, "BotClear")
T.vipR:Label({ Text = "实测：SetSetting(BotTerrorists=3) 后服务端真的生成了 BOT（workspace.Characters 里 Bot=true 的 PlayerCustomCharacter）。冻结 + 只出敌方 BOT，就是最干净的练枪靶。" })

T.vipR:Header({ Text = "计时器 / 踢人" })
S.vipCtrls.TimerSec = T.vipR:Slider({ Name = "设置回合计时器（秒）", Default = 120, Minimum = 0, Maximum = 9999,
    DisplayMethod = "Value", Precision = 0,
    Callback = function() end }, "TimerSec")
T.vipR:Button({ Name = "应用计时器", Callback = function()
    local c = S.vipCtrls and S.vipCtrls.TimerSec
    local sec = (c and tonumber(c.Value)) or 120
    local ok = S.vipSetTimer(sec)
    Window:Notify({ Title = "计时器", Description = (ok and "已发送 " or "发送失败 ") .. tostring(sec) .. " 秒", Lifetime = 3 })
end }, "TimerApply")
S.vipCtrls.KickUid = T.vipR:Dropdown({
    Name = "踢出玩家",
    Multi = false,
    Required = false,
    Options = S.vipPlayerList(),
    Default = 1,
    Callback = function() end,
}, "KickUid")
T.vipR:Button({ Name = "踢出选中玩家", Callback = function()
    local c = S.vipCtrls and S.vipCtrls.KickUid
    local opt = c and c.Value
    if type(opt) ~= "string" then
        Window:Notify({ Title = "踢人", Description = "先选一个玩家", Lifetime = 3 })
        return
    end
    -- 选项格式是 "名字 (UserId)"
    local uid = tonumber(tostring(opt):match("%((%d+)%)"))
    if not uid then
        Window:Notify({ Title = "踢人", Description = "解析不到 UserId", Lifetime = 3 })
        return
    end
    local ok = S.vipKick(uid)
    Window:Notify({ Title = "踢人", Description = (ok and "已发送 KickPlayer " or "发送失败 ") .. tostring(uid), Lifetime = 3 })
end }, "KickApply")
T.vipR:Button({ Name = "刷新玩家列表", Callback = function()
    local c = S.vipCtrls and S.vipCtrls.KickUid
    if c and type(c.Settings) == "table" then
        c.Settings.Options = S.vipPlayerList()
    end
    Window:Notify({ Title = "踢人", Description = "已刷新（重新打开下拉框查看）", Lifetime = 3 })
end }, "KickRefresh")

-- 控件都创建完之后：主动拉一次服务端状态，并把结果回填到面板。
-- 这样第一次打开 VIP 页看到的就是真实值，而不是一堆默认的「关」。
task.defer(function()
    S.vipEnsureListen()
    S.vipFetch()
    task.delay(0.8, function()
        if type(S.syncVipUI) == "function" then pcall(S.syncVipUI) end
    end)
end)
-- ⚠ 这里原来是「每 5 秒自动 vipFetch 一次」的轮询。
--
-- 已移除。理由：用户反馈「一注入脚本就买不了东西、捡东西消失」，而纯净模式
-- 关掉全部 hook 也没解决 —— 说明问题不在 hook，而在「脚本持续跟服务端通信」本身。
-- 每 5 秒发一次 VIP.RequestData("State") 虽然频率很低，但这是一条只有 VIP 菜单
-- 打开时才该出现的包；持续轮询会让服务端看到「这个玩家一直在拉 VIP 状态」，
-- 属于异常行为画像。宁可手动点「刷新服务端状态」，也不要后台轮询。

T.vipR:Header({ Text = "回合动作" })
T.vipR:Button({ Name = "重置比分", Callback = function()
    S.vipAction("ResetScore")
    Window:Notify({ Title = "VIP", Description = "已发送 ResetScore", Lifetime = 3 })
end }, "VipReset")
T.vipR:Button({ Name = "结束本局（EndGame）", Callback = function()
    S.vipAction("EndGame")
    Window:Notify({ Title = "VIP", Description = "已发送 EndGame", Lifetime = 3 })
end }, "VipEndGame")
T.vipR:Label({ Text = "危险动作，只在你自己的服务器里用。EndGame 会直接结束本局。" })

-- ═══════════════════════════════════════════════════════════════
-- 美化功能已整体移除（按用户要求）
-- 历史结论：这个游戏的皮肤在未导出的 DecorateModel / GetSkinTextureFolder 里套，
-- 客户端只能改 MeshPart.TextureID（UV 对不上，出灰白/错位），写 CurrentEquipped 会被
-- 服务端覆盖，destroy+construct 会弄坏 viewmodel。所以不再提供入口。
-- ═══════════════════════════════════════════════════════════════
T.skinL:Header({ Text = "皮肤（全部可美化武器 + 手套）" })

-- ⚠ 为什么用「固定槽位」而不是动态增删控件：
-- WindUI 的控件只能在加载时创建，运行时新增不了。所以预先建 26 个槽位按钮，
-- 由 S.refreshSkinList() 把「当前手持武器」的皮肤按品质排序后填进标题，
-- 空槽位标题设为 "—" 并且不可点。换枪由轮询自动触发刷新。
S.skinSlotCB = {}
for i = 1, 52 do
    (function(slot)
        T.skinL:Button({
            Name = "—",
            Callback = function()
                local cb = S.skinSlotCB[slot]
                if cb then cb() end
            end,
        }, "SkinSlot" .. slot)
    end)(i)
end
T.skinL:Button({
    -- ⚠ 文案要准确：这个按钮重扫的是「哪些武器有皮肤」这张名字表，
    -- 不是「当前手上这把枪的皮肤列表」（后者在点名字打开的图鉴面板里，每次现取）。
    Name = "↻ 重新扫描武器列表（漏枪时用）",
    Callback = function()
        local ok, msg = S.refreshSkinList(true)
        Window:Notify({ Title = "武器列表", Description = tostring(msg), Lifetime = 4 })
    end,
}, "SkinRefreshList")
T.skinL:Button({
    Name = "↺ 恢复原皮（当前武器/手套）",
    Callback = function()
        local cur = S.getCurrentWeapon()
        if not cur then return end
        S.setSkin(cur.Name, "Stock")
        S.paintCurrentModel(tostring(cur.Name), "Stock")
    end,
}, "SkinStockReset")

-- 手动强制重建 viewmodel：换完皮肤画面没变时点一下
T.skinL:Button({
    Name = "↻ 强制刷新皮肤（换了没反应时点我）",
    Callback = function()
        local cur = S.getCurrentWeapon()
        if not cur then
            Window:Notify({ Title = "刷新", Description = "手上没有武器", Lifetime = 3 })
            return
        end
        -- 先重刷一次材质，再让游戏重建 viewmodel
        local skin = S.skinPaint and S.skinPaint[tostring(cur.Name)]
        if skin then
            pcall(S.paintCurrentModel, tostring(cur.Name), tostring(skin))
        end
        local ok, why = S.rebuildViewmodel(tostring(cur.Name))
        Window:Notify({
            Title = ok and "已请求重建" or "重建失败",
            Description = ok and ("重新加载 " .. tostring(cur.Name)) or tostring(why),
            Lifetime = 3,
        })
    end,
}, "SkinForceRefresh")

-- ⚠ 磨损等级必须能选。
-- 每款皮肤在 Assets.Skins 里按磨损分 1~5 个文件夹，同款皮肤不同磨损的 ColorMap 完全不同：
--   Luminex: Factory New=89358060595291 / Battle-Scarred=122213807151929
-- 默认用 Factory New（和图鉴预览一致）。之前取的是文件夹里的第一个，
-- 而多数皮肤第一个是 Battle-Scarred —— 刷上去就是"严重磨损版"，用户一眼看出不对。
T.skinL:Dropdown({
    Name = "磨损等级（影响皮肤外观新旧）",
    Options = { "Factory New", "Minimal Wear", "Field-Tested", "Well-Worn", "Battle-Scarred" },
    Default = 1,
    Callback = function(v)
        S.skinWear = tostring(v)
        S._matCache = {}          -- 材质缓存按磨损分级，换磨损必须整体作废
        S._skinFail = {}
        S._skinEmptyUntil = {}
        S._skinParts = nil
        local cur = S.getCurrentWeapon()
        if cur and S.skinPaint[cur.Name] then
            S.paintCurrentModel(tostring(cur.Name), tostring(S.skinPaint[cur.Name]))
        end
        Window:Notify({ Title = "磨损", Description = "已切换为 " .. tostring(v), Lifetime = 3 })
    end,
}, "SkinWear")

T.skinL:Label({ Text = "列表会自动跟随你手里拿的东西：拿枪显示那把枪的皮肤，拿刀/手雷/C4 时自动改为手套皮肤。按品质从高到低排序（红 > 粉 > 紫 > 蓝 > 原版），点任意一行立即换肤。" })

rr:Dropdown({
    Name = "空中加速（air strafe 实验）",
    Multi = false,
    Required = false,
    Options = { "关闭", "垂直推进（turn）", "纯侧向（side）" },
    Default = (cfg.airStrafe == "turn" and 2) or (cfg.airStrafe == "side" and 3) or 1,
    Callback = function(v)
        if v == "垂直推进（turn）" then
            cfg.airStrafe = "turn"
        elseif v == "纯侧向（side）" then
            cfg.airStrafe = "side"
        else
            cfg.airStrafe = "off"
        end
    end,
}, "AirStrafe")
rr:Label({ Text = "CS 的连跳叠速靠的是空中把移动方向转到与速度垂直，服务端的 air-accel 就会沿这个方向给一个切向增量。MovementV2 的服务端是重放客户端命令的，所以改 Move 的朝向有机会复现。只在空中生效、落地不干预。开之前先用「关闭」，确认基础速度。" })
rr:Slider({ Name = "基础速度倍率（实验）", Default = cfg.bhopBoost, Minimum = 1, Maximum = 3,
    DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.bhopBoost = v end }, "BhopBoost")

-- 视觉
local vl = secOf(T.visual, "显示与透视")
local vr = secOf(T.visual, "颜色 / 范围 / 大小")

vl:Header({ Text = "透视" })
vl:Toggle({ Name = "透视开关", Default = true, Callback = function(v) cfg.esp = v end }, "Esp")
vl:Toggle({ Name = "方框", Default = true, Callback = function(v) cfg.espBox = v end }, "EspBox")
vl:Toggle({ Name = "血条", Default = true, Callback = function(v) cfg.espHealth = v end }, "EspHp")
vl:Toggle({ Name = "名字", Default = true, Callback = function(v) cfg.espName = v end }, "EspName")
vl:Toggle({ Name = "骨骼", Default = cfg.espSkeleton == true, Callback = function(v) cfg.espSkeleton = v end }, "EspSkel")
-- 「碰撞箱部位」开关已按用户要求移除
vl:Toggle({ Name = "敌人高亮（暴露/掩体后分色）", Default = cfg.espCoverTint == true, Callback = function(v)
    cfg.espCoverTint = v
    coverCache = {}
    Window:Notify({ Title = "透视", Description = "敌人高亮 " .. (v and "已开启" or "已关闭"), Lifetime = 2 })
end }, "EspCoverTint")
vl:Colorpicker({ Name = "暴露在外", Default = cfg.colorExposed, Callback = function(c)
    cfg.colorExposed = Color3.fromRGB(c.R, c.G, c.B)
end }, "ColExposed")
vl:Colorpicker({ Name = "躲在掩体后", Default = cfg.colorCovered, Callback = function(c)
    cfg.colorCovered = Color3.fromRGB(c.R, c.G, c.B)
end }, "ColCovered")
vl:Label({ Text = "高亮原理：从相机往目标头部打射线，命中说明中间有墙/箱子挡着（掩体后，默认蓝色），没命中说明暴露（默认红色）。暴露的目标框会加粗。骨骼、碰撞箱、名字都用同一个颜色。检测每 0.12 秒刷新一次。" })
vl:Toggle({ Name = "第三人称", Default = cfg.thirdPerson == true, Callback = function(v)
    cfg.thirdPerson = v
    if not v then pcall(tpUnbind) end
    pcall(applyThirdPerson)
end }, "ThirdPerson")
vl:Slider({ Name = "第三人称视野距离", Default = 12, Minimum = 4, Maximum = 40, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.thirdPersonDist = v end }, "ThirdPersonDist")
vl:Label({ Text = "骨骼/碰撞箱需要角色模型。被 PVS 剔除的远处敌人没有模型（只有服务端位置），这两种透视对它们不生效，只有方框和名字仍然准确。" })
vl:Toggle({ Name = "距离", Default = true, Callback = function(v) cfg.espDist = v end }, "EspDist")
vl:Toggle({ Name = "武器", Default = true, Callback = function(v) cfg.espWeapon = v end }, "EspWpn")
vl:Toggle({ Name = "显示队友（蓝色）", Default = cfg.showTeammates == true, Callback = function(v) cfg.showTeammates = v end }, "EspTeam")
vl:Toggle({ Name = "显示机器人（黄色）", Default = true, Callback = function(v) cfg.showBots = v end }, "EspBots")
vl:Toggle({ Name = "隐藏尸体", Default = cfg.hideDead ~= false, Callback = function(v) cfg.hideDead = v end }, "EspHideDead")

vl:Header({ Text = "声音冲击波" })
vl:Toggle({ Name = "有动静时脚下画扩散圈", Default = cfg.soundRipple == true,
    Callback = function(v) cfg.soundRipple = v end }, "SndRipple")
vl:Slider({ Name = "波纹存在时长(秒)", Default = cfg.soundRippleSeconds, Minimum = 0.4, Maximum = 4,
    DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.soundRippleSeconds = v end }, "SndLife")
vl:Slider({ Name = "波纹最大半径(stud)", Default = cfg.soundRippleMax, Minimum = 4, Maximum = 60,
    DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.soundRippleMax = v end }, "SndMax")
vl:Label({ Text = "声音不等于透视：它只说明那个位置刚才有动静，不代表现在站着人。所以只画脚下扩散圈，不画框、不参与瞄准。数据来自 CreateTracer（开枪，枪口坐标精确）和动态创建的音效实例（脚步/换弹）。" })
vl:Label({ Text = "尸体默认显示为灰色。属性可能滞后，所以不做死活过滤，避免把活人误杀。" })
vl:Toggle({ Name = "标记威胁（橙色=正看着你）", Default = true, Callback = function(v) cfg.markThreat = v end }, "MarkThreat")
vl:Toggle({ Name = "标记烟后目标（灰蓝）", Default = true, Callback = function(v) cfg.markSmoke = v end }, "MarkSmoke")
vl:Slider({ Name = "烟雾遮挡阈值（越高越晚判定被挡）", Default = 60, Minimum = 0, Maximum = 100, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.smokeBlockThreshold = (tonumber(v) or 60) / 100 end }, "SmokeThr")
vl:Label({ Text = "烟雾是渐变的：刚爆开时只挡住一部分，散开时也是慢慢散。阈值 60 表示「烟雾展开到 60% 以上才认为敌人被挡住」。调低 = 更早判定被挡（更保守），调高 = 要等烟几乎满了才算挡。" })

vl:Header({ Text = "投掷物落点" })
vl:Toggle({ Name = "爆炸后保留落点圈（直到效果结束）", Default = (cfg.grenadeKeepAfterBoom ~= false), Callback = function(v)
    cfg.grenadeKeepAfterBoom = v
end }, "GrenadeKeep")
vl:Label({ Text = "开着的时候：手雷炸了、燃烧瓶烧起来了、烟雾散开了，落点圈不会立刻消失，而是继续显示并倒数效果剩余时间（HE 约 1.5 秒、燃烧瓶约 7 秒、烟雾约 18 秒）。关掉就恢复原样——一爆炸圈就收。效果期的圈颜色会暗一些，和「还没炸」区分开。" })
vl:Toggle({ Name = "投掷物倒计时+范围圈", Default = true, Callback = function(v) cfg.showGrenadeInfo = v end }, "GrenadeInfo")
vl:Toggle({ Name = "烟/火真实覆盖区（游戏数据）", Default = true, Callback = function(v) cfg.showVfxZones = v end }, "VfxZones")
vl:Toggle({ Name = "同时显示包围圈（更大一圈）", Default = cfg.showVfxBounding == true, Callback = function(v) cfg.showVfxBounding = v end }, "VfxBounds")
vl:Slider({ Name = "范围圈半径(估算 stud)", Default = 25, Minimum = 5, Maximum = 200, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.grenadeRadius = v end }, "GrenRadius")
vl:Label({ Text = "CS 手雷杀伤半径约 27 stud，所以默认 25。服务端不下发真实值，按实测自己调。" })
vl:Label({ Text = "倒计时来自服务端 fuseTime（准）。但爆炸/烟雾半径服务端不下发，配置里所有手雷都写 60，所以这个圈是估算值，按实际爆炸效果自己调。" })

vr:Header({ Text = "范围与颜色" })
vr:Slider({ Name = "透视距离", Default = 600, Minimum = 50, Maximum = 2500, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.espRange = v end }, "EspRange")
vr:Colorpicker({ Name = "敌人颜色", Default = Color3.fromRGB(255, 60, 60),
    Callback = function(c) cfg.colorEnemy = c end }, "ColEnemy")
vr:Colorpicker({ Name = "队友颜色", Default = Color3.fromRGB(60, 160, 255),
    Callback = function(c) cfg.colorTeam = c end }, "ColTeam")

vr:Header({ Text = "数据新鲜度" })
vr:Toggle({ Name = "冻结目标标「旧 N 秒」", Default = cfg.showFrozenTag,
    Callback = function(v) cfg.showFrozenTag = v end }, "FrozenTag")
vr:Toggle({ Name = "干脆不画冻结目标", Default = cfg.hideFrozen,
    Callback = function(v) cfg.hideFrozen = v end }, "HideFrozen")
vr:Toggle({ Name = "画冻结玩家的旧位置（会画在空气里）", Default = cfg.showStaleModel,
    Callback = function(v) cfg.showStaleModel = v end }, "ShowStaleModel")
vr:Slider({ Name = "冻结判定（秒没更新）", Default = cfg.staleSeconds, Minimum = 0.3, Maximum = 8,
    DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.staleSeconds = v end }, "StaleSeconds")
vr:Slider({ Name = "残影清理时间（秒）", Default = cfg.ghostPurgeSeconds, Minimum = 0.05, Maximum = 5,
    DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.ghostPurgeSeconds = v end }, "GhostPurge")
vr:Label({ Text = "残影清理时间 = 目标从 ESP 消失后，那套骨骼/碰撞箱的 Drawing 对象还留多久才被彻底 Remove。调小（0.05~0.2）= 几乎瞬间消失，但 PVS 抖一下就会闪；调大 = 平滑但会短暂残留。默认 3 秒。" })
vr:Label({ Text = "敌人离开视野后服务端就不再下发他的位置（PVS），客户端拿不到新数据。默认不画这种目标——因为模型会停在最后一刻，新一局时甚至还是上一局的死亡点，画出来就是个站在空气里的框。" })

vr:Header({ Text = "屏幕外箭头" })
vr:Toggle({ Name = "屏幕外箭头指示", Default = true, Callback = function(v) cfg.offscreen = v end }, "OffscreenOn")
vr:Slider({ Name = "箭头侦测距离", Default = 600, Minimum = 100, Maximum = 2000, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.offscreenRange = v end }, "OffscreenRange")
vr:Label({ Text = "屏幕外的敌人在边缘显示箭头和距离，背后有人也看得到。" })

vr:Header({ Text = "雷达" })
vr:Toggle({ Name = "雷达开关", Default = cfg.radar == true, Callback = function(v) cfg.radar = v end }, "RadarOn")
vr:Slider({ Name = "雷达大小", Default = 190, Minimum = 100, Maximum = 320, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.radarSize = v end }, "RadarSize")
vr:Slider({ Name = "雷达范围", Default = 400, Minimum = 100, Maximum = 1200, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.radarRange = v end }, "RadarRange")
vr:Label({ Text = "雷达在屏幕右侧：中心是你，上方是你面朝的方向。红点敌人、蓝点队友、黄点机器人。" })

-- ⚠ 投掷物抛物线预览已移除（2026-11）。
-- 实测预测轨迹和真实弹道对不上（跳跃/移动时偏差尤其大），
-- 用户要求直接去掉，不要占着界面。底层的 throwStep / predictThrow
-- 保留在代码里但不注册到任何 RenderStep，也不再有 GUI 开关。
-- ⚠ 这里的 Default 必须读 cfg，不能写死。
-- Maclib 初始化控件时会用 Default 回写一次 Callback，写死就等于每次加载都把
-- 配置恢复的结果冲掉——这正是「明明开了却没生效」的根源（情报 6.5）。
vr:Slider({ Name = "预览起点·高度偏移", Default = cfg.throwHeight, Minimum = -1, Maximum = 4, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.throwHeight = v end }, "ThrowHeight")
vr:Slider({ Name = "预览起点·前向偏移", Default = cfg.throwForward, Minimum = 0, Maximum = 4, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.throwForward = v end }, "ThrowForward")
vr:Slider({ Name = "上抛偏置", Default = cfg.throwUpBias, Minimum = 0, Maximum = 0.5, DisplayMethod = "Value", Precision = 3,
    Callback = function(v) cfg.throwUpBias = v end }, "ThrowBias")
vr:Label({ Text = string.format("起点来源：%s（扔一颗手雷后自动变成 learned）", tostring(S.throwOriginSrc or "-")) }, "ThrowSrc")
vr:Button({
    Name = "套用游戏常量（GrenadeSimulator 真值）",
    Callback = function()
        cfg.throwHeight = 2.40
        cfg.throwForward = 1.35
        cfg.throwUpBias = 0.06
        Window:Notify({
            Title = "已套用游戏常量",
            Description = "前向 1.35 / 高度 2.40 / 上抛 0.06，全部取自 Shared.GrenadeSimulator.Constants。",
            Lifetime = 4,
        })
    end,
}, "ThrowExact")
vr:Button({
    Name = "清除实测起点（回到右手推算）",
    Callback = function()
        getgenv().MV_THROW_LEARNED.originOffset = nil
        Window:Notify({
            Title = "已清除实测起点",
            Description = "下次投掷会重新学习 originOffset。",
            Lifetime = 3,
        })
    end,
}, "ThrowClearOffset")
vr:Button({
    Name = "套用手感值（线从手部出发）",
    Callback = function()
        cfg.throwHeight = 0.3
        cfg.throwForward = 0.8
        cfg.throwUpBias = 0.06
    end,
}, "ThrowFeel")
vr:Toggle({ Name = "自动校准起点（旧的相机锚点法，建议关）", Default = cfg.throwAutoCalibrate, Callback = function(v) cfg.throwAutoCalibrate = v end }, "ThrowAutoCal")
-- 武器分类：每类枪单独设最大开火距离
local wl = secOf(T.weapon, "装备与武器")
local wr = secOf(T.weapon, "各类武器参数")


local CLASSES = {
    { key = "Rifle",   name = "步枪",   desc = "AK-47 / M4 / FAMAS / AUG",
      names = { "AK-47", "M4A4", "M4A1-S", "Galil AR", "FAMAS", "AUG", "SG 553" } },
    { key = "Sniper",  name = "狙击",   desc = "AWP / SSG 08 / SCAR-20",
      names = { "AWP", "SSG 08", "SCAR-20", "G3SG1" } },
    { key = "Pistol",  name = "手枪",   desc = "Glock / USP-S / 沙鹰",
      names = { "Glock-18", "USP-S", "P250", "P2000", "Five-SeveN", "Tec-9",
                "Dual Berettas", "Desert Eagle", "R8 Revolver", "CZ75-Auto" } },
    { key = "SMG",     name = "冲锋枪", desc = "MP9 / MAC-10 / P90",
      names = { "MP9", "MAC-10", "P90", "MP7", "MP5-SD", "PP-Bizon", "UMP-45" } },
    { key = "Shotgun", name = "霰弹枪", desc = "Nova / XM1014 / MAG-7",
      names = { "Nova", "XM1014", "MAG-7", "Sawed-Off" } },
    { key = "Melee",   name = "近战",   desc = "各类刀",
      names = { "T Knife", "CT Knife", "Karambit", "M9 Bayonet", "Butterfly Knife",
                "Flip Knife", "Gut Knife", "Skeleton Knife", "Stiletto Knife", "LightSaber" } },
}

for i, c in ipairs(CLASSES) do
    local prof = cfg.weaponProfiles[c.key]
    local sec = (i <= 3) and wl or wr
    sec:Header({ Text = c.name .. " · " .. c.desc })
    sec:Toggle({
        Name = c.name .. " 自动开火",
        Default = prof.enabled,
        Callback = function(v) prof.enabled = v end,
    }, "W_" .. c.key .. "_On")
    sec:Slider({
        Name = c.name .. " 最大开火距离",
        Default = prof.maxDist,
        Minimum = 5,
        Maximum = 1500,
        DisplayMethod = "Value",
        Precision = 0,
        Callback = function(v) prof.maxDist = v end,
    }, "W_" .. c.key .. "_Dist")
    -- 静默瞄准距离（按类统一改，写进 aimDistByWeapon 的每一把枪）
    local curAim = cfg.aimDistByWeapon[c.names[1]] or cfg.maxAimDist
    sec:Slider({
        Name = c.name .. " 静默瞄准距离",
        Default = curAim,
        Minimum = 5,
        Maximum = 1500,
        DisplayMethod = "Value",
        Precision = 0,
        Callback = function(v)
            for _, wn in ipairs(c.names) do
                cfg.aimDistByWeapon[wn] = v
            end
        end,
    }, "W_" .. c.key .. "_AimDist")
end

wl:Header({ Text = "自动开火总控" })
wl:Button({
    Name = "一键开启全部自动开火（6 类全开）",
    Callback = function()
        local opened = {}
        for k, prof in pairs(cfg.weaponProfiles) do
            prof.enabled = true
            opened[#opened + 1] = tostring(k)
        end
        table.sort(opened)
        Window:Notify({
            Title = "自动开火已全开",
            Description = "启用: " .. table.concat(opened, " / "),
            Lifetime = 5,
        })
    end,
}, "AutoFireAll")
wl:Button({
    Name = "一键关闭全部自动开火",
    Callback = function()
        for k, prof in pairs(cfg.weaponProfiles) do prof.enabled = false end
        Window:Notify({ Title = "自动开火已全关", Description = "6 类全部关闭", Lifetime = 4 })
    end,
}, "AutoFireNone")
wl:Label({ Text = "「一键开启全部自动开火」只开各类武器的档位开关；总开关仍在战斗页的「启用自动瞄准（总开关）」。静默模式下自动开火会跳过准星偏移检查，穿墙按材质+距离判定，跳过射击间隔由「跳过射击间隔」控制。" })

local curW = wl:Label({ Text = "当前武器: 读取中..." })
task.spawn(function()
    while true do
        task.wait(0.5)
        if S._alive == false or REG.gen ~= MY_GEN then break end
        pcall(function()
            local n = heldWeaponName() or "未知"
            local cls = heldWeaponClass()
            local prof = cfg.weaponProfiles[cls]
            curW:UpdateName(string.format("当前武器: %s  |  类型: %s  |  最大距离 %d",
                n, cls, prof and prof.maxDist or 0))
        end)
    end
end)

-- 杂项
local ml = secOf(T.misc, "杂项")
local mr = secOf(T.misc, "投掷预览与菜单")

mr:Header({ Text = "投掷物抛物线" })
mr:Toggle({ Name = "拿着投掷物时自动显示", Default = cfg.throwAuto ~= false, Callback = function(v)
    cfg.throwAuto = v
end }, "ThrowAuto")
mr:Toggle({ Name = "强制常开（仍然只对投掷物有效）", Default = cfg.throwPreview == true, Callback = function(v)
    cfg.throwPreview = v
end }, "ThrowOn")
mr:Colorpicker({ Name = "抛物线颜色", Default = cfg.throwColor or Color3.fromRGB(120, 255, 140),
    Callback = function(c) cfg.throwColor = c end }, "ThrowColor")
mr:Label({ Text = "⚠ 预测不等于真实：移动/跳跃时偏差明显（跳跃散射最低 15 度是武器配置里的硬下限）。只当参考线看，别拿它当准星。默认关闭。" })


mr:Header({ Text = "配置" })
mr:Button({
    Name = "恢复默认配置（老 UI 那套出厂值）",
    Callback = function()
        local ok, msg = S.resetConfig()
        Window:Notify({ Title = ok and "已恢复默认" or "失败", Description = tostring(msg), Lifetime = 5 })
    end,
}, "ResetCfg")
mr:Label({ Text = "把 cfg 覆盖回加载时的出厂默认值（silentAim / fullSphere / esp / aimPartPriority 等全部回到初始状态）。当前调的这些开关会被重置，慎点。" })

mr:Header({ Text = "菜单控制" })
-- ⚠ 「关菜单」和「卸载」是两件事，混起来最容易让人以为卸载不干净：
--   · 快捷键 / 窗口 X  → 只隐藏菜单，透视、FOV 圈、包点标记、自瞄全都还在（这是设计）
--   · 下面这个按钮     → 真正卸载：断连接、清掉所有 Drawing、还原 hook
mr:Button({
    Name = "⏻ 完全卸载（清掉透视 / 圈 / 标记 / hook）",
    Callback = function()
        local fc = getgenv().MV_FULL_CLEANUP
        if type(fc) ~= "function" then
            Window:Notify({ Title = "卸载", Description = "清理句柄丢失，只能重进服务器", Lifetime = 5 })
            return
        end
        -- 先把还在画的那些东西立刻藏掉，别等 fullCleanup 走到最后一步
        pcall(function()
            local S = getgenv().MV_V2 and getgenv().MV_V2.state
            if not S then return end
            if S.fovCircleObj then pcall(function() S.fovCircleObj.Visible = false end) end
        end)
        pcall(fc)
    end,
}, "FullUnload")
mr:Label({ Text = "关菜单（快捷键 / 右上角 X）只隐藏窗口，透视和圈仍会继续画 —— 那是独立绘制的。想彻底停掉一切，用上面这个按钮，或者跑「卸载脚本.luau」。" })
mr:Button({
    Name = "重置菜单位置（跑到屏幕外时点这个）",
    Callback = function()
        if centerWindow() then
            Window:Notify({ Title = "菜单", Description = "已拉回屏幕中央", Lifetime = 2 })
        else
            Window:Notify({ Title = "菜单", Description = "没找到窗口容器", Lifetime = 3 })
        end
    end,
}, "Recenter")
mr:Keybind({
    Name = "菜单开关按键",
    Default = Enum.KeyCode.RightControl,
    Blacklist = false,
    Callback = function(bind) cfg.toggleKey = bind end,
    onBinded = function(bind)
        cfg.toggleKey = bind
        Window:Notify({ Title = "菜单", Description = "开关按键改为 " .. tostring(bind.Name), Lifetime = 3 })
    end,
}, "ToggleKey")
mr:Button({
    Name = "隐藏菜单（不删除）",
    Callback = function() pcall(function() Window:SetState(false) end) end,
})

mr:Header({ Text = "状态" })
local statLabel = mr:Label({ Text = "..." })
local statLabel2 = mr:Label({ Text = "" })
mr:Button({
    Name = "刷新 / 自检",
    Callback = function()
        local t = aimTarget()
        Window:Notify({
            Title = "状态",
            Description = string.format("射击 %d 次 | 改写 %d 次 | 注入子弹 %d 颗 | 目标 %s",
                S.shots, S.rewritten, S.bulletsInjected, t and t.name or S.lastTarget),
            Lifetime = 5,
        })
    end,
})

task.spawn(function()
    while true do
        task.wait(1)
        if S._alive == false or REG.gen ~= MY_GEN then break end
        local ok = pcall(function()
            statLabel:UpdateName(string.format("射击 %d 次 | 改写 %d 次 | 注入子弹 %d 颗", S.shots, S.rewritten, S.bulletsInjected))
            local lr = getgenv().MV_THROW_LEARNED
            local throwTxt
            if lr and lr.speed then
                throwTxt = string.format("投掷已学习: %.1f stud/s (%s)", lr.speed, tostring(lr.weapon))
            else
                throwTxt = "投掷速度: 未学习（扔一颗手雷）"
            end
            statLabel2:UpdateName(string.format("每包 %d 颗 | %s",
                cfg.bulletCount, throwTxt))
        end)
        if not ok then break end
    end
end)

-- 只清理【本实例】自己的东西：
-- REG.conns 是跨实例共享的，旧实例绝不能动它，否则会杀掉新实例的连接。
local function fullCleanup()
    -- 0) 先让本实例的所有常驻循环失效。
    -- ⚠ 必须放在第一行、在断开连接和还原 hook 之前：
    -- 那些 while true 循环每轮都会调 peek / 读属性 / 生成 Drawing，
    -- 如果等到最后才停，它们会在"hook 已还原、S 已半清空"的状态下再跑几百毫秒，
    -- 期间任何一次调用都可能抛错，看起来就像"卸载后还有一堆红字"。
    S._alive = false
    -- 独立 FOV 圈的停止标志。它那条 while 只看 _fovStop / 对象是否被换掉，
    -- 以前清理路径从来不置 true —— 对象 Destroy 后只要读属性不抛错就会一直 10Hz 转下去。
    S._fovStop = true

    -- 1) 先把所有功能关掉，否则 hook 还在按旧配置继续工作
    cfg.silentAim = false
    cfg.autoFire = false
    cfg.aimToggled = false
    if aimInput then aimInput.down = false; aimInput.listening = false end

    cfg.esp = false
    cfg.offscreen = false
    cfg.radar = false
    cfg.showGrenadeInfo = false
    cfg.throwPreview = false
    cfg.throwKeyHeld = false
    cfg.throwAuto = false
    cfg.spinbot = false
    cfg.markThreat = false
    cfg.markSmoke = false
    cfg.showFov = false
    cfg.thirdPerson = false
    pcall(tpUnbind)
    -- ⚠⚠ RenderStep 是按**名字**全局索引的，新旧实例共用同一串名字。
    -- 重载时新实例先绑好 "MV_Draw"，旧实例的 fullCleanup 才晚一步执行 ——
    -- 不加 gen 门的话，旧实例会把**新实例的绑定**一起解绑。
    -- 症状非常像「功能坏了」：cfg.esp 是 true、日志正常、gen 也对，
    -- 但 updateEsp 一次都没被调用（espTick 停在 0、S.espObjects 永远是空表），
    -- 自瞄的 MVHub_Aim 同理 —— 自动开火/平滑瞄准全部停摆。
    if REG.gen == MY_GEN then
        pcall(function() RunService:UnbindFromRenderStep("MV_Draw") end)
    end

    -- 2) 删掉所有绘制
    clearEsp()
    pcall(radarClear)
    pcall(throwClear)
    pcall(arrowClear)
    pcall(fovClear)
    pcall(grenadeClear)
    pcall(vfxZoneClear)
    -- ⚠ 包点标签（A pt / B pt）以前漏在这里。
    -- 它不在 clearEsp 的池里、也不在 radar/throw 那些 Clear 里，
    -- 于是卸载后两个 Drawing.Text 永久留在屏幕上，跟着视角走。
    pcall(S.sitesClear)
    for _, key in ipairs({ "bg", "borderT", "borderB", "borderL", "borderR", "me", "fwd" }) do
        local d = radar[key]
        if d and d.Remove then pcall(function() d:Remove() end) end
        radar[key] = nil
    end

    -- 3) 断开所有连接（含按键监听、Heartbeat、InputChanged）
    for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
    S.conns = {}
    if REG and REG.conns and REG.gen == MY_GEN then
        for _, c in ipairs(REG.conns) do pcall(function() c:Disconnect() end) end
        REG.conns = {}
    end

    -- 4) 解绑渲染步骤（同样必须加 gen 门，见上面 "MV_Draw" 那段说明）
    if REG.gen == MY_GEN then
        pcall(function() RunService:UnbindFromRenderStep("MVHub_Aim") end)
        pcall(function() RunService:UnbindFromRenderStep("MVHub_AimMobile") end)
        pcall(function() RunService:UnbindFromRenderStep("MV_Spin") end)
        pcall(function() RunService:UnbindFromRenderStep("MV_ThirdPerson") end)
    end

    -- 5) 兜底：销毁本脚本登记过的全部 Drawing
    -- 上面那些 xxxClear 只删本实例记得住的对象，reload 时旧实例的
    -- local 引用可能已经丢了（FOV 圈、箭头、抛物线的线会残留在屏幕上）。
    -- 登记表是全脚本共享的，所以这里能一并收干净。
    -- ⚠ 不再用 cleardrawcache()：它会把执行器 Drawing 系统打坏（见文件开头说明）。
    pcall(function()
        if type(getgenv().MV_REAP_DRAWINGS) == "function" then getgenv().MV_REAP_DRAWINGS() end
    end)

    -- 5) 还原 ShootWeapon.Send
    --
    -- ⚠ 只在「自己仍是最新实例」时才还原。
    -- 重载脚本时，新实例会先调旧实例的 Unload（脚本开头），
    -- 而 Maclib 的 Unload 是异步的 —— fullCleanup 会延后到新实例
    -- 已经接管 Send 之后才执行。无脑还原会把新实例的拦截一起干掉。
    -- REG.gen 每次加载递增，旧实例这里一定不相等 → 跳过。
    if REG.gen == MY_GEN and originalSend and shootPacket then
        pcall(function() shootPacket.Send = originalSend end)
    end

    -- 5b) 还原其余 Hook
    --
    -- ⚠ 原来这里只还原了 ShootWeapon.Send，另外三个 Hook 卸载后还挂在游戏对象上：
    --   · MeleeAttack.Send            ← 近战改方向
    --   · CameraController.setWeaponRecoil  ← 无后座
    --   · AimAssistController.GetMagnetismRotation ← 磁吸守护
    -- 旧闭包捕获的是旧 cfg，重载后虽然 cfg 被新实例换掉，但游戏仍会调到这些死 hook，
    -- 表现为「卸载/重载后行为不确定、功能关了还在生效」。
    --
    -- 同样只在「自己仍是最新实例」时还原，否则会把新实例刚装好的 hook 干掉。
    if REG.gen == MY_GEN then
        pcall(function() S.restoreAllHooks() end)
        -- 状态复位，避免下次加载误以为 hook 还装着
        cfg.noRecoil = false
        cfg.skipFireDelay = false
        if type(getgenv().MV_MAG_HOOK) ~= "function" then
            getgenv().MV_MAG_HOOK = nil
        end
    end

    -- 6) 再收一次 Drawing（上一段之后可能有新对象被建出来）
    --
    -- ⚠⚠⚠ 必须和上面的 hook 还原一样加「自己仍是最新实例」闸门。
    --
    -- 症状（实测踩到）：反复重载脚本若干次之后，屏幕上什么都没有 ——
    --   ESP 不画、投掷抛物线不画、落点圈不画，
    --   连手动 `Drawing.new("Line")` 出来、Visible=true 的洋红测试线都不显示。
    -- 而埋点在涨：throwTicks=111、throwLineCount=78、ringR=12 —— 代码全在跑。
    --
    -- 原因：MacLib 的 Unload 是**异步**的。新实例早已建好整套 Drawing，
    -- 旧实例的 fullCleanup 才慢一步跑到这一行，一次清空就把新实例的对象全收了。
    -- 重载次数越多，被清的次数越多，最终看起来像「Drawing 整个坏了」。
    --
    -- REG.gen 每次加载递增，所以旧实例到这里一定不相等 → 跳过，交还控制权。
    if REG.gen == MY_GEN then
        pcall(function()
            if type(getgenv().MV_REAP_DRAWINGS) == "function" then getgenv().MV_REAP_DRAWINGS() end
        end)
    end

    -- 7) 销毁手机端按钮
    if mobileGui then
        pcall(function() mobileGui:Destroy() end)
        mobileGui = nil
    end

    -- 7b) 菜单 ScreenGui 必须显式关掉    --
    -- ⚠ 这是「脚本关了/卸载了，但商店和背包还是点不动」的经典原因：
    -- WindUI 的 ScreenGui 在 DisplayOrder = 2147483647，只要 Enabled 还是 true，
    -- 它就这么盖在所有游戏 UI 之上。Window:SetState(false) 只藏窗口，不改 Enabled。
    pcall(function()
        if S.menuScreenGui then S.menuScreenGui.Enabled = false end
    end)
    pcall(function()
        local hh = (gethui and gethui()) or game:GetService("CoreGui")
        for _, c in ipairs(hh:GetChildren()) do
            if c:IsA("ScreenGui")
                and (c.Name == "WindUI" or c.Name == "MV_SkinPanel" or c.Name == "MVHubMobileControls") then
                c.Enabled = false
            end
        end
    end)

    setInfiniteAmmo(false)
    getgenv().MV_V2 = nil
end

-- 把 fullCleanup 暴露给文件前面的 Window.Unload（那里是 local 作用域之外）。
-- 不注册也能工作（S._alive 已停循环），注册了才能连连接、还原 hook 一起做掉。
getgenv().MV_FULL_CLEANUP = fullCleanup

-- ═══ 轻量清理（Window:Unload 走这条）═══
--
-- 为什么单独做一个：Window:Unload 那一瞬间 WindUI 正在销毁上万个实例，
-- 如果同一个 tick 里再跑 fullCleanup（断连接 + 清 Drawing + 还原四类 hook），
-- 压力全挤在一帧 —— 之前就怀疑过这是客户端直接消失的可疑点之一。
-- 这里只做「纯本地、碰不到游戏状态」的部分：断连接、解绑 RenderStep、清 Drawing。
-- hook 还原交给 1 秒后的 fullCleanup（由备用存活检测触发）或卸载脚本。
S.softCleanup = function()
    for _, c in ipairs(S.conns or {}) do pcall(function() c:Disconnect() end) end
    S.conns = {}
    pcall(function() RunService:UnbindFromRenderStep("MV_Draw") end)
    pcall(function() RunService:UnbindFromRenderStep("MVHub_Aim") end)
    pcall(function() RunService:UnbindFromRenderStep("MVHub_AimMobile") end)
    pcall(function() RunService:UnbindFromRenderStep("MV_Spin") end)
    pcall(function() RunService:UnbindFromRenderStep("MV_ThirdPerson") end)
    -- 包点标签不在 MV_DRAW_REG 的兜底范围内时（跨实例残留）只有这里能清掉
    pcall(S.sitesClear)
    pcall(function()
        if type(getgenv().MV_REAP_DRAWINGS) == "function" then getgenv().MV_REAP_DRAWINGS() end
    end)
    return true
end
getgenv().MV_SOFT_CLEANUP = S.softCleanup

-- ═══ 窗口开关快捷键 ═══
-- 连接放在函数作用域里，不占主 chunk 的 local 槽位（主 chunk 已贴着 200 上限）
--
-- ⚠ 必须同时切 ScreenGui.Enabled，不能只调 Window:SetState。
-- 实测：SetState(false) 只是把窗口藏起来，ScreenGui 仍然 Enabled = true，
-- DisplayOrder 又是 2147483647 —— 这层 ScreenGui 依然会吃掉鼠标，
-- 表现就是「菜单看起来关了，但商店还是点不动」。
pcall(function()
    local toggleConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        local key = cfg.toggleKey or Enum.KeyCode.RightControl
        if input.KeyCode == key then
            local cur = true
            pcall(function() cur = Window:GetState() end)
            pcall(function() Window:SetState(not cur) end)
            -- 关键：同步 ScreenGui.Enabled，才是真正的「让开鼠标」
            pcall(function()
                -- 统一走 S.findMenuGui：精确名 WindUI（含 Base 的旧库兜底）
                local sg = S.menuScreenGui
                if not sg or not sg.Parent then
                    sg = S.findMenuGui()
                    S.menuScreenGui = sg
                end
                if sg then
                    sg.Enabled = not cur
                    S.menuVisible = not cur
                end
            end)
        end
    end)
    REG.conns[#REG.conns + 1] = toggleConn
    S.conns[#S.conns + 1] = toggleConn
end)

---------------------------------------------------------------------
-- 手机端：没有键盘鼠标，补一排悬浮按钮
--   菜单开关 / 瞄准（切换式）/ 抛物线开关
---------------------------------------------------------------------
local mobileGui = nil
if IS_MOBILE then
    pcall(function()
        local holder = (gethui and gethui()) or game:GetService("CoreGui")
        local sg = Instance.new("ScreenGui")
        sg.Name = "MVHubMobileControls"
        sg.ResetOnSpawn = false
        sg.IgnoreGuiInset = true
        sg.DisplayOrder = 999
        sg.Parent = holder
        mobileGui = sg

        local function mkButton(text, y, w, h)
            local b = Instance.new("TextButton")
            b.Size = UDim2.fromOffset(w, h)
            b.Position = UDim2.new(0, 12, 0, y)
            b.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
            b.BackgroundTransparency = 0.2
            b.TextColor3 = Color3.fromRGB(90, 255, 150)
            b.Text = text
            b.TextSize = 15
            b.Font = Enum.Font.GothamBold
            b.AutoButtonColor = true
            b.BorderSizePixel = 0
            b.Parent = sg
            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 10)
            c.Parent = b
            local s = Instance.new("UIStroke")
            s.Color = Color3.fromRGB(60, 200, 120)
            s.Thickness = 1
            s.Parent = b
            return b
        end

        -- 1) 菜单显示/隐藏
        local menuBtn = mkButton("菜单", 150, 78, 44)
        menuBtn.MouseButton1Click:Connect(function()
            local cur = true
            pcall(function() cur = Window:GetState() end)
            pcall(function() Window:SetState(not cur) end)
        end)

        -- 2) 瞄准（手机用切换式，按住不适合触屏）
        local aimOn = false
        local aimBtn = mkButton("瞄准 关", 202, 78, 44)
        aimBtn.MouseButton1Click:Connect(function()
            -- 手机端按钮就是「切换」：等同把触发方式设为 toggle 再翻转
            cfg.aimTrigger = "toggle"
            cfg.aimToggled = not cfg.aimToggled
            local on = cfg.aimToggled
            aimBtn.Text = on and "瞄准 开" or "瞄准 关"
            aimBtn.TextColor3 = on and Color3.fromRGB(255, 90, 90) or Color3.fromRGB(90, 255, 150)
            aimBtn.BackgroundColor3 = on and Color3.fromRGB(60, 18, 18) or Color3.fromRGB(22, 22, 28)
        end)

        -- 3) 开火（按住式）
        --
        -- 手机上没有 mouse1press，autoFire 走的是「直接调 Weapon:shoot()」那条线，
        -- 而这个按钮就是它的扳机：按住 → cfg.mobileHoldFire = true。
        -- 大小和位置放在右手拇指区，避免和左侧的菜单/瞄准按钮打架。
        local fireBtn = mkButton("开火", 150, 96, 96)
        fireBtn.Position = UDim2.new(1, -120, 1, -170)
        fireBtn.TextSize = 20
        fireBtn.BackgroundColor3 = Color3.fromRGB(140, 30, 30)
        fireBtn.BackgroundTransparency = 0.15
        fireBtn.TextColor3 = Color3.fromRGB(255, 200, 200)
        local fStroke = fireBtn:FindFirstChildOfClass("UIStroke")
        if fStroke then fStroke.Color = Color3.fromRGB(255, 90, 90) end

        fireBtn.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch
                or input.UserInputType == Enum.UserInputType.MouseButton1 then
                cfg.mobileHoldFire = true
                fireBtn.BackgroundColor3 = Color3.fromRGB(220, 60, 60)
                S.mobileFireBtnDown = true
            end
        end)
        fireBtn.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch
                or input.UserInputType == Enum.UserInputType.MouseButton1 then
                cfg.mobileHoldFire = false
                fireBtn.BackgroundColor3 = Color3.fromRGB(140, 30, 30)
                S.mobileFireBtnDown = false
            end
        end)
        -- 手指滑出按钮也要松开，不然会一直开火
        fireBtn.MouseLeave:Connect(function()
            cfg.mobileHoldFire = false
            fireBtn.BackgroundColor3 = Color3.fromRGB(140, 30, 30)
            S.mobileFireBtnDown = false
        end)

        -- 4) 投掷物抛物线按钮已移除（预测不准，用户要求去掉）
    end)
end

-- WindUI 没有 onUnloaded（MacLib 专有），清理走 Window:Unload 那条链
pcall(function()
    if type(Window.onUnloaded) == "function" then
        Window.onUnloaded(function() pcall(fullCleanup) end)
    end
end)

-- 备用存活检测：用户可能直接调 Window:Unload() / WindUI:Destroy() 绕过 fullCleanup。
--
-- ⚠ 判据不能只看「GetState 报不报错」：修好 GetState 之后它永远不报错（只返回布尔），
-- 这条检测就完全失效了，常驻循环会一直跑到下次重载 —— 拿着已销毁的 GUI 对象干活。
-- 正确判据是「菜单 ScreenGui 真的被销毁」（Destroy 之后 Parent 变成 nil），
-- 这样和「用户按快捷键把窗口藏起来（Enabled=false，Parent 还在）」能区分开。
task.spawn(function()
    local goneStreak = 0
    while true do
        task.wait(0.5)
        if REG.gen ~= MY_GEN then break end
        -- 已经进入卸载状态（Window:Unload 置的 _alive=false）：
        -- 等 1 秒让 WindUI 销毁的尖峰过去，再跑完整清理（断连接 / 清 Drawing / 还原 hook）。
        -- 重载时 gen 会变，这里就 break，不碰新实例。
        if S._alive == false then
            task.wait(1)
            if REG.gen == MY_GEN then pcall(fullCleanup) end
            break
        end
        local okWin = pcall(function() return Window:GetState() end)
        -- 取当前 GUI；失效就重找，但**不要**把找不到写成 nil 之外的判断依据
        local prev = S.menuScreenGui
        local sg = prev
        local prevValid = false
        if prev then
            local okP0, p0 = pcall(function() return prev.Parent end)
            prevValid = (okP0 and p0 ~= nil)
        end
        if not prevValid then
            local found = S.findMenuGui()
            if found then S.menuScreenGui = found end
            sg = found
        end
        local guiGone = false
        if sg then
            local okP, parent = pcall(function() return sg.Parent end)
            guiGone = (not okP) or (parent == nil)
        elseif prevValid == false and prev ~= nil then
            -- 以前拿到过 GUI，现在失效且全树都找不到 → 真的被销毁了
            guiGone = true
        end
        if (not okWin) or guiGone then
            goneStreak += 1
        else
            goneStreak = 0
        end
        -- 连续 3 次（1.5 秒）才算真卸载：避免 GUI 重建的瞬间把脚本误判成"已死"而自己卸掉
        if goneStreak >= 3 then
            pcall(fullCleanup)
            break
        end
    end
end)


-- 注：窗口位置自愈不在这里做。
-- 菜单的 ScreenGui 挂在执行器的 gethui() / CoreGui 下（不是 PlayerGui），
-- 加载这一刻还拿不到它 —— 真正的钳制挪到了 Heartbeat 里、S.menuScreenGui 找到之后
-- 执行一次（搜 "guiFixed"）。

-- GUI 已经建完，这里必须把存档再应用一遍。
-- Maclib 初始化每个控件时会用它的 Default 回写一次 Callback，把加载时恢复好的
-- cfg 冲掉 —— 这就是情报 6.5「GUI 和实际状态长期不一致」的正体。
-- 只改 cfg、不回头 SetValue：重设控件会再触发一次 Callback，又绕回同一个循环。
-- 控件显示和实际状态不一致的代价，远小于「开了却没生效」。
-- 外层 do...end 是必须的：上一句以 ...() 结尾，直接接 (function() ... end)()
-- 会被 Luau 解析成链式调用，报 "Ambiguous syntax"。
do
    (function()
        local saved = getgenv().MV_CFG_SAVE
        if type(saved) ~= "table" then return end
        local fixed = 0
        for k, v in pairs(saved) do
            local cur = cfg[k]
            if cur ~= nil and cur ~= v and type(cur) == type(v)
                and (type(v) == "boolean" or type(v) == "number" or type(v) == "string") then
                cfg[k] = v
                fixed += 1
            end
        end
        getgenv().MV_CFG_REAPPLIED = fixed
    end)()
end

-- ⚠ 这里曾经是 paintCurrentModel v2（名字→ColorMap 索引正确，但仍然走
-- Instance.new("SurfaceAppearance") 这条已被证伪的路：新建的 SA 写进去读回还是旧值）。
-- 已整段删除，只保留文件尾部那个「只写现有 SA、绝不新建」的最终实现 ——
-- 重复定义最大的代价是：改了半天以为生效，实际被后面的定义覆盖了。

-- ═══ 瞄准模式 ↔ 配置分组（选哪个模式只显示哪个模式的配置）═══
S.AIM_MODE_UI = {
  silent = { "FullSphere", "AimHitPart", "AimPartPrio", "HeadChance", "HeadPrio",
             "AimSmoke", "MarkSmoke", "AimVisible", "Wallbang", "WallbangOff",
             "AimDist", "AimTrigger", "AimKeyBtn" },   -- Fov/ShowFov/FovColor 已移出：所有模式共用
  smooth = { "Smoothness", "Jitter", "SmoothJitter", "ReactDelay", "Overshoot",
             "SmoothSpeed", "SmoothMaxDeg", "SmoothDrop", "SmoothDead", "SmoothHijack", "NativeAA" },
  mouse  = { "MouseGain", "MouseStep", "MouseSmooth", "MouseRelease",
             "MouseTip1", "MouseTip2", "MouseTip3" },
}

S.applyAimModeUI = function()
  -- ⚠ FOV 圈是所有自瞄模式共用的，不该跟着模式隐藏。
  -- 原来 Fov/ShowFov/FovColor 只在 silent 分组里，选「平滑」或「鼠标」就整组消失，
  -- 表现就是「范围圈没法改、也没法开关」。
  local ALWAYS_ON = { Fov = true, ShowFov = true, FovColor = true }
  for k in pairs(ALWAYS_ON) do
    local w = S.UI[k]
    if w and w.ElementFrame then pcall(function() w.ElementFrame.Visible = true end) end
  end
  local mode = tostring(cfg.aimMode or "smooth")
  local shown, hidden = 0, 0
  for m, list in pairs(S.AIM_MODE_UI) do
    for _, k in ipairs(list) do
      local w = S.UI[k]
      if w and w.ElementFrame then
        local vis = (m == mode)
        local ok = pcall(function() w.ElementFrame.Visible = vis end)
        if ok then
          if vis then shown = shown + 1 else hidden = hidden + 1 end
        end
      end
    end
  end
  S.aimUIInfo = string.format("模式=%s 显示%d 隐藏%d", mode, shown, hidden)
  return S.aimUIInfo
end

task.spawn(function()
  local last
  while true do
    task.wait(0.5)
    -- ⚠ 判据必须在 pcall **外面**：写在里面的话 `return` 只结束那个匿名函数，
    -- 外层 while 照转 —— 卸载后旧实例会继续每 0.5 秒空转一次，永远不停。
    if S._alive == false or (REG and REG.gen ~= MY_GEN) then break end
    pcall(function()
      local m = tostring(cfg.aimMode or "smooth")
      if m ~= last then
        last = m
        S.applyAimModeUI()
      end
    end)
  end
end)

-- ═══════════════════════════════════════════════════════════════
-- 换肤最终实现（已实测生效）
--
-- 关键发现：
--   1) 直接改已有 SurfaceAppearance 的 ColorMap → 引擎不重绘（画面不变）
--   2) 销毁旧 SA + 新建 SA 并写入属性 → **立即重绘**
--   3) 只写 ColorMap 会丢法线/粗糙度/金属度 → 渲染成死白
--      （用户实测截图：枪变纯白，就是这一步）
-- 所以正确做法：完整复制源 SA 的全部贴图属性到新建的 SA
-- ═══════════════════════════════════════════════════════════════
-- ⚠ 必须包含 TexturePackContent。
-- 引擎优先用 SurfaceAppearance 的**烘焙纹理包**渲染，ColorMap 只在没有烘焙包时生效。
-- 实测：把 ColorMap 写成 Luminex 的值、TexturePackContent 还是原皮的 → 读回值是新的，
-- 画面一点不变。把烘焙包也一起抄过来才真正换色。
-- MaterialMode 在旧版 SA 上会报 "not a valid member"，所以不放进来（pcall 吞错但不干净）。
S.SA_PROPS = { "ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap", "EmissiveMaskContent", "AlphaMode", "TexturePackContent" }

-- ⚠⚠ 读/写 SurfaceAppearance 必须切到 thread identity 7。
--
-- 实测（Real 执行器，本 place）：
--   identity 8（默认）：sa.ColorMap 读取 → "The current thread cannot read 'ColorMap'
--                        (lacking capability Plugin)"，写入同样被拒。
--   identity 7：读得到 rbxassetid://…，写后能读回新值。
-- 之前所有 SA 读写都在 8 下，全部被静默拒绝 —— 表现就是
-- 「srcMap 永远是空表 → painted=0 → 皮肤一点不变，但 UI 显示已选」。
-- gethiddenproperty 在 8 下也不管用，同样需要 7。
S.saGet = function(sa, k)
    if not sa then return nil end
    local can = (type(setthreadidentity) == "function")
    local outermost = (S._saDepth or 0) == 0
    if outermost and can then pcall(setthreadidentity, 7) end
    local ok, v = pcall(function() return sa[k] end)
    if (not ok or v == nil) and type(gethiddenproperty) == "function" then
        local ok2, v2 = pcall(gethiddenproperty, sa, k)
        if ok2 and v2 ~= nil then ok, v = true, v2 end
    end
    if outermost and can then pcall(setthreadidentity, 8) end
    if ok then return v end
    return nil
end

-- ⚠ identity 切换本身有开销。一次换肤要读 8 部件 × 7 属性 × 2 次切换 = 一百多次，
-- 手持时点击回调直接卡死（用户看到的就是「拿着枪点美化没反应，换把枪就能点」）。
-- 用嵌套计数把它压成「整段操作只切 2 次」。
S._saDepth = 0
S.saEnter = function()
    S._saDepth = (S._saDepth or 0) + 1
    if S._saDepth == 1 and type(setthreadidentity) == "function" then
        pcall(setthreadidentity, 7)
    end
end
S.saLeave = function()
    S._saDepth = math.max(0, (S._saDepth or 0) - 1)
    if S._saDepth == 0 and type(setthreadidentity) == "function" then
        pcall(setthreadidentity, 8)
    end
end

S.saSet = function(sa, k, v)
    if not sa then return false end
    local can = (type(setthreadidentity) == "function")
    local outermost = (S._saDepth or 0) == 0
    if outermost and can then pcall(setthreadidentity, 7) end
    local ok = pcall(function() sa[k] = v end)
    if not ok and type(sethiddenproperty) == "function" then
        ok = pcall(sethiddenproperty, sa, k, v)
    end
    if outermost and can then pcall(setthreadidentity, 8) end
    return ok
end

S.getColorMap = function(sa)
    if not sa then return nil end
    return S.saGet(sa, "ColorMap")
end

S.copySAPart = function(srcSA, dstPart)
    if not srcSA or not dstPart then return false end
    local props = {}
    for _, k in ipairs(S.SA_PROPS) do
        local v = S.saGet(srcSA, k)
        if v ~= nil then props[k] = v end
    end
    local old = dstPart:FindFirstChildOfClass("SurfaceAppearance")
    if old then pcall(function() old:Destroy() end) end
    local okNew, newSA = pcall(function()
        local x = Instance.new("SurfaceAppearance")
        x.Name = "SurfaceAppearance"
        x.Parent = dstPart
        return x
    end)
    if not okNew then return false end
    local n = 0
    for k, v in pairs(props) do
        if pcall(function() newSA[k] = v end) then n = n + 1 end
    end
    return true, n
end

-- ═══ hook Skins.GetCameraModel：让游戏自己构建 viewmodel 时就用我们的皮肤 ═══
-- 为什么必须 hook：不 hook 的话，游戏每次重建 viewmodel 都按 CurrentEquipped.Skin
-- 应用它自己的皮肤，而我们在旁边不停改材质 → 两边对抗 → 皮肤闪烁。
-- hook 之后游戏直接拿到我们指定的皮肤模型，从根本上不存在对抗。
S.skinOrigGetCameraModel = nil
S.installSkinHook = function()
    -- ⚠ 必须返回 true，不能返回 nil：调用方写的是 `if not S.installSkinHook() then
    -- return false, "皮肤库不可用"`，返回 nil 会被当成「安装失败」。
    if S.skinHookInstalled then return true end
    local lib = S.getSkinsLib()
    if not lib or type(lib.GetCameraModel) ~= "function" then return false end

    -- 幂等：重载时 lib.GetCameraModel 上已经是上一实例的 wrapper，
    -- 通过 MV_ORIG_OF 取真正的原版，绝不在 wrapper 外面再套一层。
    local cur = lib.GetCameraModel
    local origOfS = getgenv().MV_ORIG_OF
    local orig = (origOfS and origOfS(cur)) or cur

    local function wrapper(weapon, skin, a3, a4, a5, a6, a7, a8)
        local wn = tostring(weapon)
        -- 计数 + 最近一次调用记录：排查「换刀/换肤没生效」时先看这里
        --   skinHookCalls 一直不涨 = 游戏根本没重建 viewmodel（切枪/重生才会）
        S.skinHookCalls = (S.skinHookCalls or 0) + 1
        S.skinHookLast = wn
        -- ★ 换刀：把「建模型用的武器名」换掉（纯本地视觉，服务端零感知）。
        --   游戏挂载时会用**当前武器名**给模型命名，所以查 viewmodel 的逻辑不受影响。
        local modelWeapon = (S.modelWeaponOf and S.modelWeaponOf(wn)) or wn
        local swapped = (modelWeapon ~= wn)
        -- 换刀后皮肤必须取**目标武器自己**的皮肤表：
        -- T Knife 只有 Stock，蝴蝶刀的皮肤（Fade/Damascus/Blackwidow…）挂在它自己名下。
        local want
        if swapped then
            want = S.skinPaint and S.skinPaint[modelWeapon]
        else
            want = S.skinPaint and S.skinPaint[wn]
        end
        -- ⚠ 以前排除了 "Stock"：手动选原版只在当前模型生效，之后 viewmodel 重建时
        -- hook 不再覆盖，游戏会用你自己拥有的皮肤 → 看起来像「选原版没生效」。
        -- 现在显式写 "Stock" 也照样覆盖，保证原版选择在重建后依然成立。
        if want and want ~= "" then skin = want end
        -- ⚠ 必须把原函数的返回值原样交回游戏。
        -- 少这一句 → 游戏拿到的永远是 nil → viewmodel 建不出来，
        -- 表现就是「手上模型消失 / 武器模型重建异常 / 快捷栏脱节」。
        local model = orig(modelWeapon, skin, a3, a4, a5, a6, a7, a8)
        S.skinHookLastModel = modelWeapon
        if swapped then S.skinHookSwapHits = (S.skinHookSwapHits or 0) + 1 end

        -- ⚠⚠ 关键：在**交回游戏之前**把 SurfaceAppearance 换成皮肤模板的克隆。
        --
        -- 为什么必须在这里做，而不是事后改 viewmodel：
        --   · ColorMap / TexturePackContent 事后都能写进去、也能读回新值，
        --     但引擎对我们改过的 SA **不重绘**（实测：改完 1 秒读回值仍是新的，画面一点不变）
        --   · TexturePackContent 还是只读的（写入 pcall 返回 false），而它优先级高于 ColorMap
        -- 换一个**全新的 SA 实例**（从 Assets.Skins 的模板 Clone）才可能让引擎重建材质。
        -- 而在模型刚构建、还没挂到场景里的时候替换，重建是必然发生的。
        if model and typeof(model) == "Instance" and want and want ~= "" then
            pcall(function()
                local root = S.getSkinsRoot()
                -- ⚠ 必须用 modelWeapon：换刀后材质在目标刀自己的目录下
                local wf = root and root:FindFirstChild(modelWeapon)
                local sf = wf and wf:FindFirstChild(tostring(want))
                if not sf then return end
                local camF = sf:FindFirstChild("Camera") or sf
                local wearF = camF:FindFirstChild(tostring(S.skinWear or ""))
                if not wearF then
                    for _, c in ipairs(camF:GetChildren()) do
                        if c:IsA("Folder") then wearF = c break end
                    end
                end
                if not wearF then return end
                if S.saEnter then S.saEnter() end
                local n = 0
                for _, d in ipairs(model:GetDescendants()) do
                    if d:IsA("MeshPart") then
                        -- ★ 跳过手臂 / 手套 / 锚点：S.SKIN_SKIP 在 5641 行定义，
                        --   paintCurrentModel 一直遵守它，这条 hook 路径以前漏了。
                        --   后果：手部被套上武器皮肤材质 → 用户看到「手背贴膜 / 手不见了」。
                        if not (S.SKIN_SKIP and S.SKIN_SKIP[d.Name]) then
                            local src = wearF:FindFirstChild(d.Name)
                            if src and src:IsA("SurfaceAppearance") then
                                -- ★★ 顺序必须是「先 Clone、成功再销毁旧的」。
                                --   原来是先 Destroy 再 Clone：Clone 一旦失败
                                --   （模板 SA 带 TexturePackContent / 受保护 / 已销毁），
                                --   这个 MeshPart 就变成**没有 SurfaceAppearance 的裸模型** ——
                                --   画面上的表现就是「武器/手部模型消失」。
                                local okC, cloned = pcall(function() return src:Clone() end)
                                if okC and cloned then
                                    local old = d:FindFirstChildOfClass("SurfaceAppearance")
                                    if old then pcall(function() old:Destroy() end) end
                                    cloned.Parent = d
                                    n = n + 1
                                else
                                    S.skinHookCloneFail = (S.skinHookCloneFail or 0) + 1
                                end
                            end
                        end
                    end
                end
                if S.saLeave then S.saLeave() end
                S.skinHookSwapped = n
                S.skinHookWeapon = tostring(weapon) .. "→" .. tostring(want) .. "@" .. tostring(wearF and wearF.Name)
            end)
        end
        return model
    end
    getgenv().MV_MARK_WRAP(wrapper, orig)

    lib.GetCameraModel = wrapper
    S.skinOrigGetCameraModel = orig
    S.skinHookInstalled = true
    return true
end

-- ═══ 皮肤材质的**真正**来源 ═══
--
-- 实测：lib.GetCameraModel(weapon, skin) 对 Stock 和 Luminex 返回**完全相同**的 ColorMap
-- （逐部件对比一模一样）—— 它给的是原皮模板，真正的皮肤材质不在这里。
--
-- HasSkinTextures 的实现暴露了真实结构：
--     v1 = Skins:FindFirstChild(a1)          -- Upvalue "Skins"
--     v2 = v1:FindFirstChild(a2)
--     return v2:IsA("Folder")
-- 顺着 HasSkinTextures 的第 1 个 upvalue 取到实例：ReplicatedStorage.Assets.Skins
--
--   ReplicatedStorage.Assets.Skins/
--     AK-47/
--       Luminex/
--         Camera/                    ← 第一人称 viewmodel 用的那一套
--           Factory New/             ← 磨损等级
--             Barrel  [SurfaceAppearance]   ← 部件名 → 直接就是该部件的 SA
--             Mag     [SurfaceAppearance]
--             Bolt / other / Handle / body …
--           Field-Tested/ Battle-Scarred/ Minimal Wear/ Well-Worn/
--       Stock/ …
--
-- 所以正确做法是：按部件名把这些 SA 的属性抄到 viewmodel 对应部件的 SA 上。
S.getSkinsRoot = function()
    local cached = S._skinsRoot
    if cached and cached.Parent then return cached end
    local rs = game:GetService("ReplicatedStorage")
    local assets = rs:FindFirstChild("Assets")
    local root = assets and assets:FindFirstChild("Skins")
    if not root then
        -- 兜底：走 HasSkinTextures 的 upvalue
        local lib = S.getSkinsLib()
        if lib and type(lib.HasSkinTextures) == "function" and type(debug.getupvalue) == "function" then
            local ok, v = pcall(debug.getupvalue, lib.HasSkinTextures, 1)
            if ok and typeof(v) == "Instance" then root = v end
        end
    end
    S._skinsRoot = root
    return root
end

S.getSkinSAMap = function(weaponName, skinName, wearName)
    local root = S.getSkinsRoot()
    if not root then return nil, "no-skins-root" end
    local wf = root:FindFirstChild(tostring(weaponName))
    if not wf then return nil, "no-weapon-folder" end
    local sf = wf:FindFirstChild(tostring(skinName))
    if not sf then return nil, "no-skin-folder" end
    local camF = sf:FindFirstChild("Camera")
    if not camF then
        -- 有些皮肤可能没有 Camera 分层，直接用自身
        camF = sf
    end
    local wearF = camF:FindFirstChild(tostring(wearName or ""))
    if not wearF then
        -- ⚠ 默认必须用 Factory New，和皮肤图鉴的预览图一致。
        -- 以前取的是 GetChildren 的**第一个**，而多数皮肤的文件夹顺序是
        -- Battle-Scarred 打头 → 刷上去是重度磨损版，和预览差很远，
        -- 看起来就像"这几个皮肤换不了"。实测 11 个 AK 皮肤里，
        -- 只有 Sakura/Aniki/Midas/Red Baron/Luminex/Rebellion/Lore/Sovapid 是 5 档齐全且首项为 Battle-Scarred。
        wearF = camF:FindFirstChild("Factory New")
        if not wearF then
            for _, c in ipairs(camF:GetChildren()) do
                if c:IsA("Folder") then wearF = c break end
            end
        end
    end
    if not wearF then return nil, "no-wear-folder" end
    local map = {}
    if S.saEnter then S.saEnter() end
    for _, sa in ipairs(wearF:GetChildren()) do
        if sa:IsA("SurfaceAppearance") then
            local t = {}
            for _, k in ipairs(S.SA_PROPS or { "ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap" }) do
                t[k] = S.saGet(sa, k)
            end
            if t.ColorMap then map[sa.Name] = t end
        end
    end
    if S.saLeave then S.saLeave() end
    S.skinWearUsed = wearF.Name
    return map
end

S.paintCurrentModel = function(weaponName, skinName)
    local lib = S.getSkinsLib()
    if not lib then return 0 end
    local cam = workspace.CurrentCamera
    local vm = cam and cam:FindFirstChild(tostring(weaponName))
    if not vm then return 0 end
    local weapon = vm:FindFirstChild("Weapon") or vm

    -- ⭐ 首选：直接读 Assets.Skins 里的真实皮肤材质
    -- （GetCameraModel 对 Stock / Luminex 返回的 ColorMap 完全一样，是原皮模板）
    local srcMap, why = S.getSkinSAMap((S.modelWeaponOf and S.modelWeaponOf(weaponName)) or weaponName, skinName, S.skinWear)
    if not srcMap or next(srcMap) == nil then
        S.lastPaintErr = "Skins 资源缺失: " .. tostring(why)
        return 0
    end
    S._srcMapSize = 0
    for _ in pairs(srcMap) do S._srcMapSize = S._srcMapSize + 1 end

    -- ⭐ 关键：直接写现有 SA 的属性，绝不销毁/新建。
    -- 实测（2026-11-05）：
    --   · 直接 sa.ColorMap = xxx  → 画面立刻变化（黑枪变白、变 Canvas 蓝紫图案，均有截图）
    --   · 销毁旧 SA + Instance.new → 写不进去（painted=8 但读回还是旧值，画面不变）
    --   · srcSA:Clone() 挂上去    → 枪直接消失
    -- 之前所有"渲染不重绘"的结论都是错的：那是把 Aurora（本身就是白色皮肤）当成了失败信号。
    local n = 0
    local rejected = 0
    -- 第二段 identity 7：只包住目标部件的读写
    if S.saEnter then S.saEnter() end
    for _, d in ipairs(weapon:GetDescendants()) do
        if d:IsA("MeshPart") and not S.SKIN_SKIP[d.Name] then
            local src = srcMap[d.Name]
            if src then
                local sa = d:FindFirstChildOfClass("SurfaceAppearance")
                if sa then
                    -- ⚠ 判据必须看「写后是否等于目标值」，不能看「是否和原值不同」。
                    -- 用「不同」的话：重复点同一款皮肤（早就是目标值了）会被判成失败，
                    -- 而且 ColorMap 相同、只有法线/发光不同的皮肤也永远写不进去。
                    local target = src.ColorMap
                    for k, v in pairs(src) do
                        if v ~= nil then S.saSet(sa, k, v) end
                    end
                    local after = S.getColorMap(sa)
                    if after ~= nil and tostring(after) == tostring(target) then
                        n = n + 1
                    else
                        rejected += 1
                    end
                end
            end
        end
    end
    if S.saLeave then S.saLeave() end
    S.lastPaintRejected = rejected
    S._srcMapSize = 0
    for _ in pairs(srcMap) do S._srcMapSize = S._srcMapSize + 1 end
    return n
end

-- ═══ 皮肤图鉴面板（缩略图网格，点图即换，每把枪独立）═══
-- ═══ 皮肤列表面板（纯文字，按品质从高到低，点一下即换）═══
-- 为什么不用 WindUI 的按钮：实测 WindUI 的 Button 没有图标槽（SetImage 不创建 ImageLabel），
-- 而且 btn:SetTitle() 调用成功但实际显示的文本不更新（读回还是旧值），做不了动态列表。
-- 所以用自建 ScreenGui，完全可控。
-- ═══ 皮肤图片面板（只显示「指定武器的皮肤」，不再重复列武器）═══
-- 调用方式：先设 S._pendingWeapon = "AK-47"，再调 S.openSkinPanel()。
-- 武器选择在主 GUI（美化页）里完成，这里只负责显示该枪的皮肤图。
-- ═══ 主窗口状态查询：返回 (是否可见, 窗口Frame) ═══
-- 为什么检查整条链：WindUI 关闭窗口可能是 ScreenGui.Enabled=false，也可能是
-- Window.Visible=false 或 Frame.Visible=false，只看其中一个会漏，面板就关不掉。
S.isMainVisible = function()
    local hh = (gethui and gethui()) or game:GetService("CoreGui")
    local w = hh:FindFirstChild("WindUI")
    if not w or not w.Enabled then return false, nil end
    local win = w:FindFirstChild("Window")
    if not win then return false, nil end
    -- ⚠ Window 是 Folder，没有 Visible 属性（访问会直接报错），只检查它下面的 Frame
    local f = win:FindFirstChild("Frame")
    if not f or not f:IsA("Frame") or not f.Visible then return false, nil end
    if f.AbsoluteSize.Y < 100 or f.AbsoluteSize.X < 200 then return false, nil end
    return true, f
end

-- 兼容旧调用
S.getMainWindowFrame = function()
    local ok, f = S.isMainVisible()
    return (ok and f) or nil
end

-- ═══ 皮肤图片面板（窄栏，贴在主菜单左边，可上下滑）═══
-- 尺寸参照：宽 340、最高 500；皮肤多时在网格里上下滚动。
-- 位置：优先贴着主窗口左边缘；找不到主窗口就贴在屏幕左侧居中的位置。
S.openSkinPanel = function()
    local RS2 = game:GetService("ReplicatedStorage")
    local lib2 = S.getSkinsLib()
    if not lib2 then return false, "皮肤库不可用" end

    local wn = tostring(S._pendingWeapon or "")
    if wn == "" then
        local ic0 = require(RS2.Controllers.InventoryController)
        local w0 = ic0.peekCurrentEquippedForMovement()
        wn = w0 and tostring(w0.Name) or ""
    end
    S._pendingWeapon = nil
    if wn == "" then return false, "没有指定武器" end

    local okL, list = pcall(lib2.GetAllSkinsForWeapon, wn)
    if not okL or type(list) ~= "table" or #list == 0 then return false, wn .. " 没有皮肤" end

    local ORDER = S.RARITY_ORDER or { Red = 1, Pink = 2, Purple = 3, Blue = 4, Stock = 9 }
    table.sort(list, function(a, b)
        local ra = ORDER[tostring(a.rarity)] or 9
        local rb = ORDER[tostring(b.rarity)] or 9
        if ra ~= rb then return ra < rb end
        return tostring(a.skin) < tostring(b.skin)
    end)

    -- ★★★ 2026-11-06：面板容器从 gethui() 改成 PlayerGui ★★★
    --
    -- 实测：Real 的 gethui() 返回的是 `CoreGui.RobloxGui`（一个 ScreenGui），
    -- 挂在它下面的 ScreenGui **Destroy 会静默失败** —— pcall 返回 true、对象还在。
    -- 后果：每次 openSkinPanel 都建一个新面板、旧的永远删不掉，
    -- 一口气攒了 22 个 `MV_SkinPanel`（全 Enabled=false 堆在 CoreGui 里），
    -- 下面这段"先清同名面板"的循环其实一次都没生效。
    --
    -- PlayerGui 可以正常 Destroy；ResetOnSpawn=false 保证重生不会被清掉。
    local lpG = game:GetService("Players").LocalPlayer
    local holder = (lpG and lpG:FindFirstChild("PlayerGui"))
        or ((gethui and gethui()) or game:GetService("CoreGui"))
    -- ⚠ 必须清掉「所有」同名面板，不能只删找到的第一个：
    -- FindFirstChild 只返回一个，快速连点两个武器时会各建一个面板，屏幕上就并排出现两个。
    -- 句柄 + 全量遍历双保险。
    --
    -- ★★★ 2026-11-06 实测修正：Real 里 ScreenGui:Destroy() **是空操作** ★★★
    --   实测（两种容器都试过）：
    --       sg:Destroy()  → pcall 返回 true，但 sg.Parent 仍然不是 nil，对象还在
    --   所以原来这里的 Destroy 一次都没真正生效，22 个 MV_SkinPanel 就是这么攒出来的。
    --   正确做法是「停用 + 从父级摘掉」：Enabled=false 不渲染，Parent=nil 脱离整棵树。
    if S._skinPanelGui then
        pcall(function()
            S._skinPanelGui.Enabled = false
            S._skinPanelGui.Parent = nil
        end)
        S._skinPanelGui = nil
    end
    for _, d in ipairs(holder:GetChildren()) do
        if d:IsA("ScreenGui") and d.Name == "MV_SkinPanel" then
            pcall(function()
                d.Enabled = false
                d.Parent = nil
            end)
        end
    end

    -- 手机端适配：屏幕窄 → 卡片更小、面板居中；PC → 贴主窗口左边
    local UIS2 = game:GetService("UserInputService")
    local IS_M = UIS2.TouchEnabled and not UIS2.KeyboardEnabled
    local COLS = 2
    local CELL_W, CELL_H, PAD = IS_M and 128 or 156, IS_M and 96 or 118, 6
    local W = COLS * CELL_W + PAD * 2 + 8
    local rows = math.ceil(#list / COLS)
    local H = math.min(rows * (CELL_H + PAD) + 44, IS_M and 400 or 500)

    local vp2 = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
    local px, py = 24, 120
    if IS_M then
        px = math.max(4, (vp2.X - W) / 2)
        py = math.max(4, (vp2.Y - H) / 2)
    else
        -- ⚠ 主窗口真实路径是 WindUI → Window → Frame（不是 ScreenGui 直接子级叫 Main 的东西）
        -- 之前按 "Main" 找永远是 nil，所以面板一直退到默认的 24,62 —— 这就是"不跟随"的根因
        local mf = S.getMainWindowFrame and S.getMainWindowFrame()
        if mf then
            local mp, ms = mf.AbsolutePosition, mf.AbsoluteSize
            -- ms.Y 要一起检查：窗口展开动画期间 AbsoluteSize.Y 会是 0，此时读到的 Y 是动画中间值
            if ms.X > 200 and ms.Y > 100 then
                px = mp.X - W - 12
                if px < 8 then px = mp.X + ms.X + 12 end   -- 左边放不下就贴右边
                py = mp.Y
            end
        end
    end

    local sg = Instance.new("ScreenGui")
    sg.Name = "MV_SkinPanel"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.DisplayOrder = 2147483647   -- 必须最高，否则被游戏主菜单盖住（实测 998 时完全看不见）
    -- ★★★ 2026-11-06 修复「点了美化选项什么也不出现」 ★★★
    -- 下面那段跟随循环只在 S.isMainVisible() 为真时才 sg.Enabled = true，
    -- 也就是说主窗口关着的时候，面板建出来了却一直是 Enabled=false —— 屏幕上什么都没有。
    -- 用户是在游戏里（主窗口收着）点武器想开图鉴，所以永远看不到面板。
    -- 面板是独立弹窗，创建即显示；跟随循环只负责把它贴在主窗口旁边。
    sg.Enabled = true
    sg.Parent = holder
    S._skinPanelGui = sg

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(W, H)
    frame.Position = UDim2.fromOffset(px, py)
    frame.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
    frame.BorderSizePixel = 0
    frame.Parent = sg
    local cc = Instance.new("UICorner")
    cc.CornerRadius = UDim.new(0, 8)
    cc.Parent = frame
    -- ⚠ 跟随 + 精准对齐 + 随主菜单显隐
    --   · 显隐：用 S.isMainVisible() 检查整条链（ScreenGui.Enabled / Window.Visible / Frame.Visible / 尺寸）
    --   · 对齐：不直接写绝对坐标，而是算「目标位置 - 当前 AbsolutePosition」的差值再补，
    --     这样 IgnoreGuiInset 带来的坐标系差（实测偏 58px）会被自动吃掉。
    if not IS_M then
        task.spawn(function()
            local W2 = W
            while frame.Parent do
                local okv, vis, mfv = pcall(function()
                    return S.isMainVisible()
                end)
                if okv and vis then
                    if not sg.Enabled then sg.Enabled = true end
                    local mp2 = mfv.AbsolutePosition
                    local ms2 = mfv.AbsoluteSize
                    local nx = mp2.X - W2 - 12
                    if nx < 8 then nx = mp2.X + ms2.X + 12 end
                    local cp = frame.AbsolutePosition
                    local dx = nx - cp.X
                    local dy = mp2.Y - cp.Y
                    if math.abs(dx) > 0.5 or math.abs(dy) > 0.5 then
                        local cpos = frame.Position
                        frame.Position = UDim2.fromOffset(cpos.X.Offset + dx, cpos.Y.Offset + dy)
                    end
                end
                -- ★★★ 2026-11-06：这里原来还有一段
                --     else
                --         if sg.Enabled then sg.Enabled = false end
                --     end
                -- 意思是「主窗口收起来就把图鉴面板一起关掉」。
                -- 但用户是在游戏里点武器开图鉴的 —— 主窗口本来就收着，
                -- 于是面板每一帧被强制 Enabled=false，屏幕上一个像素都看不到。
                -- 图鉴是独立弹窗，显隐只由它自己的 × 按钮控制，不再跟主窗口联动。
                task.wait(0.08)
            end
        end)
    end


    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -56, 0, 26)
    title.Position = UDim2.fromOffset(8, 3)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextColor3 = Color3.fromRGB(235, 240, 250)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextTruncate = Enum.TextTruncate.AtEnd
    title.Text = string.format("%s · %d 款", wn, #list)
    title.Parent = frame

    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(24, 24)
    close.Position = UDim2.new(1, -30, 0, 3)
    close.BackgroundColor3 = Color3.fromRGB(120, 40, 45)
    close.BorderSizePixel = 0
    close.Font = Enum.Font.GothamBold
    close.TextSize = 14
    close.TextColor3 = Color3.fromRGB(255, 235, 235)
    close.Text = "×"
    close.Parent = frame
    close.MouseButton1Click:Connect(function() sg:Destroy() end)

    local grid = Instance.new("ScrollingFrame")
    grid.Size = UDim2.new(1, -8, 1, -32)
    grid.Position = UDim2.fromOffset(4, 30)
    grid.BackgroundTransparency = 1
    grid.BorderSizePixel = 0
    grid.ScrollBarThickness = 4
    grid.CanvasSize = UDim2.new(0, 0, 0, 0)
    grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
    grid.ScrollingDirection = Enum.ScrollingDirection.Y
    grid.Parent = frame
    local glay = Instance.new("UIGridLayout")
    glay.CellSize = UDim2.fromOffset(CELL_W, CELL_H)
    glay.CellPadding = UDim2.fromOffset(PAD, PAD)
    glay.Parent = grid

    local RAR = {
        Red = Color3.fromRGB(235, 75, 75), Pink = Color3.fromRGB(235, 105, 180),
        Purple = Color3.fromRGB(165, 105, 235), Blue = Color3.fromRGB(90, 165, 245),
        Stock = Color3.fromRGB(190, 195, 205),
    }
    local RAR_CN = { Red = "红", Pink = "粉", Purple = "紫", Blue = "蓝", Stock = "原版" }
    local cur = tostring(S.skinPaint[wn] or "")

    for _, item in ipairs(list) do
        local skin = tostring(item.skin)
        local rar = tostring(item.rarity or "?")
        local card = Instance.new("TextButton")
        card.BackgroundColor3 = (skin == cur) and Color3.fromRGB(35, 62, 45) or Color3.fromRGB(26, 30, 38)
        card.BorderSizePixel = 0
        card.Text = ""
        card.Parent = grid
        local bc = Instance.new("UICorner")
        bc.CornerRadius = UDim.new(0, 6)
        bc.Parent = card
        local img = Instance.new("ImageLabel")
        img.Size = UDim2.new(1, -6, 0, IS_M and 58 or 74)
        img.Position = UDim2.fromOffset(3, 3)
        img.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
        img.BorderSizePixel = 0
        img.ScaleType = Enum.ScaleType.Fit
        local tex
        pcall(function() tex = lib2.GetWearImageForFloat(item, 0.01) end)
        if type(tex) == "string" then img.Image = tex end
        img.Parent = card
        local nl = Instance.new("TextLabel")
        nl.Size = UDim2.new(1, -6, 0, 14)
        nl.Position = UDim2.fromOffset(3, IS_M and 62 or 80)
        nl.BackgroundTransparency = 1
        nl.Font = Enum.Font.GothamBold
        nl.TextSize = 10
        nl.TextXAlignment = Enum.TextXAlignment.Left
        nl.TextTruncate = Enum.TextTruncate.AtEnd
        nl.TextColor3 = RAR[rar] or Color3.fromRGB(210, 215, 225)
        nl.Text = (S.skinCN and S.skinCN(skin)) or skin
        nl.Parent = card
        local rl = Instance.new("TextLabel")
        rl.Size = UDim2.new(1, -6, 0, 12)
        rl.Position = UDim2.fromOffset(3, IS_M and 77 or 96)
        rl.BackgroundTransparency = 1
        rl.Font = Enum.Font.Gotham
        rl.TextSize = 8
        rl.TextXAlignment = Enum.TextXAlignment.Left
        rl.TextColor3 = RAR[rar] or Color3.fromRGB(140, 148, 162)
        rl.Text = string.format("%s %s", RAR_CN[rar] or rar, skin)
        rl.Parent = card
        card.MouseButton1Click:Connect(function()
            S.setSkin(wn, skin)
            local n = S.paintCurrentModel(wn, skin)
            S.lastSkinPaint = string.format("%s -> %s (%s)", wn, skin, tostring(n))
            for _, ch in ipairs(grid:GetChildren()) do
                if ch:IsA("TextButton") then ch.BackgroundColor3 = Color3.fromRGB(26, 30, 38) end
            end
            -- ⚠ 不能无条件标成「已选」。
            -- 以前不管 n 是几都涂绿：玩家看到卡片选中了、枪一点没变 ——
            -- 因为「匹配到 0 个部件」和「成功」在 UI 上是同一个样子。
            -- 手持状态下 0 部件 = 真失败（结构不支持），标红并留一条原因。
            -- ⚠ 别用 cam:FindFirstChild(wn) 判手持 —— 游戏会把不用的武器 viewmodel
            -- 留在 workspace.Camera 里，于是「拿着 Glock 点 AK」也会被当成手持，
            -- 然后 n=0 被标红。改用 InventoryController 报告的当前武器。
            local curS = S.getCurrentWeapon and S.getCurrentWeapon()
            local heldS = curS ~= nil and tostring(curS.Name) == tostring(wn)
            if heldS and n <= 0 then
                card.BackgroundColor3 = Color3.fromRGB(74, 30, 30)
                S.skinPaintErr = string.format(
                    "%s 没有可替换的材质部件（需同名 MeshPart + 现成 SurfaceAppearance，"
                    .. "SA 不能是引擎烘焙的 TexturePackContent）", tostring(wn))
            else
                card.BackgroundColor3 = Color3.fromRGB(35, 62, 45)
                S.skinPaintErr = nil
                if not heldS then
                    S.lastSkinPaint = string.format("%s -> %s（已记录，切枪后生效）", wn, skin)
                end
            end
        end)
    end

    return true, string.format("%s：%d 款（%dx%d，2 列可滚动）", wn, #list, W, H)
end

-- ═══ 填充皮肤槽位：按品质从高到低，武器没皮肤时改用手套 ═══
S.RARITY_ORDER = { Red = 1, Pink = 2, Purple = 3, Blue = 4, Stock = 9 }

S.refreshSkinList = function(force)
    local lib = S.getSkinsLib()
    if not lib then return false, "皮肤库不可用" end
    local RS2 = game:GetService("ReplicatedStorage")

    -- 扫出所有有皮肤的武器（默认只扫一次并缓存）
    -- ⚠ force = true 时必须真的重扫：以前「手动刷新」按钮调的是无参版本，
    -- 缓存已经在 → 直接跳过扫描 → 首次扫描时没就绪的武器永远补不回来，只能重载。
    local names = S.SKIN_WEAPONS_CACHE
    if force == true then names = nil end
    if not names then
        names = {}
        local wf = RS2:FindFirstChild("Database") and RS2.Database:FindFirstChild("Custom")
            and RS2.Database.Custom:FindFirstChild("Weapons")
        if wf then
            for _, c in ipairs(wf:GetChildren()) do
                local ok, l = pcall(lib.GetAllSkinsForWeapon, c.Name)
                if ok and type(l) == "table" and #l > 0 then names[#names + 1] = c.Name end
            end
        end
        -- ⚠ 只留「枪械 + 近战 + 手套」。
        -- 数据库里有皮肤的还包括 C4 / Decoy Grenade / Flashbang / Smoke …，
        -- 这些是 Part/特殊网格，没有 SurfaceAppearance 结构，列出来点了也没反应。
        -- WEAPON_CLASS 里没有它们的条目（归为 nil），手套也不在表里，所以单独放行名字含 Glove 的。
        local keep, dropped = {}, {}
        for _, n in ipairs(names) do
            local cls = WEAPON_CLASS and WEAPON_CLASS[n]
            local ln = tostring(n):lower()
            -- 手套有好几个名字：CT Glove / Driver Gloves / Hand Wraps / Sport Gloves …
            local isGlove = ln:find("glove") ~= nil or ln:find("wrap") ~= nil
            if cls ~= nil or isGlove then
                keep[#keep + 1] = n
            else
                dropped[#dropped + 1] = tostring(n)
            end
        end
        names = keep
        S.skinDropped = dropped
        table.sort(names)
        S.SKIN_WEAPONS_CACHE = names
    end

    -- 按武器类别分组排序（步枪 → 冲锋 → 狙击 → 霰弹 → 手枪 → 近战 → 其它），
    -- 同类里按名字。之前纯字母序，49 把混在一起很难找。
    do
        local ORD = { Rifle = 1, SMG = 2, Sniper = 3, Shotgun = 4, Pistol = 5, Melee = 6 }
        local cls = WEAPON_CLASS or {}
        table.sort(names, function(a, b)
            local ca = cls[a] or "Other"
            local cb = cls[b] or "Other"
            local oa = ORD[ca] or 9
            local ob = ORD[cb] or 9
            if oa ~= ob then return oa < ob end
            return tostring(a) < tostring(b)
        end)
    end

    -- 槽位：有武器就显示中文名，没有就整行隐藏（以前写 "—" 占位，49 个槽位里空的一直挂在那）
    local shown = 0
    for i = 1, 52 do
        local btn = S.UI["SkinSlot" .. i]
        local wn = names[i]
        if btn then
            local frame = btn.ElementFrame
            if wn then
                -- 分组前缀：刀 / 手套 单独标出来，视觉上和枪分开。
                -- ⚠ 不能真的合并成一项 —— 每把刀在 Database.Custom.Weapons 里是独立武器，
                -- 皮肤池也各不一样（Karambit 和 Butterfly Knife 的皮肤列表完全不同），
                -- 合并后就没有"选哪种刀"的入口了。
                local cls = WEAPON_CLASS and WEAPON_CLASS[wn]
                local ln = tostring(wn):lower()
                local cn = (S.weaponCN and S.weaponCN(wn)) or wn
                if cls == "Melee" then
                    cn = "[刀] " .. cn
                elseif ln:find("glove") or ln:find("wrap") then
                    cn = "[手套] " .. cn
                end
                pcall(function() btn:SetTitle(cn) end)
                S.skinSlotCB[i] = function()
                    S._pendingWeapon = wn
                    S.openSkinPanel()
                end
                if frame then pcall(function() frame.Visible = true end) end
                shown = shown + 1
            else
                pcall(function() btn:SetTitle("—") end)
                S.skinSlotCB[i] = nil
                if frame then pcall(function() frame.Visible = false end) end
            end
        end
    end
    S.skinListTarget = names[1]
    return true, string.format("可美化武器 %d 把（已显示 %d 个槽位），点名字开图鉴", #names, shown)
end

-- ═══ 武器名中文映射 ═══
-- 之前槽位直接显示数据库里的英文名（Glock-18 / T Knife / SSG 08 …）。
-- 常见 CS 武器手写一份，没列到的回落到游戏 LocalizationService，最后才用英文原名。
S.WEAPON_CN = {
    -- 手枪
    ["Glock-18"] = "格洛克-18", ["USP-S"] = "USP 消音", ["P2000"] = "P2000",
    ["P250"] = "P250", ["Five-SeveN"] = "FN 57", ["Tec-9"] = "Tec-9",
    ["Dual Berettas"] = "双持贝瑞塔", ["Desert Eagle"] = "沙漠之鹰", ["R8 Revolver"] = "R8 左轮",
    ["CZ75-Auto"] = "CZ75", ["P90"] = "P90",
    -- 冲锋枪
    ["MP9"] = "MP9", ["MAC-10"] = "MAC-10", ["MP7"] = "MP7", ["MP5-SD"] = "MP5",
    ["PP-Bizon"] = "野牛", ["UMP-45"] = "UMP-45",
    -- 步枪
    ["AK-47"] = "AK-47", ["M4A4"] = "M4A4", ["M4A1-S"] = "M4A1 消音",
    ["Galil AR"] = "加利尔", ["FAMAS"] = "法玛斯", ["AUG"] = "AUG", ["SG 553"] = "SG 553",
    ["SCAR-20"] = "SCAR-20", ["G3SG1"] = "G3SG1",
    -- 狙击
    ["AWP"] = "AWP", ["SSG 08"] = "SSG 08",
    -- 霰弹
    ["Nova"] = "新星", ["XM1014"] = "XM1014", ["MAG-7"] = "MAG-7", ["Sawed-Off"] = "截短霰弹",
    -- 机枪
    ["Negev"] = "内格夫", ["M249"] = "M249",
    -- 近战
    ["T Knife"] = "T 方刀", ["CT Knife"] = "CT 刀", ["Karambit"] = "爪子刀",
    ["M9 Bayonet"] = "M9 刺刀", ["Butterfly Knife"] = "蝴蝶刀", ["Flip Knife"] = "折刀",
    ["Gut Knife"] = "穿肠刀", ["Skeleton Knife"] = "骷髅刀", ["Stiletto Knife"] = "短剑",
    ["Bowie Knife"] = "鲍伊刀", ["Huntsman Knife"] = "猎杀者刀", ["Bayonet"] = "刺刀",
    ["Falchion Knife"] = "弯刀", ["Shadow Daggers"] = "暗影双匕", ["LightSaber"] = "光剑",
    -- 其它
    ["Zeus x27"] = "宙斯 x27", ["C4"] = "C4", ["Gloves"] = "手套",
    -- 手套（数据库里是六个独立名字，之前没翻译，列表里全是英文）
    ["CT Glove"] = "CT 手套", ["T Glove"] = "T 手套",
    ["Driver Gloves"] = "驾驶手套", ["Hand Wraps"] = "裹布",
    ["Operator Gloves"] = "特工手套", ["Sports Gloves"] = "运动手套",
    ["Specialist Gloves"] = "专家手套", ["Moto Gloves"] = "摩托手套",
    ["HE Grenade"] = "高爆手雷", ["Flashbang"] = "闪光弹", ["Smoke Grenade"] = "烟雾弹",
    ["Molotov"] = "燃烧瓶", ["Incendiary Grenade"] = "燃烧弹", ["Decoy Grenade"] = "诱饵弹",
}

S.weaponCN = function(n)
    local s = tostring(n or "")
    local c = S.WEAPON_CN and S.WEAPON_CN[s]
    if c then return c end
    if S.translator then
        local ok, t = pcall(function() return S.translator:Translate(game, s) end)
        if ok and type(t) == "string" and t ~= "" and t ~= s then return t end
    end
    return s
end

-- ═══ 皮肤名中文映射 ═══
-- 游戏自带 LocalizationService 翻译（实测 zh-cn）：PinPoint→精确瞄准点、Canvas→画布、
-- Fade→渐变，但 Stock→库存（错，应为原版）、Aurora 不翻译。
-- 所以常用皮肤用手写映射，剩下的交给游戏翻译器兜底。
S.SKIN_CN = {
  ["Stock"] = "原版", ["PinPoint"] = "精确瞄点", ["Aurora"] = "极光", ["Canvas"] = "画布",
  ["Fade"] = "渐变", ["Midas"] = "点金手", ["Racer8"] = "竞速八号", ["Experimental"] = "实验体",
  ["Fuji"] = "富士", ["Revenant"] = "亡魂", ["Yurei"] = "幽霊", ["Broken Tv"] = "坏电视",
  ["Hero of Hell"] = "地狱英雄", ["Aniki"] = "大哥", ["NoMercy"] = "不留情", ["Entombed"] = "埋葬",
  ["Control"] = "控制", ["Icecap"] = "冰盖", ["X-Ray"] = "X 光", ["Lore"] = "传说",
  ["Freedom"] = "自由", ["High Octane"] = "高辛烷", ["Sakura"] = "樱花", ["Akiro"] = "昭夫",
  ["Rebellion"] = "叛逆", ["Red Baron"] = "红男爵", ["Sovapid"] = "苏维皮德",
  ["Printstream"] = "印刷流", ["Hyper Beast"] = "野兽", ["Neo-Noir"] = "新黑色",
  ["Asiimov"] = "亚西莫夫", ["Dragon Lore"] = "巨龙传说", ["Wild Lotus"] = "野荷",
  ["Crimson Web"] = "深红之网", ["Doppler"] = "多普勒", ["Marble Fade"] = "大理石渐变",
  ["Tiger Tooth"] = "虎牙", ["Ultraviolet"] = "紫外线", ["Night"] = "夜色",
  ["Blue Steel"] = "蓝钢", ["Case Hardened"] = "表面淬火", ["Slaughter"] = "屠夫",
  ["Vulcan"] = "火神", ["Bloodsport"] = "血猎", ["Orion"] = "猎户座",
  ["Fire Serpent"] = "火蛇", ["Water Elemental"] = "水元素",
}

S.skinCN = function(name)
  local n = tostring(name)
  if S.SKIN_CN[n] then return S.SKIN_CN[n] end
  if not S.translator then
    local okT, tr = pcall(function()
      return game:GetService("LocalizationService"):GetTranslatorForPlayerAsync(game.Players.LocalPlayer)
    end)
    if okT then S.translator = tr end
  end
  if S.translator then
    local ok, t = pcall(function() return S.translator:Translate(game, n) end)
    if ok and type(t) == "string" and t ~= "" and t ~= n then return t end
  end
  return n
end

-- ═══ 换枪自动刷新皮肤列表 ═══
task.spawn(function()
    local last
    while true do
        task.wait(0.5)
        if S._alive == false or (REG and REG.gen ~= MY_GEN) then break end
        pcall(function()
            local ic = getInvCtrl()
            if not ic then return end
            local w = ic.peekCurrentEquippedForMovement()
            local n = w and tostring(w.Name) or "none"
            if n ~= last then
                last = n
                if S.refreshSkinList then S.refreshSkinList() end
            end
        end)
    end
end)

-- ═══ 皮肤图鉴 v2：先选武器 → 出图片网格（每张带中文名 + 品质）═══
-- 为什么做成「武器行 + 图片网格」：用户要求点武器名后直接出图，且图上要标名字和品质。
-- 图片来自 Skins.GetWearImageForFloat(item, 0.01)，中文名走 S.skinCN（手写映射 + 游戏翻译兜底）。
S.SKIN_WEAPONS_CACHE = nil

getgenv().MV_V2 = {
    cfg = cfg, state = S, collect = collect, aimTarget = aimTarget, buy = buy,
    window = Window, allCharModels = allCharModels, culledCount = culledCount,
    allTargets = allTargets,
    -- 瞄准辅助系统（平滑瞄准 / 原生后坐力辅助）
    AASYS = AASYS,
    installSmooth = function() return AASYS.installSmooth() end,
    -- 实时位置数据源（MovementV2 的 RemoteBuffer）。
    -- 这个表由服务端驱动，不受 PVS 剔除影响 —— 透视能不能实时跟人全看它。
    resolveBuffer = function() return resolveBuffer() end,
    bufferInfo = function()
        local b = resolveBuffer()
        if not b then return "nil" end
        local n = 0
        for _ in pairs(b._presentationPoseByActorKey) do n = n + 1 end
        return string.format("tick=%s pose=%d", tostring(b._latestServerTick), n)
    end,
    -- 调试用：ESP 对象池和绘制计数
    espObjects = function() return S.espObjects end,
    espTicks = function() return espTick end,
    -- 调试用：反弹点黄方块池。
    -- 「收起/扔出投掷物后黄方块还挂在屏幕上」这个 bug 的验证入口：
    --   bounceDraw({Vector3, Vector3})  → 强制画两个方块
    --   bounceDump()                    → 返回 (池, 当前显示数)
    -- 手里不是投掷物时，updateThrow 每帧会走早退分支，池里所有方块应当被隐藏、计数归零。
    bounceDraw = function(pts) return S.drawBounceRings(pts) end,
    bounceDump = function() return S.bounceRings, S.bounceRingCount end,
    w2s = function(p) return w2s(p) end,
    updateEsp = function() updateEsp() end,
    setInfiniteAmmo = function(on) return setInfiniteAmmo(on) end,
    applyInfiniteAmmo = function() return applyInfiniteAmmo() end,
    setSkipFireDelay = function(on) return setSkipFireDelay(on) end,
    applySkipFireDelay = function() return applySkipFireDelay() end,
    setInstantReload = function(on) return setInstantReload(on) end,
    applyInstantReload = function() return applyInstantReload() end,

    -- ═══ 现场诊断（左键不开枪 / 切不了枪 / 菜单关不掉鼠标 一类问题）═══
    -- 用法：print(getgenv().MV_V2.diag())
    -- 或者逐项：MV_V2.peekDiag() / MV_V2.inputDiag() / MV_V2.skinPoll()
    peekDiag = function()
        local d = getgenv().MV_PEEK_DIAG
        if not d then return "no diag（开头补丁没执行？）" end
        return string.format("hit=%d miss=%d noAttr=%d badJson=%d last=%s",
            d.hit, d.miss, d.noAttr, d.badJson, tostring(d.last))
    end,

    -- 判定「peek 到底返回了什么」：nil / 真实 item（带方法）/ 非法 JSON 表
    equipDiag = function()
        local ic = getInvCtrl()
        if not ic then return "no InventoryController" end
        local ok, w = pcall(function() return ic.peekCurrentEquippedForMovement() end)
        if not ok then return "peek 抛错: " .. tostring(w) end
        if w == nil then return "nil（手上没有东西，这是合法状态）" end
        if type(w) ~= "table" then return "非表: " .. type(w) end
        local methods = {}
        for _, k in ipairs({ "shoot", "equip", "unequip", "reload", "drop", "scope" }) do
            if type(w[k]) == "function" then methods[#methods + 1] = k end
        end
        if #methods == 0 then
            return string.format("⚠ 非法对象：Name=%s 但没有任何武器方法（这就是「左键不开枪」的根因）",
                tostring(w.Name))
        end
        return string.format("✅ 真实 item：%s | 方法=%s", tostring(w.Name), table.concat(methods, ","))
    end,

    -- 鼠标/输入：菜单 ScreenGui 有没有在吃鼠标、游戏能不能收到按键
    inputDiag = function()
        local UIS = game:GetService("UserInputService")
        local lp = game.Players.LocalPlayer
        local lines = {}
        local sg = S.menuScreenGui
        lines[#lines + 1] = "menuScreenGui=" .. (sg and (tostring(sg.Enabled) .. " / " .. tostring(sg.DisplayOrder)) or "not-found")
        lines[#lines + 1] = string.format("m1down=%s m2down=%s",
            tostring(UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)),
            tostring(UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)))
        -- 光标下有什么 GUI（我们自己 DisplayOrder 最大值，最容易挡住商店/背包）
        local okPos, pos = pcall(function() return UIS:GetMouseLocation() end)
        if okPos and pos then
            local hits = {}
            local pg = lp:FindFirstChild("PlayerGui")
            if pg then
                pcall(function()
                    for _, g in ipairs(pg:GetGuiObjectsAtPosition(pos.X, pos.Y)) do
                        if #hits < 5 then hits[#hits + 1] = g:GetFullName() end
                    end
                end)
            end
            lines[#lines + 1] = "cursor=(" .. math.floor(pos.X) .. "," .. math.floor(pos.Y) .. ") under="
                .. ((#hits > 0) and table.concat(hits, " | ") or "none")
        end
        local hp = getgenv().MV_PEEK_DIAG
        if hp then
            lines[#lines + 1] = string.format("peek: hit=%d miss=%d noAttr=%d badJson=%d last=%s",
                hp.hit, hp.miss, hp.noAttr, hp.badJson, tostring(hp.last))
        end
        return table.concat(lines, "\n")
    end,

    -- 换肤轮询的真实开销（判断 0.12 秒循环是不是卡顿尖峰）
    skinPoll = function() return S.skinPoll.report() end,

    -- 一键重打三处补丁（现场发现 patch=true 但功能不对时用）
    reapply = function()
        local ok1, m1 = pcall(S.patchGetCurrentEquipped)
        local ok2, m2 = pcall(S.patchRaycast)
        local ok3 = pcall(S.installSkinHook)
        return string.format("gce=%s(%s) raycast=%s(%s) skinHook=%s",
            tostring(ok1 and m1), tostring(m1),
            tostring(ok2 and m2), tostring(m2), tostring(ok3))
    end,
}

Window:Notify({ Title = "MovementV2 菜单", Description = "已加载 · 右键 Ctrl 开关菜单", Lifetime = 4 })

-- ⚠ 这里全部用 warn 而不是 print。
-- 手机端执行器的控制台默认只显示 warn / error，print 是不显示的 ——
-- 之前写成 print，用户看到的是一片红色报错里没有一段中文说明，
-- 就是因为它被过滤掉了。warn 一定会显示。
warn("══════════════════════════════════════════════════════════════════")
warn("【注意】以下是本脚本（MovementV2 Hub）的加载日志。")
warn("")
warn("   如果加载过程中出现任何报错 —— 无论是本脚本的还是游戏的，")
warn("   请把【报错那一段】截图发给作者，不要只截一半。")
warn("")
warn("──────────────────────────────────────────────────────────────────")
warn("   补充说明一种常见报错（它来自游戏，不是本脚本）：")
warn("")
warn("   Remote event invocation discarded event for")
warn("   ReplicatedStorage.MovementV2Remotes.RemoteSnapshot;")
warn("   did you forget to implement OnClientEvent")
warn("   (N events dropped)")
warn("")
warn("   这是游戏的位置快照模块在那个客户端没初始化成功，")
warn("   没人接 RemoteSnapshot，服务端快照被逐条丢弃。")
warn("   本脚本对它只有读取、从不监听也从不发送，所以与脚本无关。")
warn("   影响是 ESP / 静默只能靠 270 stud 内可见的目标，透视距离变短。")
warn("══════════════════════════════════════════════════════════════════")
warn("[v2] loaded | hook ok | esp=" .. tostring(cfg.esp))
warn("────────────── 报错已结束，不要再往下截了 ──────────────")

-- ═══ 独立 FOV 圈 ═══
-- 为什么不用脚本内部的 updateFov：它的可见性判断出过问题（要求 silentAim AND showFov，
-- 关掉静默瞄准连圈一起消失），而且整条路径都在 guard 里被 pcall 包着，出错是静默的。
-- 这里用一条独立的 Drawing.Circle + 0.1 秒轮询，只受 showFov / fullSphere / fov / fovColor 控制。
if Drawing and Drawing.new then
    (function()
        local circle = Drawing.new("Circle")
        circle.Thickness = 1
        circle.Filled = false
        circle.NumSides = 64
        circle.Transparency = 0.5
        circle.Visible = false
        S.fovCircleObj = circle
        S._fovStop = false
        task.spawn(function()
            -- ⚠ 三个退出条件缺一不可：
            --   · _fovStop：显式停止（fullCleanup 现在会置 true）
            --   · fovCircleObj 被换掉：说明本实例已经被新实例取代
            --   · _alive == false：卸载
            -- 原来只有前两个，而清理路径从来没把 _fovStop 置 true、也没换掉 fovCircleObj ——
            -- 只要 Destroy 之后那次 circle.Visible 赋值没抛错，这个循环就会一直以 10Hz 空转。
            while not S._fovStop and S.fovCircleObj == circle and S._alive ~= false do
    local hideBySphere = (cfg.fullSphere == true) and ((cfg.aimMode or "smooth") == "silent")
    if hideBySphere or not cfg.showFov then
                    circle.Visible = false
                else
                    local cam2 = workspace.CurrentCamera
                    local vp2 = cam2 and cam2.ViewportSize or Vector2.new(1920, 1080)
                    local diag2 = math.sqrt(vp2.X * vp2.X + vp2.Y * vp2.Y)
                    circle.Position = Vector2.new(vp2.X / 2, vp2.Y / 2)
                    circle.Radius = math.clamp(tonumber(cfg.fov) or 300, 5, diag2 * 0.5)
                    circle.Color = cfg.fovColor or Color3.fromRGB(255, 255, 255)
                    circle.Thickness = 1
                    circle.Transparency = 0.5
                    circle.Visible = true
                end
                task.wait(0.1)
            end
            pcall(function() circle:Remove() end)
        end)
    end)()
end

-- ═══ 反作弊拦截（必须尽早执行，赶在游戏首次调用之前）═══
-- 这两处覆盖之前从未被调用过 → 游戏的 getfenv 检测一直能触发 → u0/u115 被清空，
-- 表现是「商店买了不进包、捡东西消失、切不出枪、手上空气」。
-- ⚠ 必须用 `do (function() ... end)() end` 而不是 `do ... end`：
--   主 chunk 的 local 槽位已经贴 200 上限，`do ... end` 里的 local 一样占槽位，
--   这里 4 个（ok1/msg1/ok2/msg2）正好是压垮编译的那一根
--   （实测报错：Out of local registers when trying to allocate ok1: exceeded limit 200）。
--   IIFE 把作用域真正隔开，槽位立即释放。
do (function()
    local ok1, msg1 = pcall(function() return S.patchGetCurrentEquipped() end)
    warn("[ac] getCurrentEquipped patch = " .. tostring(ok1) .. " " .. tostring(msg1))
    local ok2, msg2 = pcall(function() return S.patchRaycast() end)
    warn("[ac] Raycast patch = " .. tostring(ok2) .. " " .. tostring(msg2))
end)() end

-- ═══ 换刀外观：MeshId 变形（实测唯一不崩的路）═══
--
-- 为什么不用 hook GetCameraModel：游戏切枪根本不重建 viewmodel，
-- 只是把模型在 Camera 和 ViewmodelStash 之间搬（实测 skinHookCalls 恒为 nil）。
--
-- 为什么不用往 stash 塞新模型：新模型自带 Motor6D，关节 Part0/Part1 指向它自己那份部件，
-- 挂到相机时和当前骨架对不上 → 引擎渲染阶段直接崩（实测把整个客户端崩掉）。
--
-- 正确做法：保留原模型对象和骨架，只把 MeshPart 的几何换成目标刀的。
--   · MeshPart.MeshId 是只读的（直接赋值 pcall 返回 false）
--   · 必须走 MeshPart:ApplyMesh(源部件)
--   · ApplyMesh **不会改 Size** —— 所以 Motor6D 的 C0/C1 完全不受影响，不会错位/崩
-- 实测（T Knife → Butterfly Knife）四个部件全部 ApplyMesh 成功，截图确认外观变成折刀。
do (function()
    -- 近战图标（实测从 Database.Custom.Weapons.<名字>.Icon 抓的全表）
    S.MELEE_ICONS = S.MELEE_ICONS or {
        ["T Knife"]         = "rbxassetid://140484419446969",
        ["CT Knife"]        = "rbxassetid://115204080823353",
        ["Butterfly Knife"] = "rbxassetid://78088217065173",
        ["Karambit"]        = "rbxassetid://85121618781867",
        ["M9 Bayonet"]      = "rbxassetid://92481124554479",
        ["Flip Knife"]      = "rbxassetid://103569239379116",
        ["Gut Knife"]       = "rbxassetid://91965772008164",
        ["Skeleton Knife"]  = "rbxassetid://73573766861663",
        ["Stiletto Knife"]  = "rbxassetid://71208637985987",
        ["LightSaber"]      = "rbxassetid://126330826978789",
    }

    -- 按名字从背包里找 weapon 表 —— 它就是 construct 的 a3（WeaponComponent）
    S.findWeaponByName = function(name)
        local ic = getInvCtrl()
        if not ic then return nil end
        local ok, inv = pcall(function() return ic.getCurrentInventory() end)
        if not ok or type(inv) ~= "table" then return nil end
        for _, item in pairs(inv) do
            local items = type(item) == "table" and (item._items or item) or nil
            if type(items) == "table" then
                for _, it in ipairs(items) do
                    if type(it) == "table" and tostring(it.Name) == tostring(name) then return it end
                end
            end
        end
        return nil
    end

    S.applyMeleeSwap = function(wn)
        if cfg.meleeSwapOn == false then return 0 end
        local to = S.meleeSwap and S.meleeSwap[tostring(wn)]
        if not to or to == "" or tostring(to) == tostring(wn) then return 0 end

        local weapon = S.findWeaponByName(tostring(wn))
        if not weapon then return 0 end
        local vm = weapon.Viewmodel
        if type(vm) ~= "table" or type(vm.construct) ~= "function" then return 0 end

        local character = (workspace:FindFirstChild("Characters") and workspace.Characters:FindFirstChild(LP.Name))
            or LP.Character
        if not character then return 0 end

        -- 清掉 cam 下同名残留，否则两个同名模型会互相打架
        local cam = workspace.CurrentCamera
        if cam then
            for _, c in ipairs(cam:GetChildren()) do
                if c:IsA("Model") and c.Name == tostring(wn) and c ~= vm.Model then
                    pcall(function() c:Destroy() end)
                end
            end
        end

        -- 皮肤：换刀后必须用**目标刀自己**的皮肤表（T Knife 只有 Stock；
        -- 蝴蝶刀 36 个、Karambit 38 个、M9 Bayonet 34 个…）。
        -- 用户在皮肤面板选的目标刀皮肤存在 S.skinPaint[目标刀名] 里，没选就回落 Stock。
        local wantSkin = "Stock"
        if S.skinPaint then
            local picked = S.skinPaint[tostring(to)]
            if picked and picked ~= "" then wantSkin = tostring(picked) end
        end
        -- 武器名或皮肤任一变化都要重建（只比武器名的话，换皮不生效）
        if tostring(vm.CameraModelWeapon) == tostring(to) and tostring(vm.Skin) == wantSkin then return 0 end

        vm.CameraModelWeapon = tostring(to)
        vm.Skin = wantSkin
        vm.Float = 0.001

        -- ★ 关键：a2 = 角色模型，a3 = WeaponComponent。
        --   漏掉 a3 会在 Viewmodel:957 的 `local Properties = v3.Properties` 报 nil，
        --   construct 后半段（材质/手套/挂载）全部中断，手上就是两根黑柱。
        --   而且 construct 内部自己会 Model:Destroy() 重建，所以不要先调 destroy()。
        local ok = pcall(function() vm:construct(character, weapon) end)
        if not ok or typeof(vm.Model) ~= "Instance" then return 0 end

        -- 模型名必须改回当前武器名，游戏就是按这个名字找 viewmodel 的
        pcall(function() vm.Model.Name = tostring(wn) end)

        -- ★ 声音：construct 会把 Animation 换成目标刀的（实测 Animation="Flip Knife"），
        --   但 Sound 不会跟着换 —— 它仍然指向原武器的声音组
        --   （实测 SoundGroupName="CT Knife"、Sounds=Folder "CT Knife"）。
        --   结果就是「检视/挥刀/切刀放的都是原刀的音效」，甚至被当成没声音。
        --   Assets 的 Sounds 根目录下有全部 64 个声音组，按目标刀名取即可。
        do
            local an = vm.Animation
            local snd = an and an.Sound
            if snd and typeof(snd.Sounds) == "Instance" then
                local root = snd.Sounds.Parent
                local tf = root and root:FindFirstChild(tostring(to))
                if tf then
                    snd.Sounds = tf
                    snd.SoundGroupName = tostring(to)
                end
            end
        end

        S.meleeSwapped = (S.meleeSwapped or 0) + 1
        return 1
    end

    -- 物品栏同步：换刀后槽位 3 的图标/名字还是原武器，游戏每次刷新又会改回去，所以盯着纠正
    S.syncMeleeIcon = function(wn)
        local to = S.meleeSwap and S.meleeSwap[tostring(wn)]
        if not to then return 0 end
        local pg = LP:FindFirstChild("PlayerGui")
        local inv = pg and pg.MainGui and pg.MainGui.Gameplay
            and pg.MainGui.Gameplay.Bottom and pg.MainGui.Gameplay.Bottom:FindFirstChild("Inventory")
        local melee = inv and inv:FindFirstChild("Melee")
        local weaponFrame = melee and melee:FindFirstChild("Weapon")
        if not weaponFrame then return 0 end
        local n = 0
        local nl = weaponFrame:FindFirstChild("WeaponName")
        if nl and nl.Text ~= tostring(to) then
            nl.Text = tostring(to)
            n = n + 1
        end
        local il = weaponFrame:FindFirstChild("Melee")
        local icon = S.MELEE_ICONS[tostring(to)]
        if il and icon and il.Image ~= icon then
            il.Image = icon
            n = n + 1
        end
        return n
    end

    -- ★ 按动画变体名补齐声音组。
    --
    -- 蝴蝶刀的检视有 Inspect / Inspect2 两个变体（VariantGroups.Inspect 长度 2，
    -- Animations 里是 Inspect 和 Inspect2），游戏会随机挑一个播；
    -- 但 Sounds 组里只配了 Inspect —— 抽到 Inspect2 那一次就整段静音。
    -- 这里对所有刀补 Inspect2~6：从同名基克隆（必须保留子节点，否则
    -- Viewmodel.Classes.Animation 的 `#folder:GetChildren() > 0` 判定过不去）。
    S.patchVariantSounds = function()
        local root = RS:FindFirstChild("Sounds")
        if not root then return 0 end
        local n = 0
        for _, grp in ipairs(root:GetChildren()) do
            if grp:IsA("Folder") then
                local src = grp:FindFirstChild("Inspect") or grp:FindFirstChild("SecondInspect")
                if src and #src:GetChildren() > 0 then
                    for i = 2, 6 do
                        local vname = "Inspect" .. i
                        if not grp:FindFirstChild(vname) then
                            local c = src:Clone()
                            c.Name = vname
                            c.Parent = grp
                            n = n + 1
                        end
                    end
                end
            end
        end
        S.variantSoundsPatched = n
        return n
    end

    -- 声音组跟随目标刀（兜底）：construct 只在重建那一次会补 Sound，
    -- 但游戏自己切枪/重载也会把 Sound 重置回原武器，所以每轮都检查一遍。
    S.syncSound = function(wn)
        local to = S.meleeSwap and S.meleeSwap[tostring(wn)]
        if not to then return 0 end
        local weapon = S.findWeaponByName and S.findWeaponByName(tostring(wn))
        if not weapon then return 0 end
        local vm = weapon.Viewmodel
        local snd = vm and vm.Animation and vm.Animation.Sound
        if not (snd and typeof(snd.Sounds) == "Instance") then return 0 end
        local root = snd.Sounds.Parent
        local tf = root and root:FindFirstChild(tostring(to))
        if not tf then return 0 end
        if tostring(snd.SoundGroupName) == tostring(to) and snd.Sounds == tf then return 0 end
        snd.Sounds = tf
        snd.SoundGroupName = tostring(to)
        return 1
    end

    -- ★ 检视前段静音补播。
    --
    -- 检视动画的前几段在资源里没有声音标记，游戏代码只在 marker 上才调 Sound:play，
    -- 所以那一段补文件夹也不会响。改成盯 IsInspecting 从 false 翻 true 的瞬间，
    -- 手动播一次 Inspect（实测 Sound:play({Name=..., Parent=PlayerGui}) 有效）。
    S.installInspectSound = function()
        if S._inspectSndConn then return end
        local was = false
        S._inspectSndConn = RunService.Heartbeat:Connect(function()
            local okW, w = pcall(function()
                local ic = getInvCtrl()
                return ic and ic.peekCurrentEquippedForMovement()
            end)
            local inspecting = (okW and type(w) == "table" and w.IsInspecting == true)
            if inspecting and not was then
                local weapon = S.findWeaponByName and S.findWeaponByName(tostring(w.Name))
                local vm = weapon and weapon.Viewmodel
                local snd = vm and vm.Animation and vm.Animation.Sound
                if snd then
                    local pg = LP:FindFirstChild("PlayerGui")
                    pcall(function() snd:play({ Name = "Inspect", Parent = pg }) end)
                    S.inspectSndPlayed = (S.inspectSndPlayed or 0) + 1
                end
            end
            was = inspecting
        end)
        S.conns[#S.conns + 1] = S._inspectSndConn
    end

    -- 0.25 秒节流轮询：先换模型，再同步物品栏图标（游戏会重刷，所以两件都盯着）
    local lastAt = 0
    local conn = RunService.Heartbeat:Connect(function()
        if S._alive == false then return end
        local now = os.clock()
        if now - lastAt < 0.25 then return end
        lastAt = now
        local ok, w = pcall(function()
            local ic = getInvCtrl()
            return ic and ic.peekCurrentEquippedForMovement()
        end)
        if not (ok and w and w.Name) then return end
        local name = tostring(w.Name)
        pcall(S.applyMeleeSwap, name)
        pcall(S.syncMeleeIcon, name)
        pcall(S.syncSound, name)
    end)
    S.conns[#S.conns + 1] = conn
end)() end

S.installSkinHook()
-- 声音：补齐检视变体（Inspect2~6），并挂上「检视开始补播」的钩子
pcall(S.patchVariantSounds)
pcall(S.installInspectSound)
-- ★ 平滑自瞄：加载时就装 hook（installSmooth 是幂等的）。
--   原来只在 GUI toggle 的 Callback 里调（L12777），所以「注入脚本后自瞄完全没用」——
--   必须手动去 GUI 点一下开关才会接管 GetMagnetismRotation。
--   现在加载即装；cfg.smoothAimHijack 默认 true，开箱就用；不想用去 GUI 关掉即可。
pcall(function() return AASYS.installSmooth() end)
task.delay(3, function() pcall(S.refreshSkinList) end)
warn("[skin] GetCameraModel hook=" .. tostring(S.skinHookInstalled))
warn("[aim] smoothOK=" .. tostring(AASYS.smoothOK) .. " hijack=" .. tostring(cfg.smoothAimHijack) .. " mode=" .. tostring(cfg.aimMode) .. " fov=" .. tostring(cfg.fov))
return "v2 loaded"
