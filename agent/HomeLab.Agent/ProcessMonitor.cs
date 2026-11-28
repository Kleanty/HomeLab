using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace HomeLab.Agent;

public sealed record ProcGroup(string Name, string Title, int Count, double Cpu, double MemMb, bool Locked, bool HasIcon);

/// <param name="Session">Claude Code session name when the instance is a Claude Code session.</param>
/// <param name="Window">Main window title, if any.</param>
/// <param name="Args">Command-line arguments (without the executable path), shortened.</param>
public sealed record ProcInstance(int Pid, double Cpu, double MemMb, long? StartedAt, string? Session, string? Window, string? Args, bool Locked);

public sealed record ProcDetail(string Name, string Title, bool Locked, IReadOnlyList<ProcInstance> Instances);

public sealed record KillResult(int Killed, int Failed, string? Error);

/// <summary>
/// Groups processes by name and measures their CPU (%) and memory use. Sampling only runs
/// while the phone is actually asking for the list, to avoid needless load.
/// </summary>
public sealed class ProcessMonitor(ILogger<ProcessMonitor> log) : BackgroundService
{
    // Processes Windows needs, or whose termination would break the user session.
    private static readonly HashSet<string> Protected = UnixProc.Protected;

    private readonly int _session = Process.GetCurrentProcess().SessionId;
    private readonly int _selfPid = Environment.ProcessId;
    private readonly int _cores = Environment.ProcessorCount;
    private readonly ConcurrentDictionary<string, (string Title, string? Path)> _meta = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, byte[]?> _icons = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<int, string?> _args = new();

    private Dictionary<int, TimeSpan> _lastCpu = [];
    private volatile Dictionary<int, double> _pidCpu = [];
    private long _lastTs;
    private volatile IReadOnlyList<ProcGroup> _groups = [];
    private long _lastRequest;

    public IReadOnlyList<ProcGroup> Snapshot()
    {
        Touch();
        return _groups;
    }

