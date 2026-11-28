using System.Runtime.InteropServices;

namespace HomeLab.Agent;

/// <summary>
/// Sends key combinations and text to the computer for shortcut keys and macros: "ctrl+shift+m", "win+d", "f13",
/// "playpause"; several combos separated by commas are pressed one after another.
/// Uses xdotool (X11) or wtype (Wayland).
/// </summary>
public static class KeySender
{
    internal record struct MouseCall(string Action, int Dx, int Dy, int Delta);
    internal static Action<MouseCall>? TestMouseSink;

    private static readonly string[] Modifiers = ["ctrl", "shift", "alt", "win"];

    /// <summary>Splits "Ctrl+Shift+M, Win+D" into combos of normalized key names; throws on unknown keys.</summary>
    public static List<List<string>> Parse(string spec)
    {
        var combos = new List<List<string>>();
        foreach (var part in spec.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var keys = part.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(Normalize).ToList();
            if (keys.Count == 0) continue;
            if (keys.Count(k => !Modifiers.Contains(k)) > 1) throw new ArgumentException($"\"{part}\" has more than one key besides Ctrl / Shift / Alt / Win");
            foreach (var k in keys) if (!Modifiers.Contains(k) && !IsKnown(k)) throw new ArgumentException($"unknown key \"{k}\"");
            combos.Add(keys);
        }
        if (combos.Count == 0) throw new ArgumentException("no keys given");
        return combos;
    }

    private static string Normalize(string k) => Numpad(k.ToLowerInvariant()) ?? k.ToLowerInvariant() switch
    {
        "control" or "ctl" => "ctrl",
        "cmd" or "command" or "super" or "meta" or "windows" or "⌘" => "win",
        "option" or "opt" or "⌥" => "alt",
        "return" => "enter",
        "escape" => "esc",
        "del" => "delete",
        "bksp" => "backspace",
        "pgup" => "pageup",
        "pgdn" or "pagedn" => "pagedown",
        "prtsc" or "print" => "printscreen",
        "play" or "pause" or "play/pause" => "playpause",
        "next" => "nexttrack",
        "prev" or "previous" => "prevtrack",
        "volup" => "volumeup",
        "[" or "openbracket" => "bracketleft",
        "]" or "closebracket" => "bracketright",
        "voldown" => "volumedown",
        var x => x,
    };

    // The keypad, under the names other tools use: numpad3, num3, kp3, KP_3 (xdotool), numpad_3; numpadadd, kpplus,
    // KP_Add... "numpad+" cannot be written, as + joins the keys of a combo (#270).
    private static readonly string[] NumpadPrefixes = ["numpad_", "numpad", "num_", "num", "kp_", "kp"];

    private static string? Numpad(string k)
    {
        var prefix = NumpadPrefixes.FirstOrDefault(k.StartsWith);
        if (prefix is null) return null;
        var rest = k[prefix.Length..];
        var name = rest switch
        {
            [var d] when char.IsAsciiDigit(d) => rest,
            "enter" or "return" => "enter",
            "add" or "plus" => "add",
            "subtract" or "sub" or "minus" => "subtract",
            "multiply" or "mul" or "times" or "*" => "multiply",
            "divide" or "div" or "slash" or "/" => "divide",
            "decimal" or "dec" or "period" or "dot" or "." or "comma" or "separator" => "decimal",
            _ => null,
        };
        return name is null ? null : "numpad" + name;
    }

    private static bool IsKnown(string k) =>
        (k.Length == 1 && char.IsAsciiLetterOrDigit(k[0])) || Special.ContainsKey(k) || (k.Length is 2 or 3 && k[0] == 'f' && int.TryParse(k[1..], out var n) && n is >= 1 and <= 24);

