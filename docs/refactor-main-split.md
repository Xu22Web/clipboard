# 主脚本解耦拆分计划（`src/clipboard.ps1` → `src/lib/`）

> 目标：`clipboard.ps1` 只保留「入口 + 初始化 + 装配」，其余按层拆进 `src/lib/`；
> **对外行为、CLI 输出、ini 键、插件契约、打包产物一律不变**。
>
> **状态（2026-10-27）**：P1–P4 已完成 —— 入口文件 3439 → 111 行，新增 16 个 `lib/` 模块，
> 源码全量 369/369、压缩产物 114/114 通过，压缩率 37.3% → 40.1%。
> 未做：P0 的 `struct` 结构守卫断言、P5 的面板内部再切分。

---

## 1. 目标与非目标

| 目标 | 说明 |
|---|---|
| 单一职责 | 一个文件只讲一件事（存储 / 配置 / 面板 / 常驻 / 快捷方式 …），文件内不再跨层 |
| 主脚本瘦身 | `clipboard.ps1` 从 3439 行降到 **≈110 行**：`param` → `$Root` → 点源模块 → 运行时路径 → `-Library` 返回 → `Invoke-Main` |
| 依赖方向显式 | 只允许 `dispatch/picker/serve → store/config/theme → clip/ini/util → base`，反向调用一律改由参数传入 |
| 可测 | 每个模块都能单独解析、单独断言；结构约束由测试守住，不靠自觉 |
| 无行为变化 | CLI 输出、错误文案、退出码、ini 写入时机、插件钩子语义全部保持 |

非目标（本次不做）：

- 不改压缩器（`build/minify.ps1`）的任何算法，只要求拆分后仍然通过 101 项产物验证。
- 不改插件加载模型、不改 ini schema 里的键。
- 不做 PowerShell 5.1 → 7 迁移，不引入任何依赖。
- 不为了"看起来面向对象"而引入类（`class`）或模块清单（`.psd1`）：这是**单文件可直接运行**的工具，点源仍然是唯一加载方式。

---

## 2. 现状

```
src/clipboard.ps1   3439 行   84 个顶层函数 + Show-Picker 内 24 个嵌套函数 = 108
src/lib/plugins.ps1  630 行   插件运行时（已拆）
src/lib/themes.ps1   228 行   主题加载（已拆，覆盖主脚本里的 stub）
```

主脚本的 `#region` 与实际体量：

| 行 | region | 内容 | 行数 |
|---|---|---|---|
| 1–26 | 头注释 + `param` | `Command/Value/Sub/Arg/Count/Purge/All/Library` | 26 |
| 27–68 | constants | `RS`/`US`/`FILESIG`、互斥量与事件名、`$Root`、`Metric`/`Glyphs`/`Timing` | 42 |
| 70–119 | defaults | 约 45 个 `$script:` 默认值 | 50 |
| 121–184 | settings file | `Read-Ini` + `$IniPath`/`$IniCache`/`$StoreDir`/`$StoreFile`/`$Paused`/`$LogFile`/`$Utf8`/`$BoundParams` | 64 |
| 188–379 | helpers | `Ensure-Dir` … `New-RoundRegion`，含 7 个主题 stub | 192 |
| 381–436 | clipboard | `Get-Text`/`Set-Text`/`Get-ClipItem`/`Set-ClipItem` | 56 |
| 438–812 | storage | 记录读写、加锁、标记、排序裁剪、条目文案（31 个函数） | 375 |
| 814–845 | hotkey | `Parse-Hotkey`/`Test-Modifiers-Up` | 32 |
| 847–948 | picker helpers | 几何、数字快选、命中高亮、`Get-EntryKind`、图标 | 102 |
| 950–2243 | picker | `Show-Picker` + 24 个嵌套函数（闭包） | 1294 |
| 2245–2395 | resident daemon | `Start-Serve`/`Invoke-ServeOnce` | 151 |
| 2397–2473 | diagnostics | `Invoke-Diag`/`Invoke-Restore` | 77 |
| 2475–2570 | shortcuts | lnk 安装/卸载 | 96 |
| 2572–3211 | config file | `$script:IniSchema` + 13 个函数 + `Show-Usage` | 640 |
| 3213–3439 | dispatch | 点源 themes/plugins、插件装配、`switch ($Command)` | 227 |

