using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows;

internal static class Launcher
{
    [STAThread]
    private static int Main(string[] args)
    {
        bool smokeTest = Array.Exists(args, a => a == "--smoke-test");
        try
        {
            AppContext.SetSwitch("Switch.System.Windows.DoNotScaleForDpiChanges", false);
            AppContext.SetSwitch("Switch.System.Windows.DoNotUsePresentationDpiCapabilityTier2OrGreater", false);
            string directory = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(directory, "Switcher.ps1");
            if (!File.Exists(script))
                throw new FileNotFoundException("Switcher.ps1 was not found. Keep the whole application folder together.");
            Directory.SetCurrentDirectory(directory);
            // Match the previous launcher's process-only execution policy.
            Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass", EnvironmentVariableTarget.Process);
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell powershell = PowerShell.Create())
                {
                    powershell.Runspace = runspace;
                    // Keep WPF in this manifest-declared DPI-aware process.
                    powershell.AddCommand(script);
                    if (smokeTest) powershell.AddParameter("SmokeTest");
                    foreach (PSObject result in powershell.Invoke()) Console.WriteLine(result.ToString());
                    if (powershell.HadErrors) throw new InvalidOperationException(powershell.Streams.Error[0].ToString());
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            if (smokeTest) Console.Error.WriteLine(error.Message);
            else MessageBox.Show(error.Message, "Codex 配置切换", MessageBoxButton.OK, MessageBoxImage.Error);
            return 1;
        }
    }
}
