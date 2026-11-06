# Clipboard

Windows 10 / 11 的剪贴板历史工具，纯 PowerShell 5.1 实现，无第三方依赖。提供全局热键、可搜索的历史面板与常驻捕获。

程序由入口 `src\clipboard.ps1` 与 `src\lib\` 下的模块组成，分发时需整个目录一起复制。

数据保存在脚本目录内，不依赖 Windows 剪贴板历史服务（`cbdhsvc`），不联网，不需要管理员权限。

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

| 深色 | 浅色 |
|---|---|
| ![深色主题的历史面板](docs/screenshot-dark.png) | ![浅色主题的历史面板](docs/screenshot-light.png) |

> 截图为示例数据。

## 功能

- 全局热键呼出历史面板（默认 `Ctrl+Alt+V`），输入即过滤，回车粘回原窗口；原窗口的前台、焦点与光标位置始终不变（[焦点模型](#焦点模型)）
- 后台轮询剪贴板并去重，捕获文本、文件列表、图片与带格式文本（含图文混排）；条目过大或不适合保存的内容按配置跳过（[图片与带格式文本](#图片与带格式文本)）
- 容量可控：条数、单条大小、文本总量、媒体预算各自独立，超出时由旧到新丢弃，受保护标记的行不被裁剪（[配置](#配置)）
- 面板为 Win11 Fluent 风格自绘界面：虚拟列表只画可见行，置顶行在顶部冻结，长文本按行宽省略，搜索命中高亮，悬停 0.35 秒弹出预览卡片（文本 / 图片 / 排版），深浅两套主题
- 键盘与鼠标完备：方向键 / `Home` `End` / `PgUp` `PgDn` / 滚轮、`Ctrl+1..0` 数字快选、`Del` 删除、`Ctrl+Z` 撤销、`F2` 就地改文本；右键菜单作用于光标所在行，插件可注册条目
- 常驻进程带托盘菜单（显示 / 暂停 / 恢复 / 清空 / 退出），崩溃后自动重启；可选开机自启与桌面快捷方式（[开机自启与桌面快捷方式](#开机自启与桌面快捷方式)）
- 置顶 / 收藏 / 高亮 / 类型分析 / 按类型打开 / 粘贴改写 / 过期清理由插件提供，默认全部启用（[插件](#插件)）
- 所有设置都在 `clipboard.ini`：`config init` 写出带注释的模板，`config set` 逐键校验后写入（[配置](#配置)）
- 历史文件带格式版本号，`clipboard migrate` 负责升级（[数据版本与迁移](#数据版本与迁移)）


## 环境要求

- Windows 10 / 11
- PowerShell 5.1（系统自带，无需安装 .NET 或模块）
- 需要 **STA** 线程模型：启动器与快捷方式均带 `-Sta`，直接调用脚本时需自行加上

## 快速开始

源码目录不是安装包：直接在仓库里运行程序本体（`src\clipboard.ps1` + `src\lib\` / `utils\` / `schema\`），或在仓库根用 `cli` 执行 `package.ini` 中声明的命令。

```powershell
cli              # 列出 package.ini 中的命令
cli dev          # 启动常驻进程，被加载的文件变化后自动重启
cli test         # 运行全部自测
cli build        # 打包到 dist\clipboard-<version>\
```

`cli` 有 `cli`（Git Bash / MSYS）与 `cli.cmd`（CMD）两个启动入口，命令名不区分大小写，例如 `cli test -Unit`、`cli build -Config other.ini`；机制见[开发](#开发)。

程序本身也可直接调用，Git Bash 下 `./src/clipboard <命令>`，CMD 下 `src\clipboard.cmd <命令>`：

```powershell
.\src\clipboard.cmd diag               # 检查运行环境
.\src\clipboard.cmd install            # 建开机自启 + 桌面快捷方式
.\src\clipboard.cmd uninstall          # 只删快捷方式，保留历史与配置
.\src\clipboard.cmd uninstall purge    # 连历史、配置、日志一起删
```

`install` 生成的快捷方式以 `-ExecutionPolicy RemoteSigned` 运行脚本，可覆盖目标机 `Restricted` / `AllSigned` 的评估结果；需要更宽松的策略时用 `install bypass`。

打包产物（`dist\clipboard-<version>\`）含两个批处理，与 `clipboard.ps1` 同层：

| 脚本 | 做的事 |
|---|---|
| `install.bat` | `config init`（写出带注释的 `clipboard.ini`）→ `migrate`（升级旧格式历史）→ `install`（开机自启 + 桌面快捷方式） |
| `uninstall.bat` | `stop`（先停常驻进程）→ `uninstall purge`（删快捷方式，同时删除 `data\` 与 `clipboard.ini`） |

## 命令一览

| 分组 | 命令 | 说明 |
|---|---|---|
| **daemon** | `serve` | 运行常驻进程（捕获 + 热键 + 托盘） |
| | `stop` | 停止常驻进程 |
| | `ui` | 打开历史面板（常驻进程没跑会自动拉起） |
| | `status` | 常驻状态、自启状态、生效热键、存储路径、各标记数量 |
| | `pause` / `resume` | 暂停 / 恢复捕获 |
| **history** | `list [-Count N]` | 列出条目，最新在前（相对时间，排在最前的标记带 `*`） |
| | `get` | 输出剪贴板文本 |
| | `put "text"` | 写入剪贴板（省略文本时读 stdin） |
| | `pick N` | 把第 N 条放回剪贴板（图片与带格式文本按原格式写回） |
| | `edit N` | 用记事本改写第 N 条的文本（位置、时间、标记都不变；格式随旧文本一起丢掉） |
| | `del N` | 删除第 N 条（受保护的行要先由插件取消标记） |
| | `clear [-All]` | 清空历史（受保护标记的行永远保留；`-All` 连“标记保留”的行一起删） |
| **config** | `config` | 全部配置项与生效值（基础项 + 按插件分组，标注 ini / 默认值） |
| | `config get KEY` | 单个键的生效值与 ini 原始值 |
| | `config set KEY VAL` | 校验并写入单个键，常驻进程在跑时自动重启生效 |
| | `config edit` / `config init` | 用记事本编辑 / **与当前版本对齐**：补上新增的键、把已不存在的键注释掉，不动任何已有值 |
| | `config reset` | 用默认值**重写整个 ini**（唯一会丢配置的路径） |
| **theme** | `themes` | 列出可用主题（`*` = 当前生效） |
| **setup** | `diag` | 检查运行环境与数据版本 |
| | `export FILE` | 导出历史：`.json` 全量、`.csv` / `.txt` 仅文本；`-Media` 把图片写进 json |
| | `import FILE` | 导入导出文件；`-Replace` 整库替换（替换前自动备份） |
| | `backup [name]` / `restore-data [name]` | 把 `data\` 打成 zip 放到 `data\backup\` / 把某个快照放回去（当前历史先备份） |
| | `migrate [-Purge]` | 把旧格式的 `history.dat` 升级到当前版本；`-Purge` 把无法升级的文件归档到 `data\backup\` |
| | `restore` | 尝试恢复系统原生剪贴板历史的相关设置 |
| | `install [bypass]` / `uninstall [purge]` | 增删快捷方式（`purge` 连数据一起删） |
| | `version` | 输出程序版本与数据格式版本 |
| | `help` | 帮助（插件命令按插件名分组列在后面） |

`clipboard help` 的分组与之对应：`[daemon]` `[history]` `[config]` `[theme]` `[setup]`，加上每个已加载插件的 `[plugin: <name>]`；没有设置类的命令行开关，所有取值都在 `clipboard.ini`。

### 导出、导入与备份

| 文件 | 带什么 | 用于 |
|---|---|---|
| `.json` | 文本、时间、标记；`-Media` 时还有每张图片与每个富文本块的 base64 | 搬到另一台机器、长期归档 |
| `.csv` | 三列 `text,time,marks` | 丢进表格里筛、统计 |
| `.txt` | 每条一段，中间用 `---` 分隔 | 只读，不能再导回来 |

- **导入只认本程序的格式**：JSON 必须带 `format: clipboard-history` 与同名 `version`，CSV 必须是那三列的表头；否则直接报错，不会把别的文件当成历史读进来。
- **合并语义**：默认 `-Merge`，库里已有的条目（按文本比对）**原封不动**，标记也以库里为准，只补充缺失的；`-Replace` 换掉整个库，换之前先做一次快照，选错了还能用 `backup` 列表里的前一个恢复。
- **媒体还原不信任文件里的名字**：导入时按字节重算 sha1 再落盘，一份手改过的导出文件无法让记录指向 `data\media` 里的别的文件。
- **备份是整张 `data\` 的 zip**：历史、媒体、blob 一起走，否则图片条目恢复后只剩描述。`restore-data` 不带名字时取最新的一份；带名字时精确匹配，否则按子串匹配。

### 面板快捷键

| 按键 | 作用 |
|---|---|
| 直接输入 | 过滤，语法见[搜索语法](#搜索语法) |
| `↑` `↓` / 滚轮 / `PgUp` `PgDn` | 移动选中 / 滚动（滚轮后选中项会跟随可见区） |
| `Home` / `End` | 跳到第一条 / 最后一条 |
| `Enter` | 把选中条目粘到原来的窗口 |
| `Ctrl+Enter` | 只写入剪贴板，不自动粘贴 |
| `Ctrl+1..9` / `Ctrl+0` | 选取**当前可见**的第 1~9 / 10 行；每行行尾有 `Ctrl+1` … `Ctrl+0` 键帽提示（按住 `Ctrl` 时高亮），与小键盘位置一致（第 10 行是 `0`），滚动后从 `1` 重新编号 |
| `Del` / `Ctrl+Z` | 删除选中项 / 撤销上一次删除 |
| `F2` | 就地改写选中条目的文本：编辑框盖住列表，`Enter` 保存、`Shift+Enter` 换行、`Esc` 放弃；时间与标记不变，格式随旧文本一起丢掉 |
| `Ctrl+点击` / `Shift+点击` / `Ctrl+A` | 多选：`Ctrl` 逐个加或减，`Shift` 取一段，`Ctrl+A` 全选当前结果 |
| `Del`（多选时） | 一次删除所有选中项；带受保护标记的行会保留，并说明是哪个标记挡住的 |
| `Ctrl+Enter`（多选时） | 按列表顺序用换行拼接后复制（图片与文件条目没有文本，会统计在提示里） |
| `Esc` | 有搜索词时清空搜索，空搜索时关闭面板 |
| 拖动标题区 / 右下角手柄 | 移动面板 / 缩放面板（手柄悬停时才显示） |

### 搜索语法

输入按空格切分，每个词都要命中（默认只看每条记录的前 4096 个字符）。除普通词外还有几种写法：

| 写法 | 含义 |
|---|---|
| `word` | 包含该词（不区分大小写） |
| `"two words"` | 短语，空格算在内 |
| `-word` | 不包含该词 |
| `type:text` `type:files` `type:image` `type:rich` | 只看某一类；逗号表示「或」（`type:image,rich`），多个 `type:` 之间是「且」 |
| `type:link` `type:mail` `type:path` `type:code` `type:multi` | 由 `entry-actions` 插件提供的细分类型，未启用该插件时不可用 |
| `mark:p` / `-mark:p` | 带 / 不带某个标记（标记字符见[标记](#标记mark)） |
| `age:7d` | 早于 7 天（单位 `d` `h` `m` `s`，只写数字按天算） |
| `newer:2026-11-01` / `older:2026-11-01` | 时间范围 |
| `re:^alpha\s` | 正则表达式（忽略大小写，250 ms 超时） |
| `py:zg` | 拼音首字母，例如 `zg` 命中「中国」（GB2312 一级字） |

写错字段时面板会直接说明「搜索无法理解」，而不是当作普通词搜：未知的 `type:`、编译失败的正则、非法的时间都会让这一次搜索无结果。拼音只在前 128 个字符内取首字母，并且只在显式写 `py:` 时才计算——每次按键都对整库算一遍会让输入变卡。

### 焦点模型

面板以不激活方式显示（`WS_EX_NOACTIVATE`），按键由低级键盘钩子（`WH_KEYBOARD_LL`）截获后转发给面板自身：原窗口保持前台、焦点、光标位置与层级不变，面板中可直接输入过滤，原窗口收不到字符。关闭面板（`Esc`、回车粘贴、再按热键、点击面板外部）只卸载钩子。

输入法输入需要真实的键盘焦点（Win32 无双焦点，`SetFocus` 必定激活目标窗口），因此面板不在打开时接管，而是在输入法处于中文组字模式（`IME_CMODE_NATIVE`）且收到可打印键时交接：卸载钩子、临时去掉 `WS_EX_NOACTIVATE`、用 `AttachThreadInput` 附加前台线程后调用 `SetForegroundWindow`，确认成为前台后重放该键与本批剩余按键；失败则不重放并重装钩子。纯英文 / 数字输入不触发交接，`Ctrl+Space` 等输入法切换键一律放行。取不到键盘钩子时，面板从打开起即为接管模式。

粘贴前确认原窗口已回到前台（最多重试 24 次）；确认失败则不注入按键，保留面板并提示按 `Ctrl+V`。

插件可通过 `PanelKeys` 注册面板按键：`item-marks` 提供 `Ctrl+P` / `Ctrl+S` / `Ctrl+H`，`entry-actions` 提供 `Ctrl+O`，均列在 `clipboard help` 的 Panel keys 并根据来源插件标注。

底部提示为描边按键胶囊，随状态切换：默认 `Enter` Paste · `Ctrl+Enter` Copy only · `Del` Delete · `Esc` Close；按住 `Ctrl` 时变为 `1-9,0` Pick · `Enter` Copy only · `Z` Undo（启用 `item-marks` 时另有 `P` Pin / `S` Star / `H` Mark）；列表为空时只显示 `Esc` Close。删除、置顶、清空后短暂显示结果，被拒绝的操作（如置顶已达上限）在同处说明原因。

## 配置

程序启动时只读取脚本旁的 `clipboard.ini`，文件或某个键缺失时按内置默认值运行；只有 `config init` / `config set` / `config reset` 与下面提到的窗口尺寸回写会写文件。

读取时做一次全量校验：未知键、类型或范围不符的值、不存在的主题名、枚举项中的非法取值，在 `clipboard config` 顶部逐条列出，`status` 与 `diag` 只给出计数（`[!] N value(s) need attention`）；出错项按默认值继续运行。

`clipboard config init` 写出一份带注释的模板：只补缺失的键，已写的值（含插件设置）保留，所有插件的设置键都会列出（无论是否在 `Plugins=` 中启用），并把本版本不认识的键改为 `# [unknown] 原内容`；可重复执行。`clipboard config reset` 用默认值重写整个文件。ini 语法见 [INI 约定](#ini-约定)，插件键就写在 `[<插件名>]` 段里。

