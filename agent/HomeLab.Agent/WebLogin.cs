using Microsoft.AspNetCore.Http;
using System.Security.Cryptography;
using System.Text;

namespace HomeLab.Agent;

/// <summary>
/// Optional login (HTTP Basic) for the settings page on the local port. The install script writes the file
/// <c>web-login</c> next to the config: <c>v1 userB64 iterations saltB64 hashB64</c> (PBKDF2-SHA256, 32 bytes).
/// No file = no login (as before). A file that cannot be read locks the page, so a broken file never opens it.
/// Scripts on this computer that push alerts stay open (this port is loopback only).
/// </summary>
public static class WebLogin
{
    static readonly string[] OpenPaths = ["/api/info", "/api/notify", "/api/push"];

    static string? cachedFile;
    static DateTime cachedStamp;
    static (byte[] User, byte[] Salt, byte[] Hash, int Iterations)? cached;
    static byte[]? okKey;
    static DateTime okStamp;
    static readonly object Gate = new();

    /// <summary>True when the request may continue; false means answer 401 with a Basic challenge.</summary>
    public static bool Allows(PathString path, string authorization, string configDir)
    {
        foreach (var open in OpenPaths)
            if (path.StartsWithSegments(open)) return true;

        var file = Path.Combine(configDir, "web-login");
        if (!File.Exists(file)) return true;
        var cred = Load(file);
        if (cred is null) return false;

        if (!authorization.StartsWith("Basic ", StringComparison.OrdinalIgnoreCase)) return false;
        string raw;
        try { raw = Encoding.UTF8.GetString(Convert.FromBase64String(authorization[6..].Trim())); }
        catch (FormatException) { return false; }
        var colon = raw.IndexOf(':');
        if (colon < 0) return false;

        // The page makes many requests; the slow hash is checked once per login and the answer is remembered
        // (until the login file changes), compared in constant time.
        var key = SHA256.HashData(Encoding.UTF8.GetBytes(authorization));
        var stamp = File.GetLastWriteTimeUtc(file);
        lock (Gate)
            if (okKey is not null && okStamp == stamp && CryptographicOperations.FixedTimeEquals(okKey, key)) return true;

        var c = cred.Value;
        var userHash = SHA256.HashData(Encoding.UTF8.GetBytes(raw[..colon]));
        var userOk = CryptographicOperations.FixedTimeEquals(userHash, SHA256.HashData(c.User));
        var hash = Rfc2898DeriveBytes.Pbkdf2(raw[(colon + 1)..], c.Salt, c.Iterations, HashAlgorithmName.SHA256, c.Hash.Length);
        var passOk = CryptographicOperations.FixedTimeEquals(hash, c.Hash);
        if (!(userOk && passOk)) return false;
        lock (Gate) { okKey = key; okStamp = stamp; }
        return true;
    }

    static (byte[] User, byte[] Salt, byte[] Hash, int Iterations)? Load(string file)
    {
        lock (Gate)
        {
            var stamp = File.GetLastWriteTimeUtc(file);
            if (cachedFile == file && cachedStamp == stamp) return cached;
            cachedFile = file;
            cachedStamp = stamp;
            cached = null;
            try
            {
                var parts = File.ReadAllText(file).Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length == 5 && parts[0] == "v1" && int.TryParse(parts[2], out var iterations) && iterations is >= 10_000 and <= 5_000_000)
                {
                    var hash = Convert.FromBase64String(parts[4]);
                    if (hash.Length >= 16)
                        cached = (Convert.FromBase64String(parts[1]), Convert.FromBase64String(parts[3]), hash, iterations);
                }
            }
            catch (Exception e) when (e is IOException or FormatException or UnauthorizedAccessException) { cached = null; }
            return cached;
        }
    }
}
