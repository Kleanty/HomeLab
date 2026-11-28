
namespace HomeLab.Agent;

/// <summary>
/// Real app icons for shortcuts whose command is an actual program on disk (an .exe, an .app bundle, a Linux binary).
/// Shell addresses (shell:AppsFolder\…), protocol handlers (ms-settings:, ms-screenclip:), URLs, builtin: commands,
/// and Windows' App Execution Alias stubs for packaged apps (wt.exe, ms-teams.exe: a reparse point with no icon of
/// its own) have no real icon to read, so this returns null for them and the phone keeps showing the chosen emoji.
/// </summary>
internal static class ShortcutIcons
{
    // Keyed by command, not shortcut id: resolving a path walks every PATH directory on Windows, so repeating it
    // for every shortcut on every /api/config request is wasteful. A command only changes when the config is
    // saved, so Program.cs's /api/settings PUT clears this then. Only a successful resolution is cached: if the
    // command does not currently resolve, the cache must not keep saying so once the program gets installed,
    // since nothing else would tell it to look again before the next settings save.
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, string> ResolvedPathCache = new();
    private static string? CachedResolvePath(string cmd)
    {
        if (ResolvedPathCache.TryGetValue(cmd, out var cached))
        {
            if (IsResolvedProgram(cached)) return cached;
            ResolvedPathCache.TryRemove(new KeyValuePair<string, string>(cmd, cached));
        }
        var resolved = ResolvePath(cmd);
        if (resolved is not null) ResolvedPathCache[cmd] = resolved;
        return resolved;
    }

    /// <summary>Cheap check for whether <see cref="Icon"/> is worth asking for, without extracting one.</summary>
    public static bool HasIcon(Shortcut sc) => CachedResolvePath(sc.Cmd) is not null;

    /// <summary>A value that changes when the detected program's own icon could have changed (it was reinstalled).</summary>
    public static long? Revision(Shortcut sc)
    {
        if (CachedResolvePath(sc.Cmd) is not { } path) return null;
        // A plain write time can repeat under heavy load (Windows file timestamps tick in ~15ms steps); folding in
        // the path and size as well means only an actual reinstall (new bytes, almost never the same size) changes
        // this, and a program that merely gets touched without changing does not spuriously change it. A macOS
        // .app is a directory (FileInfo.Length throws on one), so size only applies to a real file.
        try
        {
            var isBundle = Directory.Exists(path);
            var writeTime = isBundle ? Directory.GetLastWriteTimeUtc(path) : File.GetLastWriteTimeUtc(path);
            var size = isBundle ? 0L : new FileInfo(path).Length;
            return HashCode.Combine(path, size, writeTime.Ticks);
        }
        catch { return null; }
    }

    public static void ClearHasIconCache() => ResolvedPathCache.Clear();

    /// <summary>The picture /api/shortcuts/icon serves: an upload first, else the program's own icon. With
    /// <paramref name="uploadOnly"/> (a Big button filling itself with the picture) only the upload, so an upload removed
    /// after the phone read its config is never replaced by a program icon stretched across the key.</summary>
    public static (byte[] Bytes, string ContentType)? Picture(Shortcut sc, ShortcutIconUploads uploads, bool uploadOnly) =>
        uploads.Read(sc.Id) ?? (!uploadOnly && Icon(sc) is { } png ? (png, "image/png") : null);

    public static byte[]? Icon(Shortcut sc)
    {
        var path = ResolvePath(sc.Cmd);
        if (path is null) return null;
        var name = Path.GetFileNameWithoutExtension(path);
        // UnixProc.Icon only recognises a macOS bundle when the path contains ".app/"; a bare "X.app" has nothing after it.
        var probe = path.EndsWith(".app", StringComparison.OrdinalIgnoreCase) ? path + "/" : path;
        return UnixProc.Icon(name, probe);
    }

    /// <summary>
    /// True for an actual file path ("C:\…\app.exe", "/usr/bin/x", "code", "~/bin/x"); false for a builtin: command,
    /// a URL, a protocol handler (ms-settings:) or a shell address (shell:AppsFolder\…) — none of which name a file.
    /// </summary>
    internal static bool LooksLikeFilePath(string cmd)
    {
        if (string.IsNullOrWhiteSpace(cmd)) return false;
        cmd = cmd.Trim().Trim('"');
        if (cmd.StartsWith("builtin:", StringComparison.OrdinalIgnoreCase)) return false;
        // A drive letter ("C:\…") is a path; any other "word:" is a shell address or protocol handler (ms-settings:, shell:AppsFolder\…, https://…).
        var colon = cmd.IndexOf(':');
        return colon < 0 || (colon == 1 && char.IsLetter(cmd[0]));
    }

    /// <summary>
    /// The real file behind a shortcut's command, or null when it is not a program with its own icon (a shell
    /// address, a protocol handler, a URL, a builtin: command, or an App Execution Alias stub).
    /// </summary>
    private static string? ResolvePath(string cmd)
    {
        if (!LooksLikeFilePath(cmd)) return null;
        cmd = cmd.Trim().Trim('"');
        if (cmd.StartsWith("~")) cmd = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + cmd[1..];
        if (cmd.EndsWith(".app", StringComparison.OrdinalIgnoreCase) || cmd.Contains('/'))
            return IsResolvedProgram(cmd) ? cmd : null;
        return Sh.Which(cmd); // a bare command name: resolve it through PATH, like the shell would
    }

    private static bool IsResolvedProgram(string path) =>
        path.EndsWith(".app", StringComparison.OrdinalIgnoreCase) ? Directory.Exists(path) : File.Exists(path);
}