| 键 | 默认值 | 说明 |
|---|---|---|
| `DataDir` | 空 | 写入位置；空 = 脚本旁的 `data/`（即 `src\data\`）。相对路径相对脚本目录 |
| `Hotkey` | `Ctrl+Alt+V` | 全局热键；`Win+V` 在多数系统上被占用，注册失败会自动回退 |
| `HotkeyFallbacks` | 空 | 逗号分隔的回退链，按顺序尝试；空 = 内置 Ctrl+Alt+V / Win+V / Alt+反引号 / Win+Shift+V |
| `PasteKeys` | `^v` | 选定后用 SendKeys 发送的按键（`^+v` = Ctrl+Shift+V） |
| `ModReleaseTimeout` | `1200` | 最多等多久（毫秒）让修饰键松开再注入粘贴 |
| `PasteSettle` | `80` | 切回原窗口后、发 `PasteKeys` 前等待的时长（毫秒）；目标应用响应较慢时可增大 |
| `MaxItems` | `300` | 最多保留条数（置顶条目不受裁剪影响） |
| `MaxBytes` | `204800` | 单条**文本**上限，超出不入库（图片用 `MaxImageBytes`） |
| `MaxTotal` | `4194304` | 文本条目的总容量上限，超出丢最旧的（置顶条目保留） |
| `BlobThreshold` | `32768` | 超过该字符数的条目正文存到 `data/blobs/`，历史文件只留引用；`0` = 始终内联（单个 `history.dat` 自包含） |
| `MaxMediaTotal` | `134217728` | 图片与富文本附件（`data/media/`）的总容量上限，`0` = 不限；与 `MaxTotal` 分开计算，所以截图不会把文本条目挤掉 |
| `CaptureImages` | `1` | `1` = 捕获剪贴板里的图片 |
| `MaxImageBytes` | `16777216` | 单张图片上限；更大的图片记日志后跳过（不缩放，避免粘回去不是原图） |
| `CaptureRich` | `1` | `1` = 记住带格式文本的 HTML / RTF（含随复制一起来的图片块） |
| `MaxRichBytes` | `8388608` | 富文本**每个块**的上限（HTML 与 RTF 分开计数）；超出的那一块单独丢弃，不会连带丢另一块。RTF 里的图是十六进制，8 MB 的 RTF 约装得下 4 MB 的图 |
| `MaxRichImages` | `4194304` | HTML 里引用本机临时文件的图片，单张不超这个字节数就内联进 HTML（`data:` URI）；`0` = 不内联 |
| `PasteRich` | `1` | `1` = `pick` / 回车粘贴时把格式一起写回剪贴板，`0` = 只粘纯文本 |
| `PasteFilesAsText` | `1` | `1` = 文件条目粘贴时同时写入路径文本（地址栏、终端、编辑器才有内容），`0` = 只写文件列表 |
| `AppRules` | 空 | 按应用改粘贴行为：`程序名:动作`，`;` 分隔，如 `windowsterminal.exe:plain;code.exe:rich;*`；动作见[按应用规则](#按应用规则) |
| `Interval` | `300` | 剪贴板轮询间隔（毫秒） |
| `NoPaste` | `0` | `1` = 只写剪贴板，不自动粘贴 |
| `Balloon` | `1` | `1` = 启动时弹托盘气泡 |
| `Theme` | `win11-dark` | 主题名 = `themes/` 里的 `.ini` 文件名（如 `win11-dark` / `win11-light`），不接受别名 |
| `ExcludePattern` | 空 | 正则，匹配到的文本永远不会入库 |
| `WindowWidth` | `700` | 面板宽度（96 dpi 基准，高 DPI 按比例缩放），可自由拖右下角或用 `config set` 改 |
| `Rows` | `10` | **可见行数，面板高度的唯一来源**：高度 = 行数 × 行高（40）+ 头部（68）+ 底栏（40）+ 边框（2），永远只显示整行；会被屏幕工作区再收一次 |
| `WindowLeft` / `WindowTop` | 空 | 面板位置；空 = 在呼出窗口所在显示器的中上部 |
| `SaveWindowWidth` | `0` | `1` = 关闭面板时把拖出来的宽度写回 ini（高度不参与，它由 `Rows` 决定） |
| `SaveWindowPos` | `0` | `1` = 关闭面板时把当前位置写回 ini |
| `ShowTime` | `1` | `1` = 显示相对时间列 |
| `ShowTypeIcon` | `1` | `1` = 显示插件给的行图标；没有插件时本来就没有图标 |
| `ShowThumbnails` | `1` | `1` = 图片条目在图标槽里画一张小图（占满图标到文字之间的空间，等比缩放）；关掉只留文字标签 |
| `Highlight` | `1` | `1` = 高亮搜索命中 |
| `HighlightMaxBytes` | `8192` | 超过该大小的条目不参与高亮（`0` = 总是高亮） |
| `ShowNewlineMarker` | `1` | `1` = 换行显示为 ` <NL> `，`0` = 折成空格 |
| `PreviewHover` | `1` | `1` = 鼠标停留时在面板旁弹出预览卡片，`0` = 完全不弹 |
| `PreviewDelay` | `350` | 停在该行多久（毫秒）才弹卡片；快速扫过列表不会弹 |
| `PreviewChars` | `6000` | 卡片最多读取 / 显示的字符数（超出部分以 `...` 省略） |
| `Undo` | `1` | `1` = 面板内 `Ctrl+Z` 撤销上一次删除 |
| `DpiAware` | `1` | `1` = 按系统 DPI 渲染，`0` = 旧渲染方式 |
| `ScrollLines` | `0` | 滚轮步长（行），`0` = 跟随系统设置 |
| `Animations` | `1` | `1` = 悬停 / 选中切换 / 滚动条 / 搜索框下划线带过渡，`0` = 全部瞬时（不做整窗淡入，那会改变面板的不激活行为） |
| `Autostart` | `1` | `1` = `install` 创建登录自启快捷方式（`serve`） |
| `DesktopShortcut` | `1` | `1` = `install` 创建桌面快捷方式（`ui`） |
| `Plugins` | 全部插件 | 逗号分隔的插件**文件名**（不含 `.ps1`），**顺序即加载顺序**。默认逐个列出 `plugins/` 下的全部插件；改小列表就只加载列出的那几个 |

`config set` 按上表的类型与范围校验，写回时只改对应行（注释与其它键保持原样），常驻进程运行时自动重启生效。`config get <key>` 同时显示生效值与 ini 中的原始值，`config` 每行标注来源（`<- ini` / `<- default`）。

- 命令行只处理位置参数与 `list -Count N`；向命令传设置开关会因参数绑定失败被拒绝（如 `clipboard put hi -MaxItems 50`）。
- 只有 `SaveWindowWidth=1` / `SaveWindowPos=1` 会让程序写 ini：关闭面板时回写 `WindowWidth` / `WindowLeft` / `WindowTop` 三个键。
- `Rows` 同时约束置顶：粘性置顶最多占 `Rows - 1` 行，`item-marks.StickyRows` 超过该上限时 `config set` 拒绝，调小 `Rows` 时已设值自动下调；满额后再置顶会被拒绝并说明原因（命令行打印 `[!]`，面板显示在底部提示）。
- 默认值只有一处：`src\schema\clipboard.ps1` 每个键的 `Default`（`config init` 写它，读取失败也回退到它），值驱动的变量在 `src\lib\base.ps1`；改默认值改 schema 即可。

### INI 约定

仓库内的 ini 使用同一套语法（`package.ini`、`build.ini`、`clipboard.ini`、`themes\*.ini`），并共用同一份实现：`utils\ini.ps1` 负责文本与数据结构，`utils\import.ps1` 负责读文件与缓存，`utils\schema.ps1` 负责校验——程序、`cli` 与 `cli build` 都调它们，规则不会两边跑偏。

- 一行一个 `Key=Value`；`#` 或 `;` 开头**整行**为注释，行尾没有注释（值里的 `#` 属于值本身，如 `Accent=#5AC8FA`）；值不加引号，两端空白会被去掉；同一个键写两次以最后一次为准。
- `[section]` 把后续键归入该段：`[scripts]` 下的 `Dev=...` 与顶层的 `scripts.Dev=...` 是同一个键，`[item-marks]` 下的 `MaxPins=50` 与 `item-marks.MaxPins=50` 同理。段头必须整行只有 `[名字]`，后面不能跟注释。
- 段名小写，键名大驼峰；两者都不区分大小写，`config set`、`cli` 接受任意写法。
- 解析结果按文件缓存（键为路径，比较大小与写入时间），同一进程内重复读取不再扫盘解析；写入只改对应行并作废该文件的缓存，不重建整个文件。