    private void Touch() => Interlocked.Exchange(ref _lastRequest, Environment.TickCount64);

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            if (Environment.TickCount64 - Interlocked.Read(ref _lastRequest) < 15_000)
            {
                try
                {
                    // On a cold start there is no previous sample to diff against: take a second one right away.
                    if (_lastTs == 0) { Sample(); await Task.Delay(700, ct); }
                    Sample();
                }
                catch (Exception ex) { log.LogDebug("process sampling: {Msg}", ex.Message); }
                await Task.Delay(2000, ct);
            }
            else
            {
                if (_lastTs != 0)
                {
                    _lastCpu = []; // idle: start fresh on the next request
                    _pidCpu = [];
                    _lastTs = 0;
                    _groups = [];
                    _args.Clear();
                }
                await Task.Delay(250, ct); // wake up quickly once requests arrive
            }
        }
    }

    /// <summary>For tests and the sampling loop. On macOS includes PID 0 (<c>kernel_task</c>); elsewhere PID 0 is skipped.</summary>
    internal void Sample()
    {
        var now = Stopwatch.GetTimestamp();
        var elapsed = _lastTs == 0 ? 0 : (now - _lastTs) / (double)Stopwatch.Frequency;
        _lastTs = now;

        var cpuNow = new Dictionary<int, TimeSpan>();
        var pidCpu = new Dictionary<int, double>();
                var acc = new Dictionary<string, (int Count, double Cpu, long Mem, bool Locked, int? Pid)>(StringComparer.OrdinalIgnoreCase);

        foreach (var p in Process.GetProcesses())
        {
            using (p)
            {
                try
                {
                    if (p.Id == 0) continue;
                    var name = p.ProcessName;
                    if (string.IsNullOrEmpty(name)) continue;

                    double cpu = 0;
                    try
                    {
                        var t = p.TotalProcessorTime;
                        cpuNow[p.Id] = t;
                        if (elapsed > 0 && _lastCpu.TryGetValue(p.Id, out var prev))
                            cpu = Math.Max(0, (t - prev).TotalSeconds / elapsed / _cores * 100);
                    }
                    catch { /* protected process: CPU time is not readable */ }
                    pidCpu[p.Id] = cpu;

                    long mem = 0;
                    try { mem = p.WorkingSet64; } catch { }

                    // Protected names stay listed but cannot be ended from the phone.
                    var locked = p.Id == 0 || p.Id == _selfPid || Protected.Contains(name) || !Mine(p);
                    acc.TryGetValue(name, out var a);
                    acc[name] = (a.Count + 1, a.Cpu + cpu, a.Mem + mem, a.Locked || locked, a.Pid ?? p.Id);
                }
                catch { }
            }
        }
        _lastCpu = cpuNow;
        _pidCpu = pidCpu;

        _groups = acc
            .Select(kv =>
            {
                if (!_meta.TryGetValue(kv.Key, out var meta) || meta.Path is null)
                {
                    meta = ReadMeta(kv.Value.Pid ?? 0, kv.Key);
                    if (meta.Path is not null) _meta[kv.Key] = meta;
                }
                return new ProcGroup(kv.Key, meta.Title, kv.Value.Count, Math.Round(kv.Value.Cpu, 1),
                    Math.Round(kv.Value.Mem / 1048576.0), kv.Value.Locked, meta.Path is not null);
            })
            .OrderByDescending(g => g.Cpu)
            .ThenByDescending(g => g.MemMb)
            .ToList();
    }

    private static IEnumerable<Process> ProcessesNamed(string name) => Process.GetProcessesByName(name);

    /// <summary>Every instance of a process name, with what identifies each one.</summary>
    public ProcDetail Detail(string name)
    {
        Touch();
        var cpu = _pidCpu;
        var list = new List<ProcInstance>();
        foreach (var p in ProcessesNamed(name))
        {
            using (p)
            {
                try
                {
                    long mem = 0;
                    try { mem = p.WorkingSet64; } catch { }
                    long? started = null;
                    try { started = new DateTimeOffset(p.StartTime).ToUnixTimeMilliseconds(); } catch { }
                    string? window = null;
                    try { window = string.IsNullOrWhiteSpace(p.MainWindowTitle) ? null : p.MainWindowTitle; } catch { }
                    var locked = p.Id == 0 || p.Id == _selfPid || Protected.Contains(name) || !Mine(p);
                    list.Add(new ProcInstance(p.Id, Math.Round(cpu.GetValueOrDefault(p.Id), 1), Math.Round(mem / 1048576.0),
                        started, null, window, _args.GetOrAdd(p.Id, ReadArgs), locked));
                }
                catch { }
            }
        }
        if ((!_meta.TryGetValue(name, out var meta) || meta.Path is null) && list.Count > 0)
        {
            meta = ReadMeta(list[0].Pid, name);
            if (meta.Path is not null) _meta[name] = meta;
        }
        else if (!_meta.TryGetValue(name, out meta)) meta = (name, null);
        var groupLocked = Protected.Contains(name) || (list.Count > 0 && list.All(i => i.Locked));
        return new ProcDetail(name, meta.Title, groupLocked,
            list.OrderByDescending(i => i.Cpu).ThenByDescending(i => i.MemMb).ToList());
    }

    /// <summary>Terminates every unprotected process with this name in the current user session.</summary>
    public KillResult Kill(string name)
    {
        if (string.IsNullOrWhiteSpace(name)) return new(0, 0, "no name given");
        if (Protected.Contains(name)) return new(0, 0, $"{name} is protected and cannot be terminated");

        int killed = 0, failed = 0;
        // Same recovered-name match as the process list / Detail, so every listed instance is considered.
        foreach (var p in ProcessesNamed(name))
        {
            using (p)
            {
                var resolved = p.ProcessName;
                // Check the resolved process name (not the request spelling) so case variants cannot bypass Protected.
                if (p.Id == 0 || p.Id == _selfPid || Protected.Contains(resolved) || !Mine(p)) { failed++; continue; }
                try { p.Kill(); killed++; }
                catch { failed++; }
            }
        }
        log.LogInformation("terminated all {Name}: {Killed} ok, {Failed} failed", name, killed, failed);
        if (killed == 0 && failed == 0) return new(0, 0, "process not found");
        return new(killed, failed, killed == 0 ? "access denied (it may be running as administrator)" : null);
    }

    /// <summary>
    /// Terminates a single process together with its child processes. Every descendant passes the same checks as the
    /// process itself (protected names, other sessions or users, the agent): those are left running. Process.Kill's
    /// own tree mode checks none of that, so it would end, say, a protected dotnet or adb started from a terminal.
    /// </summary>
    public KillResult KillPid(int pid)
    {
        if (pid == 0) return new(0, 0, "PID 0 is protected and cannot be terminated");
        if (pid == _selfPid) return new(0, 0, "that is the HomeLab agent itself");
        Process p;
        try { p = Process.GetProcessById(pid); }
        catch { return new(0, 0, "process not found"); }
        using (p)
        {
            var name = p.ProcessName;
            if (Protected.Contains(name)) return new(0, 0, $"{name} is protected and cannot be terminated");
            if (!Mine(p)) return new(0, 0, "process belongs to another session or user");
            var descendants = Descendants(pid);
            try { p.Kill(); }
            catch (Exception ex) { return new(0, 1, "could not terminate: " + ex.Message); }
            int killed = 1, skipped = 0;
            foreach (var d in descendants)
            {
                try
                {
                    using var c = Process.GetProcessById(d);
                    var childName = c.ProcessName;
                    if (d == _selfPid || Protected.Contains(childName) || !Mine(c)) { skipped++; continue; }
                    c.Kill();
                    killed++;
                }
                catch (ArgumentException) { } // already gone
                catch { skipped++; }
            }
            log.LogInformation("terminated {Name} (pid {Pid}) and {Children} child processes ({Skipped} left running)", name, pid, killed - 1, skipped);
            return new(killed, skipped, null);
        }
    }

    /// <summary>
    /// Every process below <paramref name="root"/>. A child counts only if it started after its parent, so a parent
    /// PID that Windows or Unix has since given to an unrelated process does not pull that process in.
    /// </summary>
    public static List<int> Descendants(int root)
    {
        var started = new Dictionary<int, DateTime>();
        var children = new Dictionary<int, List<int>>();
        foreach (var p in Process.GetProcesses())
        {
            using (p)
            {
                try { started[p.Id] = p.StartTime; } catch { continue; } // not readable: not ours to end anyway
                if (ParentPid(p.Id) is { } parent && parent != p.Id)
                    (children.TryGetValue(parent, out var list) ? list : children[parent] = []).Add(p.Id);
            }
        }
        var result = new List<int>();
        var seen = new HashSet<int> { root };
        var queue = new Queue<int>([root]);
        while (queue.Count > 0)
        {
            var parent = queue.Dequeue();
            if (!children.TryGetValue(parent, out var kids) || !started.TryGetValue(parent, out var parentStart)) continue;
            foreach (var kid in kids)
                if (started[kid] >= parentStart && seen.Add(kid)) { result.Add(kid); queue.Enqueue(kid); }
        }
        return result;
    }

    /// <summary>Windows: same logon session as the agent. Linux / macOS: same user.</summary>
    private bool Mine(Process p)
    {
        return UnixProc.IsOwn(p.Id);
    }

    public byte[]? Icon(string name)
    {
        if (_icons.TryGetValue(name, out var cached) && cached is not null) return cached;
        if (!_meta.TryGetValue(name, out var meta) || meta.Path is null)
        {
            foreach (var p in Process.GetProcessesByName(name))
            {
                using (p)
                {
                    if (meta.Path is null)
                    {
                        try { meta = ReadMeta(p.Id, name); } catch { }
                        if (meta.Path is not null) _meta[name] = meta;
                    }
                }
            }
        }
        byte[]? png = null;
        png = UnixProc.Icon(name, meta.Path);
        if (png is not null) _icons[name] = png;
        return png;
    }

    private static (string Title, string? Path) ReadMeta(int pid, string name)
    {
        string? upath = null;
        try { using var up = Process.GetProcessById(pid); upath = UnixProc.ImagePath(up); } catch { }
        return (UnixProc.Title(name, upath), upath);
    }

    internal static string? ShortenArgs(string? cmd)
    {
        if (string.IsNullOrWhiteSpace(cmd)) return null;
        cmd = cmd.Trim();
        // drop the executable (quoted or not)
        var rest = cmd.StartsWith('"') ? cmd[(cmd.IndexOf('"', 1) is var q && q > 0 ? q + 1 : cmd.Length)..]
                                      : cmd[(cmd.IndexOfAny([' ', '\t']) is var s && s > 0 ? s : cmd.Length)..];
        rest = rest.Trim();
        if (rest.Length == 0) return null;
        return rest.Length > 140 ? rest[..137] + "…" : rest;
    }

    private static string? ReadArgs(int pid) => UnixProc.Args(pid);
    private static int? ParentPid(int pid) => UnixProc.ParentPid(pid);
}
