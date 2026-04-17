using System;
using System.Diagnostics;
using System.IO;

namespace DiktaWindows.Services
{
    /// <summary>
    /// Rolling file logger for diagnostics. All public methods are gated by the DIAGNOSTICS
    /// compilation symbol — in builds without it, every call compiles to a no-op.
    /// Log files are written to %APPDATA%\Dikta\logs\dikta-0.log and rotated at 1 MB,
    /// keeping a maximum of 5 files (dikta-0.log … dikta-4.log).
    /// </summary>
    public static class DiagnosticLogger
    {
        private static readonly object _lock = new();

        private static readonly string _logDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Dikta",
            "logs");

        private const long MaxBytes = 1_048_576; // 1 MB
        private const int MaxFiles = 5;

        // ── Public API ────────────────────────────────────────────────────────

        [Conditional("DIAGNOSTICS")]
        public static void Info(string message) => Append("INFO", message);

        [Conditional("DIAGNOSTICS")]
        public static void Warning(string message) => Append("WARNING", message);

        [Conditional("DIAGNOSTICS")]
        public static void Error(string message) => Append("ERROR", message);

        [Conditional("DIAGNOSTICS")]
        public static void Exception(string context, Exception ex)
        {
            var text = $"{context} | {ex.GetType().FullName}: {ex.Message}{Environment.NewLine}{ex.StackTrace}";
            Append("ERROR", text);
        }

        // ── Private helpers ───────────────────────────────────────────────────

        private static void Append(string level, string message)
        {
            lock (_lock)
            {
                try
                {
                    Directory.CreateDirectory(_logDir);

                    string path = Path.Combine(_logDir, "dikta-0.log");

                    if (File.Exists(path) && new FileInfo(path).Length >= MaxBytes)
                    {
                        RotateFiles();
                    }

                    File.AppendAllText(path, $"{DateTime.UtcNow:O} {level} {message}\n");
                }
                catch
                {
                    // Log failures are best-effort — never throw.
                }
            }
        }

        private static void RotateFiles()
        {
            // Walk from the oldest slot downward so we never clobber a file
            // before it has been moved.
            for (int i = MaxFiles - 1; i >= 0; i--)
            {
                string src = Path.Combine(_logDir, $"dikta-{i}.log");
                string dst = Path.Combine(_logDir, $"dikta-{i + 1}.log");

                // Drop the destination if it would exceed the maximum slot.
                if (i + 1 >= MaxFiles && File.Exists(dst))
                {
                    File.Delete(dst);
                }

                if (File.Exists(src))
                {
                    File.Move(src, dst, overwrite: true);
                }
            }
            // After rotation dikta-0.log no longer exists; the next Append creates it fresh.
        }
    }
}
