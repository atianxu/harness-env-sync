using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

// 启动器：不落地控制台黑窗，只把 GUI（PowerShell + WinForms）拉起来。
// 脚本路径相对于本 exe 所在目录，因此整个 tools\env-sync 文件夹可原样搬到别的机器。
public class EnvSyncLauncher
{
    public static void Main(string[] args)
    {
        string dir = Path.GetDirectoryName(Application.ExecutablePath);
        string script = Path.Combine(dir, "EnvSyncConsole.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("找不到 EnvSyncConsole.ps1，请保持它与本程序在同一目录。\r\n" + script,
                "Harness 环境同步", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(ps))
        {
            ps = "powershell.exe";
        }

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = ps;
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
        psi.WorkingDirectory = dir;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        try
        {
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show("启动失败：" + ex.Message, "Harness 环境同步", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