三条**必须保留**的现有契约（拆分时最容易被破坏的三处）：

1. **根目录只能由主脚本算**。`$Root = Split-Path -Parent $PSCommandPath` 必须在 `clipboard.ps1` 里执行；
   在点源文件里 `$PSScriptRoot` 指向 `lib\`，`Join-Path $PSScriptRoot 'themes'` 会指向不存在的目录。
   拆分后 `lib\*.ps1` **一律只读 `$Root`**，禁止出现 `$PSScriptRoot` / `$PSCommandPath`。
2. **`-Library` 必须在所有模块加载完之后 return**（测试靠它拿到函数与 `$StoreDir` 等变量）。
   现在 return 在 dispatch 区，拆分后位置不变，只是前面多了一串点源。
3. **顶层变量赋值要么留在主脚本，要么写成 `$script:`**。`$StoreDir`/`$StoreFile`/`$Paused`/`$LogFile`/`$Utf8`/`$IniPath`
   现在是脚本作用域的裸赋值；若搬进函数里而漏了 `$script:`，它们会变成函数局部变量，
   结果是"写入位置悄悄变成 `lib\data`"——这类 bug 不会报错，只会丢历史。

---

## 3. 目标结构

```
src/
  clipboard.ps1          入口：param、$Root、点源模块、运行时路径、-Library、Invoke-Main   (~110)
  lib/
    base.ps1             常量、记录格式、运行时标识、Metric/Glyphs/Timing、全部 $script: 默认值  (~110)
    ini.ps1              Read-Ini、$script:IniSchema、Get-IniKey/Convert-IniValue/Get-CfgValue/
                         Set-IniKey/Write-IniTemplate                                       (~230)
    util.ps1             Ensure-Dir/Write-Log/Add-Native/Load-Forms/Test-Font/Use-Drawing/
                         Initialize-Dpi/Px/Get-Epoch/Get-RelTime/New-RoundPath/New-RoundRegion (~150)
    theme-stub.ps1       内置兜底：Get-ThemeDir/Get-ThemeNames/Resolve-ThemeName/Read-Theme/
                         Apply-Theme/Get-BasePalette/Get-UiPalette（被 themes.ps1 覆盖）     (~65)
    clip.ps1             剪贴板四件套：Get-Text/Set-Text/Get-ClipItem/Set-ClipItem             (~60)
    store.ps1            CBHIST2 读写、加锁、标记、排序裁剪、Add/Remove/Restore/Update、
                         Get-ActionText/Get-ItemLabel/Format-Item                             (~380)
    hotkey.ps1           Parse-Hotkey/Test-Modifiers-Up                                       (~35)
    entry.ps1            Get-EntryKind/Get-IconGlyph/Get-RowGlyph（基础类型判定与行图标兜底）  (~35)
    picker-geom.ps1      纯计算：Get-VisibleRowCount/Get-QuickKey*/Get-PickerBounds/Get-HitMarks(~85)
    picker.ps1           Show-Picker（先整体搬，P5 再按场景细化）                            (~1300 → 见 P5)
    serve.ps1            Start-Serve/Invoke-ServeOnce                                        (~160)
    diag.ps1             Invoke-Diag/Invoke-Restore                                          (~85)
    shortcut.ps1         Get-AutostartPath/Get-DesktopPath/New-ClipLnk/Install-Remove        (~100)
    config.ps1           Apply-Config/Get-ConfigReport/Show-Config/Show-ConfigKey/
                         Set-ConfigKey/Restart-ResidentIfRunning                             (~420)
    usage.ps1            Show-Usage                                                          (~115)
    dispatch.ps1         Invoke-Main：插件装配 + switch ($Command)                            (~230)
    plugins.ps1          （不动）插件运行时
    themes.ps1           （不动）主题加载，覆盖 theme-stub 里的同名函数
```

`clipboard.ps1` 拆分后的骨架（示意，非最终代码）：

```powershell
param(...)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath          # 只能在主脚本里算

