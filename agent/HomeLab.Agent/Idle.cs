using System.Runtime.InteropServices;

namespace HomeLab.Agent;

/// <summary>How long the PC's user has not touched the keyboard or mouse.</summary>
public static class Idle
{
    public static double Seconds()
    {
        // X11 only (xprintidle); on Wayland this reports 0, i.e. "at the PC"
        return double.TryParse(Sh.Run("xprintidle")?.Trim(), out var ms) ? ms / 1000 : 0;
    }

}
