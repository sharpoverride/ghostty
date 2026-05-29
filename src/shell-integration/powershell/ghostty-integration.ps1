# Ghostty shell integration for PowerShell (Windows / win32 apprt).
#
# Emits OSC 133 semantic-prompt markers so the terminal knows where the
# prompt, the editable input, and command output begin and end. The key
# marker for "click to move cursor" is `133;A;cl=line`, which tells Ghostty
# the prompt is a single editable line; on a left-click in the prompt the
# terminal then synthesizes arrow keys to move the line editor's cursor.
#
# This script is injected by ConPTY.zig via `-EncodedCommand`; it runs once
# after the user's profile, in the global scope, for the interactive session.

$Global:__GhosttyHasRun = $true
$Global:__GhosttyFirstPrompt = $true

# Preserve any user-defined prompt so we can render it between our markers
# instead of clobbering the user's customizations.
if (Test-Path Function:\prompt) {
    Rename-Item Function:\prompt Global:__GhosttyOriginalPrompt -ErrorAction SilentlyContinue
}

function Global:prompt {
    # Capture the prior command's status before anything else mutates it.
    $exit = $LASTEXITCODE
    $ok = $?

    $esc = [char]27
    $bel = [char]7
    $out = ""

    # OSC 133;D — previous command finished (with its exit code). Skipped on
    # the very first prompt since no command has run yet.
    if (-not $Global:__GhosttyFirstPrompt) {
        $code = if ($ok) { 0 } elseif ($null -ne $exit) { $exit } else { 1 }
        $out += "$esc]133;D;$code$bel"
    }
    $Global:__GhosttyFirstPrompt = $false

    # OSC 133;A — fresh line + start of prompt. `cl=line` enables
    # click-to-move-cursor; `redraw=last` matches the bash integration.
    $out += "$esc]133;A;redraw=last;cl=line$bel"

    # Render the user's original prompt, or a sensible default.
    if (Test-Path Function:\__GhosttyOriginalPrompt) {
        $out += [string](& $Global:__GhosttyOriginalPrompt)
    } else {
        $loc = $executionContext.SessionState.Path.CurrentLocation
        $out += "PS $loc$('>' * ($nestedPromptLevel + 1)) "
    }

    # OSC 133;B — end of prompt, start of user input. Everything the user
    # types after this is marked as editable input, which is what lets the
    # terminal know it may move the cursor within it.
    $out += "$esc]133;B$bel"

    return $out
}

# OSC 133;C — command executed: emitted when the user submits a line, so the
# terminal knows the cursor has left the editable prompt region and stops
# treating subsequent output rows as movable input. Mirrors the approach used
# by Windows Terminal's PowerShell shell integration.
if (Get-Module -ListAvailable -Name PSReadLine -ErrorAction SilentlyContinue) {
    Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {
        [Console]::Write("$([char]27)]133;C$([char]7)")
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }

    # Disable PSReadLine prediction inside Ghostty-launched shells.
    # Recent PSReadLine ships with PredictionSource = HistoryAndPlugin
    # enabled by default; the very first thing it suggests in a fresh
    # shell is the previous shell's last command. If that command was
    # `exit`, the suggestion appears inline and one Enter accepts it,
    # which closes the tab the user just opened. Turn it off so users
    # see a clean prompt.
    try {
        Set-PSReadLineOption -PredictionSource None -ErrorAction Stop
    } catch {
        # Older PSReadLine (<2.1) doesn't support PredictionSource.
        # Nothing to do — predictions don't exist there.
    }
}
