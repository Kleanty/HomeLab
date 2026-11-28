using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace HomeLab.Agent;

/// <summary>CPU, memory and temperature readings on Linux (/proc, /sys).</summary>
public static partial class UnixSystem
{
    /// <summary>Cumulative CPU ticks: (idle, total). The load is the change of busy ticks over the change of total ticks.</summary>
    public static (long Idle, long Total) CpuTimes()
    {
        var line = File.ReadLines("/proc/stat").First(); // cpu user nice system idle iowait irq softirq steal …
        var f = line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Skip(1).Take(8).Select(long.Parse).ToArray();
        return (f[3] + f[4], f.Sum());
    }

    /// <summary>(used, total) memory in bytes.</summary>
    public static (double Used, double Total) Memory()
    {
        long Kb(string key) => File.ReadLines("/proc/meminfo").Where(l => l.StartsWith(key + ":"))
            .Select(l => long.Parse(l.Split(' ', StringSplitOptions.RemoveEmptyEntries)[1])).FirstOrDefault() * 1024;
        var tot = Kb("MemTotal");
        return (tot - Kb("MemAvailable"), tot);
    }

    public static string CpuName()
    {
        var info = Sh.ReadFile("/proc/cpuinfo") ?? "";
        foreach (var key in new[] { "model name", "Model", "Hardware" })
            if (Regex.Match(info, $@"^{key}\s*:\s*(.+)$", RegexOptions.Multiline) is { Success: true } m) return m.Groups[1].Value.Trim();
        return "CPU";
    }

    /// <summary>CPU package temperature in °C from Linux hwmon (k10temp, zenpower, coretemp…).</summary>
    public static double? CpuTemp()
    {
        if (!Directory.Exists("/sys/class/hwmon")) return null;
        string[] preferred = ["k10temp", "zenpower", "coretemp", "cpu_thermal", "soc_thermal", "acpitz"];
        var sensors = Directory.GetDirectories("/sys/class/hwmon")
            .Select(d => (Dir: d, Name: Sh.ReadFile(Path.Combine(d, "name"))?.Trim() ?? ""))
            .Where(s => preferred.Contains(s.Name))
            .OrderBy(s => Array.IndexOf(preferred, s.Name));
        foreach (var (dir, _) in sensors)
            if (double.TryParse(Sh.ReadFile(Path.Combine(dir, "temp1_input"))?.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var milli))
                return Math.Round(milli / 1000, 1);
        return null;
    }
}
