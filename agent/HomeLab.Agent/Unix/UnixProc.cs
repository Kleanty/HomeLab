using System.Diagnostics;

namespace HomeLab.Agent;

/// <summary>Process details from /proc: executable, arguments, owner, a friendly name and an icon.</summary>
public static class UnixProc
{
    // OrdinalIgnoreCase: Kill() matches the process list's names however they are cased.
    public static readonly HashSet<string> Protected = new(StringComparer.OrdinalIgnoreCase)
    {
        "systemd", "init", "kthreadd", "Xorg", "Xwayland", "gnome-shell", "gnome-session-binary", "plasmashell", "kwin_x11", "kwin_wayland",
        "mutter", "pipewire", "pipewire-pulse", "wireplumber", "pulseaudio", "dbus-daemon", "dbus-broker", "sshd", "login", "gdm", "sddm", "lightdm",
        "NetworkManager", "polkitd", "udisksd", "upowerd",
        // ours
        "HomeLabAgent", "adb", "dotnet",
    };



    /// <summary>True if the process belongs to the user running the agent (only those may be ended).</summary>
    public static bool IsOwn(int pid)
    {
        var status = Sh.ReadFile($"/proc/{pid}/status");
        var uidLine = status?.Split('\n').FirstOrDefault(l => l.StartsWith("Uid:"));
        return uidLine is not null && uint.TryParse(uidLine.Split('\t', ' ', StringSplitOptions.RemoveEmptyEntries)[1], out var uid) && uid == Sh.Uid;
    }

    /// <summary>The parent's PID: /proc/&lt;pid&gt;/stat (the field after the command name).</summary>
    public static int? ParentPid(int pid)
    {
        var stat = Sh.ReadFile($"/proc/{pid}/stat");
        var close = stat?.LastIndexOf(')') ?? -1; // the command name may contain spaces and parentheses
        var f = close < 0 ? [] : stat![(close + 1)..].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return f.Length > 1 && int.TryParse(f[1], out var pp) ? pp : null;
    }

    public static string? ImagePath(Process p)
    {
        try { return new FileInfo($"/proc/{p.Id}/exe").LinkTarget; } catch { return null; }
    }

    public static string? Args(int pid)
    {
        var cmd = Sh.ReadFile($"/proc/{pid}/cmdline")?.Replace('\0', ' ').Trim();
        if (string.IsNullOrWhiteSpace(cmd)) return null;
        var i = cmd.IndexOf(' ');
        var rest = i > 0 ? cmd[(i + 1)..].Trim() : "";
        return rest.Length == 0 ? null : rest.Length > 140 ? rest[..137] + "…" : rest;
    }

    /// <summary>The launcher's name for the process, otherwise the process name.</summary>
    public static string Title(string name, string? path) => DesktopName(name) ?? name;

    private static readonly Lazy<Dictionary<string, (string Name, string? Icon)>> Desktop = new(ReadDesktopFiles);

    private static string? DesktopName(string exe) => Desktop.Value.TryGetValue(exe, out var d) ? d.Name : null;

    /// <summary>Linux: maps executables to the Name and Icon of their .desktop launcher.</summary>
    private static Dictionary<string, (string, string?)> ReadDesktopFiles()
    {
        var map = new Dictionary<string, (string, string?)>(StringComparer.Ordinal);
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        foreach (var dir in new[] { "/usr/share/applications", "/usr/local/share/applications", "/var/lib/snapd/desktop/applications",
                     "/var/lib/flatpak/exports/share/applications", Path.Combine(home, ".local/share/applications") })
        {
            if (!Directory.Exists(dir)) continue;
            foreach (var file in Directory.EnumerateFiles(dir, "*.desktop"))
            {
                try
                {
                    string? name = null, exec = null, icon = null;
                    foreach (var line in File.ReadLines(file))
                    {
                        if (line.StartsWith('[') && line != "[Desktop Entry]" && name is not null) break;
                        if (name is null && line.StartsWith("Name=")) name = line[5..];
                        else if (exec is null && line.StartsWith("Exec=")) exec = line[5..];
                        else if (icon is null && line.StartsWith("Icon=")) icon = line[5..];
                    }
                    if (name is null || exec is null) continue;
                    var bin = Path.GetFileName(exec.Trim('"').Split(' ')[0].Trim('"'));
                    if (bin.Length > 0 && bin.Length <= 15) map.TryAdd(bin.Length > 15 ? bin[..15] : bin, (name, icon));
                    map.TryAdd(bin, (name, icon));
                }
                catch { }
            }
        }
        return map;
    }

    /// <summary>A PNG icon for the process, if one can be found (Linux icon themes).</summary>
    public static byte[]? Icon(string name, string? path)
    {
        try
        {
            {
                var icon = Desktop.Value.TryGetValue(name, out var d) ? d.Icon : null;
                icon ??= name;
                if (icon.StartsWith('/') && icon.EndsWith(".png") && File.Exists(icon)) return File.ReadAllBytes(icon);
                foreach (var size in new[] { "64x64", "48x48", "128x128", "256x256", "32x32" })
                    foreach (var root in new[] { "/usr/share/icons/hicolor", "/usr/share/icons/Adwaita" })
                    {
                        var f = Path.Combine(root, size, "apps", icon + ".png");
                        if (File.Exists(f)) return File.ReadAllBytes(f);
                    }
                var px = Path.Combine("/usr/share/pixmaps", icon + ".png");
                return File.Exists(px) ? File.ReadAllBytes(px) : null;
            }
        }
        catch { }
        return null;
    }
}
