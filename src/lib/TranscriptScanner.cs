// ClaudeLockWidget - TranscriptScanner
//
// Aggregates Claude Code transcript files (~/.claude/projects/**/*.jsonl) into daily buckets,
// replicating how Claude Code's own /stats screen counts things:
//   * a "session" is one transcript file
//   * a "message" is one user or assistant transcript line
//   * tokens are input + output + cache-creation + cache-read of every assistant line
//
// This file is deliberately C# 5 (no string interpolation, no ?. operator, ...) because it is
// compiled at runtime by Add-Type on Windows PowerShell 5.1, which ships with every Windows
// 10/11 install. No SDK or extra runtime is needed.
//
// Per-file results are cached (keyed by path + length + mtime) so a refresh only re-reads
// transcripts that changed since the previous run.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace ClaudeLockWidget
{
    public static class TranscriptScanner
    {
        private const int CacheVersion = 1;

        private sealed class DayAgg
        {
            public long Messages;
            public long Tokens;
            public readonly Dictionary<string, long> Models = new Dictionary<string, long>();
        }

        private sealed class FileAgg
        {
            public long Length;
            public long MTimeTicks;
            public string StartDay;   // local yyyy-MM-dd of the first message, or null
            public int StartHour;     // local hour of the first message
            public readonly Dictionary<string, DayAgg> Days = new Dictionary<string, DayAgg>();
        }

        /// <summary>
        /// Scans <paramref name="projectsDir"/> and returns a JSON document:
        /// { files, scanned, days: { "yyyy-MM-dd": { m, t, models: { id: tokens } } },
        ///   sessions: [ { d: "yyyy-MM-dd", h: 0-23 } ] }
        /// </summary>
        public static string Scan(string projectsDir, string cachePath, bool dedupe)
        {
            JavaScriptSerializer ser = NewSerializer();
            TimeZoneInfo tz = TimeZoneInfo.Local;
            string tzKey = tz.Id + "|" + (dedupe ? "dedupe" : "raw");

            Dictionary<string, FileAgg> cache = LoadCache(cachePath, ser, tzKey);
            var current = new Dictionary<string, FileAgg>(StringComparer.OrdinalIgnoreCase);
            int scanned = 0;

            var files = new List<string>();
            if (!string.IsNullOrEmpty(projectsDir) && Directory.Exists(projectsDir))
            {
                Walk(projectsDir, files);
            }

            foreach (string path in files)
            {
                FileInfo fi;
                try { fi = new FileInfo(path); }
                catch (Exception) { continue; }

                long len = fi.Length;
                long mt = fi.LastWriteTimeUtc.Ticks;

                FileAgg agg;
                if (cache.TryGetValue(path, out agg) && agg.Length == len && agg.MTimeTicks == mt)
                {
                    current[path] = agg;
                    continue;
                }

                try
                {
                    agg = ScanFile(path, dedupe, ser, tz);
                    agg.Length = len;
                    agg.MTimeTicks = mt;
                    current[path] = agg;
                    scanned++;
                }
                catch (Exception)
                {
                    // Locked or unreadable transcript: skip it this round, keep any old copy.
                    FileAgg old;
                    if (cache.TryGetValue(path, out old)) { current[path] = old; }
                }
            }

            if (scanned > 0 || cache.Count != current.Count)
            {
                SaveCache(cachePath, ser, tzKey, current);
            }

            return BuildResult(ser, current, scanned);
        }

        private static JavaScriptSerializer NewSerializer()
        {
            var ser = new JavaScriptSerializer();
            ser.MaxJsonLength = int.MaxValue;
            ser.RecursionLimit = 256;
            return ser;
        }

        private static void Walk(string dir, List<string> files)
        {
            try
            {
                foreach (string f in Directory.GetFiles(dir, "*.jsonl")) { files.Add(f); }
            }
            catch (Exception) { }

            try
            {
                foreach (string d in Directory.GetDirectories(dir)) { Walk(d, files); }
            }
            catch (Exception) { }
        }

        private static FileAgg ScanFile(string path, bool dedupe, JavaScriptSerializer ser, TimeZoneInfo tz)
        {
            var agg = new FileAgg();
            HashSet<string> seen = dedupe ? new HashSet<string>() : null;
            DateTime firstUtc = DateTime.MaxValue;

            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var sr = new StreamReader(fs, Encoding.UTF8, false, 1 << 16))
            {
                string line;
                while ((line = sr.ReadLine()) != null)
                {
                    if (line.Length < 20) { continue; }

                    // Cheap pre-filter: only lines that can be user/assistant messages are parsed.
                    if (line.IndexOf("\"type\":\"assistant\"", StringComparison.Ordinal) < 0 &&
                        line.IndexOf("\"type\":\"user\"", StringComparison.Ordinal) < 0)
                    {
                        continue;
                    }

                    Dictionary<string, object> o;
                    try { o = ser.DeserializeObject(line) as Dictionary<string, object>; }
                    catch (Exception) { continue; }
                    if (o == null) { continue; }

                    string type = Str(o, "type");
                    if (type != "user" && type != "assistant") { continue; }

                    DateTime utc;
                    if (!TryParseUtc(Str(o, "timestamp"), out utc)) { continue; }

                    Dictionary<string, object> msg = Obj(o, "message");

                    if (type == "assistant" && dedupe && msg != null)
                    {
                        string id = Str(msg, "id");
                        if (id != null)
                        {
                            if (!seen.Add(id + "|" + Str(o, "requestId"))) { continue; }
                        }
                    }

                    if (utc < firstUtc) { firstUtc = utc; }

                    DateTime local = TimeZoneInfo.ConvertTimeFromUtc(utc, tz);
                    string day = local.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

                    DayAgg d;
                    if (!agg.Days.TryGetValue(day, out d))
                    {
                        d = new DayAgg();
                        agg.Days[day] = d;
                    }
                    d.Messages++;

                    if (type == "assistant" && msg != null)
                    {
                        Dictionary<string, object> usage = Obj(msg, "usage");
                        string model = Str(msg, "model");
                        if (usage != null)
                        {
                            long total = Num(usage, "input_tokens") + Num(usage, "output_tokens")
                                       + Num(usage, "cache_creation_input_tokens") + Num(usage, "cache_read_input_tokens");
                            d.Tokens += total;
                            if (!string.IsNullOrEmpty(model) && model[0] != '<')
                            {
                                long cur;
                                d.Models.TryGetValue(model, out cur);
                                d.Models[model] = cur + total;
                            }
                        }
                    }
                }
            }

            if (firstUtc != DateTime.MaxValue)
            {
                DateTime first = TimeZoneInfo.ConvertTimeFromUtc(firstUtc, tz);
                agg.StartDay = first.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                agg.StartHour = first.Hour;
            }
            return agg;
        }

        private static string BuildResult(JavaScriptSerializer ser, Dictionary<string, FileAgg> files, int scanned)
        {
            var days = new Dictionary<string, DayAgg>();
            var sessions = new ArrayList();

            foreach (FileAgg f in files.Values)
            {
                if (f.StartDay != null)
                {
                    var s = new Dictionary<string, object>();
                    s["d"] = f.StartDay;
                    s["h"] = f.StartHour;
                    sessions.Add(s);
                }

                foreach (KeyValuePair<string, DayAgg> kv in f.Days)
                {
                    DayAgg total;
                    if (!days.TryGetValue(kv.Key, out total))
                    {
                        total = new DayAgg();
                        days[kv.Key] = total;
                    }
                    total.Messages += kv.Value.Messages;
                    total.Tokens += kv.Value.Tokens;
                    foreach (KeyValuePair<string, long> m in kv.Value.Models)
                    {
                        long cur;
                        total.Models.TryGetValue(m.Key, out cur);
                        total.Models[m.Key] = cur + m.Value;
                    }
                }
            }

            var result = new Dictionary<string, object>();
            result["files"] = files.Count;
            result["scanned"] = scanned;
            result["days"] = DaysToObject(days);
            result["sessions"] = sessions;
            return ser.Serialize(result);
        }

        private static Dictionary<string, object> DaysToObject(Dictionary<string, DayAgg> days)
        {
            var result = new Dictionary<string, object>();
            foreach (KeyValuePair<string, DayAgg> kv in days)
            {
                var d = new Dictionary<string, object>();
                d["m"] = kv.Value.Messages;
                d["t"] = kv.Value.Tokens;
                var models = new Dictionary<string, object>();
                foreach (KeyValuePair<string, long> m in kv.Value.Models) { models[m.Key] = m.Value; }
                d["models"] = models;
                result[kv.Key] = d;
            }
            return result;
        }

        // ---------------------------------------------------------------- cache

        private static Dictionary<string, FileAgg> LoadCache(string cachePath, JavaScriptSerializer ser, string tzKey)
        {
            var result = new Dictionary<string, FileAgg>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (string.IsNullOrEmpty(cachePath) || !File.Exists(cachePath)) { return result; }

                var root = ser.DeserializeObject(File.ReadAllText(cachePath, Encoding.UTF8)) as Dictionary<string, object>;
                if (root == null) { return result; }
                if ((int)Num(root, "v") != CacheVersion || Str(root, "key") != tzKey) { return result; }

                Dictionary<string, object> files = Obj(root, "files");
                if (files == null) { return result; }

                foreach (KeyValuePair<string, object> kv in files)
                {
                    var fo = kv.Value as Dictionary<string, object>;
                    if (fo == null) { continue; }

                    var agg = new FileAgg();
                    agg.Length = Num(fo, "len");
                    agg.MTimeTicks = Num(fo, "mt");
                    agg.StartDay = Str(fo, "sd");
                    agg.StartHour = (int)Num(fo, "sh");

                    Dictionary<string, object> days = Obj(fo, "days");
                    if (days != null)
                    {
                        foreach (KeyValuePair<string, object> dk in days)
                        {
                            var dobj = dk.Value as Dictionary<string, object>;
                            if (dobj == null) { continue; }
                            var d = new DayAgg();
                            d.Messages = Num(dobj, "m");
                            d.Tokens = Num(dobj, "t");
                            Dictionary<string, object> models = Obj(dobj, "models");
                            if (models != null)
                            {
                                foreach (KeyValuePair<string, object> mk in models)
                                {
                                    d.Models[mk.Key] = Convert.ToInt64(mk.Value, CultureInfo.InvariantCulture);
                                }
                            }
                            agg.Days[dk.Key] = d;
                        }
                    }
                    result[kv.Key] = agg;
                }
            }
            catch (Exception)
            {
                result.Clear();   // corrupt cache: rebuild from scratch
            }
            return result;
        }

        private static void SaveCache(string cachePath, JavaScriptSerializer ser, string tzKey, Dictionary<string, FileAgg> files)
        {
            if (string.IsNullOrEmpty(cachePath)) { return; }
            try
            {
                var filesObj = new Dictionary<string, object>();
                foreach (KeyValuePair<string, FileAgg> kv in files)
                {
                    var fo = new Dictionary<string, object>();
                    fo["len"] = kv.Value.Length;
                    fo["mt"] = kv.Value.MTimeTicks;
                    fo["sd"] = kv.Value.StartDay;
                    fo["sh"] = kv.Value.StartHour;
                    fo["days"] = DaysToObject(kv.Value.Days);
                    filesObj[kv.Key] = fo;
                }

                var root = new Dictionary<string, object>();
                root["v"] = CacheVersion;
                root["key"] = tzKey;
                root["files"] = filesObj;

                string dir = Path.GetDirectoryName(cachePath);
                if (!string.IsNullOrEmpty(dir)) { Directory.CreateDirectory(dir); }

                string tmp = cachePath + ".tmp";
                File.WriteAllText(tmp, ser.Serialize(root), new UTF8Encoding(false));
                if (File.Exists(cachePath)) { File.Delete(cachePath); }
                File.Move(tmp, cachePath);
            }
            catch (Exception)
            {
                // The cache is an optimisation only; ignore write failures.
            }
        }

        // -------------------------------------------------------------- helpers

        private static bool TryParseUtc(string s, out DateTime utc)
        {
            utc = DateTime.MinValue;
            if (string.IsNullOrEmpty(s)) { return false; }
            return DateTime.TryParse(s, CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out utc);
        }

        private static string Str(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) ? v as string : null;
        }

        private static Dictionary<string, object> Obj(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) ? v as Dictionary<string, object> : null;
        }

        private static long Num(Dictionary<string, object> d, string key)
        {
            object v;
            if (d == null || !d.TryGetValue(key, out v) || v == null) { return 0; }
            try { return Convert.ToInt64(v, CultureInfo.InvariantCulture); }
            catch (Exception) { return 0; }
        }
    }
}
