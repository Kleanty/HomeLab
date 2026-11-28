using System.Diagnostics;
using System.Net.Sockets;
using System.Text;

namespace HomeLab.Agent;

/// <summary>Configured control actions. Phones never supply executable paths, credentials or shell commands.</summary>
public sealed partial class ControlDeck : BackgroundService
{
    private readonly ConfigStore _config;
    private readonly ILogger<ControlDeck> _log;
    private readonly ControlTasks _tasks;
    private readonly PushStore? _push;
    private readonly AudioControl? _master;

    public ControlDeck(ConfigStore config, AudioControl audio, ILogger<ControlDeck> log, PushStore push)
    {
        _config = config; _log = log; _push = push; _master = audio;
        _tasks = new(config, log);
    }

    public Task<object> Snapshot(CancellationToken ct)
    {
        var c = _config.Get();
        return Task.FromResult<object>(new
        {
            actions = c.Controls.Actions.Where(a => a.Enabled).Select(Describe).ToArray(),
            shortcuts = c.Shortcuts.Select(DescribeShortcut),
        });
    }

    public string TaskOutput(string id) => _tasks.Output(id);

    public async Task<DeckResult> Act(string kind, string? id, string? op, int? value, CancellationToken ct)
    {
        id ??= ""; op ??= "";
        if (id.Length > 2048 || op.Length > 64) return new(false, "Invalid control request");
        try
        {
            switch (kind)
            {
                case "action": return await Action(id, op, value, ct);
                case "lock": case "monitor-off":
                    var ok = Shortcuts.Execute(new Shortcut { Cmd = "builtin:" + kind, Label = kind }, _log) is null;
                    return new(ok, ok ? null : "This control is unavailable on this computer");
                default: return new(false, "Unknown control action");
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception ex) { _log.LogDebug(ex, "Control {Kind} failed", kind); return new(false, "Control failed"); }
    }

    /// <summary>Stops task or server controls that have been disabled.</summary>
    public void StopDisabledControls()
    {
        foreach (var a in _config.Get().Controls.Actions.Where(a => !a.Enabled && a.Kind is "task" or "server"))
            _tasks.StopIfRunning(a.Id);
    }

    private async Task<DeckResult> Action(string id, string op, int? value, CancellationToken ct)
    {
        var c = _config.Get();
        if (id.StartsWith("shortcut:", StringComparison.Ordinal))
            return await ShortcutAction(c, id[9..], op, ct);
        var action = c.Controls.Actions.FirstOrDefault(a => a.Id == id);
        if (action is null) return new(false, "Choose a configured control in desktop settings");
        if (!action.Enabled && !(op == "stop" && action.Kind is "task" or "server"))
            return new(false, "Control is disabled");
        switch (action.Kind)
        {
            case "task": case "server": return _tasks.Start(action, op == "stop");
            case "shortcut": case "macro": case "snippet": case "project": case "app": case "focus":
                return await ShortcutAction(c, action.Target, op, ct);
            case "keys": KeySender.SendKeys(action.Target); return new(true);
            case "text": KeySender.TypeText(action.Target); return new(true);
            case "osc":
                await SendOsc(action.Device ?? "", action.Target, value ?? action.Value, ct); return new(true);
            default: return new(false, "Unknown control kind");
        }
    }

    private static bool ShortcutRunning(Shortcut shortcut)
    {
        if (shortcut.Cmd.StartsWith("builtin:", StringComparison.Ordinal) || Uri.TryCreate(shortcut.Cmd, UriKind.Absolute, out var uri) && !uri.IsFile) return false;
        try
        {
            var name = Path.GetFileNameWithoutExtension(shortcut.Cmd);
            if (name.Length == 0) return false; // a folder: an empty name would match every process
            var processes = Process.GetProcessesByName(name);
            try { return processes.Any(p => p.MainWindowHandle != 0); }
            finally { foreach (var process in processes) process.Dispose(); }
        }
        catch { return false; }
    }
    private static DeckItem DescribeShortcut(Shortcut s) => new(s.Id, s.Label, s.Cmd switch
    { "builtin:keys" => "keys", "builtin:text" => "text", "builtin:macro" => "macro", _ when s.Cmd.StartsWith("builtin:", StringComparison.Ordinal) => "shortcut", _ => "app" }, ShortcutRunning(s) ? "Running" : null);
    private async Task<DeckResult> ShortcutAction(AgentConfig config, string id, string op, CancellationToken ct)
    {
        var shortcut = config.Shortcuts.FirstOrDefault(s => s.Id == id);
        if (shortcut is null) return new(false, "Configured shortcut is missing");
        var error = Shortcuts.Run(config, id, _log, _push, _master);
        return new(error is null, error is null ? null : "Configured shortcut failed");
    }

    internal static byte[] OscPacket(string address, float value)
    {
        if (!address.StartsWith('/') || address.Length > 256 || address.Any(c => c < 33 || c > 126)) throw new ArgumentException("Invalid OSC address");
        static byte[] Text(string s) { var raw = Encoding.UTF8.GetBytes(s); var padded = new byte[(raw.Length + 4) / 4 * 4]; raw.CopyTo(padded, 0); return padded; }
        var data = new List<byte>(Text(address)); data.AddRange(Text(",f"));
        var number = BitConverter.GetBytes(value); if (BitConverter.IsLittleEndian) Array.Reverse(number); data.AddRange(number); return data.ToArray();
    }
    private static async Task SendOsc(string endpoint, string address, int value, CancellationToken ct)
    {
        if (!Uri.TryCreate("udp://" + endpoint, UriKind.Absolute, out var uri) || uri.Port is <= 0 or > 65535) throw new ArgumentException("Configure an OSC host and port");
        using var client = new UdpClient();
        var packet = OscPacket(address, value);
        await client.SendAsync(packet, uri.Host, uri.Port, ct);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try { await Task.Delay(Timeout.Infinite, stoppingToken); }
        catch (OperationCanceledException) { }
        finally { await _tasks.StopAsync(); }
    }

    public override void Dispose()
    {
        base.Dispose();
        _tasks.Dispose();
    }
}
