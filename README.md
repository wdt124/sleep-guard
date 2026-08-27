# Sleep Guard · 睡眠守卫

> 一个会关掉深夜娱乐、哄你去睡觉，还用 JLPT N4 小测拦住摆烂的桌面伙伴。

Sleep Guard 是一个运行在 Windows 上的温柔但不太容易摆烂的夜间自律守卫。它会在你设定的时间段内监测新启动的浏览器、Steam、Epic、战网及其游戏，关闭夜间娱乐程序并弹出睡觉提醒。

## 功能

- 后台监测默认运行于 02:00–06:00；桌面小窗双击时间即可修改，也支持跨午夜。
- 小窗可拖动、可隐藏到托盘，并由 `wscript.exe` 静默启动，不伴随 CMD/PowerShell 控制台。
- 普通停用前先展示当天随机抽取的 30 个 JLPT N4 知识点，内容涵盖生词、语法、动词活用和句型。
- 阅读到底后才可进入考试。考试从当天 30 个知识点中抽取 10 个出题；交卷后无论对错都显示答案与解析，10 题全对才可停用。
- 答题失败可放弃或换一份新卷；新卷仍只从当天知识点范围内出题。
- 每个自然月保留 3 次免答题的“纵容”机会。
- 可选 OpenAI 兼容 LLM 生成试题和睡觉提醒；接口不可用时自动使用本地题目与文案。

守卫只读取进程名、父子进程关系、前台窗口所属进程和游戏安装路径，不读取浏览历史、网址、网页内容或聊天内容。日志保存在 `%LOCALAPPDATA%\SleepGuardian\logs`，默认保留 14 天。

## 安装

要求 Windows 10/11 与 Windows PowerShell 5.1。

```powershell
git clone https://github.com/wdt124/sleep-guard.git
Set-Location .\sleep-guard
Copy-Item .\config.example.json .\config.json
notepad .\config.json
& .\Install-SleepGuardian.ps1
```

安装程序会创建两个当前用户计划任务：`SleepGuardian_Daily` 和 `SleepGuardian_Widget`，以及桌面快捷方式“睡眠守卫”。按 `Ctrl+Alt+S`、双击快捷方式或双击托盘图标均可唤起小窗。

## LLM 配置

`config.json` 不会被 Git 跟踪。更推荐让 `apiKey` 保持空白，并设置用户环境变量：

```powershell
[Environment]::SetEnvironmentVariable('SLEEP_GUARDIAN_API_KEY', '在这里填写密钥', 'User')
```

然后在 `config.json` 的 `llm` 中设置 `enabled`、`baseUrl`、`model` 与 `apiMode`。也支持环境变量 `SLEEP_GUARDIAN_BASE_URL` 和 `SLEEP_GUARDIAN_MODEL`。支持 `chat-completions` 与 `responses` 两种 OpenAI 兼容模式。

LLM 只负责按预设 JSON 结构生成题目和文案；题目所属知识点、题数、四个选项、答案索引和重复项都会由本机严格校验，最终判分也完全在本机完成。

## 使用与管理

```powershell
& .\Guardian-Control.ps1 -Action Status
& .\Guardian-Control.ps1 -Action DisableTonight
& .\Guardian-Control.ps1 -Action DisableIndefinitely
& .\Guardian-Control.ps1 -Action Enable
```

命令行临时停用仍需要填写理由、等待 90 秒并逐字输入确认句；长期停用需要等待 180 秒和两次确认。重新开启没有等待。

安全自检不会关闭任何程序：

```powershell
& .\SleepGuardian.ps1 -SelfTest
& .\Guardian-Widget.ps1 -SelfTest
& .\Guardian-Widget.ps1 -TestQuestionGeneration
```

本地和 GitHub 的日常同步可使用：

```powershell
& .\Sync-SleepGuardian.ps1 -Action Status
& .\Sync-SleepGuardian.ps1 -Action Pull
& .\Sync-SleepGuardian.ps1 -Action Push -Message '说明这次修改'
```

同步脚本在推送前会再次确认 `config.json` 已被忽略且从未被 Git 跟踪。

## 安全边界

任何拥有本机账户控制权的人最终都能通过任务计划程序、任务管理器或删除脚本绕过它。这个项目提供的是刻意增加的行为摩擦，不是不可撤销的系统锁定。

## License

[MIT](LICENSE)
