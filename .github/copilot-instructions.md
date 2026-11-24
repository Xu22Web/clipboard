# 仓库约定

## 每次改动都要判断是否同步 README

交付前先判断本次改动是否影响 `README.md`（英文）与 `README.zh-CN.md`（中文），并在回复末尾用一行说明结论（"README：已更新 X" 或 "README：无需改动"）；两份文档的章节与事实必须一致。

必须同步：

- 命令、设置键、标记、文件布局、目录结构、插件或主题契约发生变化
- 默认值、取值范围、尺寸或数量上限、超时、文件格式、退出码发生变化
- 新增或移除对外能力

不必写进 README：

- 纯内部重构、性能微调、日志措辞、测试增删
- 单次排查过程、临时取舍、本机实测数据、对话中的零碎要求
- 长期有效的技术结论写进代码注释，不写进 README

## README 写法

- 只写行为、键名、取值、限制与契约；不写实现过程与权衡经过
- 简洁客观、通俗易懂、不口语化：不用比喻、拟人化表达与评价性形容词
- 同一事实只在一处说明，其余用链接指向该处；能并入现有表格的不新开段落
- 新增小节前先确认现有段落无法承载；预计超过约 40 行时优先并入现有表格或列表
- 一致性：命令与配置表的取值必须与 `clipboard help`、`clipboard config`、`src\shared\schema\clipboard.ps1` 相同

## 文档与截图