| 文件 | 用途 | 段 |
|---|---|---|
| `package.ini` | 项目元数据与命令，`cli` 读取 | `[package]` 的 `Name` / `Version`，`[scripts]` 的命令名 |
| `build.ini` | 打包选项，`cli build` 读取 | `[build]` |
| `clipboard.ini` | 程序设置，由 `config init` 生成 | 基础键不分组；插件键写在 `[<插件名>]` 段里（平铺的 `<插件名>.<Key>` 仍可读） |
| `themes\*.ini` | 主题定义 | `[palette]` `[fonts]` `[metrics]` `[<插件名>]` |
| `schema\*.ps1` | 给上面两类文件用的 schema（`clipboard.ps1` / `theme.ps1`） | — |
| `schema\plugins\*.ps1` | 每个插件自己的键表：`Properties` 进 `clipboard.ini` 的 `[<插件名>]` 段，`ThemeProperties` 进主题 | — |

### schema 文件

一个 schema 就是一个 `.ps1` 文件，直接 `@{}` 输出哈希表（被点源，所以 `Ref` 能指向程序自己的变量）：

| 字段 | 必填 | 说明 |
|---|---|---|
| `Name` | 是 | schema 标识，也是文件名 |
| `File` | 否 | 它描述的 ini 文件（`clipboard.ini`、`themes\*.ini`） |
| `Description` / `Version` | 否 | 一句话说明 / schema 版本（键增删时递增） |
| `Properties` | 是 | `[ordered]` 键 → 键规格；顶层键与段内键都在这里 |
| `ThemeProperties` | 否 | 同上，但是只有主题能重写的外观键（不算 ini 键） |
| `Sections` | 否 | `[ordered]` 段名 → 段规格，描述一个段里的值（主题的 `palette` / `fonts` / `metrics`） |
| `ExtraSections` | 否 | 未列名段的规格（主题里的插件段、插件键的 `<插件名>.<Key>`） |

键规格（JSON Schema 的叫法优先）：

| 字段 | 说明 |
|---|---|
| `Type` | `string` / `int` / `number` / `bool` / `list` / `enum` / `regex` / `color` / `hotkey` / `theme` / `any` |
| `Default` | 文件里的默认写法（`1` / `0`、纯数字）；`config init` 写它，读取失败时也回退到它 |
| `Minimum` / `Maximum` | `int` / `number` 的下上界 |
| `Enum` | `enum` 的合法值；`list` 时是允许的 token |
| `Pattern` | `list` 里单个 token 的形状（默认字母、数字、`_ . -`） |
| `Description` | 一句话，`config` 与 `config init` 生成的文件都用它 |
| `Ref` | 值驱动的变量（`[ref]$script:X`）；点源后 `Apply-Config` 直接写它 |
| `Themeable` | `true` = 外观键，不是 ini 键 |
| `Target` | 仅用于 `Sections`：段里的值落到主题的哪一张表（`Palette` / `Fonts` / `Metrics` / `Plugin`） |

## 图片与带格式文本

图片与富文本都不写入 `history.dat`：图片存为 `data\media\<sha1>.png`，富文本的每个块各存一个文件（`<sha1>.html` / `.rtf` / `.png` / `.dib` / `.emf`），文件名是块自身内容的哈希，所以两条记录共用同一张图时只存一份；历史文件只保留引用（图片条目为 `image:<sha1>:<宽>x<高>:<字节>:PNG`，富文本记录留 `H:<sha1>:<字节>|T:<sha1>:<字节>|P:<sha1>:<字节>` 这样的块清单）。两者都按剪贴板给的原始字节落盘：`HTML Format` 的头部写着自身缓冲区里的字节偏移，`Rich Text Format` 是 8 位格式，经过一次字符串编解码就会把 UTF-8 变成乱码、偏移全部错位。

- 单次复制只让历史文件增长几十字节；重复复制同一张图按内容哈希去重。
- 记录被删除、清空或裁剪时，其独占的媒体文件在同一次保存中回收。
- 媒体有独立预算 `MaxMediaTotal`（默认 64 MB）：超出时由旧到新丢弃带媒体的行，受保护标记的行不动。

`pick N` 与面板中回车把捕获到的块全部写回剪贴板：纯文本、`HTML Format`、`Rich Text Format`，以及源应用同时提供的 `PNG` / 设备无关位图 / 图元文件（Excel 的图表、Word 的形状就是后两种），所以粘回 Word / Excel / PowerPoint / WordPad / 邮件客户端都能保留排版与图片，粘到记事本得到纯文本。

图文混排靠三步做到：

