// COM class factory that hands the widget host an IWidgetProvider (boilerplate from Microsoft's
// widget provider walkthrough).
using System.Runtime.InteropServices;
using Microsoft.Windows.Widgets.Providers;
using WinRT;

namespace COM;

internal static class Guids
{
    public const string IClassFactory = "00000001-0000-0000-C000-000000000046";
    public const string IUnknown = "00000000-0000-0000-C000-000000000046";
    public const string IInspectable = "AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90";
    public const string IAgileObject = "94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90";
}

[ComImport, ComVisible(false), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid(Guids.IClassFactory)]
internal interface IClassFactory
{
    [PreserveSig]
    int CreateInstance(IntPtr pUnkOuter, ref Guid riid, out IntPtr ppvObject);

    [PreserveSig]
    int LockServer(bool fLock);
}

[ComVisible(true)]
internal sealed class WidgetProviderFactory<T> : IClassFactory
    where T : IWidgetProvider, new()
{
    private const int CLASS_E_NOAGGREGATION = unchecked((int)0x80040110);
    private const int E_NOINTERFACE = unchecked((int)0x80004002);

    public int CreateInstance(IntPtr pUnkOuter, ref Guid riid, out IntPtr ppvObject)
    {
        ppvObject = IntPtr.Zero;
        if (pUnkOuter != IntPtr.Zero) { return CLASS_E_NOAGGREGATION; }

        if (riid == typeof(T).GUID
            || riid == typeof(IWidgetProvider).GUID
            || riid == Guid.Parse(Guids.IUnknown)
            || riid == Guid.Parse(Guids.IInspectable)
            || riid == Guid.Parse(Guids.IAgileObject))
        {
            ppvObject = MarshalInspectable<IWidgetProvider>.FromManaged(new T());
            return 0;
        }
        return E_NOINTERFACE;
    }

    public int LockServer(bool fLock) => 0;
}
