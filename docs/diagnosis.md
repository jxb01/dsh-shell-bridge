# 复现与根因（Windows / 代码页 936）

以下均在本机 DSH 会话里、通过真实 `pwsh` 工具执行得到。

## 1. 原生工具输出乱码（转译）

```powershell
ipconfig | Select-Object -First 6
# 实际：Ethernet adapter ��̫��:
python -c "import sys;print(sys.stdout.encoding);print('中文输出')"
# 实际：gbk cp936  /  ???????
```

原因：`dsh-pwsh-local` 给 pwsh 设 UTF-8 输出编码，但该进程没有控制台，`SetConsoleOutputCP(65001)`
实际没有生效（`chcp` 仍是 936）。原生工具按 ANSI/OEM 代码页写管道，而 subprocess 收集器按 UTF-8 解码。

## 2. 管道中文进原生工具乱码

```powershell
"中文管道" | python -c "import sys;print(repr(sys.stdin.read()))"
# 实际：'�\udcad文�\udcae�道\n'
```

原因：pwsh 的 `$OutputEncoding` 是 UTF-8，原生工具按 cp936 读 stdin。

## 3. `param()` / `using` 被前置语句破坏

DSH 实际执行的是：

```
pwsh -NoLogo -NoProfile -NonInteractive -Command "[Console]::OutputEncoding = ...; $OutputEncoding = ...; <你的命令>"
```

于是：

```powershell
param([string]$x='hi'); Write-Output $x   # 报 param 不是 cmdlet
using namespace System.Text; ...          # ParserError: using 必须位于脚本最前
```

解析期错误还发生在编码设置之前，所以错误文本本身也是乱码。

## 4. 32K 命令行上限

```powershell
# 约 36000 字符的命令
# 实际：ToolCallError: spawn ENAMETOOLONG
```

## 5. 转义层级

模型写工具参数时是 JSON 字符串，反斜杠必须写成 `\\`；DSH 不做 JSON 修复（`dsh-llm-deepseek` 对无效 JSON
返回 `tool input is invalid JSON`）。

## 6. 标点语义（实测）

```powershell
$a = @('a',)          # ParserError: ',' 后缺少表达式
Get-Item 'x\p[1].txt' # [] 被当通配符 -> 找不到；要 -LiteralPath
Write-Output "a“b”c"  # 输出 a / bc，弯引号被当分隔符
'a‘b’c'               # 同样被单弯引号截断
cmd /c echo a^&b      # PowerShell 先解释 ^ 和 &，变成后台任务
```

## 7. 退出码

```powershell
& bridge.ps1 -Command 'exit 5'   # 工具报 exit code 1
& bridge.ps1 -Command 'exit 5'; exit $LASTEXITCODE   # 报 5
```

原因：`pwsh -Command` 在命令正常结束时不看脚本内部 `exit`，只看最后一条语句的 `$?`。

## 桥的验证结果

```
main.ps1        -> 你好, 世界 / python中文输出 / node中文        exit 0
fail.ps1        -> about to fail                                  exit 3
fail.cmd        -> about to fail cmd                              exit 9
slow.ps1 超时   -> [dsh-shell] timed out after 1s                 exit 124
big.ps1 (40k)   -> len=40000                                      exit 0
```
