namespace HomeLab.Agent;

/// <param name="Mic">Whether an app is using a microphone; null where this cannot be detected.</param>
public sealed record PrivacySnapshot(bool? Mic, bool? Camera, IReadOnlyList<string> MicApps, IReadOnlyList<string> CameraApps);

/// <summary>
/// Is the microphone or the camera in use, and by which app? For the "On air" widget and rules.
/// ALSA capture streams that are running, and processes with a /dev/video* device open.
/// </summary>
public sealed class PrivacyMonitor(ILogger<PrivacyMonitor> log) : BackgroundService
{
    private volatile PrivacySnapshot? _snap;

    public PrivacySnapshot? Snapshot() => _snap;

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        string? lastLog = null;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var (mic, cam) = Read();
                _snap = new(mic.Count > 0, cam.Count > 0, mic, cam);
                var line = $"mic: {(mic.Count > 0 ? string.Join(", ", mic) : "off")}, camera: {(cam.Count > 0 ? string.Join(", ", cam) : "off")}";
                if (line != lastLog) { if (lastLog is not null) log.LogInformation("{State}", line); lastLog = line; }
            }
            catch (Exception ex) { log.LogDebug("privacy: {Msg}", ex.Message); }
            await Task.Delay(2000, ct);
        }
    }

    private static (List<string> Mic, List<string> Camera) Read() => (LinuxMic(), LinuxCamera());

    /// <summary>Running ALSA capture substreams (PipeWire / PulseAudio open them while something records).</summary>
    private static List<string> LinuxMic()
    {
        var apps = new List<string>();
        if (!Directory.Exists("/proc/asound")) return apps;
        foreach (var status in Directory.EnumerateFiles("/proc/asound", "status", SearchOption.AllDirectories))
        {
            if (!status.Contains("c/sub")) continue; // pcmNc = capture
            var text = Sh.ReadFile(status);
            if (text is null || !text.Contains("state: RUNNING")) continue;
            var pid = text.Split('\n').FirstOrDefault(l => l.StartsWith("owner_pid"))?.Split(':').LastOrDefault()?.Trim();
            apps.Add(pid is not null && Sh.ReadFile($"/proc/{pid}/comm")?.Trim() is { Length: > 0 } comm ? comm : "microphone");
        }
        return apps.Distinct().ToList();
    }

    /// <summary>Processes (of this user) with a video device open.</summary>
    private static List<string> LinuxCamera()
    {
        var apps = new List<string>();
        if (!Directory.EnumerateFiles("/dev", "video*").Any()) return apps;
        foreach (var proc in Directory.EnumerateDirectories("/proc"))
        {
            var pid = Path.GetFileName(proc);
            if (!pid.All(char.IsDigit)) continue;
            try
            {
                foreach (var fd in Directory.EnumerateFiles(Path.Combine(proc, "fd")))
                {
                    if (new FileInfo(fd).LinkTarget?.StartsWith("/dev/video") != true) continue;
                    apps.Add(Sh.ReadFile(Path.Combine(proc, "comm"))?.Trim() ?? pid);
                    break;
                }
            }
            catch { /* another user's process */ }
        }
        return apps.Distinct().ToList();
    }
}
