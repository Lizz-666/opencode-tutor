// Compiled as a Windows GUI-subsystem executable: Task Scheduler never creates a console.
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
internal static class HiddenLauncher {
    [STAThread]
    static int Main() {
        try {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(root, "prewarm.ps1");
            if (!File.Exists(script)) return 2;
            string command = "& '" + script.Replace("'", "''") + "'; exit $LASTEXITCODE";
            var psi = new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(command)),
                WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using (var child = Process.Start(psi)) { child.WaitForExit(); return child.ExitCode; }
        } catch (Exception e) {
            try { File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "launcher-error.log"), DateTime.Now.ToString("o") + " " + e.Message + Environment.NewLine); } catch {}
            return 1;
        }
    }
}
