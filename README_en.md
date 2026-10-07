# rime.nvim

English | [简体中文](README.md)

Automatically switches Fcitx5 Rime between Chinese and ASCII based on Neovim's mode and focus. Navigation modes temporarily use ASCII; text entry or leaving the editor restores the previous input state. No changes to Rime schemas or input-switching shortcuts are required.

## Quick start

Requires Linux, Neovim 0.11+ with LuaJIT, Fcitx5, fcitx5-rime and `libdbus-1.so.3`, running in a local desktop session with `DBUS_SESSION_BUS_ADDRESS`. Input-method integration is inactive on Windows, macOS and SSH sessions.

### 1. Install with lazy.nvim

```lua
return {
  "HoronLee/rime.nvim",
  main = "rime_toggle",
  lazy = false,
  cond = vim.fn.has("linux") == 1,
  opts = {},
}
```

`opts` automatically calls the plugin's `setup()`. `cond` skips loading on Windows and macOS, so the same Neovim configuration can be shared across platforms. The plugin also skips initialization on non-Linux platforms independently of this condition.

### 2. Disable Rime state sharing

In the Fcitx5 configuration tool, open the **Rime addon's settings**, set **Shared Input State** to **No**, and apply. The configuration tool saves the setting; no manual file editing is necessary. This is not the similarly named option in Fcitx5's global settings.

The equivalent setting in `~/.config/fcitx5/conf/rime.conf` is:

```ini
InputState=No
```

If editing the file manually, reload the Rime addon afterward:

```sh
busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 ReloadAddonConfig s rime
```

`InputState` is an enum and does not accept `Yes`. The effective policy must disable sharing: select **No**, or select **Follow Global Configuration** with global **Shared Input State** set to **No**. Selecting **No** directly is recommended so later global configuration changes do not affect Rime.

**All** (Rime's default) shares state across input contexts; **Program** shares it per application. Neither satisfies the isolation required for context-scoped restoration. The plugin does not change or check this setting automatically.

### 3. Enable terminal focus events

The terminal, multiplexer or GUI must forward focus events to Neovim. For tmux, add this to its configuration:

```tmux
set -g focus-events on
```

Multiple panes can share one Fcitx input context. `InputState=No` does not distinguish these panes; restoration between them depends on focus events. Headless Neovim does not act on mode or focus events.

## Behavior

- At focus or text-entry mode boundary events, navigation modes temporarily use ASCII. Insert, Replace, command-line and terminal-input modes release the override. Startup does not guess whether a background pane has focus.
- Existing user-selected ASCII is preserved. Only an ASCII change made by this plugin creates a rollback record.
- Leaving a pane within the same input context restores Chinese; returning applies the current mode.
- When another application's input context is focused, the old context's restoration is deferred instead of being written into the new one. While a rollback remains pending, it checks every 100 ms and can restore when returning directly to a shell pane.
- Context-scoped file locks and ownership records coordinate multiple Neovim processes. A late old-owner `FocusLost` cannot undo a new owner's override. Busy locks are revisited by the timer rather than waited on synchronously.
- Disable, suspend and normal exit attempt restoration. When the original context cannot safely be accessed, its record is retained; no timer survives editor exit.
- Query failure is not mistaken for Chinese. Calls use a persistent D-Bus connection, not subprocesses; each RPC has a 100 ms timeout.

Records live under `$XDG_RUNTIME_DIR/rime.nvim`, falling back to `rime.nvim` under Neovim's state directory. They contain context UUIDs and instance IDs, never input text. Persistent `flock` files prevent inode-replacement lock races.

## Commands

- `:RimeEnable`: enable and apply the current mode when the known UI/focus permits it.
- `:RimeDisable`: disable and undo outstanding temporary ASCII changes.
- `:RimeToggle`: toggle enabled state.

## Limits

Fcitx5's `SetAsciiMode(bool)` accepts **no context argument and provides no atomic compare-and-set**. The plugin rechecks the focused UUID immediately before writes, but cannot eliminate a focus change between that check and the write. Strict atomic context isolation requires an fcitx5-rime API extension.

The current `DebugInfo` output identifies focused contexts. Missing/ambiguous focus and non-Rime input methods do not cause writes. Malformed output is reported instead of guessed. Global Rime sharing, missing focus events, SSH and forcibly killed processes are outside unconditional restoration guarantees. Individual GUIs, kitty and other multiplexers still require their own focus-forwarding verification.

