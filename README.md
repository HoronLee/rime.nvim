# rime.nvim

[English](README_en.md) | 简体中文

根据 Neovim 的模式和焦点自动切换 Fcitx5 Rime 的中英文状态。操作模式临时使用 ASCII，进入文本输入模式或离开编辑器时恢复此前的输入状态，无需修改 Rime 输入方案或中英文切换快捷键。

## 快速开始

需要 Linux、Neovim 0.11+（LuaJIT）、Fcitx5、fcitx5-rime 和 `libdbus-1.so.3`，并在具有 `DBUS_SESSION_BUS_ADDRESS` 的本机桌面会话中使用。Windows、macOS 和 SSH 会话不启用输入法联动。

### 1. 使用 lazy.nvim 安装

```lua
return {
  "HoronLee/rime.nvim",
  main = "rime_toggle",
  lazy = false,
  cond = vim.fn.has("linux") == 1,
  opts = {},
}
```

`opts` 会自动调用插件的 `setup()`。`cond` 使 Windows 和 macOS 跳过加载，无需维护多份 Neovim 配置；插件自身也会在非 Linux 平台直接跳过初始化。

### 2. 关闭 Rime 的状态共享

在 Fcitx5 配置工具中打开 **中州韵附加组件的配置**，将“共享输入状态”设为 **否**，然后应用。配置工具会保存设置，无需手写配置文件。注意，这不是 Fcitx5 全局选项页中的同名设置。

等价的文件配置是 `~/.config/fcitx5/conf/rime.conf`：

```ini
InputState=No
```

如果手动编辑文件，再重新加载中州韵附加组件：

```sh
busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 ReloadAddonConfig s rime
```

`InputState` 是枚举，不接受 `Yes`。插件要求实际生效的策略为“不共享”：直接选择“否”，或选择“跟随全局选项”并确保全局“共享输入状态”为“否”。推荐直接选择“否”，避免后续全局配置变化影响 Rime。

“全部”（`All`，Rime 默认值）会跨输入上下文共享状态；“程序”（`Program`）会按应用程序共享状态。两者都不满足插件按上下文恢复的隔离前提。插件不会自动修改或检查这项配置。

### 3. 确保终端传递焦点事件

终端、复用器或 GUI 需要向 Neovim 传递焦点事件。使用 tmux 时，在其配置中启用：

```tmux
set -g focus-events on
```

多个 pane 可能共用一个 Fcitx 输入上下文，`InputState=No` 本身不会区分这些 pane；分屏间的恢复依赖焦点事件。无 UI 的 Neovim 不响应模式或焦点事件。

## 行为

- 收到焦点或文本输入模式边界事件时，Normal / Visual 等操作模式临时切为 ASCII；Insert / Replace / 命令行 / 终端输入模式撤销临时切换。初始启动不猜测后台 pane 是否有焦点。
- 原来已是英文，不创建“恢复中文”标记。只有插件从中文强制切成英文，才需要撤销。
- 同一输入上下文内切到其他 pane：`FocusLost` 撤销切换，返回时按当前模式重新应用。
- 切到其他应用：不把旧上下文的中文状态写到新上下文。等待原上下文重新聚焦，再恢复；即使返回的是 shell pane 而非 Neovim，也可恢复。待恢复期间每 100 ms 检查一次。
- 多个 Neovim 通过同一上下文的文件锁和临时所有权记录交接；较晚到达的旧 `FocusLost` 不会撤销新实例的状态。锁忙时在后续定时回调处理，不阻塞等待锁。
- 停用、挂起、正常退出时尝试恢复。无法安全操作原上下文时保留恢复记录；编辑器退出后不再有后台定时器。
- 查询失败与英文状态严格区分，失败不被当成“当前中文”。D-Bus 使用持久连接，不为每次切换启动外部命令，单次 RPC 超时 100 ms。

临时记录存于 `$XDG_RUNTIME_DIR/rime.nvim`，无 runtime 目录时使用 Neovim state 目录下的 `rime.nvim`。只存输入上下文 UUID 和实例标识，不存输入内容。进程间使用 `flock`；锁文件保留以避免删除锁文件造成竞争。

## 命令

- `:RimeEnable`：启用，并在已有 UI/焦点允许时应用当前模式。
- `:RimeDisable`：停用，并撤销已施加的临时英文状态。
- `:RimeToggle`：切换启用状态。

## 已知边界

Fcitx5 的 `SetAsciiMode(bool)` **没有上下文参数，也没有原子 compare-and-set**。本插件在写入前重新检查焦点 UUID，避免已观察到的跨上下文误写；但“检查与写入之间恰好发生焦点变化”的极窄竞争无法仅靠 Lua 消除。严格的原子上下文保证需要扩展 fcitx5-rime 接口。

`DebugInfo` 当前提供的焦点信息用于识别上下文；无焦点、多个焦点或非 Rime 输入法时不写入。若 Fcitx 修改其输出格式，错误会被报告，而不是猜测目标。中州韵的默认全局共享、缺失焦点事件、SSH 和强制杀死进程都不在无条件恢复保证范围内。独立 GUI/kitty/其他复用器仍需验证各自的焦点转发。