- 对外文档两份：`README.md`（英文，GitHub 默认显示）与 `README.zh-CN.md`（中文），顶部互相链接；改一处必须同步另一处，章节与事实保持一致
- 插件与主题说明页按语言分目录：`docs\<语言>\plugin\`、`docs\<语言>\theme\`，两种语言各一份；文件名在两边相同
- 截图一处一套：`docs\en\`（`cli shot`）与 `docs\zh-cn\`（`cli shot -Language zh-CN`）。不要手放、复制或跨语言引用截图
- 文档内文件的移动或改名要同时改两边 README、`tests\pkg\build.ps1` 的 docs 断言，并跑一次相对链接自检（链接目标必须存在）；跨目录引用要按新深度调整路径
- 互链按语言分流：英文页指向 `README.md` 的锚点，中文页指向 `README.zh-CN.md` 的锚点；`docs\<语言>\` 的回链也指向同语言的那一份，锚点要落在该文件的真实标题上

## 多语言与文案

- 界面文案一律经 `Get-UiText` / `Get-UiTextOr` / `Get-UiTextCount`（`src\renderer\src\utils\text.ps1`）；绘制、交互与设置代码里不得出现可见的英文或中文
- 不用 `Get-Text`：那是读剪贴板文本的函数，后加载的 `main\utils\clip.ps1` 会覆盖同名函数
- 语言包是数据，放在 `src\lang\<code>.ini`：`en.ini` 是基准，其他语言叠加在它之上；键 = `<界面>.<槽位>`，身份用 schema 键名、组名、单位名或插件 `Name`
- 插件标记词用 `mark.<插件 Name>.<标记字符>` （缺键回退插件声明的 `Word`）；设置项的灰置原因与只读原因用 `settings.why.<Key>`，句子外壳是 `settings.help.off` / `settings.help.pick`
- 面板与托盘的可见文案（含 `AccessibleName`、`MessageBox` 正文、底部提示）都走语言包；`Get-RowEditBlock` 返回的原因串只给测试看，保持英文
- 新增或修改一条文案要同时改 `en.ini` 与每种在售语言（当前 `zh-CN.ini`）；不许只改一边
- 键不能只有大小写不同（PowerShell 哈希表大小写不敏感）：`about.version` 与 `about.Version` 会互相覆盖
- 占位符 `{0}` `{1}` 的数量与顺序在两种语言里必须一致；复数写 `<key>.one` / `<key>.other`，没有单复数区分的语言只写 `.other`
- `en.ini` 不必写设置项标题与说明：缺 `settings.key.<Key>` 时回退键名推导，缺 `settings.desc.<Key>` 时回退 schema 的 `Description`；译文语言两者都必须写（覆盖率用例守着）
- 语言包 UTF-8 带 BOM，可写 `[meta] code` / `name` / `font`；`font` 是绘制字体族，CJK 语言必须给（Segoe 系列没有中日韩字形）
- 新增语言：加 `src\lang\<code>.ini`、在 `schema\clipboard.ps1` 的 `Language` 枚举里登记、跑 `cli test -Unit`
- 不翻译：CLI 输出、日志、`clipboard.ini` 模板注释（schema 的 `Description` 同时是模板注释，所以保持英文）、快捷键名
- 文案改动必跑 `cli test -Unit`（基准包含、占位符一致、设置覆盖率三条用例）；改了可见界面还要重拍两套截图

## 代码

- `*.ps1` / `*.cmd` 必须纯 ASCII（Windows PowerShell 5.1 按 GBK 解码无 BOM 的 UTF-8）
- 模块按职责划分，不按行数：一个文件只做一件事、只依赖下层；新增逻辑优先放进已有的职责模块，只有明显属于另一个职责时才新建文件，也不要为缩短文件而拆散同一个职责
- 新增模块要同步四处：`src\clipboard.ps1` 的模块表、`tests\unit\unit.ps1` 的 `$requiredLib`、README 的文件树、README 的模块清单段落
- 新增设置键要同步四处：`schema\clipboard.ps1`、`config-template.ps1` 的模板布局、`config.ps1` 的 `Get-ConfigReport` 表、语言包的 `settings.key` / `settings.desc`（漏掉报表的键在 `clipboard config` 里看不见，在 `config set` 里回显为空）
- 新增设置分组要给它一个图标：`settings-draw.ps1` 的 `Get-SettingsGroupGlyph`（键 = schema 组名，码位须在 Segoe Fluent Icons 与 MDL2 都有），用例守着每个组都有自己的图标
- 两参数调用的实参不要一个写括号表达式、另一个写强制转换（如 `f ('a.' + $x) ([string]$x)`）：压缩器会粘成非法语法、`cli build` 直接失败。先把两个实参都赋给变量再调用

## 测试

- 断言只写两类：守回归（对应实际缺陷）与守契约（对外行为、文件格式、命令行输出）。新增用例前先说出它守哪一条，说不出就不加
- 不复述常量：schema 默认值、提示文案、模块与键清单不从测试里再抄一遍，断言由常量推出的结果
- 不断言私有实现细节：函数体逐行与导入声明不写断言；结构断言只用于分层契约分件（模块清单、可解析性、命名与 ini 约定）
- 同一行为不写第二条等价断言，合并成一条；一次实际缺陷对应一条断言；发现这类断言就地删除或合并，不为“多测一点”保留
- 用例一律用 `Describe` / `It` / `Expect` 写，`Describe` 块内只放声明，准备与清理写进钩子；跳过用 `It -Skip` 或 `Skip-Test`，不用条件包裹整个 `It`
- 改完要实际跑：`cli test -Unit -Integration`，改到面板、常驻进程或剪贴板时再跑 `-E2E`（跑前先 `clipboard stop`）。未跑过的用例不算通过，报告里不写猜测的通过数

## 发布说明

每次发布都用同一份大纲，结构、语气与篇幅保持一致：

```
与 <上一个版本> 相比的变化。

## 新增
- 一句话一条，用户能看到的新能力

## 修复
- 一句话一条，用户能感知到的行为变化

## 兼容
- 旧版配置能否沿用
- 安装包文件名与校验文件
```

- 只写与上一个版本的差异，以及用户能观察到什么；不写内部实现、不解释"以前为什么错"、不列内部键名与文件清单
- 需要时增加 `## 移除`，没有内容的小节直接省略；不新增其他小节
- 每节 2–5 条，每条一句、不换行续写；全文控制在约 15 行以内
- 不写包体积、压缩测试、构建耗时、工作流步骤等过程数据
- 用中文写；版本号、文件名、命令与设置键保持原样
- 每个版本存一份 `docs\release-notes\v<版本>.md`（文件名与标签一致，如 `v0.5.0.md`）；首个版本首行写「首个版本。」，没有内容的小节照常省略
- 流程：改 `package.ini` 的 `Version` → 写 `docs\release-notes\v<版本>.md` → 附注标签 `v<版本>` → 推 master 与标签 → 工作流按 `package.ini` 打包并建 Release（自动生成说明）→ 用 `gh release edit v<版本> --notes-file docs\release-notes\v<版本>.md` 把说明覆盖为该文件
- 旧版本的说明也以这两份文件为准：改了历史说明要同时改文件与对应的 GitHub Release