- **图片内联**：Word / Excel / 浏览器把图片放在临时目录（`msohtmlclip1/clip_image001.png`）里、HTML 里只写路径，那个目录活不过这次复制。不超 `MaxRichImages` 的图片在捕获时被读进来、换成 `data:` URI，四个头部偏移跟着重算。
- **粘贴时再落回文件**：Word / Excel / PowerPoint **不认 CF_HTML 里的 `data:` URI**，它们只按照 `<img>` 指向的文件取图（这也是它们自己写剪贴板的方式）。因此粘贴前会把 `data:` 图片解出来写成 `%TEMP%\clipboard-paste\<sha1>.<ext>`，HTML 里的 `src` 换回 `file:///` 并重算偏移 —— 否则文字能贴上，而每个图位都是空白框（预览卡片看着正常，因为它直接用存下的位图块画，不走 HTML）。同一张图只写一份；超过 24 小时的残留文件在下次粘贴时清掉。
- **留不住的图给个占位**：`<img>` 指向的临时文件若届时还在，就先拷进 `%TEMP%\clipboard-paste\` 再改写（源目录被删也不影响）；**文件已经不在**（超过 `MaxRichImages` 没被内联、或整块 HTML 以 `file:` 路径存下）时，这个图位换成一个虚线框占位：宽高沿用原图 `width` / `height`（夹在 96–360 px 宽之间），灰色虚线框里写着 `[ image not saved ]`。这样粘出去的文字与版式仍然完整，接收方能看出"这里原本有张图，只是没保存"，而不是一个空洞的裂图框。远程 `http(s):` 图片原样保留，目标自己去取。
- **图片块随行**：同一次复制里源应用额外提供的位图 / 图元文件也一起存下，粘贴时一并还原；目标程序自己会挑它偏好的那种。卡片渲染不出排版时（如 Excel 只给 HTML 与图元文件），就用第一张图片当缩略图。
- **卡片里的图片**：悬停卡片用离屏 `RichTextBox` 排版 RTF，而这个排版引擎**不画 `\pngblip`（PNG 图片）**——偏偏 Word / Excel 复制时的图片就是这种写法，所以卡片只能显示文字。因此排版前会把 `\pngblip` 就地改写成 `\dibitmap0`（`ConvertTo-CardRtf`，只影响显示，不动存储与剪贴板字节）；单张超过 4 MB、或一次排版累计超过 24 MB 的图片不改写，以免卡片卡住面板。

超过 `MaxRichImages`（默认 4 MB）的图不会被内联，日志里记一行 `html image not inlined`。这类图仍然能被预览（它存在源临时目录时就已拷进 `data\media`），但**源目录消失后只能粘出占位框**：想要图文混排长期可粘，把这个值调大，例如 `clipboard config set MaxRichImages 16777216`。

分别关闭：`clipboard config set CaptureImages 0` / `clipboard config set CaptureRich 0`；只粘纯文本：`clipboard config set PasteRich 0`。

在 Word 等程序中选中文字时，剪贴板同时包含一张位图，因此捕获以文本 / 富文本优先，所选内容不会被存成图片。

## 按应用规则

同一份历史粘到不同程序里，想要的结果不一样：终端要纯文本，Word 要排版。`AppRules` 按"粘到哪里"改行为。规则只管**粘贴**，捕获一律照旧。

```ini
AppRules=windowsterminal.exe:plain;code.exe:rich;*:no-paste
```

| 动作 | 含义 |
|---|---|
| `plain` | 即使这条记录带格式也只粘纯文本 |
| `rich` | 按 `PasteRich` 走（默认就带格式），写出来是为了让规则表自己说明意图 |
| `no-paste` | 只把内容写回剪贴板，不发 `PasteKeys`，省得终端里的 `Ctrl+V` 被当成别的意思 |
| `*` | 兜底：没被上面任何一条命中的程序用它 |

- 程序名写进程名，`.exe` 可省，大小写不敏感；`;` 或 `,` 分隔，空格随意。
- 看的是**粘贴时**的前台窗口；面板不抢焦点，所以它就是用户来的那个程序。
- `PasteRich` 仍是总开关：`PasteRich=0` 时 `rich` 规则也不会粘格式。
- 写错的规则会被拦下：`clipboard config set AppRules "notepad:cursive"` 报 `unknown action`。
- `clipboard config` 会显示当前生效的规则表；空表示所有程序一样。

## 主题

界面配色与字体不写在脚本里：每个主题是 `themes/<name>.ini`（纯 ini，不执行任何代码），`clipboard.ini` 的 `Theme=` 只写主题名。

| 主题 | 配色 | 说明页 |
|---|---|---|
| `win11-dark` | Windows 11 Fluent 深色，默认主题（也是参考布局） | [win11-dark.md](src/themes/win11-dark.md) |
| `win11-light` | Windows 11 Fluent 浅色，布局相同，底色反相 | [win11-light.md](src/themes/win11-light.md) |

```powershell
clipboard themes                        # 列出可用主题（* = 当前生效）
clipboard config set Theme win11-light  # 校验 + 写入 + 重启常驻
```

主题定义颜色、字体、行几何与插件外观，本节说明主题文件的写法与可用 token。两条约束：

- 主题颜色不是 `clipboard.ini` 的键，只能在主题文件中修改（`config set Theme.Accent` 会报 unknown key）。
- 未知 token、非法颜色、越界数值仅写日志，不影响其它项；`Theme=` 无效时回退 `win11-dark`。

### 主题文件格式

```ini
# 注释必须独占一行：# 或 ; 开头
Name=my-theme
Description=my colours
# 空 = 自动（Segoe UI Variable Text → Segoe UI）
FontFamily=
# 空 = 自动（Segoe Fluent Icons → Segoe MDL2 Assets）
IconFamily=

# 颜色值以 # 开头，那是值的一部分，不是注释
[palette]
# #RRGGBB 或 #AARRGGBB（alpha 在前）
Surface=#101418
Text=#E8EAED
Accent=#5AC8FA
Border=#18FFFFFF

# 字号（pt）
[fonts]
Body=10.5
Title=13

# 可选，96 dpi 设计度量
[metrics]
RowHeight=40

