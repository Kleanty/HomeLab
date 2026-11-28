namespace HomeLab.Agent;

/// <summary>When the phone last talked to the agent over Wi-Fi: the panel shows "connected" while it did so in the last 5 seconds.</summary>
public static class PhoneLink
{
    public static long LastSeen;

    public static bool Connected => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - Interlocked.Read(ref LastSeen) < 5000;
}