    // name -> xdotool key name
    private static readonly Dictionary<string, string> Special = new()
    {
        ["enter"] = "Return", ["tab"] = "Tab", ["esc"] = "Escape", ["space"] = "space",
        ["backspace"] = "BackSpace", ["delete"] = "Delete", ["insert"] = "Insert",
        ["home"] = "Home", ["end"] = "End", ["pageup"] = "Prior", ["pagedown"] = "Next",
        ["up"] = "Up", ["down"] = "Down", ["left"] = "Left", ["right"] = "Right",
        ["printscreen"] = "Print", ["minus"] = "minus", ["equals"] = "equal",
        ["comma"] = "comma", ["period"] = "period", ["slash"] = "slash", ["semicolon"] = "semicolon",
        ["bracketleft"] = "bracketleft", ["bracketright"] = "bracketright",
        ["playpause"] = "XF86AudioPlay", ["nexttrack"] = "XF86AudioNext", ["prevtrack"] = "XF86AudioPrev",
        ["mute"] = "XF86AudioMute", ["volumeup"] = "XF86AudioRaiseVolume", ["volumedown"] = "XF86AudioLowerVolume",
        // the keypad (#270): its own keys, not the number row, so a shortcut bound to Numpad3 (Discord, games) is matched
        ["numpad0"] = "KP_0", ["numpad1"] = "KP_1", ["numpad2"] = "KP_2", ["numpad3"] = "KP_3",
        ["numpad4"] = "KP_4", ["numpad5"] = "KP_5", ["numpad6"] = "KP_6", ["numpad7"] = "KP_7",
        ["numpad8"] = "KP_8", ["numpad9"] = "KP_9",
        ["numpadmultiply"] = "KP_Multiply", ["numpadadd"] = "KP_Add", ["numpadsubtract"] = "KP_Subtract",
        ["numpaddecimal"] = "KP_Decimal", ["numpaddivide"] = "KP_Divide",
        ["numpadenter"] = "KP_Enter",
    };

    public static void SendKeys(string spec)
    {
        var combos = Parse(spec);
        foreach (var combo in combos)
        {
            Send(combo);
            if (combos.Count > 1) Thread.Sleep(60);
        }
    }

    /// <summary>Presses one parsed combo; false when xdotool or wtype failed (throws when no tool is installed).</summary>
    public static bool SendCombo(List<string> combo) => Send(combo);

    private static bool Send(List<string> combo)
    {
        // X11: xdotool; Wayland: wtype
        var x = string.Join("+", combo.Select(k => k switch
        {
            "win" => "super", "ctrl" or "shift" or "alt" => k,
            _ when Special.TryGetValue(k, out var s) => s,
            _ when k[0] == 'f' && k.Length > 1 => k.ToUpperInvariant(),
            _ => k,
        }));
        if (Sh.Which("xdotool") is not null && Environment.GetEnvironmentVariable("WAYLAND_DISPLAY") is null) return Sh.Run("xdotool", "key", "--clearmodifiers", x) is not null;
        if (Sh.Which("wtype") is not null)
        {
            var args = new List<string>();
            var mods = combo.Where(Modifiers.Contains).Select(m => m == "win" ? "logo" : m).ToList();
            foreach (var m in mods) args.AddRange(["-M", m]);
            var key = combo.FirstOrDefault(k => !Modifiers.Contains(k));
            if (key is not null) args.AddRange(["-k", Special.TryGetValue(key, out var s) ? s : key]);
            foreach (var m in Enumerable.Reverse(mods)) args.AddRange(["-m", m]);
            return Sh.Run("wtype", [.. args]) is not null;
        }
        if (Sh.Which("xdotool") is not null) return Sh.Run("xdotool", "key", "--clearmodifiers", x) is not null;
        throw new InvalidOperationException("sending keys needs xdotool (X11) or wtype (Wayland)");
    }

    public static void TypeText(string text) => TryTypeText(text, CancellationToken.None);

    /// <summary>
    /// Types the text; false when the tool failed (throws when no tool is installed). The tool gets time for the whole text
    /// (xdotool types a character every 8 ms) and is killed when <paramref name="ct"/> is cancelled.
    /// </summary>
    public static bool TryTypeText(string text, CancellationToken ct)
    {
        var timeout = TimeSpan.FromMilliseconds(3000 + 20L * text.Length);
        bool Run(string tool, params string[] args)
        {
            var path = Sh.Which(tool);
            if (path is null) return false;
            var psi = new System.Diagnostics.ProcessStartInfo(path);
            foreach (var a in args) psi.ArgumentList.Add(a);
            try { return ToolProcess.RunAsync(psi, timeout, ct).GetAwaiter().GetResult().ExitCode == 0; }
            catch (TimeoutException) { return false; }
        }
        if (Sh.Which("xdotool") is not null && Environment.GetEnvironmentVariable("WAYLAND_DISPLAY") is null) return Run("xdotool", "type", "--delay", "8", "--", text);
        if (Sh.Which("wtype") is not null) return Run("wtype", "--", text);
        if (Sh.Which("xdotool") is not null) return Run("xdotool", "type", "--delay", "8", "--", text);
        throw new InvalidOperationException("typing needs xdotool (X11) or wtype (Wayland)");
    }