# 段名 = 插件名：重写该插件的 ThemeProperties
[item-marks]
StarColor=#FFD700
```

| 段 | 说明 |
|---|---|
| 顶层 | `Name` / `Description` / `FontFamily` / `IconFamily` |
| `[palette]` | 颜色 token，未知 token 忽略并写日志 |
| `[fonts]` | `Body` `Small` `Tiny` `Title` `Icon` `IconSmall` `IconBig` |
| `[metrics]` | 覆盖行几何：`RowHeight` `HeadHeight` `FootHeight` `RowGap` `RowInset` `TextInset` `IconSlot` `TimeWidth` `CapWidth` `ChipHeight` …（键名 = `base.ps1` 的 `$script:Metric`，取值 1–4000，未知键或越界值写日志后忽略；每次应用主题都从内置表重新叠加，不继承上一个主题的数字） |
| `[<插件名>]` | 重写该插件的 **ThemeProperties**（只对这个主题生效） |

可用颜色 token（全部可选，缺省沿用内置 dark 值）：

```
Surface Field FieldBorder Text Dim Faint Accent AccentSoft Border SelBg HoverBg
BadgeBg BadgeText KeyCapBg KeyCapBorder Mark Warn
```

> 叠层色（`SelBg` / `HoverBg` / `Border` / `BadgeBg` / `AccentSoft` / `KeyCapBorder`）请保留 alpha：面板是把它们半透明地叠在 `Surface` 上，不透明就失去了 Fluent 的层次感。

加载规则：

- 只有 `themes/*.ini` 参与，名字 = 文件名（忽略大小写）；不写主题名（或名字不存在）会回退到 `win11-dark` 并记一行日志。
- 解析名字只读文件名，不解析内容，所以坏主题不会影响 `config` / `status`；名字不存在或文件读不了 → 回退 `win11-dark` / 内置配色并写日志。
- 主题切换后需重启常驻进程生效（`config set Theme` 会自动重启；手工改 ini 则 `clipboard stop` + `clipboard serve`）。

## 插件

插件默认全部启用：`clipboard.ini` 的 `Plugins=` 逐名列出 `plugins\` 下的文件，顺序即加载顺序，未列出的文件不会被执行。加载靠前的插件在右键菜单中更靠前，并优先获得 `TypeGlyph` / `Transform` 这类只允许一个插件生效的钩子。

| 插件 | 功能 | 启用 |
|---|---|---|
| [`item-marks`](src/plugins/item-marks.md) | 置顶 / 收藏 / 高亮：`pin` `unpin` `star` `unstar` `highlight` `unhighlight` `marks`，面板 `Ctrl+P` `Ctrl+S` `Ctrl+H`，右键三项；高亮修改文字与背景色，不改变左侧选择条；粘性置顶默认开启（置顶行冻结在列表顶部，受行数上限约束），达到上限后拒绝置顶并说明原因 | `Plugins=item-marks` |
| [`entry-actions`](src/plugins/entry-actions.md) | 类型分析与打开：`kind` / `kinds` 输出类型、格式与预览，`open` 按类型打开（链接 / 路径 / 文件列表 / 图片），面板 `Ctrl+O`，右键 “Open link or path”；行图标由该插件提供 | `Plugins=entry-actions` |
| [`transform`](src/plugins/transform.md) | 粘贴前改写文本：纯文本 / 全大写 / 小写 / 驼峰 / 蛇形 / 烤肉串 / 标题式；右键按 `transform.Modes` 逐项列出 `Transform as <模式>` | `Plugins=transform` |
| [`retention`](src/plugins/retention.md) | 过期清理：按天数删除旧条目，受保护标记的行不清理 | `Plugins=retention` |

各插件的命令、设置项、主题项见其说明页。

```ini
# 默认值：全部插件逐个列出，顺序即加载顺序
Plugins=entry-actions,item-marks,retention,transform

# 只留部分功能：删掉不需要的名字即可
Plugins=item-marks,entry-actions
```

| 层 | 位置 | 职责 |
|---|---|---|
| 入口 | `clipboard.ps1` | 参数绑定、`$Root`、必需模块清单、运行时路径（ini / store / log 位置）、`Invoke-Main` |
| 装配 | `lib/dispatch.ps1` | `Invoke-Main`：先 `Apply-Config`，再按 `Plugins=` 装配插件，最后执行一个命令 |
| 场景 | `lib/picker.ps1`、`lib/pinlist.ps1`、`lib/picker-draw.ps1`、`lib/picker-edit.ps1`、`lib/preview.ps1`、`lib/anim.ps1`、`lib/keyhook.ps1`、`lib/serve.ps1`、`lib/config.ps1`、`lib/config-template.ps1`、`lib/diag.ps1`、`lib/shortcut.ps1`、`lib/usage.ps1` | 面板窗与交互、自绘列表、可复用的绘制件、就地编辑条目、悬停预览卡片、过渡动画、键盘钩子、常驻进程、设置命令面与写出的模板、诊断恢复、快捷方式、帮助 |
| 领域 | `lib/clip.ps1`、`lib/store.ps1`、`lib/marks.ps1`、`lib/layout.ps1`、`lib/media.ps1`、`lib/migrate.ps1`、`lib/entry.ps1`、`lib/hotkey.ps1`、`lib/picker-geom.ps1` | 剪贴板读写、历史记录存储、标记语义、行序与冻结行数、图片与富文本附件、数据格式迁移、条目分类与文案、修饰键状态、面板纯计算 |
| 基础 | `lib/native.ps1` | 平台层（P/Invoke、WinForms 类型、程序集、字体探测、DPI） |
| 工具 | `utils/log.ps1`、`utils/time.ps1`、`utils/format.ps1`、`utils/draw.ps1` | 纯函数：日志写入、epoch 与相对时间、字节计数、像素缩放与圆角路径（不碰剪贴板、不碰历史） |
| ini | `utils/ini.ps1`、`utils/import.ps1`、`utils/schema.ps1` | 文本→文档、按 key 增删改查、文件导入与缓存、schema 加载/校验/单值转换（不知道任何一个具体的键） |
| 描述 | `schema/clipboard.ps1`、`schema/theme.ps1`、`schema/plugins/*.ps1` | 每个 ini 文件、每个插件的键表：类型、范围、默认值、说明、驱动变量 |
| 底 | `lib/base.ps1`、`lib/theme-stub.ps1` | 常量与全部默认值；内置配色与主题空实现（`lib/themes.ps1` 覆盖它们） |
| 加载层 | `lib/plugins.ps1`、`lib/plugin-settings.ps1`、`lib/plugin-marks.ps1` | 插件运行时（白名单 / 命令 / 右键项 / 按键 / 行图标 / 钩子）、插件设置面、标记含义（保护 / 置顶 / `clear` 保留 / 打印用词） |
| 加载层 | `lib/themes.ps1` | 主题发现 / 校验 / 颜色解析 / `Apply-Theme`（缺失时 `theme-stub` 的内置配色接管） |
| 扩展 | `plugins/*.ps1` + `schema/plugins/*.ps1` | 插件文件只声明行为（命令、右键项、面板按键、行图标、标记）；它的键表在自带的 schema 文件里 |

插件契约：一个 `.ps1` 文件 `return` / 直接输出一个哈希表。

| 键 | 必填 | 说明 |
|---|---|---|
| `Name` | 是 | 插件名，必须与文件名（去扩展名）一致（不一致会写一行警告） |
| `Description` | 否 | 一句话说明，`clipboard config` 会展示 |
| `Commands` | 否 | `@{ 'open' = { param($value) ... } }` → 变成 `clipboard open <值>` |
| `CommandHelp` / `CommandOrder` | 否 | 每个命令的一行说明（`clipboard help` 用）/ 打印顺序 |
| `ContextMenu` | 否 | `@( @{ Label = '...'; Test = { param($rec) ... }; Invoke = { param($rec) ... } } )`，右键菜单项；`Test` 返回 `$false` 时不显示。基础层按插件分组：每组以灰字插件名开头（不可点），组间一条分隔线，组内不插标题，顺序 = `Plugins=` 加载顺序；整组隐藏时标题与分隔线一同消失。也可写成返回同构数组的脚本块，使项数跟随插件设置（`transform` 按 `transform.Modes` 生成）。项内 `After = 'paste'` 表示动作结束后直接粘贴到原窗口（`transform` 使用），缺省则只写入历史；`Invoke` 返回字符串时作为底部提示显示 |
| `PanelKeys` | 否 | `@( @{ Key = 'O'; Ctrl = $true; Label = '...'; Test = ...; Invoke = ... } )`，面板按键；不会覆盖基础按键。`Invoke` 返回一个字符串时，那句话会显示在底部提示行（`item-marks` 拒绝置顶时就这样说原因） |
| `TypeGlyph` | 否 | `{ param($payload) ... }`，条目 → 行图标（返回空 = 该行不画图标）；第一个给出非空值的插件胜出 |
| `Tick` / `Transform` | 否 | 常驻循环任务（`@{ Seconds; Action }`，`Seconds` 可写脚本块，所以间隔能跟随自己的设置）/ 粘贴前改写 |
| `RowDecor` | 否 | `{ param($rec) @{ Marks = @( @{ Glyph = '..'; Color = '#..' } ); TextColor = '#..'; BackColor = '#..' } }`，行尾标记字形与整行文字/背景色 |
| `Marks` | 否 | `[ordered]@{ x = @{ Set = 'on'; Unset = 'off'; Word = 'marked'; Hint = 'Ctrl+X'; Protected = $false } }`，声明本插件用的标记字符 |
| `SortMark` | 否 | 带该标记的行浮到列表最前（只能有一个） |
| `StickyMark` | 否 | 带该标记的行在列表顶部**冻结**，不随滚动移动（“粘性置顶”；只能有一个） |
| `StickyRows` | 否 | 数字或脚本块，冻结的粘性行最多占几行：`0` = 关闭该特性，负数 = 由面板按可见行数决定；插件写置顶动作时要先用 `Get-PluginStickyCap` 看剩余配额 |
| `ClearKeeps` | 否 | 数组或脚本块，`clear` 默认保留的标记 |
| `Init` | 否 | 每个进程只跑一次的初始化（设置全部解析完之后） |

插件文件里**不写** `Settings` / `ThemeSettings`：设置键表在 `schema\plugins\<插件名>.ps1`（`Properties` → `clipboard.ini`，`ThemeProperties` → 主题），加载时合并，详见[插件自己的配置项](#插件自己的配置项)。

### 标记（mark）

记录的 `flags` 由一个类型字符（`t` 文本 / `f` 文件列表 / `i` 图片）加若干单字符标记组成。**基础层不认识任何一个具体标记**：它只存字符、按声明排序/保护/统计，其余全由插件声明：

| 声明 | 基础层的行为 |
|---|---|
| `Marks` | 命令行收尾提示、`status`、`clear` 文案都用声明里的词；`Protected` 决定该标记是否保护行 |
| `Protected = $true` | `del` 拒绝、裁剪与 `clear` 跳过，直到插件用自己的 `Unset` 命令取消标记 |
| `SortMark` | 带该标记的行排到列表最前（置顶就是这么实现的） |
| `StickyMark` + `StickyRows` | 带 `StickyMark` 的行固定在列表顶部、不随滚动移动，冻结行数取 `StickyRows` 与 `可见行数 - 1` 的较小值，**永远给下面的行留一行**；这个上限同时约束“置顶”动作，满额后再置顶会被拒绝而不是把列表冻满。冻结行数在底部计数里显示（`10 of 15   3 pinned`） |
| `ClearKeeps` | `clear` 默认保留这些标记；`-All` 忽略它，但保护标记永远保留 |

因此新增一个标记不需要改基础层（`lib\store.ps1`）：写插件、声明标记、在 `RowDecor` 里画出来即可。多个标记可以同时存在同一行。

基础层调用 `Get-PluginActions` 时会给每个菜单项标上 `Plugin`（指向声明它的插件），画面才据此分组；插件自己声明的哈希表不会被改动。

钩子按触发时机看：

| 时机 | 钩子 |
|---|---|
| 加载完成一次 | `Init` |
| 命令行 | `Commands` + `CommandHelp` + `CommandOrder` |
| 面板加载 / 按键 | `PanelKeys`、`ContextMenu`、`RowDecor`、`TypeGlyph` |
| 粘贴前 | `Transform` |
| 常驻循环 | `Tick` |
| 配置 / 标记规则 | `Properties`（ini）、`ThemeProperties`（主题）、`Marks` / `SortMark` / `StickyMark` / `StickyRows` / `ClearKeeps`（标记） |

基础按键（`Enter` / `Ctrl+Enter` / `Ctrl+1..9` / `Ctrl+0` / `Del` / `Ctrl+Z` / `Esc` / 翻页）永远优先，插件按键只在都不匹配时才会被询问。

基础的 `Get-EntryKind` 只回答“文本、文件列表还是图片”（存储、行内容与粘贴往返用），**基础层不画任何行图标**：图标完全由插件通过 `TypeGlyph` 提供，返回空就不画，文字也从行首开始。`entry-actions` 就是靠它按类型给图标的，所以要图标就启用它。

插件自带两路的键表是两个不同的通道，不要混（同一个文件里写，分别落在两个表）：

| | `Properties` | `ThemeProperties` |
|---|---|---|
| 写在哪 | `clipboard.ini` 的 `[<插件名>]` 段（用户设置） | `themes/*.ini` 的同名段（主题文件） |
| 键名 | `<插件名>.<Key>`，`config set` 用这个名字 | 段内写 `<Key>` |
| 谁改 | 用户（`config set` / 直接编辑） | 主题作者 |
| 适合 | 行为开关（模式、是否启用） | 颜色、字形、强调样式 |
| 读取 | `Get-PluginSetting 'x' 'Key'` | `Get-PluginTheme 'x' 'Key'` |

两条通道的分界：**行为**进 `Properties`（`clipboard.ini`，用户可改），**外观**进 `ThemeProperties`（`themes\*.ini`，随主题生效）。`item-marks` 的高亮是这样落地的：高亮行的文字色与底色只来自主题键 `[item-marks]` 的 `EmphasisInk` / `EmphasisFill`，`clipboard.ini` 中没有对应项。

`ThemeProperties` 不会被写进 `clipboard.ini`，`config` 里也看不到（它不是用户可以改的东西）；优先级是 schema 的 `Default` < 主题 ini 段（只对该主题生效），值同样按 `Type` 校验。

### 插件自己的配置项

插件可以带零到多个设置，声明在 `schema\plugins\<插件名>.ps1` 的 `Properties` 里；插件加载时合并进设置 schema，与基础键共用一套校验/展示管线，键名为 `<插件名>.<Key>`。

> `clipboard config init` 只补缺失的键：插件设置段默认已经写在文件里（插件默认全开），已写的插件值不会被默认值顶掉。

```ini
# 只启用一个插件时，Plugins= 只写它（默认列出全部）
Plugins=entry-actions

[entry-actions]
Browser=C:\Tools\browser.exe
Reveal=1
```

```powershell
clipboard config                          # 基础键之后按插件分组列出
clipboard config get entry-actions.Reveal
clipboard config set entry-actions.Reveal 0
```

- `Type` 与基础 schema 一致：`bool` / `int`（配 `Minimum`/`Maximum`）/ `enum`（配 `Enum`）/ `regex` / `hotkey` / `list` / `string`；非法值会被拒绝（`config set`）或在加载时回退默认并写日志。
- 插件代码里用 `Get-PluginSetting 'entry-actions' 'Reveal'` 读当前生效值（已合并 ini 与默认值）；外观项用 `Get-PluginTheme`。
- 插件未在 `Plugins=` 中列名时，它的键**不生效**：`config get` 会提示先把插件加回 `Plugins=`，插件命令与 `help` 也看不到；但 `config init` 仍会把它的设置键写进模板，便于先看清有哪些旋钮。

注意事项：

- 插件默认全部加载：`Plugins=` 在模板中逐个列出所有插件，删除某个名字后其文件不会被执行；名字写错时提示 `[!] plugin not found: xxx`，基础功能不受影响。
- 脚本块必须自包含：可以调用基础函数（`Get-Records`、`Get-EntryKind`、`Write-Log`、`Format-Item`），但不能引用插件文件作用域的变量，该作用域在命令执行时已销毁，捕获到的值为 `$null`。多个脚本块需共享逻辑时，把逻辑作为哈希表的一个键（如 `KindOf = { ... }`），通过 `& (Get-PluginData '<插件名>' 'KindOf') $arg` 调用。
- 同一逻辑只实现一次：钩子、命令、右键项、面板按键常需同一行为，应抽成插件的共享块分别调用；内置四个插件均为此结构（`KindOf` / `CanOpen` / `OpenPayload` / `Sniff`、`Apply`、`Sweep`、`PinOne`）。
- 使用基础层提供的接口，不直接读取内部状态：行装饰用 `RowDecor`、图标用 `Get-RowGlyph`、标记用 `Test-Mark` / `Get-ProtectedMarks` / `Get-SortMark`、批量修改用 `Update-Records`。
- 插件文件保持纯 ASCII：PowerShell 5.1 将无 BOM 的 UTF-8 按 ANSI 解码，中文会导致语法错误。
- 单个插件抛出异常时只记录一行日志，不影响其它插件与基础命令。

写一个新插件的最小示例：

```powershell
# plugins/my-thing.ps1
@{
  Name     = 'my-thing'
  Commands = @{
    'upper' = {
      param($value)
      $i = 0
      if (-not [int]::TryParse([string]$value, [ref]$i)) { Write-Host 'usage: clipboard upper 3'; return }
      $recs = @(Get-Records)
      if ($i -lt 1 -or $i -gt $recs.Count) { Write-Host 'index out of range'; return }
      Write-Host ([string]$recs[$i - 1].Payload).ToUpper()
    }
  }
}
```

## 兼容性（Windows 10 / 11）

| 项 | 处理方式 |
|---|---|
| 图标字体 | 优先 `Segoe Fluent Icons`（Win11），缺失时回退 `Segoe MDL2 Assets`（Win10），字形码全部在两者中都存在 |
| 系统 DPI | `SetProcessDPIAware` + `GetDpiForSystem` 都放在 `try/catch` 里（Win10 1607 之前没有 `GetDpiForSystem`），失败时按 96 dpi 渲染 |
| 主题 | 深浅色由自绘调色板决定，不依赖 `DwmSetWindowAttribute` 之类的 Win11 专用 API |
| 全局热键 | `Win+V` 在 Win10/11 上被剪贴板历史占用，注册失败按 `HotkeyFallbacks` 回退 |
| 托盘 / 通知 | 只用 `NotifyIcon` 与气泡，不依赖 Win11 的 Toast 通道 |
| PowerShell | 只要求 5.1（系统自带），不使用 Core 专有语法 |

## 文件与数据

```
package.ini             项目元数据与命令：Name / Version / [scripts] 下的命令名（cli 读取）
cli  cli.cmd  cli.ps1   命令入口（sh / CMD / PowerShell），执行 package.ini 中的命令
build.ini               打包选项（输出目录 / 压缩 / 重命名 / 验证 / 打哪些插件与主题）
scripts/build.ps1       打包脚本（读 src\，输出 dist\clipboard-<version>\，并写 install.bat / uninstall.bat）
scripts/minify.ps1      压缩器（按语法树合并语句、删注释与缩进、重命名内部函数与局部变量、C# 段去注释折行）
scripts/dev.ps1         开发运行：启动常驻并监视被加载的文件，变化即重启
scripts/test.ps1        自测入口（转发 tests\run-tests.ps1 的开关）
scripts/shot.ps1        重新生成 docs\ 下的界面截图
tests/run-tests.ps1     自测套件
docs/                   界面截图
dist/                   打包产物（不入库）

src/                    程序本体（打包只读这个目录）
  clipboard               Git Bash / MSYS2 启动器（sh 壳，负责把路径转成 Windows 形式）
  clipboard.cmd           CMD 启动器
  clipboard.ps1           入口：参数绑定 / $Root / 必需模块清单 / 运行时路径 / 调用 Invoke-Main
  clipboard.ini           配置（只读；不存在时用内置默认，config init 才生成）
  data/                   历史 / 日志 / 生效热键缓存 / 媒体（不入库）
  lib/base.ps1            常量、版本读取、记录格式、运行时标识、度量/字形/时序与全部默认值
  lib/native.ps1          平台层：P/Invoke、WinForms 类型、程序集加载、字体探测、DPI
  lib/theme-stub.ps1      内置配色与主题空实现（lib/themes.ps1 会覆盖它们）
  lib/media.ps1           图片与富文本的媒体文件：块存储、图片内联、载荷编解码、孤儿回收
  lib/media-render.ps1    图片与富文本的位图：缩略图文件、两级位图缓存、缩放与三种预览图
  lib/clip.ps1            剪贴板读写（文本 / 文件清单 / 图片 / HTML+RTF）
  lib/store.ps1           历史文件：CBHIST 读写、版本字段、加锁、记录增删与裁剪
  lib/marks.ps1           标记的读写与含义查询（保护 / 置顶 / clear 保留 / 打印用词，不碰文件）
  lib/layout.ps1          行序规则：排序标记置顶、粘性置顶的可冻结行数（纯计算）
  lib/migrate.ps1         数据格式迁移：检测版本、备份、逐级升级
  lib/settings.ps1        设置文件层：schema 装配、读全量 / 读单键 / 写单键（config 与插件设置共用）
  lib/hotkey.ps1          修饰键状态（解析在 utils/hotkey.ps1）
  lib/entry.ps1           条目分类（text / files / image / empty）、图标兜底与条目文案
  lib/query.ps1           搜索语法：字段含义、正则编译、类型判定、逐条匹配与执行
  lib/select.ps1          批量选择：位置集合、Ctrl/Shift 规则、批量复制与批量删除
  lib/picker-geom.ps1     面板纯计算：行数、数字快选、窗口位置、命中高亮
  lib/anim.ps1            过渡动画的数值层（缓动 / 插值，不碰窗口）
  lib/picker-draw.ps1     可复用绘制：按键胶囊、搜索命中着色（只要 Graphics + 参数）
  lib/pinlist.ps1         自绘列表控件 Cb.PinList：只画可见行，置顶行不随滚动
  lib/preview.ps1         悬停预览卡片：复用窗口，渲染文本 / 图片 / 富文本
  lib/keyhook.ps1         低级键盘钩子：面板拿按键但不抢前台窗口
  lib/picker.ps1          历史面板：窗体、过滤、列表、按键、右键菜单、粘贴
  lib/serve.ps1           常驻进程：捕获循环、热键、托盘、崩溃重启
  lib/diag.ps1            diag 报告与 restore
  lib/shortcut.ps1        开机自启 / 桌面快捷方式的安装与卸载
  lib/config.ps1          config 命令面：应用设置、打印有效值、重启常驻
  lib/config-template.ps1 写进文件的 clipboard.ini：注释模板、config init 的补键合并、config reset
  lib/usage.ps1           help 输出（基础命令分组 + 每个插件的分组）
  lib/dispatch.ps1        Invoke-Main：先 Apply-Config，再装配插件，最后执行一个命令
  lib/plugins.ps1         插件运行时（Load-Plugins / 命令 / 右键项 / 按键 / 行图标 / 钩子）
  lib/plugin-settings.ps1 插件设置面（schema\plugins 的 Properties → ini 段，ThemeProperties → 主题段）
  lib/plugin-marks.ps1    标记含义（保护 / 置顶 / clear 保留 / 打印用词）
  lib/themes.ps1          主题加载层（发现 / 校验 / 颜色解析 / Apply-Theme）
  plugins/*.ps1           插件（item-marks / entry-actions / transform / retention；默认全部加载）
  plugins/*.md            每个插件的说明页
  themes/*.ini            主题（win11-dark 默认 / win11-light）
  themes/*.md             每个主题的说明页

  utils/ini.ps1           文本 → 文档（Read-IniDoc）与文档上的按 key 增删改查（纯函数）
  utils/import.ps1        导入一个 ini 文件（按路径缓存，文件大小 + 写入时间失效）与写回单个键
  utils/schema.ps1        schema 的加载 / 形状校验 / 单值校验转换（不认识的键一律报错）
  utils/hotkey.ps1        热键字符串 → 修饰键 + 虚拟键码（纯查表，不碰窗口）
  utils/log.ps1           日志文件写入（Ensure-Dir / Write-Log，永不抛异常）
  utils/time.ps1          epoch 与相对时间（now / 5m / 3h / 2d / MM-dd）
  utils/query.ps1         把一行搜索切成词：引号短语、-排除、name:value 拆分（不理解含义）
  utils/pinyin.ps1        汉字首字母（GB2312 一级字按拼音排序，范围查表，无码表）
  utils/format.ps1        字节计数（812 B / 12 KB / 2.3 MB）
  utils/draw.ps1          DPI 缩放（Px）与圆角路径/区域（纯计算，返回对象由调用方释放）

  schema/clipboard.ps1    clipboard.ini 的 schema（键 / 类型 / 范围 / 默认 / 说明 / 驱动变量）
  schema/theme.ps1        themes\*.ini 的 schema（元键、palette/fonts/metrics 段、插件段）
  schema/plugins/*.ps1    每个插件自己的键表（Properties / ThemeProperties），加载时合并进设置
```

分层顺序即依赖方向：`clipboard.ps1`（入口）→ `dispatch`（装配命令）→ `picker` / `preview` / `media-render` / `serve` / `config` / `diag` / `shortcut` / `usage`（场景）→ `store` / `migrate` / `clip` / `media` / `entry` / `hotkey` / `picker-geom`（领域）→ `native`（基础）→ `utils`（ini / import / schema、log / time / format / draw）→ `schema` / `base` / `theme-stub`（描述、常量与兜底配色）。只允许上层调用下层；`utils` 里的函数只接受值、返回值，不读剪贴板也不读写历史，也不认识任何一个具体的键。

两条结构约束由 `struct` 组校验：

- `$Root` 只在入口文件中计算。点源文件中的 `$PSScriptRoot` 指向 `lib\`，据此拼接路径会使 `themes\`、`plugins\`、`data\` 全部错一层。
- 只有 `base.ps1`（默认值）与 `config.ps1`（加载 `schema\clipboard.ps1` 并持有设置表）在加载时赋值，其余模块只定义函数，因此点源顺序只对这两个文件敏感。

除 `lib\themes.ps1` 与插件三件套（`plugins.ps1` / `plugin-settings.ps1` / `plugin-marks.ps1`，要么全有要么全无）外，模块缺失会报 `missing: …\<lib|utils>\<name>.ps1` 并以退出码 1 结束，因此分发时必须提供 `lib\`、`utils\`、`schema\` 三个目录。

写入位置由 `clipboard.ini` 的 `DataDir=` 决定，留空则使用脚本旁的 `data\`（相对路径相对脚本目录）；`config` 的 `data dir` 与 `status` 的 `store file` 显示实际生效位置。程序不写入 `%LOCALAPPDATA%` 或其它用户目录：位置不可写时报错并以退出码 1 结束，不回退到其它位置。除 `install`（快捷方式）与 `restore`（注册表项）外不写注册表。

### 历史文件格式

`data\history.dat` 是纯文本，不使用 JSON 或数据库：

```
CBHIST RS <数据版本> RS <flags> US <epoch 秒> US <extra> US <payload> RS <flags> US ...
```

- 头部两项：固定标记 `CBHIST` 与数据格式版本（当前为 `1`）
- `flags` = 一个类型字符（`t` 文本 / `f` 文件列表 / `i` 图片）后跟若干单字符标记；标记含义由插件声明，基础层只存不改，例如 `tps` 为文本条目加 `p`、`s` 两个标记
- `extra` 为空，或写富文本附件的块清单：`H:<sha1>:<字节>`、`T:`（RTF）、`P:`（PNG）、`D:`（设备无关位图）、`E:`（图元文件），用 `|` 连接；`payload` 为条目本体
- 分隔符：`RS` = `0x1E`，`US` = `0x1F`；类型签名字符为 `0x01`（文件列表）与 `0x03`（图片）
- 条目本体有三种形态：普通文本；文件列表（`0x01` + 换行连接的路径）；图片描述（`0x03` + `image:<sha1>:<宽>x<高>:<字节>:PNG`）
- 入库前文本中的 `RS` / `US` 字符替换为空格，避免破坏记录结构；图片与富文本本体存于 `data\media\`，大文本存于 `data\blobs\`
- 读取路径只接受当前版本：头部不符的文件不会被解析，也不会被写入覆盖

### 数据版本与迁移

数据格式版本定义在 `src\lib\base.ps1` 的 `$script:DataVersion`。修改记录结构的版本需要同步两处：

1. 在 `base.ps1` 中递增 `$script:DataVersion`；
2. 在 `src\lib\migrate.ps1` 的 `$script:MigrationSteps` 中增加一步，键为起始版本，步骤接收整个文件文本并返回下一版本的文本。

`clipboard migrate` 读取文件版本并逐级执行步骤，写入前把原文件备份到 `data\backup\history-v<版本>-<时间>.dat`；每个步骤不直接写盘，便于单独测试。当前只发布过一种布局，步骤表为空，因此：

- 版本等于当前版本：不做事；
- 版本更低但无对应步骤：拒绝处理，提示用 `clipboard migrate -Purge` 将文件归档到 `data\backup\`；
- 版本更高（由更新的程序写入）：不处理也不降级，提示更新程序。

`status` 与 `diag` 会显示当前数据版本与磁盘文件版本；文件版本不符时 `status` 给出一行 `migration` 提示。写入路径同样拒绝覆盖无法识别的文件，以免一次捕获清空旧历史。打包产物的 `install.bat` 会在 `install` 之前执行 `migrate`，升级安装时无需手动操作。

### 版本号

程序版本由 `package.ini` 的 `Version=` 维护，只有这一处：

- 开发运行（`src\clipboard.ps1`）时，`base.ps1` 在加载阶段读取仓库根的 `package.ini`，改版本只需改该键；
- 打包时 `scripts\build.ps1` 把这段读取替换为常量，产物不含 `package.ini`，也不读取任何文件。

该值同时决定产物目录名（`dist\clipboard-<version>\`），并由面板底部（`x of y   v<version>`）、`clipboard version`、`status`、`diag`、`help` 输出。数据格式版本是另一个值（`$script:DataVersion`），只影响存储格式。

## 开机自启与桌面快捷方式

`install` 建两个快捷方式（`Autostart=0` / `DesktopShortcut=0` 可分别跳过），目标均为 `powershell.exe`，不使用代理进程包装；参数中的 `-ExecutionPolicy RemoteSigned` 用于覆盖目标机 `Restricted` / `AllSigned` 的本地策略：

| 快捷方式 | 参数 | 用途 |
|---|---|---|
| `Startup\clipboard.lnk` | `-NoProfile -ExecutionPolicy RemoteSigned -Sta -WindowStyle Hidden -File "...\clipboard.ps1" serve` | 登录时静默启动常驻进程 |
| `Desktop\clipboard.lnk` | `-NoProfile -ExecutionPolicy RemoteSigned -Sta -WindowStyle Hidden -File "...\clipboard.ps1" ui` | 双击打开历史面板 |

> 本工具不作为 Windows 服务运行：服务位于 Session 0，没有桌面与托盘，`RegisterHotKey` 收不到用户输入，剪贴板也按会话隔离。

## 测试

```powershell
cli test                             # 全部四组
cli test -Unit                       # 只跑一组
cli test -Source dist\clipboard-0.1.0   # 对打包副本跑 CLI 组
```

也可以直接调用，参数相同：`powershell -NoProfile -ExecutionPolicy Bypass -Sta -File tests\run-tests.ps1`。

结构组没有开关，任何模式下都会先跑；其余三组默认全跑，也可以单独指定：

| 组 | 开关 | 覆盖内容 |
|---|---|---|
| 结构 | 无（总是执行） | 分层契约：46 个必需模块（`lib\` 32 + `utils\` 12）与 2 个 schema 文件齐全、每个模块可解析、模块中不得出现 `param()` 与 `$PSScriptRoot`/`$PSCommandPath`、无重名顶层函数（`theme-stub` ↔ `themes` 的覆盖是唯一例外）、载荷类型只通过 `base.ps1` 的谓词判断、行几何与面板计时只从常量表读取、入口 ≤ 200 行且 `$Root` 只算一次、单模块 ≤ 1400 行；源码模式还校验工具链文件齐全、`package.ini` 声明的命令与 ini 文件的大小写约定。产物模式只校验可解析 / 无 param / 无自引用 / 无重名，因为尺寸与 `$Root` 那行已被改名 |
| 单元 | `-Unit` | 纯函数与存储层：热键解析、条目文案、ini 读写与单值校验、`Apply-Config` 与配置诊断、记录读写与版本识别、迁移引擎（拒绝无步骤 / 备份 / `-Purge` 归档）、图片与富文本的编解码与媒体回收、CF_HTML 片段解析、真实剪贴板的图片与格式往返、标记与保护规则、面板几何与命中计算、条目分类与行图标、主题发现与 `[metrics]` 重置、插件白名单。通过 `-Library` dot-source 主脚本，不触发命令分发 |
| 集成 | `-Integration` | 每条 CLI 能力都起子进程验证：`put` / `get` / `list` / `pick` / `del` / `clear` / `pause` / `resume` / `status` / `version` / `migrate` / `themes` / `config get` / `config set` / `config init` / `diag`、主题切换与非法主题名拒绝、插件白名单与各插件命令、错误插件名提示、只读命令不生成 ini、设置开关被参数绑定拒绝、`cli` 命令列表；以及打包（进包内容、`install.bat`、包内版本为常量且与 `package.ini` 一致、`Plugins=` / `Themes=` 裁剪、`Overwrite=0` 拒绝覆盖、未知插件名报错） |
| 端到端 | `-E2E` | 拉起真实常驻进程 → 校验热键注册 → 复制内容验证捕获链路 → 暂停后不再捕获 → `stop` 后干净退出且没有重启循环 |

全部在 `%TEMP%` 下的沙箱副本（脚本 + `lib` + `utils` + `schema` + `plugins` + `themes`）中运行，不修改 `data/` 与 `clipboard.ini`；真实剪贴板在开始前备份、结束后还原。任一项失败时退出码为 1。

> 检测到常驻进程时会临时 `pause`，跑完先恢复剪贴板再 `resume`（原本已处于 paused 则保持不动）。

> `-E2E` 运行期间占用全局热键并接管剪贴板；已有常驻进程时该组自动跳过。面板绘制与粘贴注入不在自动化范围内。

## 开发

| 命令 | 作用 |
|---|---|
| `cli dev` | 停止残留常驻进程，启动 `src\clipboard.ps1 serve`，被加载的文件变化后重启 |
| `cli test` | 运行自测（开关见上一节） |
| `cli bench` | 在临时副本里计时捕获、保存、解析与过滤，用于改动前后对比 |
| `cli shot` | 重新生成 `docs\screenshot-dark.png` 与 `screenshot-light.png` |
| `cli build` | 打包到 `dist\` |

`cli` / `cli.cmd` / `cli.ps1` 三个入口行为一致，均先把工作目录切到仓库根，再把其余参数原样追加到 `package.ini` 里 `[scripts]` 那一行命令。

`cli bench` 在 `%TEMP%` 下复制一份 `src\` 并把 `DataDir` 指向临时目录，所以在常驻进程运行时也能跑：输出 `clipboard status` / `clipboard list` 的冷启动、2 KB 与 200 KB 文本的捕获、保存、解析、单词过滤七项耗时（`-Records` 改库规模，`-Json` / `-Out <文件>` 便于改动前后对比）。面板打开与粘贴注入需要真实桌面，不在其中。

`cli dev` 只有一种模式：常驻进程一直在跑，文件一变就重启。

- 监视范围是程序真正会读的文件：`src` 下全部 `.ps1`（入口、`lib\`、`utils\`）、`themes\*.ini`、`plugins\`、`src\clipboard.cmd` 以及 `package.ini`（版本号）。`clipboard.ini` 不在范围内：常驻进程会写窗口尺寸与位置，盯它会导致自己重启自己。
- 新增与删除也算变化，所以新建 `lib\foo.ps1` 并补上加载行后只需保存一次；入口里的 dot-source 行会被解析，指向不存在文件的引用会打印 `[!] missing: ...`。
- 变化按路径逐行列出（`[+]` 新增、`[-]` 删除、`[~]` 修改），并等待文件写完，通过正常的 stop 事件停掉常驻进程再启动；启动不成功会明确提示，下一次变化重试。
- `Ctrl+C` 结束循环，常驻进程保留运行。

`cli shot` 在 `%TEMP%` 下复制一份 `src\`，写入示例历史（固定时间、一条置顶、一条收藏），启动常驻进程并通过显示事件打开面板，再用 `CopyFromScreen` 截取面板区域；仓库的 `data\` 与 `clipboard.ini` 不参与。

## 打包分发

`cli build` 调用 `scripts\build.ps1`：读取 `src\`，输出 `dist\clipboard-<version>\`。目录结构不变、产物仍是 PowerShell，但每个 `.ps1` 都按语法树重写（删注释与缩进、重命名内部函数与局部变量）。不编译、不生成 exe、默认不打包 zip。

```powershell
cli build                       # 用 build.ini
cli build -Config other.ini     # 换一份配置
```

`build.ini` 只放打包选项，语法与其它 ini 一致（`[build]` 段，也可以写成顶层的 `build.OutDir=...`）；版本在 `package.ini`：

| 键 | 默认 | 说明 |
|---|---|---|
| `OutDir` | `dist` | 输出目录；相对路径按仓库根解析 |
| `Minify` | `1` | `1` = 按语法树压缩脚本（删注释 / 缩进 / 空行） |
| `Rename` | `1` | `1` = 同时重命名内部函数（全项目一套映射）与局部变量（每文件一套）；`0` = 只压缩不改名 |
| `Verify` | `1` | `1` = 打包后拿产物再跑一遍 CLI 测试，不通过就删掉产物并失败 |
| `IncludeDocs` | `1` | `1` = 把 `README.md`、`LICENSE`、`docs\` 也放进产物 |
| `Overwrite` | `0` | `1` = 覆盖同版本已存在的目录 |
| `Plugins` | 空 | 只打这些插件（逗号分隔，名字 = `src\plugins\` 下的文件名去 `.ps1`）；空 = 全部 |
| `Themes` | 空 | 只打这些主题（同上）；空 = 全部 |
| `Zip` | `0` | `1` = 另外再打一个 `clipboard-<version>.zip` |

```ini
# 只发一个精简包：两个插件 + 一套主题，不压缩不验证
OutDir=D:\release
Minify=0
Rename=0
Verify=0
IncludeDocs=0
Overwrite=1
Plugins=item-marks,transform
Themes=win11-dark
```

产物目录名取自 `package.ini` 的 `Version=`（见[版本号](#版本号)）；`Overwrite=1` 会替换同版本目录，需要同时保留两份时改 `OutDir`。

压缩（`scripts\minify.ps1`）按语法树处理，分五步：

- 内部函数名与局部变量名换成短名，全项目一套函数映射、每文件一套局部变量映射；`param()` 名、`$script:` / `$env:` 变量、自动变量、成员名与哈希键不改；
- here-string 里的 C# 块去掉 `//` 与 `/* */` 注释、把空白折成一个空格（只在两个标识符或两个运算符之间留空格），`"..."`、`'...'`、`@"..."` 字面量原样复制——这是产物里最大的一块可压缩文本；
- `-ErrorAction SilentlyContinue` 变成 `-ea 0`，已知的枚举名换成数字（`Stop`=1、`Continue`=2、`Inquire`=3、`Ignore`=4）；
- 同一语句块内相邻语句之间的换行合成 `;`，边界由解析器给出，`if` / `else` / `try` / `catch` / `param()` 等跨行位置不受影响；
- 删除注释（`#Requires` 保留）与缩进，token 之间只在标点旁去掉空格，其余保留一个空格。

