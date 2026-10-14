# Sleep Guard · 睡眠守卫

> 一个会关掉深夜娱乐、哄你去睡觉，还用 JLPT N4 小测拦住摆烂的桌面伙伴。

Sleep Guard 是一个运行在 Windows 上的温柔但不太容易摆烂的夜间自律守卫。它会在你设定的时间段内监测新启动的浏览器、Steam、Epic、战网及其游戏，关闭夜间娱乐程序并弹出睡觉提醒。

## 功能

- 后台监测默认运行于 02:00–06:00；桌面小窗双击时间即可修改，也支持跨午夜。
- 小窗可拖动、可隐藏到托盘，并由 `wscript.exe` 静默启动，不伴随 CMD/PowerShell 控制台。
- 普通停用前先展示当天抽取的 30 个 JLPT N4 知识点，内容涵盖生词、语法、动词活用和句型。
- 阅读到底后才可进入考试。考试从当天 30 个知识点中抽取 10 个出题；交卷后无论对错都显示答案与解析，10 题全对才可停用。
- 答题失败可放弃或换一份新卷；新卷仍只从当天知识点范围内出题。
- 每个自然月保留 3 次免答题的“纵容”机会。
- 小窗与托盘都提供随时可访问的知识库、搜索、十个目录和错题本。
- 上一卷错题知识点强制进入下一卷；从未答错的知识点权重降至新知识点的约 2%，并尽量均衡覆盖目录。读过的内容也按日期降权，过两周适当增加复习机会。
- 优先使用对应知识点的官方公开真题；其余由 OpenAI 兼容 LLM 即时生成，再由两次独立调用审查。开考前明确显示真题、即时生成与旧缓存的数量。

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

个人使用的官方题库可另外导入（需要 Python 3 与 `pypdfium2`）：

```powershell
python -m pip install pypdfium2
& .\Install-OfficialQuestions.ps1
```

目前导入 2012、2018 官方 N4 真题选编中与本知识库对应的 10 道语法题。保留原文图片与官方答案，全部存于 `%LOCALAPPDATA%\SleepGuardian`，不上传 GitHub。开源仓库只包含下载脚本、题目位置和映射索引。[官方公开真题选编](https://www.jlpt.jp/e/samples/sampleindex.html)与[个人学习使用规则](https://www.jlpt.jp/e/policy.html)。这些原题不属于本项目的 MIT 授权。

安装程序会创建两个当前用户计划任务：`SleepGuardian_Daily` 和 `SleepGuardian_Widget`，以及桌面快捷方式“睡眠守卫”。按 `Ctrl+Alt+S`、双击快捷方式或双击托盘图标均可唤起小窗。

## LLM 配置

`config.json` 不会被 Git 跟踪。更推荐让 `apiKey` 保持空白，并设置用户环境变量：

```powershell
[Environment]::SetEnvironmentVariable('SLEEP_GUARDIAN_API_KEY', '在这里填写密钥', 'User')
```

然后在 `config.json` 的 `llm` 中设置 `enabled`、`baseUrl`、`model` 与 `apiMode`。也支持环境变量 `SLEEP_GUARDIAN_BASE_URL` 和 `SLEEP_GUARDIAN_MODEL`。支持 `chat-completions` 与 `responses` 两种 OpenAI 兼容模式。

运行时每次需要生成题目，调用同一 API 的三个独立会话：

1. 出题 agent：根据抽取的知识点原创题目，避免历史题干与例句。
2. N4 范围审查 agent：逐题核对词汇、语法、难度和实际考查知识点。
3. 独立答案审查 agent：看不到预设答案与解析，将四个选项逐一代入，判断题干、唯一解和自然程度。

范围审查通过、独立解题答案与出题答案一致且字段校验通过后，题目才能进入试卷。任何审查失败会重新生成，最多两轮。API 不可用时只允许官方真题或此前双审通过的缓存题；数量不足就提示稍后重试，不使用旧版未审查的固定题。不同会话仍使用配置的同一模型，因此审查能减少错误，但不能保证完全无误。

`quizRequestTimeoutSeconds` 控制每次考试 API 调用超时，默认 60 秒，最低 45 秒。睡觉提醒仍使用 `requestTimeoutSeconds`。开考说明与日志会标注来源和各 agent 的成功或失败，日志不包含 API Key。

知识点标题只在学习页、交卷解析和知识库出现，答题页仅显示题号。学习记录和错题保存于 `%LOCALAPPDATA%\SleepGuardian\learning-history.json`，已答对的历史错题仍可查阅；保留最近 200 份交卷记录与最近 1000 个题干。旧版没有保存交卷结果，所以历史正误无法回溯，本次更新后开始积累。

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
& .\Guardian-Widget.ps1 -TestLearning
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
