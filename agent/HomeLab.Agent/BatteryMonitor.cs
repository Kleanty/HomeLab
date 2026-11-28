using System.Runtime.InteropServices;
using System.Text.Json;

namespace HomeLab.Agent;

/// <param name="Kind">headphones, mouse, keyboard, controller, laptop or other (for the icon).</param>
public sealed record DeviceBattery(string Name, int Level, string Kind, bool? Charging);

/// <summary>
/// Battery levels of wireless devices: headphones, mice, keyboards, controllers (and a laptop's own battery on Linux).
///  - Linux: UPower (BlueZ devices, Logitech receivers, the laptop battery).
/// Read every 20 seconds, only while a phone shows the widget.
/// </summary>
public sealed partial class BatteryMonitor(ILogger<BatteryMonitor> log) : BackgroundService
{
    private const long NoRequest = long.MinValue;
    internal const long ActiveRefreshIntervalMs = 20_000;
    private volatile IReadOnlyList<DeviceBattery> _devices = [];
    private long _lastRequest = NoRequest;
    private long? _readAt;

    public IReadOnlyList<DeviceBattery> Snapshot()
    {
        Interlocked.Exchange(ref _lastRequest, Environment.TickCount64);
        return _devices;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var lastRequest = Interlocked.Read(ref _lastRequest);
            var now = Environment.TickCount64;
            var wanted = lastRequest != NoRequest && now - lastRequest < 120_000;
            if (wanted && (_readAt is null || now - _readAt.Value > ActiveRefreshIntervalMs))
            {
                _readAt = now;
                try { _devices = await Task.Run(Read, ct); }
                catch (Exception ex) { log.LogDebug("batteries: {Msg}", ex.Message); }
            }
            await Task.Delay(1000, ct);
        }
    }

    private static List<DeviceBattery> SortDevices(IEnumerable<DeviceBattery> list)
        => list.OrderBy(d => d.Kind == "laptop" ? 1 : 0).ThenBy(d => d.Name).ToList();

    private static IReadOnlyList<DeviceBattery> Read()
        => SortDevices(Linux());

    /// <summary>Guesses the kind of device from its name.</summary>
    public static string KindOf(string name)
    {
        var n = name.ToLowerInvariant();
        if (System.Text.RegularExpressions.Regex.IsMatch(n, @"buds|airpods|headphone|headset|earbud|earphone|\bwh-|\bwf-|jabra|bose|beats|sennheiser|soundcore|\bqc\d|xm\d|arctis|hyperx cloud|blackshark|barracuda|kraken|nari|kaira|opus")) return "headphones";
        if (System.Text.RegularExpressions.Regex.IsMatch(n, @"mouse|mx master|mx anywhere|pebble|trackball|trackpad|\bm\d{3}\b|g\d{3} |basilisk|viper|deathadder|naga|orochi|cobra|lancehead|mamba")) return "mouse";
        if (System.Text.RegularExpressions.Regex.IsMatch(n, @"keyboard|keys|\bk\d{3}\b|slim|craft|magic keyboard|blackwidow|huntsman|deathstalker|ornata|tartarus")) return "keyboard";
        if (System.Text.RegularExpressions.Regex.IsMatch(n, @"controller|gamepad|xbox|dualsense|dualshock|joy-con|8bitdo")) return "controller";
        if (System.Text.RegularExpressions.Regex.IsMatch(n, @"pencil|stylus|pen\b")) return "pen";
        return "other";
    }

    // ---------------------------------------------------------------- Linux
    private static List<DeviceBattery> Linux()
    {
        var list = new List<DeviceBattery>();
        foreach (var path in (Sh.Run("upower", "-e") ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (path.EndsWith("DisplayDevice") || path.Contains("line_power")) continue;
            var info = Sh.Run("upower", "-i", path) ?? "";
            string? Field(string key) => info.Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.StartsWith(key + ":"))?[(key.Length + 1)..].Trim();
            if (!int.TryParse(Field("percentage")?.TrimEnd('%').Split(',', '.')[0], out var level)) continue;
            if (Field("present") == "no") continue;
            var file = Path.GetFileName(path);
            var kind = file.StartsWith("battery_") ? "laptop" : file.StartsWith("mouse_") ? "mouse" : file.StartsWith("keyboard_") ? "keyboard"
                : file.StartsWith("headset_") || file.StartsWith("headphones_") ? "headphones" : file.StartsWith("gaming_input_") ? "controller" : null;
            var name = Field("model") is { Length: > 0 } m ? m : kind == "laptop" ? "Laptop" : file;
            if (kind == "laptop") name = "This laptop";
            var state = Field("state");
            list.Add(new DeviceBattery(name, Math.Clamp(level, 0, 100), kind ?? KindOf(name), state is null ? null : state is "charging" or "fully-charged"));
        }
        return list;
    }

}