# 必需模块：缺失即失败，不静默降级
foreach ($m in @('base','ini','util','theme-stub','clip','store','hotkey','entry',
                 'picker-geom','picker','serve','diag','shortcut','config','usage','dispatch')) {
  $p = Join-Path $Root ('lib\' + $m + '.ps1')
  if (-not (Test-Path -LiteralPath $p)) { Write-Host ('[x] missing lib\' + $m + '.ps1'); exit 1 }
  . $p
}
# 可选模块：缺失时退化为内置配色 / 只用基础功能
if (Test-Path -LiteralPath (Join-Path $Root 'lib\themes.ps1'))  { . (Join-Path $Root 'lib\themes.ps1') }
if (Test-Path -LiteralPath (Join-Path $Root 'lib\plugins.ps1')) { . (Join-Path $Root 'lib\plugins.ps1') }

# 运行时路径：需要 Read-Ini，必须在 ini.ps1 之后、Invoke-Main 之前
$IniPath = Join-Path $Root 'clipboard.ini'
$script:IniCache = Read-Ini
... $StoreDir / $StoreFile / $Paused / $LogFile / $Utf8 / $script:BoundParams ...

if ($Library) { return }
Invoke-Main
```

点源顺序的唯一硬约束是 **`base` → `ini` → 其余**：只有 `base.ps1`（纯数据）和 `ini.ps1`（`$script:IniSchema` 顶层表）
会在加载期执行赋值，其余文件只定义函数（函数体在调用时才解析名字，先后无关）。
`theme-stub.ps1` 必须排在 `themes.ps1` 之前，否则兜底实现会覆盖真实现。

---

## 4. 函数归属（逐段对照）

| 目标文件 | 现在的行 | 函数 |
|---|---|---|
| `base.ps1` | 29–38, 41–67, 70–118 | 常量与默认值（`RS`/`US`/`FILESIG`/`V2TAG`、`MutexName`/`EventName`/`StopName`/`StoreLock`、`Metric`/`Glyphs`/`Timing`/`UiScale`，45 个 `$script:` 默认值） |
| `ini.ps1` | 125–183, 2575–2607, 2609–2720 | `Read-Ini`、`$script:IniSchema`、`Get-IniKey`、`Convert-IniValue`、`Get-CfgValue`、`Set-IniKey`、`Write-IniTemplate` |
| `util.ps1` | 189–267, 319–379 | `Ensure-Dir`、`Write-Log`、`Add-Native`、`Load-Forms`、`Test-Font`、`Use-Drawing`、`Initialize-Dpi`、`Px`、`Get-Epoch`、`Get-RelTime`、`New-RoundPath`、`New-RoundRegion` |
| `theme-stub.ps1` | 268–285, 288–318 | `Get-ThemeDir`、`Get-ThemeNames`、`Resolve-ThemeName`、`Read-Theme`、`Apply-Theme`、`Get-BasePalette`、`Get-UiPalette` |
| `clip.ps1` | 382–436 | `Get-Text`、`Set-Text`、`Get-ClipItem`、`Set-ClipItem` |
| `store.ps1` | 446–812 | 31 个：`New-Record` … `Clear-Store`、`Get-ActionText`、`Get-ItemLabel`、`Format-Item` |
| `hotkey.ps1` | 815–845 | `Parse-Hotkey`、`Test-Modifiers-Up` |
| `entry.ps1` | 925–948 | `Get-EntryKind`、`Get-IconGlyph`、`Get-RowGlyph` |
| `picker-geom.ps1` | 849–923 | `Get-VisibleRowCount`、`Get-QuickKeyIndex`、`Get-QuickKeyLabel`、`Get-QuickKeyOffset`、`Get-PickerBounds`、`Get-HitMarks` |
| `picker.ps1` | 950–2243 | `Show-Picker`（含 24 个嵌套函数，P5 之前保持原样） |
| `serve.ps1` | 2246–2395 | `Start-Serve`、`Invoke-ServeOnce` |
| `diag.ps1` | 2398–2473 | `Invoke-Diag`、`Invoke-Restore` |
| `shortcut.ps1` | 2476–2570 | `Get-AutostartPath`、`Get-DesktopPath`、`New-ClipLnk`、`Install-Autostart`、`Remove-Autostart` |
| `config.ps1` | 2616–3100 | `Convert-IniValue` 之后的 `Apply-Config`…`Restart-ResidentIfRunning`（`Convert-IniValue` 本身归 `ini.ps1`） |
| `usage.ps1` | 3102–3211 | `Show-Usage` |
| `dispatch.ps1` | 3220–3439 | 插件装配 + `switch ($Command.ToLower())` → `Invoke-Main` |

> 行号是**当前**文件的行号，实施时按函数名搬迁，不按行号切（改一处行号就全变）。

---

## 5. 分阶段实施

每个阶段都是**可独立提交、可独立验证**的一步；任何一步失败都能整段回滚而不影响其它阶段。

### P0 基线与结构守卫（先立规矩，再动代码）

1. 记录基线：`tests\run-tests.ps1`（369 项）、`-Source dist\<pkg>`（101 项）、压缩体积（224,571 → 140,865）。
2. 在 `tests\run-tests.ps1` 新增 `struct` 组（拆分前先跑通，作为"不许退化"的锚）：
   - `clipboard.ps1` 行数 ≤ 200、`lib\*.ps1` 每个 ≤ 1400；
   - `lib\` 下每个文件 `Parser::ParseFile` 零错误；
   - `lib\` 下不出现 `$PSScriptRoot`、`$PSCommandPath`（AST 扫 `VariableExpressionAst`）；
   - `lib\` 下不出现顶层 `param(`（点源文件不接受参数）；
   - 主脚本里 `$Root = Split-Path -Parent $PSCommandPath` 恰好出现一次；
   - `-Library` 之后关键函数可见（`Show-Picker`/`Add-Item`/`Apply-Config`/`Invoke-Main` …）。
3. 确认 `build.ps1` 已按目录枚举 `lib\*.ps1`（现状如此），无需改动；跑一次打包确认新文件自动进包。

### P1 纯搬运：无依赖的叶子层

`base.ps1` → `ini.ps1` → `util.ps1` → `theme-stub.ps1` → `clip.ps1`。
这一步只移动文本，不改一行逻辑；主脚本点源后跑 `-Unit`（会大量调用 `Read-Ini`/`Get-CfgValue`/`Px`/`Format-Item`…）。

**验收**：`-Unit` 全绿；`status`/`config` 输出与拆分前逐字节一致（用 `diff` 比对保存的两份输出）。

### P2 领域层：存储与基础判定

`store.ps1`、`hotkey.ps1`、`entry.ps1`、`picker-geom.ps1`。

**验收**：`-Unit -Integration`；`get/list/put/pick/del/clear/status/diag` 输出与基线一致。

### P3 边界层：常驻、诊断、快捷方式、配置、帮助

`serve.ps1`、`diag.ps1`、`shortcut.ps1`、`config.ps1`、`usage.ps1`。

**验收**：`-Integration`（含 `install`/`uninstall`、`config set/init`、只读命令不生成 ini 等断言）、`-E2E`（起 daemon → 捕获 → 暂停 → stop → 查日志）。

### P4 装配层：主脚本收尾

`picker.ps1`（整体搬 `Show-Picker`）+ `dispatch.ps1`（`Invoke-Main`），主脚本缩到 ≈110 行。

**验收**：完整套件 369 项 + 打包产物 101 项 + 真机 `clipboard ui` 截图（面板、右键分组菜单、transform 直接粘贴）。

### P5 面板内部细化（可选，单独提交）

`Show-Picker` 现在 1294 行、24 个闭包，是唯一还"耦合"的地方。预案：

| 新文件 | 搬出内容 | 传参方式 |
|---|---|---|
| `picker-layout.ps1` | `Layout-Chrome`、`Size-List`、`Sync-Sb`、`Sb-ScrollTo`、`Scroll-By`、`Keep-SelectionVisible` | 收 `$P`（控件与状态哈希） |
| `picker-draw.ps1` | `Draw-KeyChips`、`Draw-Highlight`、行/空状态绘制、`Get-MeasureGraphics` | 收 `$P` + 绘制参数 |
| `picker-list.ps1` | `Get-Rows`、`Update-List`、过滤/高亮 token、`Sync-Placeholder`、`$rowCache` | 收 `$P`，返回新状态 |
| `picker-actions.ps1` | `Use-Index`、`Paste-Clip`、`Del-Index`、`Undo-Delete`、`Request-Clear`、`Clear-All`、`Find-PanelKey` | 收 `$P` |
| `picker.ps1` | 只剩窗体构造 + 事件绑定 + `$P` 初始化 | — |

关键点：`$P` 是**一个** `@{}`（`Form`/`List`/`Search`/`Prev`/`Debounce`/`Sbar`/`Keys`/`Rows`…），
替代闭包捕获。这样每个函数是纯"输入 `$P` → 产出效果"，可以单测 `Get-HitMarks`/`Layout-Chrome` 这类纯函数。

**验收**：369 + 101 + 三张真机截图（默认面板 / 搜索命中 / 右键分组菜单）+ `Ctrl+数字` 快选。

---

## 6. 风险与对策

| 风险 | 症状 | 对策 |
|---|---|---|
| `$PSScriptRoot` 混进 lib | 主题/插件/数据目录被解析到 `lib\` 下，面板空白或历史丢失 | `struct` 组用 AST 断言禁止；主脚本只保留一处 `$PSCommandPath` |
| 裸赋值搬进函数 | `$StoreDir` 变局部变量，写入位置变 `lib\data`，旧历史"消失" | 顶层路径初始化**留在主脚本**；必须在函数里做时一律 `$script:` |
| 点源顺序变了 | `$script:IniCache = Read-Ini` 在 `ini.ps1` 之前执行 → 命令全部走默认值 | 顺序固定：`base → ini → 其它`；`IniCache` 赋值放在所有点源之后 |
| 主题兜底被覆盖 | 删掉 `themes.ps1` 后 `Apply-Theme` 不存在，启动即崩 | 兜底实现单独放 `theme-stub.ps1`，且排在 `themes.ps1` 之前；`-Integration` 已有"主题缺失"相关断言 |
| 压缩器跨文件改名 | 拆出更多文件后 `New-FunctionMap` 仍是全项目一套，`ScriptVarMap` 按共享作用域分组 | 无需改压缩器；每阶段用 `-Source <pkg>` 跑 101 项验证兜底 |
| 沙箱漏拷贝 | 测试用 `New-Sandbox` 复制 `lib` 目录整份，新文件自动进；但 `build.ps1` 只复制插件/主题的非 `.ps1` | 新模块**只放 `.ps1`**；若将来加 `.txt`/`.md` 要同步改 `build.ps1` |
| 函数名撞车 | 同一点源作用域，重名会互相覆盖 | 沿用现有命名前缀（`Get-/Set-/Invoke-/Show-`）；`struct` 组断言"没有重复的顶层函数名" |
| 一次性提交过大 | 出问题无法定位是哪一步 | 严格按 P0–P5 分提交，每步都过 `-Unit -Integration` |

---

## 7. 验收标准

一次完整重构算完成，需要同时满足：

1. `tests\run-tests.ps1`（unit + integration + e2e）**369/369**；
2. 打包产物 `run-tests.ps1 -Integration -Source dist\clipboard-<ver>` **101/101**；
3. 压缩后体积不劣化（当前 37.3%，允许 ±0.5% 波动）；
4. `struct` 组全绿（行数上限、可解析、无 `$PSScriptRoot`、无顶层 `param`、`$Root` 唯一）；
5. 真机三张截图与重构前一致（面板 / 搜索 / 右键分组菜单），`transform` 点击仍直接粘贴；
6. `clipboard.ps1` ≤ 200 行，`lib\` 每个文件职责单一（一个文件里不出现"既读 ini 又画控件"这类跨层代码）；
7. `README.md` 的目录树与"插件契约/钩子"章节同步更新（新增 `lib\` 模块表）。

---

## 8. 回滚

每个阶段单独一个 commit，commit message 前缀 `refactor(lib):`；任一步验证不过即 `git revert` 该 commit。
P5 因涉及闭包改 `$P` 传参，允许在该 commit 上再做一次 `git revert` 而不影响 P0–P4。
