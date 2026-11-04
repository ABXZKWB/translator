-- MovementV2 Hub 魔改版：hyperFire 默认开

--[[
    MovementV2 Hub  v2  ──  Maclib GUI
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
pcall(function()
    if cleardrawcache then cleardrawcache() end
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
end

---------------------------------------------------------------------
-- 依赖
---------------------------------------------------------------------
local MacLib = loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()

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
    fov = 250,
    -- 360° 静默：忽略「目标是否在画面内」，屏幕外、背后一律纳入候选。
    -- 静默只改子弹方向、不转视角，所以画面上看不看得见他并不影响能不能打中。
    -- 只保留「距离」和「视线通畅」两条限制。
    --
    -- ⚠ 默认改成 true。用户实测「6 连发里有的追踪、有的打墙」，诊断出来是
    --    vDbg = "fov d=488>250" —— 目标一移到屏幕边缘外 250px 就不锁了，
    --    那几发直接照准星方向飞。既然静默不依赖准星朝向，这个 FOV 限制本来就没必要。
    fullSphere = true,
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
    aimVisibleCheck = false,
    maxAimDist = 500,
    aimKeyHeld = false,          -- 已废弃，改用 aimInput.down
    -- 目标锁定
    lockEnabled = true,
    lockMaxSeconds = 6,
    -- 目标优先级
    targetMode = "crosshair",     -- crosshair|nearest|farthest|lowesthp|highesthp|balanced|threat
    crosshairWeight = 1.0,        -- balanced 模式：屏幕距离权重
    distanceWeight = 2.0,         -- balanced 模式：世界距离权重
    preferFacing = false,         -- 优先瞄正在看着你的人
    -- 人体化：让操作看起来像真人
    smoothness = 0.06,           -- 越大越慢越像人。0.22 明显跟不上移动目标，0.05~0.08 才跟手
    jitter = 0.18,               -- 手抖强度（度，连续噪声）
    reactionDelay = 0.14,        -- 发现目标后多久开始瞄（秒）
    headChance = 0.55,           -- 旧模式：瞄准头部的概率
    aimHitPart = "auto",         -- 静默打哪个部位：auto / head / chest / stomach / legs
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
    autoPickupEquip = true,       -- 两套共用：捡到后自动装备（AllowAutoEquip）
    autoPickupInterval = 0.35,    -- 两套共用：扫描间隔（秒）；服务端限速 7/s
    -- ⚠ 换肤是否允许「本地改写 CurrentEquipped 属性」。
    -- 打开它会破坏背包同步（买东西不进、捡东西消失、主武器切不出来），
    -- 默认永久关闭，只留作反面开关。
    skinWriteAttr = false,
    -- 移动端：屏幕「开火」按钮按住时为 true（由按钮的 InputBegan/Ended 驱动）
    mobileHoldFire = false,
    aimPartPriority = true,      -- 露哪打哪：头 > 脖子/胸 > 腹 > 手 > 腿 > 脚
    overshoot = true,            -- 过冲再回拉
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
    skipFireDelay = false,       -- 跳过开火间隔（本地解除冷却，不加快服务端射速）
    bunnyhop = false,            -- 自动兔子跳（落地瞬间再跳，参考 CS）
    wallbang = false,            -- 穿墙：把子弹起点搬到目标身前
    wallbangOffset = 3,          -- 起点距目标多远（stud）
    bulletTrack = false,         -- 子弹追踪：起点整个搬到目标身侧
    trackOffset = 2,             -- 追踪时起点距目标多远
    meleeSpeed = 3,              -- 挥刀动画加速倍数
    mouseGain = 0.12,            -- 鼠标瞄准增益（太高会过冲 → 来回抖）
    mouseMaxStep = 12,           -- 鼠标瞄准每帧最大移动像素
    mouseSmooth = 0.55,          -- 鼠标瞄准低通系数（越大越顺但越慢）
    mouseReleaseDelay = 0.6,     -- 真实键鼠操作后暂停鼠标瞄准多久
    nativeAimAssist = false,     -- 解锁游戏原生瞄准辅助（后坐力减半 + 磁性吸附）
    autoFireMaxOffset = 45,      -- 自动开火：准星离目标多少像素内才允许开火
    smoothAimHijack = false,     -- 平滑瞄准（接管游戏磁性吸附入口，真正转视角）
    smoothAimJitter = 0,         -- 平滑瞄准的抖动幅度（度）
    smoothAimDrop = 0.9,         -- 平滑瞄准的瞄准点：从头部往下多少 stud（瞄胸口）
    smoothAimSpeed = 0.12,       -- 平滑瞄准：每帧走剩余角度的比例（越小越慢越平滑）
    smoothAimMaxDeg = 1.5,       -- 平滑瞄准：每帧最大转角（度），防止大角度硬切
    smoothAimDeadzone = 0.3,     -- 平滑瞄准：死区（度），已经很接近就不再动
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
    autoFire = false,
    autoFireDelay = 180,          -- 毫秒：锁定目标后等这么久才开火（模拟反应时间）
    -- 每种武器类型的自动开火参数
    weaponProfiles = {
        Rifle   = { enabled = true,  maxDist = 300 },
        Sniper  = { enabled = true,  maxDist = 900 },
        Pistol  = { enabled = true,  maxDist = 150 },
        SMG     = { enabled = true,  maxDist = 180 },
        Shotgun = { enabled = true,  maxDist = 60  },
        Melee   = { enabled = false, maxDist = 6   },
    },
    -- ESP
    esp = true,
    espBox = true,
    espHealth = true,
    espName = true,
    espSkeleton = false,         -- 骨骼线（头-躯干-四肢）
    espHitbox = false,           -- 每个部位画碰撞框
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
    espWeapon = true,
    espRange = 600,
    showTeammates = false,
    showBots = true,
    -- 尸体默认不画。
    -- 尸体没有「位置漂移」问题，但它的框会一直挂在那儿（还带名字 + 距离），
    -- 很容易被误认成「自瞄锁着一个空气位置」。实测 vDbg=dead 说明自瞄根本没锁，
    -- 只是画面上有个框。想看残局信息的人可以在菜单里打开。
    hideDead = true,
    -- 没有模型的目标不画（PVS 剔除 / 已离开 / 已死亡但服务端还在发 pose）。
    -- 关掉它就会看到停在旧位置的框，也就是「火柴人」。
    hideNoModel = true,
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
    recoilCompPercent = 100,   -- 100 = 完全压平，50 = 压一半
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
    hyperFire = true,
    -- 连发间隔（秒）。0.02 = 50 发/秒。shoot() 内部要求
    -- (now - NextShotDue) < 0.035，所以 0.02 是安全下限附近，别低于 0.015。
    hyperGap = 0.02,
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
    aimThroughSmoke = true,      -- 烟后的人是否还锁（子弹能穿烟，所以默认允许）
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
        if ver < 5 then
            getgenv().MV_CFG_MIGRATED = string.format("%d -> 5", ver)
        end
        local restored = 0
        for k, v in pairs(saved) do
            local cur = cfg[k]
            if cur ~= nil and type(cur) == type(v)
                and (type(v) == "boolean" or type(v) == "number" or type(v) == "string") then
                cfg[k] = v
                restored += 1
            end
        end
        getgenv().MV_CFG_RESTORED = restored
    end)()
end

-- 把当前配置写回 getgenv，供下次加载恢复
local function saveCfg()
    local out = {}
    for k, v in pairs(cfg) do
        local t = type(v)
        if t == "boolean" or t == "number" or t == "string" then
            out[k] = v
        end
    end
    out.__v = 5
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
}
local function myTeam() return tostring(LP:GetAttribute("Team")) end
local function charsFolder() return workspace:FindFirstChild("Characters") end
local function culledFolder() return RS:FindFirstChild("_PVS_CulledCharacters") end

-- 全量角色来源：可见角色 + 被 PVS 剔除的角色（后者在 ReplicatedStorage 里）
--
-- ⚠⚠⚠ 必须递归下钻一层：workspace.Characters 的直接子项是**按阵营分的 Folder**
--     Characters/
--       Terrorists/            ← Folder
--         <玩家名>/            ← 真正的 Model
--       Counter-Terrorists/    ← Folder
--         <玩家名>/
-- 旧代码 `for _, m in ipairs(folder:GetChildren()) do if m:IsA("Model")` 只看直接子项，
-- 拿到的是 Folder，IsA("Model") 恒为 false —— allCharModels() **一直返回空表**，
-- myModel() 也永远找不到自己。
-- 后果：骨骼 / 碰撞箱 / 头部精确坐标这些「模型数据源」全是空的，透视只能靠
-- RemoteBuffer 的 pose 兜底，而 pose 对不可见玩家是冻结的 ——
-- 这正是「开局一瞬间对、之后位置就错」和「框在原地不动」的真正原因。
local function allCharModels()
    local list, seen = {}, {}
    local function takeModel(m)
        if m:IsA("Model") and not seen[m.Name] then
            seen[m.Name] = true
            table.insert(list, m)
        end
    end
    local function take(folder)
        if not folder then return end
        for _, m in ipairs(folder:GetChildren()) do
            if m:IsA("Model") then
                takeModel(m)
            elseif m:IsA("Folder") or m:IsA("Configuration") then
                -- 阵营层：往下再取一层模型
                for _, mm in ipairs(m:GetChildren()) do
                    if mm:IsA("Model") then takeModel(mm) end
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
    -- ⚠ 同样要下钻阵营层：FindFirstChild(LP.Name) 在 Characters 根下找不到
    -- （自己的模型在 Characters.Terrorists.<名字>）。之前这里恒为 nil，
    -- myRoot() 跟着恒为 nil → 投掷起点、位置外推、近战判定全都拿不到自身坐标。
    local f = charsFolder()
    if not f then return nil end
    local direct = f:FindFirstChild(LP.Name)
    if direct and direct:IsA("Model") then return direct end
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
    if not cfg.silentAim then return false end
    local trig = cfg.aimTrigger or "hold"
    if trig == "always" then return true end
    if trig == "toggle" then return cfg.aimToggled == true end
    return aimInput.down == true      -- hold：真的按住才算
end

-- 目标锁定：锁定后不再每帧重选，避免两人靠近时来回跳
-- 解锁条件：目标死亡 / 离开 FOV / 超过 lockMaxSeconds / 玩家自己动视角
local aimLock = { name = nil, at = 0 }

local function breakAimLock()
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

    -- 威胁优先：正对我的人先打，其次按屏幕距离
    if cfg.preferFacing and facingMe(t) then
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
    local vFailCounts = S.vFail
    local function vFail(kind, detail)
        S.vDbg = detail or kind
        vFailCounts[kind] = (vFailCounts[kind] or 0) + 1
        return false
    end

    local function viable(t)
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
        if cfg.fullSphere ~= true then
            if sp.Z <= 0 then return vFail("zneg", "z=" .. string.format("%.1f", sp.Z)) end
            d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
            if d > cfg.fov then
                return vFail("fov", string.format("fov d=%.0f>%.0f", d, cfg.fov))
            end
        else
            d = 0
        end
        if cfg.aimVisibleCheck then
            local dir = t.headPos - cam.CFrame.Position
            local hit = workspace:Raycast(cam.CFrame.Position, dir, visParams)
            if hit and (t.headPos - hit.Position).Magnitude >= 1.5 then
                return vFail("blocked", "blocked by " .. tostring(hit.Instance and hit.Instance.Name))
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

    local candidates = {}
    for _, t in ipairs(allTargets()) do
        if t.distance <= cfg.maxAimDist then
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

    if best and cfg.lockEnabled then
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
    if c and now - c.at < 0.15 then return c.pos, c.part end
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
    if not (cfg.aimMode == "smooth" and aimActive()) then
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
    local aimPos = aimPointFor(t)

    -- 过冲：短时间内把瞄准点往目标外侧偏一点，再由平滑拉回
    if cfg.overshoot and os.clock() < human.overshootUntil then
        local off = (aimPos - cam.CFrame.Position).Unit
        aimPos = aimPos + Vector3.new(-off.Z, 0, off.X) * human.overshootSign * (2 + math.random() * 3)
    end

    local desired = CFrame.lookAt(cam.CFrame.Position, aimPos)

    -- 指数平滑：smoothness 越大越慢
    local speed = math.max(cfg.smoothness, 0.01)
    local alpha = 1 - math.exp(-dt / speed)
    local newCF = cam.CFrame:Lerp(desired, math.clamp(alpha, 0, 1))

    -- 手抖：真人永远不可能完全静止
    -- 抖动：连续噪声 + 只在「还没对准」时生效。
    -- 之前每帧 math.random() 产生 60Hz 高频震颤，幅度还大于每帧转向量，
    -- 结果就是疯狂抖但瞄不上。已经对准（夹角 < 3°）后不再抖，像真人锁定。
    if cfg.jitter > 0 then
        local angErr = (desired.LookVector - cam.CFrame.LookVector).Magnitude
        if angErr > 0.05 then
            local now = os.clock()
            local j = math.rad(cfg.jitter) * 0.5
            local nx = math.sin(now * 2.3) * 0.6 + math.sin(now * 5.1) * 0.4
            local ny = math.cos(now * 1.9) * 0.6 + math.cos(now * 4.7) * 0.4
            newCF = newCF * CFrame.fromEulerAnglesXYZ(nx * j, ny * j, 0)
        end
    end

    cam.CFrame = newCF
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
    local conn = UIS.InputBegan:Connect(function(input, gameProcessed)
        local t = input.UserInputType
        if t == Enum.UserInputType.Keyboard
            or t == Enum.UserInputType.MouseButton1
            or t == Enum.UserInputType.MouseButton2
            or t == Enum.UserInputType.MouseButton3
            or t == Enum.UserInputType.Touch then
            lastManualInput = os.clock()
        end
    end)
    S.conns[#S.conns + 1] = conn
end)

local function updateMouseAim(dt)
    if not (cfg.aimMode == "mouse" and aimActive()) then return end
    if typeof(mousemoverel) ~= "function" then return end
    -- 窗口没焦点就别动（也是防止误操作别的窗口）
    if isrbxactive and not isrbxactive() then return end
    -- 刚才有真实键鼠操作 → 让出控制权
    if os.clock() - lastManualInput < (cfg.mouseReleaseDelay or 0.6) then return end
    -- 平移期间不抢鼠标（用户在看背包/买枪菜单）
    if UIS:GetFocusedTextBox() then return end

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
    ["LightSaber"] = "Melee",
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
        local t = aimTarget()
        if t and not t.dead then
            -- 按武器类型判断这个距离打不打得着
            local cls = heldWeaponClass()
            local prof = cfg.weaponProfiles[cls]
            if prof and prof.enabled and t.distance <= prof.maxDist then
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

                    -- 视线检测：目标在掩体后就不开火（排除隐形屏障）
                    if pass then
                        coverParams.FilterDescendantsInstances = coverIgnoreList()
                        local from = cam.CFrame.Position
                        local hit = workspace:Raycast(from, t.headPos - from, coverParams)
                        af.blocked = (hit ~= nil)
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
                pcall(function() mouse1press() end)
                pcall(function() mouse1release() end)
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
                -- 执行器没有按住式 API 时退回点击，并保留节流
                local clickGap = tonumber(cfg.autoFireClickGap) or 0.04
                if os.clock() - af.lastClick > clickGap then
                    af.lastClick = os.clock()
                    pcall(function() mouse1click() end)
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
        if REG.gen ~= MY_GEN then return end
        -- 移动端走 MVHub_AimMobile 那条线，这里跳过避免重复应用平滑
        if not IS_MOBILE then
            -- 鼠标瞄准和"改相机"两条路分开：相机被游戏锁死，只有鼠标输入有效
            pcall(updateMouseAim, dt)
            if cfg.aimMode == "smooth" then
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
    if not (cfg.aimMode == "smooth" and aimActive()) then return end
    if os.clock() > mobileFireWindowUntil then
        resetHuman()
        return
    end
    pcall(updateSmoothAim, dt)
end

local okBindMobile = pcall(function()
    RunService:BindToRenderStep("MVHub_AimMobile", Enum.RenderPriority.Last.Value - 4, function(dt)
        if REG.gen ~= MY_GEN then return end
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
        local up1 = select(2, debug.getupvalue(originalSend, 1))
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
    local shouldAim = (cfg.silentAim == true)
    local target = nil

    if shouldAim or cfg.multiShot then
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
                -- 静默模式下没有目标就没有继续补发的意义，直接跳出。
                if cfg.silentAim then
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
        AA.GetMagnetismRotation = function(dt)
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
            local best, bestD = nil, math.huge
            for _, t in ipairs(allTargets()) do
                -- 冻结目标不转视角：那个位置可能只是敌人最后一次被看到的点，
                -- 人早走了，转过去就是对着空气硬锁。
                local okT = (not t.dead) and (not t.frozen)
                if cfg.teamCheck and t.sameTeam then okT = false end
                if t.distance > (cfg.maxAimDist or 500) then okT = false end
                if okT and t.distance < bestD then
                    local aimAt = t.headPos - Vector3.new(0, drop, 0)
                    smoothRP.FilterDescendantsInstances = coverIgnoreList()
                    local hit = workspace:Raycast(eyePos, aimAt - eyePos, smoothRP)
                    if not hit then
                        best, bestD = t, t.distance
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
            local speed = math.clamp(tonumber(cfg.smoothAimSpeed) or 0.12, 0.02, 1)
            local maxDeg = math.clamp(tonumber(cfg.smoothAimMaxDeg) or 1.5, 0.2, 5)
            local cap = math.rad(maxDeg)
            dYaw = math.clamp(dYaw * speed, -cap, cap)
            dPitch = math.clamp(dPitch * speed, -cap, cap)

            -- 死区：已经很接近就别再动，否则会在目标点附近来回微抖
            local dead = math.rad(tonumber(cfg.smoothAimDeadzone) or 0.3)
            if math.abs(dYaw) < dead then dYaw = 0 end
            if math.abs(dPitch) < dead then dPitch = 0 end

            if cfg.smoothAimJitter and cfg.smoothAimJitter > 0 then
                local j = math.rad(cfg.smoothAimJitter)
                local now = os.clock()
                dYaw = dYaw + math.sin(now * 7.3) * j * 0.3
                dPitch = dPitch + math.cos(now * 6.1) * j * 0.3
            end

            S.smoothAimTicks = (S.smoothAimTicks or 0) + 1
            return Vector2.new(dYaw, dPitch)
        end
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
    if cfg.skipFireDelay then pcall(applySkipFireDelay) end
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
            if REG.gen ~= MY_GEN then
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
    if getgenv().MV_GCE_PATCHED then return true, "already" end
    getgenv().MV_ORIG_GCE = ic.getCurrentEquipped
    local peek = ic.peekCurrentEquippedForMovement
    ic.getCurrentEquipped = function()
        if type(peek) == "function" then
            return peek()
        end
        return nil
    end
    getgenv().MV_GCE_PATCHED = true
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
    pcall(function()
        if typeof(getgenv().MV_ORIG_MAG) == "function" then
            require(game.ReplicatedStorage.Controllers.AimAssistController).GetMagnetismRotation =
                getgenv().MV_ORIG_MAG
        end
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
    if REG.gen ~= MY_GEN then return end
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
S.applySkin = function(skinName)
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

S.siteLabels = {}

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
                    rec.obj.Text = string.format("%s 点   %dm", k, math.floor(dist))
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
    obj.Text = string.format("💣 %s   %s   %s", timeText, canDefuse and "可拆" or "拆不掉", kitText)
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

    -- ① setWeaponRecoil —— 只设**目标**（内部是 u131:setGoal）
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
        return orig(tbl, scale, ...)
    end

    -- ② weaponKick —— ⚠⚠ 这才是真正把后座「立即」写进相机的那一个
    --
    -- 实测（docId 170 第 541 行）：
    --     function u0.weaponKick(a1, a2)
    --         u121:setDampingRatio(a1.Damper)
    --         u121:setFrequency(a1.Speed)
    --         u121:setPosition(a1.Value * 0.017453292519943295)   ← 直接设当前值！
    --         u126:setDampingRatio(a2.Damper)
    --         u126:setFrequency(a2.Speed)
    --         ...
    --     end
    -- 而 getWeaponKickRotation() 返回的就是 u121:getPosition()。
    --
    -- 所以只拦 setWeaponRecoil（setGoal）根本没用：目标没被设，但每发子弹
    -- weaponKick 直接 setPosition 把弹簧顶起来 → 相机照样跳。
    -- 用户看到的「子弹是无后座了，但准星乱飞」就是这个 —— 拦截点找错了。
    -- 实测证据：setWeaponRecoil 已被拦 122,397 次，手动调一次 weaponKick
    -- 就能把 kick 从 (0,0,0) 顶到 (0.023, 0.008, 0)，0.6 秒后才自然衰减。
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
        return origKick(a1, a2, ...)
    end

    S.noRecoilHookOn = true
    return true
end

-- 自动压枪：读弹簧当前值，反向补到相机
--
-- ⚠ 这里的符号曾经是错的：写成 kick.X * k（正号）等于把后坐力**又叠加一次**，
-- 用户看到的就是「开火时镜头上下抖得更厉害」。压枪必须是**反向**的。
--
-- 另外：noRecoil 打开时 setWeaponRecoil 被拦，弹簧恒为 0，压枪无事可做 ——
-- 两个选项同时开只会互相打架，所以这里直接跳过。
S.applyRecoilComp = function(dt)
    local pct = tonumber(cfg.recoilCompPercent) or 0
    if cfg.autoRecoilComp ~= true or pct <= 0 then return end
    if cfg.noRecoil == true then return end
    local ok, CC = pcall(require, game.ReplicatedStorage.Controllers.CameraController)
    if not ok or type(CC) ~= "table" then return end
    local okv, kick = pcall(CC.getWeaponKickRotation)
    if not okv or typeof(kick) ~= "Vector3" then return end
    if kick.Magnitude < 0.0005 then return end
    local cam = workspace.CurrentCamera
    if not cam then return end
    local k = math.clamp(pct / 100, 0, 1)
    -- 反向：弹簧把枪口往上抬 kick.X，压枪就往回拉 -kick.X
    pcall(function()
        cam.CFrame = cam.CFrame * CFrame.fromEulerAnglesXYZ(-kick.X * k, -kick.Y * k, 0)
    end)
    S.recoilCompSteps = (S.recoilCompSteps or 0) + 1
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
    -- 这里在 noRecoil 模式下每帧把它们按回最小扩散值。只影响显示，不影响命中。
    if cfg.noRecoil == true then
        pcall(function()
            local pg = LP and LP:FindFirstChild("PlayerGui")
            local mg = pg and pg:FindFirstChild("MainGui")
            local gp = mg and mg:FindFirstChild("Gameplay")
            -- ⚠ 这里原来写的是 `local mid = gp and mid and gp:FindFirstChild("Middle")`
            -- —— 右边那个 mid 是它自己（未赋值）或外层同名变量，属于自引用。
            -- 外层没有 mid 时整个表达式恒为 nil，准星复位就静默失效了。
            local mid = gp and gp:FindFirstChild("Middle")
            local ch = mid and mid:FindFirstChild("Crosshair")
            if not ch then return end
            -- 四个正交分叉：Right/Left 改 X 偏移，Up/Down 改 Y 偏移，基准 7
            local BASE = 7
            for _, d in ipairs(ch:GetDescendants()) do
                local n = d.Name
                if n == "Right" or n == "Left" or n == "Up" or n == "Down" then
                    local okp, p = pcall(function() return d.Position end)
                    if okp and typeof(p) == "UDim2" then
                        if n == "Right" and p.X.Offset ~= BASE then
                            d.Position = UDim2.new(p.X.Scale, BASE, p.Y.Scale, p.Y.Offset)
                        elseif n == "Left" and p.X.Offset ~= -BASE then
                            d.Position = UDim2.new(p.X.Scale, -BASE, p.Y.Scale, p.Y.Offset)
                        elseif n == "Up" and p.Y.Offset ~= -BASE then
                            d.Position = UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, -BASE)
                        elseif n == "Down" and p.Y.Offset ~= BASE then
                            d.Position = UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, BASE)
                        end
                    end
                elseif n == "Arm" then
                    -- 斜角臂保持 ±6，不让它在 ±6 之间来回跳
                    local okp, p = pcall(function() return d.Position end)
                    if okp and typeof(p) == "UDim2" then
                        local sx = (p.X.Offset >= 0) and 6 or -6
                        local sy = (p.Y.Offset >= 0) and 6 or -6
                        if p.X.Offset ~= sx or p.Y.Offset ~= sy then
                            d.Position = UDim2.new(p.X.Scale, sx, p.Y.Scale, sy)
                        end
                    end
                end
            end
        end)
    end

    -- 磁吸守护（见下方注释）。跳过拉栓已经移到 Heartbeat 每帧执行。
    --
    -- ⚠ 顺便在这里兜底重装 noRecoil 的 hook。
    --
    -- S.noRecoilHook() 原来只在点 GUI 开关时调用一次，重载脚本后不会自动装回去。
    -- 结果 cfg.noRecoil 明明是 true，setWeaponRecoil 却没人拦（recoilBlocked 恒为 nil），
    -- 后坐力照常生效。用户看到的就是「开了无后座但镜头还是抖」。
    if cfg.noRecoil == true and not S.noRecoilHookOn then
        pcall(S.noRecoilHook)
    end
    -- ⚠ 这个函数现在兼职「磁吸守护」。
    --
    -- 用户反馈：每局结束就恢复正常，新开一局又开始锁定。
    -- 原因是 AimAssistController 的 GetMagnetismRotation 会在对局切换时被重新赋值
    -- （模块重新初始化 / 我们上次的 hook 被覆盖），而我们只在加载时装一次。
    --
    -- 这里每帧检查：只要发现挂的不是我们那个恒返回 (0,0) 的函数，就重新焊上。
    -- 开销极小（一次表比较），但能保证不管换多少局磁吸都关着。
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
    if not (cfg.silentAim and cfg.showFov) then
        if fovCircle then fovCircle.Visible = false end
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
                                return workspace:Raycast(cc, Vector3.new(0, -40, 0), groundParams)
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
                                gK.text.Text = string.format("%s  效果 %.1fs", tostring(gname), effLeft)
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
                            return workspace:Raycast(pos, Vector3.new(0, -40, 0), groundParams)
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
            return workspace:Raycast(impactPos, Vector3.new(0, -40, 0), rp)
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
            m.text.Text = string.format("预 %.0fm", dist)
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
                m.realText.Text = string.format("实 %.0fm", (realPos - cam.CFrame.Position).Magnitude)
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
    -- ⚠ updateEsp 里原来没有 cam 变量：只有 w2s() 内部自己去取 CurrentCamera。
    -- 结果下面 drawSkeleton(set, cam, ...) / drawHitboxes(set, cam, ...) 传进去的是
    -- 全局 nil，一路报 "attempt to index nil with 'WorldToViewportPoint'"，
    -- 骨架和碰撞箱从来没画出来过。这里补上。
    local cam = workspace.CurrentCamera
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
                    set.frozen.Text = string.format("旧 %.1fs", secs)
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
        if REG.gen ~= MY_GEN then
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
    if REG.gen ~= MY_GEN then
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

    -- ⚠ 跳过拉栓必须放在 Heartbeat（每帧），不能只放在 MV_Draw 的 30fps 节流里。
    --
    -- 游戏的拉栓是 self.ShootDelayThread = task.delay(FireRate, ...)。
    -- shoot() 状态机开头会检查这个字段：非空就 task.cancel 并直接跳到开火判定。
    -- 我们取消得越勤，能连发的窗口就越多。30fps 只能抓 33ms 的间隙，
    -- 60fps 的射击循环里会漏掉一半的机会。
    if cfg.skipFireDelay == true then
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
    -- 自动重新装备：手上有空但背包里有东西 → 主动 equip（每 0.75 秒）
    S.reequipTick = (S.reequipTick or 0) + dt
    if S.reequipTick >= 0.75 then
        S.reequipTick = 0
        if cfg.autoReequip ~= false then
            pcall(S.autoReequip)
        end
    end

    -- 自动拾取地上的武器（按价值 / 自定义优先）
    pcall(function() S.autoPickupStep(dt) end)

    S.buyTick = (S.buyTick or 0) + dt
    if S.buyTick >= 0.15 then
        S.buyTick = 0
        pcall(function()
            if not S.menuScreenGui then
                -- 菜单的 ScreenGui 在执行器的 gethui() 容器里（CoreGui.RobloxGui.ScreenGui），
                -- 所以递归找：哪个 ScreenGui 里有一个叫 Base 的 Frame，就是我们的。
                local roots = {}
                if typeof(gethui) == "function" then
                    local okh, h = pcall(gethui)
                    if okh and h then roots[#roots + 1] = h end
                end
                roots[#roots + 1] = game:GetService("CoreGui")
                for _, rt in ipairs(roots) do
                    local okd, descs = pcall(function() return rt:GetDescendants() end)
                    if okd and descs then
                        for _, d in ipairs(descs) do
                            if d:IsA("ScreenGui") then
                                local b = d:FindFirstChild("Base")
                                if b and b:IsA("Frame") then
                                    S.menuScreenGui = d
                                    break
                                end
                            end
                        end
                    end
                    if S.menuScreenGui then break end
                end
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
local Window = MacLib:Window({
    Title = "MovementV2 菜单",
    Subtitle = IS_MOBILE and "手机版" or "v2 | 静默瞄准 + 暴力",
    Size = IS_MOBILE and UDim2.fromOffset(560, 560) or UDim2.fromOffset(880, 660),
    DragStyle = IS_MOBILE and 2 or 1,   -- 手机整窗拖动
    DisabledWindowControls = {},
    ShowUserInfo = true,
    Keybind = IS_MOBILE and Enum.KeyCode.ButtonStart or Enum.KeyCode.RightControl,
    AcrylicBlur = false,
})

if IS_MOBILE then
    pcall(function() Window:SetScale(0.9) end)
end

-- 窗口居中修正
-- Maclib 的 Base 用的是 AnchorPoint(0.5,0.5) + Position(0.5,-1004 / 0.5,+344)，
-- 那个像素偏移会把整窗推到屏幕外（实测 pos.X = -484）。加载后强制拉回中央。
local function centerWindow()
    local cg = game:GetService("CoreGui")
    for _, d in ipairs(cg:GetDescendants()) do
        if d:IsA("Frame") and d.Name == "Base"
            and d.Parent and d.Parent:IsA("ScreenGui") then
            d.Position = UDim2.fromScale(0.5, 0.5)
            return true
        end
    end
    return false
end

task.spawn(function()
    for _ = 1, 8 do
        task.wait(0.25)
        if REG.gen ~= MY_GEN then return end
        if centerWindow() then break end
    end
end)

local TG = Window:TabGroup()
local T = {
    combat = TG:Tab({ Name = "战斗", Image = "rbxassetid://18821914323" }),
    rage = TG:Tab({ Name = "暴力", Image = "rbxassetid://10747373183" }),
    visual = TG:Tab({ Name = "视觉", Image = "rbxassetid://10734950309" }),
    weapon = TG:Tab({ Name = "武器", Image = "rbxassetid://10747373183" }),
    -- VIP 服务器专属能力单独一页（只在私人服/有 VIP 权限时可用）
    vip = TG:Tab({ Name = "VIP服", Image = "rbxassetid://10747373183" }),
    -- 美化（皮肤/外观）单独一页，纯本地视觉
    skin = TG:Tab({ Name = "美化", Image = "rbxassetid://10734950309" }),
    misc = TG:Tab({ Name = "杂项", Image = "rbxassetid://10734950569" }),
}

-- VIP 页：服务端管理接口（无限弹药/金钱/无敌/BOT 控制/结算动作）
-- 注意：这里不能声明新的顶层 local（主 chunk 已经 200 上限），所以挂到 T 上。
T.vipL = T.vip:Section({ Side = "Left" })
T.vipR = T.vip:Section({ Side = "Right" })
-- 美化页：皮肤切换（只影响自己客户端看到的枪）
T.skinL = T.skin:Section({ Side = "Left" })
T.skinR = T.skin:Section({ Side = "Right" })

-- 战斗
local cl = T.combat:Section({ Side = "Left" })
local cr = T.combat:Section({ Side = "Right" })

cl:Header({ Text = "静默瞄准" })
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
    end,
}, "AimMode")
cl:Toggle({ Name = "360° 静默（屏幕外也锁）", Default = cfg.fullSphere == true,
    Callback = function(v) cfg.fullSphere = v end }, "FullSphere")
cl:Label({ Text = "静默只改子弹方向、不转视角，所以「目标在不在画面里」这条限制没有意义。打开后只保留距离和视线通畅两条约束——身后、墙侧的目标一样能锁。" })
cl:Slider({ Name = "鼠标瞄准 增益", Default = 0.12, Minimum = 0.02, Maximum = 0.6, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.mouseGain = v end }, "MouseGain")
cl:Slider({ Name = "鼠标瞄准 每帧最大移动", Default = 12, Minimum = 1, Maximum = 60, DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.mouseMaxStep = v end }, "MouseStep")
cl:Slider({ Name = "鼠标瞄准 平滑", Default = 0.55, Minimum = 0, Maximum = 0.95, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.mouseSmooth = v end }, "MouseSmooth")
cl:Slider({ Name = "鼠标瞄准 手动操作后暂停(秒)", Default = 0.6, Minimum = 0.1, Maximum = 3, DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.mouseReleaseDelay = v end }, "MouseRelease")
cl:Label({ Text = "「鼠标瞄准」用 mousemoverel 发真实鼠标输入，游戏相机会正常响应——这是唯一能真正转动视角的方式。" })
cl:Label({ Text = "⚠ 它会真的移动系统光标。所以只要检测到任何真实键鼠操作（按键、左右键），就暂停一段时间让你能操作菜单、切窗口、按 Esc。窗口失焦时也会自动停。" })
cl:Label({ Text = "抖动的原因：增益太高会过冲——这一帧转过头、下一帧反向拉回，两帧一循环就成了肉眼可见的抖。默认 0.12 + 每帧上限 12px + 指数平滑，基本是单调逼近不抖。如果还抖就继续降增益、调高平滑。" })

cl:Header({ Text = "平滑瞄准（真正转视角）" })
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
cl:Slider({ Name = "平滑瞄准 速度", Default = 0.12, Minimum = 0.02, Maximum = 1, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.smoothAimSpeed = v end }, "SmoothSpeed")
cl:Slider({ Name = "平滑瞄准 每帧最大转角", Default = 1.5, Minimum = 0.2, Maximum = 5, DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.smoothAimMaxDeg = v end }, "SmoothMaxDeg")
cl:Slider({ Name = "平滑瞄准 死区(度)", Default = 0.3, Minimum = 0, Maximum = 3, DisplayMethod = "Value", Precision = 2,
    Callback = function(v) cfg.smoothAimDeadzone = v end }, "SmoothDead")
cl:Slider({ Name = "平滑瞄准 瞄点下移", Default = 0.9, Minimum = 0, Maximum = 3, DisplayMethod = "Value", Precision = 1,
    Callback = function(v) cfg.smoothAimDrop = v end }, "SmoothDrop")
cl:Label({ Text = "原理：CameraController 每帧调用 AimAssistController.GetMagnetismRotation()，拿到 Vector2(水平角, 垂直角) 后 clamp 到 ±5 度再应用到相机。这里把那个函数换成「返回指向目标的角度差」，相机就被游戏自己每帧转过去。" })
cl:Label({ Text = "和另外两种的区别：改 cam.CFrame 会被每帧覆盖（实测 384 帧写 0 度变化）；mousemoverel 会抢你的鼠标。这条走引擎内部管道，既不覆盖也不碰鼠标。" })
cl:Label({ Text = "实测：1.2 秒内相机转了 6.66 度，目标从屏幕外（Z=118）进到正前方（Z=11）。每帧上限 5 度，60fps 就是 300 度/秒。" })

cl:Header({ Text = "原生瞄准辅助（游戏自带）" })
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
        if REG.gen ~= MY_GEN then break end
        pcall(function()
            local txt = "瞄准按键: " .. aimInputLabel()
            if aimInput.listening then txt = txt .. "   [等待按键...]" end
            aimKeyBtn:UpdateName(txt)
        end)
    end
end)
cl:Slider({ Name = "视野范围 FOV", Default = (cfg.fov or 250), Minimum = 20, Maximum = 2400, DisplayMethod = "Value", Precision = 0,
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

cr:Header({ Text = "目标优先级" })
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
cr:Slider({ Name = "平滑度（越大越慢）", Default = 0.22, Minimum = 0.02, Maximum = 1.0, DisplayMethod = "Value", Precision = 2,
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
cr:Toggle({ Name = "部位优先级（露哪打哪）", Default = true, Callback = function(v) cfg.aimPartPriority = v end }, "AimPartPrio")
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
local rl = T.rage:Section({ Side = "Left" })
local rr = T.rage:Section({ Side = "Right" })

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
    Window:Notify({ Title = "后座", Description = "自动压枪 " .. (v and "已开启" or "已关闭"), Lifetime = 2 })
end }, "AutoRecoilComp")
rr:Slider({ Name = "压枪幅度（%）", Default = cfg.recoilCompPercent, Minimum = 0, Maximum = 100,
    DisplayMethod = "Value", Precision = 0,
    Callback = function(v) cfg.recoilCompPercent = v end }, "RecoilCompPct")
rr:Label({ Text = "每帧读 getWeaponKickRotation（弹簧当前后座偏移），按百分比反向补到相机上。100% = 完全压平，50% = 压一半，保留一点真实手感。埋点 state.recoilCompSteps。" })

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
-- 美化（独立页 T.skin）—— 纯本地视觉，服务端不认
-- ═══════════════════════════════════════════════════════════════
T.skinL:Header({ Text = "武器皮肤（已禁用）" })
T.skinL:Button({
    Name = "切换皮肤（会破坏背包，已停用）",
    Callback = function()
        Window:Notify({
            Title = "换肤已停用",
            Description = "写 CurrentEquipped 会让服务端背包同步失效：买东西不进、捡东西消失、主武器切不出来。",
            Lifetime = 8,
        })
    end,
}, "SkinCycle")
T.skinL:Button({
    Name = "列出当前武器的皮肤名（只读）",
    Callback = function()
        local list = S.listSkins()
        local cur = S.getCurrentWeapon()
        Window:Notify({
            Title = "皮肤列表（" .. tostring(cur and cur.Name) .. "）",
            Description = (#list > 0) and table.concat(list, " / ") or "该武器没有可选皮肤",
            Lifetime = 8,
        })
    end,
}, "SkinList")
T.skinL:Label({ Text = "换肤功能已停用。原因：它靠本地改写 CurrentEquipped 属性实现，而这个属性是服务端下发的武器数据，游戏所有背包/拾取/购买逻辑都读它。改了之后旧武器切不出来、新买的东西不进来、捡到的立刻消失。想看皮肤名可以点下面的只读按钮。" })

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
local vl = T.visual:Section({ Side = "Left" })
local vr = T.visual:Section({ Side = "Right" })

vl:Header({ Text = "透视" })
vl:Toggle({ Name = "透视开关", Default = true, Callback = function(v) cfg.esp = v end }, "Esp")
vl:Toggle({ Name = "方框", Default = true, Callback = function(v) cfg.espBox = v end }, "EspBox")
vl:Toggle({ Name = "血条", Default = true, Callback = function(v) cfg.espHealth = v end }, "EspHp")
vl:Toggle({ Name = "名字", Default = true, Callback = function(v) cfg.espName = v end }, "EspName")
vl:Toggle({ Name = "骨骼", Default = cfg.espSkeleton == true, Callback = function(v) cfg.espSkeleton = v end }, "EspSkel")
vl:Toggle({ Name = "碰撞箱部位", Default = cfg.espHitbox == true, Callback = function(v) cfg.espHitbox = v end }, "EspHitbox")
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
local wl = T.weapon:Section({ Side = "Left" })
local wr = T.weapon:Section({ Side = "Right" })

-- ── 装备修复（原来挂在「战斗」页，用户要求归到武器页） ──
wl:Header({ Text = "装备：手上空着 / 买了不进去" })
wl:Toggle({ Name = "自动重新装备（推荐开）", Default = (cfg.autoReequip ~= false), Callback = function(v)
    cfg.autoReequip = v
    Window:Notify({
        Title = v and "自动重新装备 已开启" or "自动重新装备 已关闭",
        Description = v and "背包里有武器但手上是空的时，每 0.75 秒自动装备一次"
            or "关闭后需要手动点下面的按钮",
        Lifetime = 5,
    })
end }, "AutoReequip")
wl:Button({ Name = "立即重新装备（手动）", Callback = function()
    local ok, msg = S.autoReequip()
    Window:Notify({
        Title = ok and "已重新装备" or "没有可装备的东西",
        Description = tostring(msg),
        Lifetime = 5,
    })
end }, "ReequipNow")
wl:Label({ Text = "判定优先级（实测）：先看手上有没有东西 —— 有就完全不动；"
    .. "手上真的空着时，才按 Slot1 → Slot5 找第一个有物品的槽装备（所以是主武器优先，不会去装手雷/刀）。"
    .. "另外加了一道保护：只要手上拿着投掷物（Class=Grenade），一律不动作。" })
wl:Label({ Text = "症状：回合开始后商店能点、有音效、属性面板也正常，但买的东西不进物品栏、手上一直是空的 —— "
    .. "原因是游戏在回合重建背包后没有自动装备初始武器。这个开关每 0.75 秒检查一次并补上装备，"
    .. "equip() 本身会发包，服务端是接受的（回 WeaponEquipResolved）。" })
wl:Label({ Text = string.format("当前状态：自动装备成功次数 = %s   最近一次 = %s",
    tostring(S.autoEquipCount or 0), tostring(S.autoEquipLast or "无")) })

-- ── 自动拾取地上的武器：两个阵营各一套独立配置 ──
-- 切到 T 用 pickupOn_T / pickupStrat_T / pickupRange_T / pickupNamed_T，
-- 切到 CT 用 _CT 那一套；队伍没定时整套不动作。
S.addPickupSection(wl, "T", "恐怖分子 T")
S.addPickupSection(wl, "CT", "反恐精英 CT")
wl:Label({ Text = "两个阵营的配置互不影响：上面「恐怖分子 T」一整段只在你属于 T 时生效，"
    .. "下面「反恐精英 CT」同理。切换阵营会立刻改用对应那一套。" })
wl:Label({ Text = "阵营过滤的含义：武器的 Team 字段（Both / Terrorists / Counter-Terrorists）"
    .. "与自己阵营比对，不符就跳过；策略选「敌人的枪也捡」则关闭这道过滤。" })
wl:Label({ Text = string.format("当前阵营：%s   已拾取 %s 次   最近一次 = %s",
    tostring(LP:GetAttribute("Team") or "未分配"),
    tostring(S.pickupCount or 0), tostring(S.lastPickup or "无")) })

local CLASSES = {
    { key = "Rifle",   name = "步枪",   desc = "AK-47 / M4 / FAMAS / AUG" },
    { key = "Sniper",  name = "狙击",   desc = "AWP / SSG 08 / SCAR-20" },
    { key = "Pistol",  name = "手枪",   desc = "Glock / USP-S / 沙鹰" },
    { key = "SMG",     name = "冲锋枪", desc = "MP9 / MAC-10 / P90" },
    { key = "Shotgun", name = "霰弹枪", desc = "Nova / XM1014 / MAG-7" },
    { key = "Melee",   name = "近战",   desc = "各类刀" },
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
end

local curW = wl:Label({ Text = "当前武器: 读取中..." })
task.spawn(function()
    while true do
        task.wait(0.5)
        if REG.gen ~= MY_GEN then break end
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
local ml = T.misc:Section({ Side = "Left" })
local mr = T.misc:Section({ Side = "Right" })

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

ml:Header({ Text = "快捷购买" })

-- 每把武器的实际买价和阵营（从游戏配置读，不写死）
local BUY_LIST = { "AK-47", "M4A1-S", "AWP", "M4A4", "Desert Eagle", "Glock-18",
                   "USP-S", "Kevlar + Helmet" }

local buyStatus = ml:Label({ Text = "读取中..." })

for _, w in ipairs(BUY_LIST) do
    ml:Button({
        Name = "购买 " .. w,
        Callback = function()
            local ok, msg = buy(w)
            Window:Notify({
                Title = ok and "购买" or "买不了",
                Description = tostring(msg),
                Lifetime = ok and 2.5 or 4,
            })
        end,
    })
end

task.spawn(function()
    while true do
        task.wait(1)
        if REG.gen ~= MY_GEN then break end
        pcall(function()
            local st = tostring(workspace:GetAttribute("GameState") or "?")
            local money = tostring(LP:GetAttribute("Money") or "?")
            local team = myTeam()
            buyStatus:UpdateName(string.format("阶段=%s  阵营=%s  钱=%s", st, team, money))
        end)
    end
end)

mr:Header({ Text = "菜单控制" })
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
        if REG.gen ~= MY_GEN then break end
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
    -- 主绘制循环也要停，否则卸载后还在每帧投影
    pcall(function() RunService:UnbindFromRenderStep("MV_Draw") end)

    -- 2) 删掉所有绘制
    clearEsp()
    pcall(radarClear)
    pcall(throwClear)
    pcall(arrowClear)
    pcall(fovClear)
    pcall(grenadeClear)
    pcall(vfxZoneClear)
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

    -- 4) 解绑渲染步骤
    pcall(function() RunService:UnbindFromRenderStep("MVHub_Aim") end)
    pcall(function() RunService:UnbindFromRenderStep("MVHub_AimMobile") end)
    pcall(function() RunService:UnbindFromRenderStep("MV_Spin") end)
    pcall(function() RunService:UnbindFromRenderStep("MV_ThirdPerson") end)

    -- 5) 兜底：清空整个 Drawing 缓存
    -- 上面那些 xxxClear 只删本实例记得住的对象，reload 时旧实例的
    -- local 引用可能已经丢了（FOV 圈、箭头、抛物线的线会残留在屏幕上）。
    -- cleardrawcache 一刀切，保证卸载后屏幕干净。
    pcall(function()
        if cleardrawcache then cleardrawcache() end
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

    -- 6) 清空全部 Drawing，防止残留
    --
    -- ⚠⚠⚠ 必须和上面的 hook 还原一样加「自己仍是最新实例」闸门。
    --
    -- 症状（实测踩到）：反复重载脚本若干次之后，屏幕上什么都没有 ——
    --   ESP 不画、投掷抛物线不画、落点圈不画，
    --   连手动 `Drawing.new("Line")` 出来、Visible=true 的洋红测试线都不显示。
    -- 而埋点在涨：throwTicks=111、throwLineCount=78、ringR=12 —— 代码全在跑。
    --
    -- 原因：MacLib 的 Unload 是**异步**的。新实例早已建好整套 Drawing，
    -- 旧实例的 fullCleanup 才慢一步跑到这一行，一次 `cleardrawcache()`
    -- 把新实例的对象全清了：对象仍在内存里、Visible 仍是 true，但不渲染。
    -- 重载次数越多，被清的次数越多，最终看起来像「Drawing 整个坏了」。
    --
    -- REG.gen 每次加载递增，所以旧实例到这里一定不相等 → 跳过，交还控制权。
    if REG.gen == MY_GEN then
        pcall(function()
            if cleardrawcache then cleardrawcache() end
        end)
    end

    -- 7) 销毁手机端按钮
    if mobileGui then
        pcall(function() mobileGui:Destroy() end)
        mobileGui = nil
    end

    setInfiniteAmmo(false)
    getgenv().MV_V2 = nil
end

-- 可靠的显示/隐藏快捷键：自己监听输入，不依赖 Maclib 的 Keybind
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
                local sg = S.menuScreenGui
                if not sg then
                    local roots = {}
                    if typeof(gethui) == "function" then
                        local okh, hh = pcall(gethui)
                        if okh and hh then roots[#roots + 1] = hh end
                    end
                    roots[#roots + 1] = game:GetService("CoreGui")
                    for _, rt in ipairs(roots) do
                        local okd, descs = pcall(function() return rt:GetDescendants() end)
                        if okd and descs then
                            for _, d in ipairs(descs) do
                                if d:IsA("ScreenGui") and d:FindFirstChild("Base") then
                                    S.menuScreenGui = d
                                    break
                                end
                            end
                        end
                        if S.menuScreenGui then break end
                    end
                end
                if S.menuScreenGui then
                    S.menuScreenGui.Enabled = not cur
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

Window.onUnloaded(function()
    pcall(fullCleanup)
end)

-- 旧实例只退场，绝不做清理：新实例在加载时已经统一清理过了，
-- 如果旧实例也去清，就会把新实例的连接和绘制一起干掉。
task.spawn(function()
    while true do
        task.wait(0.5)
        if REG.gen ~= MY_GEN then break end
        local okWin = pcall(function() return Window:GetState() end)
        if not okWin then
            pcall(fullCleanup)
            break
        end
    end
end)

MacLib:SetFolder("MVHubV2")
T.combat:InsertConfigSection("Right")
T.combat:Select()
MacLib:LoadAutoLoadConfig()

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
    w2s = function(p) return w2s(p) end,
    updateEsp = function() updateEsp() end,
    setInfiniteAmmo = function(on) return setInfiniteAmmo(on) end,
    applyInfiniteAmmo = function() return applyInfiniteAmmo() end,
    setSkipFireDelay = function(on) return setSkipFireDelay(on) end,
    applySkipFireDelay = function() return applySkipFireDelay() end,
    setInstantReload = function(on) return setInstantReload(on) end,
    applyInstantReload = function() return applyInstantReload() end,
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

return "v2 loaded"
