# transform —— 粘贴前改写文本

[← 回到主说明](../README.md) · [插件契约](../README.md#插件)

选中条目按 `Enter` 粘贴时，先把内容按指定模式改写：纯文本、全大写、全小写、驼峰、蛇形、烤肉串、标题式。适合往 IDE / 终端 / 数据库里粘"格式要求不同"的同一段内容。

## 启用

```ini
# clipboard.ini
Plugins=transform
```

不启用时粘贴走原始文本，`transform` 是未知命令。

## 命令

| 命令 | 作用 |
|---|---|
| `clipboard transform N` | 用配置里的 `Mode` 改写第 N 条，并写入剪贴板 |
| `clipboard transform "N mode"` | 临时指定模式（整体要加引号） |

```
$ clipboard transform 1 upper
[upper] HELLO WORLD DEMO

$ clipboard transform "1 snake"
[snake] hello_world_demo
```

## 模式

| `Mode` | 效果 | 示例（输入 `Hello World demo`） |
|---|---|---|
| `keep` | 不改写（默认） | `Hello World demo` |
| `text` | 纯文本：换行与连续空格压成单个空格 | `Hello World demo` |
| `upper` | 全大写 | `HELLO WORLD DEMO` |
| `lower` | 全小写 | `hello world demo` |
| `camel` | 驼峰 | `helloWorldDemo` |
| `snake` | 蛇形 | `hello_world_demo` |
| `kebab` | 烤肉串 | `hello-world-demo` |
| `title` | 标题式 | `Hello World Demo` |

驼峰 / 蛇形 / 烤肉串 / 标题式会先按空格、下划线、连字符以及小写→大写的边界切词，再按目标格式拼接。

## 设置项（`clipboard.ini`）

| 键 | 默认 | 说明 |
|---|---|---|
| `transform.Mode` | `keep` | 粘贴时使用的改写模式（`keep` / `text` / `upper` / `lower` / `camel` / `snake` / `kebab` / `title`） |
| `transform.Trim` | `1` | `1` = 去掉结果首尾空白 |

```powershell
clipboard config set transform.Mode snake
clipboard config set transform.Trim 0
```

## 说明

- **改写规则只有一份**：粘贴钩子与 `transform` 命令都调用插件里的 `Apply` 块（`param($text, $mode)`），不存在两套容易走偏的实现；命令行只是多了一步「取第 N 条 → 写剪贴板 → 记入历史」。
- **文件清单条目不会被改写**：粘贴的是一批文件路径，改写会破坏路径。
- 改写只发生在**粘贴路径**上；`clipboard get` / `clipboard put` 与历史里存的内容保持原样。
- 常驻进程在跑时，`config set transform.Mode ...` 会自动重启常驻进程使新值生效。
- 一次性模式（`clipboard transform "3 upper"`）不改配置，只影响这一次调用。