改名后、C# 段与偏好名改写后、合并后、压缩后各解析一次，出现语法错误即中止；
`Verify=1` 再对产物跑一遍真实 CLI 测试。

压缩器依赖两个 PowerShell AST 事实：

- 变量名需从 `VariablePath.UserPath` 读取。`VariablePath.UnqualifiedPath` 在本机运行时对 `$x` 与 `$script:x` 均返回空串，据此做映射会导致部分变量未改名，`$MaxItems` 与 `$script:MaxItems` 成为两个变量。
- 函数返回空集合（如 `HashSet`）时会被 PowerShell 展开为 `$null`，调用方 `.Contains()` 会报错；需 `return , $set` 包一层或在调用处用 `@()`。

实测（本仓库）：脚本总量 `480947 → 261330` 字节，约 `46%` 更小；`lib\base.ps1` −74%、
`clipboard.ps1` −57%、`lib\picker.ps1` −44%、`lib\plugins.ps1` −54%，C# 段收益最大的两个
是 `lib\native.ps1` −39% 与 `lib\keyhook.ps1` −47%（压缩前后都能通过 `Add-Type`）。

> `Verify=1` 用于验证重命名后的产物：包内函数名与变量名均已改变，只有运行真实 CLI 测试才能确认行为不变。`-Source` 指向产物时单元组跳过（它按名字调用内部函数），集成与端到端照常运行。

