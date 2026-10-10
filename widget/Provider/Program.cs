using System.Runtime.InteropServices;
using ClaudeLockWidget.Provider;
using COM;

// Windows starts this executable with -RegisterProcessAsComServer (see AppxManifest.xml) when a
// widget from this package needs a provider. Started any other way it just explains itself.
internal static class Program
{
    [DllImport("ole32.dll")]
    private static extern int CoRegisterClassObject(
        [MarshalAs(UnmanagedType.LPStruct)] Guid rclsid,
        [MarshalAs(UnmanagedType.IUnknown)] object pUnk,
        uint dwClsContext,
        uint flags,
        out uint lpdwRegister);

    [DllImport("ole32.dll")]
    private static extern int CoRevokeClassObject(uint dwRegister);

    private const uint CLSCTX_LOCAL_SERVER = 0x4;
    private const uint REGCLS_MULTIPLEUSE = 0x1;

    private static int Main(string[] args)
    {
        if (args.Length == 0 || !args[0].Equals("-RegisterProcessAsComServer", StringComparison.OrdinalIgnoreCase))
        {
            // WinExe has no console; nothing to print. Just exit quietly when double-clicked.
            return 1;
        }

        try
        {
            WinRT.ComWrappersSupport.InitializeComWrappers();
            Log.Info("Registering widget provider COM class");

            var hr = CoRegisterClassObject(WidgetProvider.ClsId, new WidgetProviderFactory<WidgetProvider>(),
                CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE, out var cookie);
            if (hr != 0)
            {
                Log.Error($"CoRegisterClassObject failed: 0x{hr:X8}");
                return hr;
            }

            WidgetProvider.RunUntilNoWidgets();

            CoRevokeClassObject(cookie);
            Log.Info("No widgets left; provider exiting");
            return 0;
        }
        catch (Exception ex)
        {
            Log.Error("Provider crashed", ex);
            return 2;
        }
    }
}
