using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class VeloxLauncher
{
    [STAThread]
    static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "VeloxTweaks.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("VeloxTweaks.ps1 est introuvable.\n\nGarde « Velox Tweaks.exe » dans le même dossier que VeloxTweaks.ps1.",
                "Velox Tweaks", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        var psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + script + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        try { Process.Start(psi); }
        catch (Exception e)
        {
            MessageBox.Show("Impossible de lancer Velox Tweaks :\n\n" + e.Message, "Velox Tweaks", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
