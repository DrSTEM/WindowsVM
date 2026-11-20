using System;
using System.Runtime.InteropServices;

public static class D3D11Probe
{
    [DllImport("d3d11.dll", ExactSpelling = true)]
    private static extern int D3D11CreateDevice(
        IntPtr adapter, int driverType, IntPtr software, uint flags,
        uint[] featureLevels, uint levelCount, uint sdkVersion,
        out IntPtr device, out uint featureLevel, out IntPtr context);

    public static void Run()
    {
        uint[] requested = { 0xb100, 0xb000 }; // Direct3D 11.1 and 11.0
        IntPtr device;
        IntPtr context;
        uint level;
        const int hardware = 1;
        const uint sdkVersion = 7;
        int result = D3D11CreateDevice(IntPtr.Zero, hardware, IntPtr.Zero, 0,
                                       requested, (uint)requested.Length, sdkVersion,
                                       out device, out level, out context);
        try
        {
            Console.WriteLine("D3D11 hardware HRESULT: 0x{0:X8}", (uint)result);
            if (result < 0 || device == IntPtr.Zero)
                throw new InvalidOperationException("Direct3D 11 hardware device creation failed.");
            Console.WriteLine("D3D11 hardware feature level: {0}.{1}", level >> 12, (level >> 8) & 15);
        }
        finally
        {
            if (context != IntPtr.Zero) Marshal.Release(context);
            if (device != IntPtr.Zero) Marshal.Release(device);
        }
    }
}
