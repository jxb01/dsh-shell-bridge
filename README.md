# dsh-shell-bridge

给 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）的 `pwsh` 工具用的 **Windows 中文编码 / 转义桥**。

在真实的中文 Windows（控制台代码页 936）上，DSH 的 `pwsh` 工具会出现下面这些问题；这个桥把它们一次修掉，
并把「写脚本 -> 跑脚本」变成一条不会踩转义坑的固定工作流。

## 实测的问题

| # | 现象 | 复现 | 根因 |
|---|------|------|------|
| 1 | 原生工具输出乱码 | `ipconfig`、`python -c "print('中文')"` | 子进程没有控制台，`[Console]::OutputEncoding=UTF8` 改不动代码页；工具按 cp936 输出，被按 UTF-8 解码 |
| 2 | 中文管道进原生工具乱码 | `'中文' \| python -c "..."` | pwsh 用 UTF-8 写管道，原生工具按 cp936 读 |
| 3 | `param()` / `using` 直接报错 | `param([string]$x='hi'); ...` | DSH 会在命令前拼编码语句，二者不再是第一句；解析期错误还早于编码设置，所以错误也是乱码 |
| 4 | 长脚本 `spawn ENAMETOOLONG` | 约 36 KB 的命令 | 整段脚本作为一个 argv，撞 Windows 32K 命令行上限 |
| 5 | 转义层级过多 | 路径 `\`、正则 `\d`、引号 | 模型 JSON -> PowerShell -> cmd 三层转义；DSH 不做 JSON 修复，出格即 `tool input is invalid JSON` |
| 6 | 标点语义坑 | `@('a',)`、`[1]`、`"“”"` | 尾逗号是 PS 语法错误；`[]` 是通配符（要用 `-LiteralPath`）；中文弯引号被 PowerShell 当引号分隔符 |
| 7 | 退出码丢失 | 子进程退出 3，工具报 1 | `pwsh -Command "& script"` 结束时按 `$?` 给码 |

完整的复现命令与观察结果见 [docs/diagnosis.md](docs/diagnosis.md)。

## 安装

```powershell
git clone https://github.com/<you>/dsh-shell-bridge.git
cd dsh-shell-bridge
pwsh -NoProfile -File ./install.ps1
```

默认装到 `$env:DSH_HOME`（没有就 `~/.dsh`）：

- `tools/dsh-shell.ps1` —— 桥本身
- `tools/revert-dsh-shell.ps1` —— 卸载脚本
- `tasks/main.ps1` —— 示例任务（已存在则不覆盖）
- `AGENTS.md` —— 插入一段带标记的 DSH-SHELL-BRIDGE 规则，之后每个会话都会自动走桥

选项：

```powershell
./install.ps1 -DshHome D:/dsh-home     # 指定 DSH home
./install.ps1 -SkipInstructions        # 不动 AGENTS.md
./install.ps1 -Force                   # 覆盖已有 bridge/tasks/main.ps1
```

卸载：

```powershell
pwsh -NoProfile -File ./revert.ps1
# 或
pwsh -NoProfile -File (Join-Path $env:DSH_HOME 'tools/revert-dsh-shell.ps1')
```

## 用法

两步：

1. 用 DSH 的 `write` 工具把脚本原样写到 `$DSH_HOME/tasks/main.ps1`（cmd 任务写 `main.cmd`）。
   文件内容是字面写入的，反斜杠、引号、中文标点不需要再套一层转义。
2. 用 `pwsh` 工具执行，**结尾必须带 `; exit $LASTEXITCODE`**，退出码才会原样传回：

   ```powershell
   & 'C:\Users\<you>\.dsh\tools\dsh-shell.ps1'; exit $LASTEXITCODE
   ```

其它形式（同样以 `; exit $LASTEXITCODE` 结尾）：

| 场景 | 命令 |
|------|------|
| 默认任务 `tasks/main.ps1` | `& '<bridge>'; exit $LASTEXITCODE` |
| 指定任务 | `& '<bridge>' -Name build; exit $LASTEXITCODE` |
| cmd 批处理 | `& '<bridge>' -Shell cmd -Name build; exit $LASTEXITCODE` |
| 指定目录 / 超时 | `& '<bridge>' -Name build -WorkDir 'D:/repo' -TimeoutSec 600; exit $LASTEXITCODE` |
| 小命令内联 | `& '<bridge>' -Command 'Get-Date'; exit $LASTEXITCODE` |

### 写脚本时的标点规则

- 路径优先用正斜杠 `D:/work/_lab`，完全绕开 JSON 反斜杠转义。
- 含 `[ ] & # % ! ^ , ; = + @ ~` 或空格的路径必须配 `-LiteralPath`。
- 数组/哈希最后一项不要尾逗号：`@('a',)` 会语法报错。
- 中文弯引号 `“ ” ‘ ’` 会被 PowerShell 当引号分隔符：`“ ”` 放进单引号串，`‘ ’` 放进双引号串，或用 `[char]0x201C` 构造。
- cmd 内建命令用 `-Shell cmd`，不要在 PowerShell 里套 `cmd /c`。

## 原理

桥做三件事：

1. **脚本落盘再执行**：把 payload 交给子 shell 以脚本文件方式运行，消掉外层引号/转义、`param()`/`using` 与 32K 长度限制。
2. **隐藏控制台 + 代码页 65001**：用 `CreateNoWindow` 起子 shell，让 `chcp` 真正生效，再设 `[Console]::OutputEncoding`、`$OutputEncoding`，并注入 `PYTHONUTF8`/`PYTHONIOENCODING`。
   这样 PowerShell、cmd.exe 和所有原生子进程对「UTF-8」达成一致，输入输出都能往返。
3. **原始字节透传**：子进程 stdout/stderr 用 `CopyToAsync` 直接泵到桥的流上，不做二次编码，保留流式输出，后台任务照常；退出码原样返回。

## 目录结构

```
dsh-shell.ps1                 桥
install.ps1                   安装到 $DSH_HOME
revert.ps1                    卸载
samples/main.ps1              示例任务
docs/instructions-block.md    写进 AGENTS.md 的规则块（含 @@BRIDGE@@ / @@TASKS@@ 占位符）
docs/diagnosis.md             问题复现与根因
```

## 已验证

在 Windows 11 / PowerShell 7.6 / 代码页 936 上实测：

- 中文：`你好, 世界`、`python中文输出`、`node中文`、`ipconfig` 的「以太网适配器」
- `param()`、`using namespace`、40000 字符脚本
- cmd 模式：中文 + `dir /b` + 特殊字符路径
- 退出码：`0 / 3 / 9 / 124`（超时）
- `write` / `read` 对反斜杠、引号、中文标点逐字节一致

## 限制

- 面向 Windows + PowerShell 7（`pwsh`）；PowerShell 5.1 未验证（桥会取当前进程的可执行文件，5.1 下部分语法可用性未测）。
- 依赖能被创建隐藏控制台；若宿主禁止，会退化成普通子进程，编码问题可能回来。
- 需要每个会话都带规则时，规则块写在 `$DSH_HOME/AGENTS.md`（DSH 的用户级指令文件）。

## License

MIT