产物里是什么、不是什么：

| 进包（来自 `src\`） | 不进包 |
|---|---|
| `clipboard.ps1`、`clipboard.cmd`、`clipboard`（Git Bash 壳） | `src\data\`（历史与日志） |
| `lib\`（28 个模块：24 必需 + `themes.ps1` 与插件三件套共 4 个可选加载层）、`utils\`（9 个纯工具）、`schema\`（2 个文件 schema + 所选插件的 `schema\plugins\*.ps1`）、所选 `plugins\`（含 `.md`）、所选 `themes\`（ini 与 `.md`） | `src\clipboard.ini`（用户设置） |
| `README.md`、`LICENSE`、`docs\`（截图，`IncludeDocs=1` 时） | `tests\`、`scripts\`、`build.ini`、`package.ini`、`dist\`、`.git` |

> `Plugins=` / `Themes=` 里写了不存在的名字会直接失败并指出是哪个；被选中的插件/主题会连同自己的 `.md` 一起进包（`lib\` 是基础层，永远随包走）。

> 拿到产物后：`clipboard.cmd config init` 生成带注释的 `clipboard.ini`，`clipboard.cmd migrate` 升级旧格式历史，再 `clipboard.cmd install` 建开机自启与桌面快捷方式（`install.bat` 把这三步串在一起）。`clipboard` 这个 Git Bash 启动器在 zip 中会丢可执行位，用 `sh ./clipboard` 即可（或 `chmod +x clipboard`）。

插件不用打包器操心：它就是 `plugins\` 目录 + `Plugins=` 白名单，目录跟着包走就能用；想分发自己写的插件，把 `.ps1` 放进产物里的 `plugins\` 也生效。

## 持续集成与发布

`.github\workflows\` 下两个 workflow，都跑在 `windows-latest`：工具依赖 WinForms 面板、剪贴板 API 与 `RegisterHotKey`，只有 Windows 上的 PowerShell 5.1 才是目标环境，换平台验证不了任何东西。

| workflow | 触发 | 步骤 |
|---|---|---|
| `ci.yml` | 推到 `master`、PR、手动 | 打印 PowerShell 版本 → `cli test -Unit -Integration` → `cli build`（`Verify=1`，产物复测） |
| `release.yml` | 推 `v*` tag、手动 | 校验 tag 与 `package.ini` 的版本一致 → 跑测试 → 打包成 `clipboard-<version>.zip` → 生成 `SHA256SUMS.txt` → 发布 Release |

- 结构组校验文件布局与纯 ASCII（PowerShell 5.1 按 GBK 解码无 BOM 的 UTF-8，脚本里有中文就会炸），单元组按名字调用内部函数，集成组起子进程跑每一条 CLI 能力——三者都在 `ci.yml` 里，每次推送都会跑。
- 端到端组（常驻进程 / 全局热键 / 剪贴板接管）需要真实桌面，托管 runner 不保证有交互式会话，所以在 `ci.yml` 里单独一个 job 且不阻塞合并，只作参考信号；要确认这一层请在本机跑 `cli test -E2E`。
- 发版只改 `package.ini` 的 `Version=`，然后 `git tag v<version>` 并推送 tag；版本号与 tag 对不上时 workflow 在第一步就失败，不会发出一个版本号对不上的包。手动触发 `release.yml` 时按 `package.ini` 发同名 Release，已存在就覆盖资产。

## 常见问题

### 安全软件把快捷方式判为 `Trojan/LNK.Runner`

`install` 生成的快捷方式目标为 `powershell.exe`，不带 `-ExecutionPolicy Bypass`（客户端默认策略 `RemoteSigned` 已允许运行本地无签名脚本）。部分安全软件的启发式规则会把「快捷方式 + 系统代理进程（`conhost` / `rundll32`）+ 隐藏窗口 + 执行策略绕过」的组合判为 `LNK.Runner`，因此本工具不使用代理进程包装。

### 快捷方式提示「在此系统上禁止运行脚本」

快捷方式默认带 `-ExecutionPolicy RemoteSigned`。若仍被拒绝，按顺序检查：

1. 脚本带网络来源标记（从压缩包或下载目录解出）—— 执行 `Unblock-File .\src\clipboard.ps1`
2. 需要更宽松的进程级策略 —— `clipboard install bypass`（改用 `-ExecutionPolicy Bypass`）
3. 组策略（`MachinePolicy` / `UserPolicy`）已指定执行策略 —— 此时 `-ExecutionPolicy` 参数不生效，`install` 会打印 `group policy defines the execution policy` 提示

### 热键无响应

`status` 的 `active key` 反映实际生效的按键：

- `poll:<键>` —— 候选热键全部注册失败，退化为 `GetAsyncKeyState` 轮询
- 与 `Hotkey` 不同的键名 —— 首选键被其它程序占用，已按 `HotkeyFallbacks` 回退
- `(stopped)` / `(daemon never started)` —— 常驻进程未运行

修改 `Hotkey` 后需要重启常驻进程。

### 恢复系统自带的 Win+V

`diag` 逐项列出环境检查结果；`restore` 针对注册表项（`EnableClipboardHistory`、策略 `AllowClipboardHistory`）与 `cbdhsvc` 实例执行恢复。文件层面的缺失（如 `TextInputHost.exe`）无法通过脚本修复。

## 许可

[MIT](LICENSE) © 2026 Xu22Web
