using System;
using System.Runtime.InteropServices;

// Windows ARM64/AnyCPU helper for the supported Windows display-mode APIs.
// It changes only resolution, after first asking the driver to validate it.
public static class VMDisplay
{
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode, Size = 220)]
    private struct Mode
    {
        [FieldOffset(68)] public ushort Size;
        [FieldOffset(72)] public uint Fields;
        [FieldOffset(168)] public uint BitsPerPixel;
        [FieldOffset(172)] public uint Width;
        [FieldOffset(176)] public uint Height;
        [FieldOffset(184)] public uint Frequency;
    }
    [DllImport("user32.dll", EntryPoint = "EnumDisplaySettingsW", CharSet = CharSet.Unicode)]
    private static extern bool Enumerate(string device, int index, ref Mode mode);
    [DllImport("user32.dll", EntryPoint = "ChangeDisplaySettingsW", CharSet = CharSet.Unicode)]
    private static extern int Change(ref Mode mode, uint flags);

    public static void List()
    {
        Mode mode = new Mode(); mode.Size = 220;
        for (int index = 0; Enumerate(null, index, ref mode); index++)
            Console.WriteLine("{0} x {1}, {2} bit, {3} Hz", mode.Width, mode.Height, mode.BitsPerPixel, mode.Frequency);
    }
    public static void MatchMac(int width, int height)
    {
        if (width < 800 || width > 7680 || height < 600 || height > 4320)
            throw new ArgumentOutOfRangeException("resolution");
        Mode mode = new Mode(); mode.Size = 220;
        if (!Enumerate(null, -1, ref mode)) throw new InvalidOperationException("Cannot read the active Windows display mode.");
        Console.WriteLine("Before: {0} x {1}", mode.Width, mode.Height);
        mode.Width = (uint)width; mode.Height = (uint)height;
        mode.Fields = 0x180000; // DM_PELSWIDTH | DM_PELSHEIGHT
        int result = Change(ref mode, 2); // CDS_TEST: no change on unsupported modes
        if (result != 0) throw new InvalidOperationException("The display driver rejected this resolution (" + result + "). Use VMDisplay.List() to inspect supported modes.");
        result = Change(ref mode, 1); // CDS_UPDATEREGISTRY
        if (result != 0) throw new InvalidOperationException("Windows could not apply the resolution (" + result + ").");
        mode.Size = 220;
        if (!Enumerate(null, -1, ref mode) || mode.Width != width || mode.Height != height)
            throw new InvalidOperationException("The requested resolution is not active.");
        Console.WriteLine("Verified active mode: {0} x {1}", mode.Width, mode.Height);
    }
}
