using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace HomeLab.Agent;

/// <summary>
/// The TCP ports one process listens on that are reachable through 127.0.0.1 (or ::1). Used to find local servers that
/// pick their port at run time and don't print it on their command line. Every failure yields an empty list.
/// </summary>
internal static class ListeningPorts
{
    /// <summary>Default number of ports returned, so a busy process can't use up a caller's time budget.</summary>
    internal const int DefaultMax = 8;

    /// <summary>
    /// A listening port and the loopback address to reach it on: 127.0.0.1 for an IPv4 listener, ::1 for an IPv6 one.
    /// An IPv6 socket may refuse IPv4 (on Windows it does by default), so the family the process chose is kept.
    /// </summary>
    internal readonly record struct Listener(IPAddress Address, int Port);

    /// <summary>
    /// Lists the loopback (or all-interfaces) TCP listening ports of <paramref name="pid"/>, lowest first; a port open on
    /// both families is listed twice, IPv4 first, since the two sockets can be different servers.
    /// </summary>
    public static IReadOnlyList<Listener> ForProcess(int pid, int max = DefaultMax)
    {
        if (pid <= 0 || max <= 0) return [];
        try
        {
            IEnumerable<Listener> found = Linux(pid);
            // two sockets on one port (127.0.0.1 and [::1]) are different servers, so both stay
            return found.OrderBy(l => l.Port).ThenBy(l => l.Address.AddressFamily == AddressFamily.InterNetworkV6)
                .Distinct().Take(max).ToArray();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return [];
        }
    }

    /// <summary>An IPv4-mapped IPv6 address (::ffff:127.0.0.2) as the IPv4 address it stands for.</summary>
    private static IPAddress Plain(IPAddress address) => address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;

    /// <summary>Whether a listener on this local address answers connections to the loopback address of its family.</summary>
    internal static bool ReachableOnLoopback(IPAddress address)
    {
        address = Plain(address);
        return IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any);
    }

    /// <summary>
    /// Where to reach a listener: its own address when it is bound to a loopback address (127.0.0.2 is one too), the
    /// loopback address of its family when it is bound to every interface.
    /// </summary>
    internal static IPAddress LoopbackFor(IPAddress listener)
    {
        listener = Plain(listener);
        return IPAddress.IsLoopback(listener) ? listener
            : listener.AddressFamily == AddressFamily.InterNetworkV6 ? IPAddress.IPv6Loopback : IPAddress.Loopback;
    }

    /// <summary>The address as a URL host: IPv6 in brackets.</summary>
    internal static string UrlHost(IPAddress address) =>
        address.AddressFamily == AddressFamily.InterNetworkV6 ? $"[{address}]" : address.ToString();

    private static IEnumerable<Listener> Linux(int pid)
    {
        var inodes = new HashSet<string>(StringComparer.Ordinal);
        foreach (var fd in Directory.EnumerateFileSystemEntries($"/proc/{pid}/fd"))
        {
            string? target;
            try { target = new FileInfo(fd).LinkTarget; }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
            if (target is not null && target.StartsWith("socket:[", StringComparison.Ordinal) && target.EndsWith(']'))
                inodes.Add(target["socket:[".Length..^1]);
        }
        if (inodes.Count == 0) return [];
        var ports = new List<Listener>();
        foreach (var file in new[] { "/proc/net/tcp", "/proc/net/tcp6" })
        {
            string text;
            try { text = File.ReadAllText(file); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
            ports.AddRange(ParseProcNetTcp(text, inodes));
        }
        return ports;
    }

    /// <summary>
    /// Reads <c>/proc/net/tcp</c> or <c>tcp6</c> text: listening rows (state <c>0A</c>) owned by one of the socket inodes,
    /// on a loopback or all-interfaces address. Addresses are hex 32-bit words in host (little-endian) order.
    /// </summary>
    internal static List<Listener> ParseProcNetTcp(string text, IReadOnlySet<string> inodes)
    {
        var ports = new List<Listener>();
        foreach (var line in text.Split('\n'))
        {
            var cols = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (cols.Length < 10 || !cols[0].EndsWith(':')) continue; // the header row and torn lines
            if (cols[3] != "0A" || !inodes.Contains(cols[9])) continue;
            var local = cols[1].Split(':');
            if (local.Length != 2 || ProcAddress(local[0]) is not { } address || !ReachableOnLoopback(address)) continue;
            if (int.TryParse(local[1], NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var port)
                && port is > 0 and <= 65535)
                ports.Add(new Listener(LoopbackFor(address), port));
        }
        return ports;
    }

    private static IPAddress? ProcAddress(string hex)
    {
        if (hex.Length is not (8 or 32)) return null;
        var bytes = new byte[hex.Length / 2];
        for (var word = 0; word < hex.Length / 8; word++)
        for (var b = 0; b < 4; b++)
        {
            // Each 32-bit word is printed as a number, so its bytes appear in reverse memory order.
            if (!byte.TryParse(hex.AsSpan(word * 8 + (3 - b) * 2, 2), NumberStyles.AllowHexSpecifier,
                    CultureInfo.InvariantCulture, out var value)) return null;
            bytes[word * 4 + b] = value;
        }
        return new IPAddress(bytes);
    }

}
