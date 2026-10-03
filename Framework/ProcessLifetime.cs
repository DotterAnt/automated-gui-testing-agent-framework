using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

public static class AGTAProcessLifetime {
    // Forward raw protocol bytes on a native thread, never through PowerShell
    // pipelines or host prompts. Closing input signals EOF to the child.
    public static void Relay(Stream input,Stream output,bool closeOutput) {
        var thread=new Thread(delegate() {
            try {
                var buffer=new byte[8192];int count;
                while ((count=input.Read(buffer,0,buffer.Length))>0) {
                    output.Write(buffer,0,count);output.Flush();
                }
            } catch (IOException) {
            } catch (ObjectDisposedException) {
            } finally {
                if (closeOutput) {try {output.Dispose();} catch {}}
            }
        });
        thread.IsBackground=true;
        thread.Start();
    }
    // A native thread still runs while PowerShell/UIA is blocked. Match the
    // original process lifetime so PID reuse cannot leave an orphan worker.
    public static void WatchParent(int id) {
        var parent=Process.GetProcessById(id);
        long started=parent.StartTime.ToUniversalTime().Ticks;
        var thread=new Thread(delegate() {
            while (true) {
                try {
                    if (parent.HasExited || parent.StartTime.ToUniversalTime().Ticks!=started)
                        Environment.Exit(0);
                } catch { Environment.Exit(0); }
                Thread.Sleep(250);
            }
        });
        thread.IsBackground=true;
        thread.Start();
    }
}
