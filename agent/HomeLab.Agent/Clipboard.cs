using System.Diagnostics;
using System.Text;

namespace HomeLab.Agent;

/// <summary>
/// The computer's text clipboard, for macro steps (<c>clipboard:</c>, <c>paste:</c>) and the <c>{clipboard}</c> placeholder.
/// The text stays in the agent: it is never sent to the phone, logged or kept.
///  - wl-copy / wl-paste (Wayland), or xclip / xsel (X11).
/// </summary>
public static class Clipboard
{
    internal interface IBackend
    {
        string? Get();
        void Set(string text, bool sensitive);
    }

    /// <summary>Tests swap the clipboard for one in memory, so they never touch (or depend on) the machine's own.</summary>
    internal static IBackend? TestBackend;

    /// <summary>The text on the clipboard; empty when it holds something else (a picture, files) or nothing.</summary>
    public static string GetText() => (TestBackend is { } t ? t.Get() : Read()) ?? "";

    /// <summary>
    /// Replaces what is on the clipboard with the text. Throws when no clipboard tool is available. With
    /// <paramref name="sensitive"/> (a token, an address typed by a paste: step) Windows is told to keep it out of its
    /// clipboard history, the cloud clipboard and clipboard managers; elsewhere there is no such flag to set.
    /// </summary>
    public static void SetText(string text, bool sensitive = false)
    {
        if (TestBackend is { } t) t.Set(text, sensitive);
        else Write(text, sensitive);
    }

    private static bool Wayland => Environment.GetEnvironmentVariable("WAYLAND_DISPLAY") is { Length: > 0 };

    private const string Missing = "the clipboard needs wl-clipboard (Wayland) or xclip / xsel (X11)";

    private static string? Read()
    {
        // xclip, xsel and wl-paste exit non-zero when the clipboard holds nothing as text (an empty clipboard, a picture),
        // which cannot be told apart from a failure here; that is "no text".
        if (Wayland && Sh.Which("wl-paste") is not null) return Sh.Run("wl-paste", "--no-newline") ?? "";
        if (Sh.Which("xclip") is not null) return Sh.Run("xclip", "-selection", "clipboard", "-out") ?? "";
        if (Sh.Which("xsel") is not null) return Sh.Run("xsel", "--clipboard", "--output") ?? "";
        if (Sh.Which("wl-paste") is not null) return Sh.Run("wl-paste", "--no-newline") ?? "";
        throw new InvalidOperationException(Missing);
    }

    private static void Write(string text, bool sensitive)
    {
        if (Wayland && Sh.Which("wl-copy") is not null) Pipe("wl-copy", text);
        else if (Sh.Which("xclip") is not null) Pipe("xclip", text, "-selection", "clipboard", "-in");
        else if (Sh.Which("xsel") is not null) Pipe("xsel", text, "--clipboard", "--input");
        else if (Sh.Which("wl-copy") is not null) Pipe("wl-copy", text);
        else throw new InvalidOperationException(Missing);
    }

    /// <summary>
    /// Feeds the text to a tool's standard input. Its output is not captured: xclip and wl-copy stay running in the
    /// background to serve the clipboard, and would keep a captured pipe open until the timeout.
    /// </summary>
    private static void Pipe(string tool, string text, params string[] args)
    {
        var psi = new ProcessStartInfo(Sh.Which(tool) ?? throw new InvalidOperationException(Missing))
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            StandardInputEncoding = new UTF8Encoding(false), WorkingDirectory = AppPaths.NeutralCwd,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var process = Process.Start(psi) ?? throw new IOException("Could not start " + tool);
        // the write has the same deadline as the tool: one that stops reading would block it once the pipe is full
        var feed = Task.Run(() =>
        {
            try
            {
                process.StandardInput.Write(text);
                process.StandardInput.Close();
            }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException or InvalidOperationException) { /* the tool quit early (or was killed); its exit code says why */ }
        });
        var deadline = DateTime.UtcNow.AddSeconds(3);
        if (!feed.Wait(TimeSpan.FromSeconds(3)) || !process.WaitForExit(Math.Max(1, (int)(deadline - DateTime.UtcNow).TotalMilliseconds)))
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw new TimeoutException(tool + " did not finish");
        }
        if (process.ExitCode != 0) throw new InvalidOperationException(tool + " failed");
    }
}