    private static readonly object UnixMoveLock = new();
    private static readonly object UnixSendLock = new();
    private static int _unixPendingDx;
    private static int _unixPendingDy;
    private static bool _unixMoveScheduled;

    private static void FlushUnixMove()
    {
        int dx, dy;
        lock (UnixMoveLock)
        {
            dx = _unixPendingDx;
            dy = _unixPendingDy;
            _unixPendingDx = 0;
            _unixPendingDy = 0;
        }
        if (dx != 0 || dy != 0)
            UnixMouse("mousemove_relative", "--", dx.ToString(System.Globalization.CultureInfo.InvariantCulture), dy.ToString(System.Globalization.CultureInfo.InvariantCulture));
    }

    private static void UnixAction(params string[] args)
    {
        lock (UnixSendLock)
        {
            FlushUnixMove();
            UnixMouse(args);
        }
    }

    private static void UnixMouse(params string[] args)
    {
        var xdotool = Sh.Which("xdotool");
        if (xdotool is null)
            throw new InvalidOperationException("controlling the mouse needs xdotool (X11)");
        var psi = new System.Diagnostics.ProcessStartInfo(xdotool);
        foreach (var a in args) psi.ArgumentList.Add(a);
        try
        {
            ToolProcess.RunAsync(psi, TimeSpan.FromSeconds(2), CancellationToken.None).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException("xdotool failed: " + ex.Message, ex);
        }
    }

    public static void MouseMove(int dx, int dy)
    {
        if (TestMouseSink is not null) { TestMouseSink(new MouseCall("move", dx, dy, 0)); return; }
        lock (UnixMoveLock)
        {
            _unixPendingDx += dx;
            _unixPendingDy += dy;
            if (_unixMoveScheduled) return;
            _unixMoveScheduled = true;
        }
        Task.Run(async () =>
        {
            await Task.Delay(16);
            lock (UnixSendLock)
            {
                lock (UnixMoveLock) { _unixMoveScheduled = false; }
                FlushUnixMove();
            }
        });
    }

    public static void MouseClick()
    {
        if (TestMouseSink is not null) { TestMouseSink(new MouseCall("click", 0, 0, 0)); return; }
        UnixAction("click", "1");
    }

    public static void MouseRightClick()
    {
        if (TestMouseSink is not null) { TestMouseSink(new MouseCall("rightClick", 0, 0, 0)); return; }
        UnixAction("click", "3");
    }

    private static int _unixVScrollAcc;
    private static int _unixHScrollAcc;

    public static void MouseScroll(int delta)
    {
        if (delta == 0) return;
        if (TestMouseSink is not null) { TestMouseSink(new MouseCall("scroll", 0, 0, delta)); return; }
        _unixVScrollAcc += delta;
        var n = Math.Abs(_unixVScrollAcc) / 120;
        if (n == 0) return;
        var dir = _unixVScrollAcc > 0 ? "4" : "5";
        _unixVScrollAcc -= Math.Sign(_unixVScrollAcc) * n * 120;
        UnixAction("click", "--repeat", n.ToString(System.Globalization.CultureInfo.InvariantCulture), dir);
    }

    public static void MouseHorizontalScroll(int delta)
    {
        if (delta == 0) return;
        if (TestMouseSink is not null) { TestMouseSink(new MouseCall("hscroll", 0, 0, delta)); return; }
        _unixHScrollAcc += delta;
        var n = Math.Abs(_unixHScrollAcc) / 120;
        if (n == 0) return;
        var dir = _unixHScrollAcc > 0 ? "7" : "6";
        _unixHScrollAcc -= Math.Sign(_unixHScrollAcc) * n * 120;
        UnixAction("click", "--repeat", n.ToString(System.Globalization.CultureInfo.InvariantCulture), dir);
    }

    public static void MouseDown()
    {
        if (TestMouseSink is not null) { TestMouseSink(new MouseCall("mouseDown", 0, 0, 0)); return; }
        UnixAction("mousedown", "1");
    }

    public static void MouseUp()
    {
        if (TestMouseSink is not null) { TestMouseSink(new MouseCall("mouseUp", 0, 0, 0)); return; }
        UnixAction("mouseup", "1");
    }
}
