// Engine.cs - Reclaim native engine. C# 5 only: compiled by Windows PowerShell 5.1 (Add-Type).
// Walk: one directory handle per folder, GetFileInformationByHandleEx(FileFullDirectoryInfo)
// returns logical size (EndOfFile) and on-disk size (AllocationSize) for every entry without
// opening the files.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace Reclaim
{
    public static class Native
    {
        public const uint FILE_LIST_DIRECTORY = 0x1;
        public const uint SHARE_ALL = 0x7;
        public const uint OPEN_EXISTING = 3;
        public const uint FLAG_BACKUP_SEMANTICS = 0x02000000;
        public const int FileFullDirectoryInfo = 14;
        public const int ERROR_ACCESS_DENIED = 5;
        public const int ERROR_NO_MORE_FILES = 18;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa,
            uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetFileInformationByHandleEx(SafeFileHandle h, int cls, IntPtr buf, uint size);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetDiskFreeSpaceW(string root, out uint sectorsPerCluster, out uint bytesPerSector,
            out uint freeClusters, out uint totalClusters);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetDiskFreeSpaceExW(string dir, out ulong freeToCaller, out ulong total, out ulong totalFree);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetVolumePathNameW(string path, StringBuilder volume, int len);

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        struct TOKEN_PRIVILEGES { public int Count; public long Luid; public int Attributes; }

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool LookupPrivilegeValueW(string system, string name, out long luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES state,
            int len, IntPtr prev, IntPtr retLen);

        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr h);

        // Extended-length form so paths beyond 260 characters work everywhere.
        public static string Long(string path)
        {
            if (path.StartsWith(@"\\?\")) return path;
            if (path.StartsWith(@"\\")) return @"\\?\UNC\" + path.Substring(2);
            return @"\\?\" + path;
        }

        public static string VolumeRoot(string path)
        {
            StringBuilder sb = new StringBuilder(1024);
            if (!GetVolumePathNameW(path, sb, sb.Capacity)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return sb.ToString();
        }

        public static long ClusterSize(string path)
        {
            uint spc, bps, fc, tc;
            if (!GetDiskFreeSpaceW(VolumeRoot(path), out spc, out bps, out fc, out tc))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return (long)spc * bps;
        }

        public static long FreeBytes(string path)
        {
            ulong caller, total, free;
            if (!GetDiskFreeSpaceExW(VolumeRoot(path), out caller, out total, out free))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return (long)free;
        }

        public static long TotalBytes(string path)
        {
            ulong caller, total, free;
            if (!GetDiskFreeSpaceExW(VolumeRoot(path), out caller, out total, out free))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return (long)total;
        }

        // Elevated tokens carry SeBackupPrivilege (disabled). Enabled + FILE_FLAG_BACKUP_SEMANTICS,
        // directory listings bypass ACLs (System Volume Information, other profiles). Read-only use.
        public static bool EnableBackupPrivilege()
        {
            IntPtr tok;
            if (!OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out tok)) return false;
            try
            {
                long luid;
                if (!LookupPrivilegeValueW(null, "SeBackupPrivilege", out luid)) return false;
                TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                tp.Count = 1; tp.Luid = luid; tp.Attributes = 2;
                if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
                return Marshal.GetLastWin32Error() == 0;
            }
            finally { CloseHandle(tok); }
        }
    }

    // One KB pattern. Name = regex for the last path segment (cheap pre-filter), Full = whole path.
    public class Rule
    {
        public string Id;
        public bool IsFile;
        public int Specificity;
        public Regex Full;
        public Regex Name;

        public Rule(string id, bool isFile, string fullRegex, string nameRegex, int specificity)
        {
            Id = id; IsFile = isFile; Specificity = specificity;
            RegexOptions o = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled;
            Full = new Regex(fullRegex, o);
            Name = new Regex(nameRegex, o);
        }

        // Last segment when it has no wildcard: a string compare instead of a regex per entry.
        public string LiteralName;

        // Most specific matching rule of the requested kind, or -1.
        public static int Best(List<Rule> rules, bool files, string name, string path)
        {
            int best = -1;
            for (int i = 0; i < rules.Count; i++)
            {
                Rule r = rules[i];
                if (r.IsFile != files) continue;
                if (best >= 0 && r.Specificity <= rules[best].Specificity) continue;
                if (r.LiteralName != null)
                {
                    if (!string.Equals(r.LiteralName, name, StringComparison.OrdinalIgnoreCase)) continue;
                }
                else if (!r.Name.IsMatch(name)) continue;
                if (!r.Full.IsMatch(path)) continue;
                best = i;
            }
            return best;
        }
    }

    public class Item
    {
        public string Kind;            // dir | file | files
        public string Path;            // folder or file; for "files" the folder holding Members
        public string RuleId;          // null = UNKNOWN
        public long OnDisk;            // residual: bytes not already claimed by items below
        public long Logical;
        public long TotalOnDisk;       // everything under Path
        public long TotalLogical;
        public long Files;
        public long NewestWrite;
        public long PlaceholderLogical;
        public List<string> Members = new List<string>();
    }

    // Deterministic item model: KB matches become items sized by their residual; nested KB matches
    // split off; a match under the same rule is absorbed; UNKNOWN only where no KB ancestor exists.
    public static class Classifier
    {
        static string LastSegment(string path)
        {
            string p = path.TrimEnd('\\');
            int i = p.LastIndexOf('\\');
            return i >= 0 ? p.Substring(i + 1) : p;
        }

        public static List<Item> Classify(ScanResult r, List<Rule> rules, long dirUnknownMin, long fileUnknownMin)
        {
            int n = r.Dirs.Count;
            int[] match = new int[n];
            bool[] covered = new bool[n];
            string[] nearest = new string[n];
            for (int i = 0; i < n; i++)
            {
                DirNode d = r.Dirs[i];
                match[i] = Rule.Best(rules, false, LastSegment(d.Path), d.Path);
                if (d.Parent >= 0)
                {
                    int p = d.Parent;
                    covered[i] = covered[p] || match[p] >= 0;
                    nearest[i] = match[p] >= 0 ? rules[match[p]].Id : nearest[p];
                }
                if (match[i] >= 0 && nearest[i] == rules[match[i]].Id) match[i] = -1;
            }

            long[] below = new long[n];
            long[] belowL = new long[n];
            List<Item> items = new List<Item>();
            Dictionary<string, Item> groups = new Dictionary<string, Item>();
            foreach (FileRec f in r.Files)
            {
                if (f.RuleIndex >= 0)
                {
                    string key = f.Dir + "|" + rules[f.RuleIndex].Id;
                    Item g;
                    if (!groups.TryGetValue(key, out g))
                    {
                        g = new Item();
                        g.Kind = "file"; g.Path = f.Path; g.RuleId = rules[f.RuleIndex].Id;
                        groups[key] = g; items.Add(g);
                    }
                    else { g.Kind = "files"; g.Path = r.Dirs[f.Dir].Path; }
                    AddFile(g, f);
                }
                else if (match[f.Dir] < 0 && !covered[f.Dir] && f.OnDisk >= fileUnknownMin)
                {
                    Item u = new Item();
                    u.Kind = "file"; u.Path = f.Path; u.RuleId = null;
                    AddFile(u, f);
                    items.Add(u);
                }
                else continue;
                below[f.Dir] += f.OnDisk; belowL[f.Dir] += f.Logical;
            }

            for (int i = n - 1; i >= 0; i--)
            {
                DirNode d = r.Dirs[i];
                long resid = d.OnDisk - below[i];
                long residL = d.Logical - belowL[i];
                long claimed = below[i], claimedL = belowL[i];
                bool unknown = match[i] < 0 && !covered[i] && d.Parent >= 0 && !d.Denied && resid >= dirUnknownMin;
                if (match[i] >= 0 || unknown)
                {
                    Item it = new Item();
                    it.Kind = "dir"; it.Path = d.Path; it.RuleId = match[i] >= 0 ? rules[match[i]].Id : null;
                    it.OnDisk = resid; it.Logical = residL; it.TotalOnDisk = d.OnDisk; it.TotalLogical = d.Logical;
                    it.Files = d.Files; it.NewestWrite = d.NewestWrite; it.PlaceholderLogical = d.PlaceholderLogical;
                    items.Add(it);
                    claimed = d.OnDisk; claimedL = d.Logical;
                }
                if (d.Parent >= 0) { below[d.Parent] += claimed; belowL[d.Parent] += claimedL; }
            }
            items.Sort(delegate (Item a, Item b) { return b.OnDisk.CompareTo(a.OnDisk); });
            return items;
        }

        static void AddFile(Item g, FileRec f)
        {
            g.OnDisk += f.OnDisk; g.Logical += f.Logical;
            g.TotalOnDisk += f.OnDisk; g.TotalLogical += f.Logical;
            g.Files++;
            if (f.LastWrite > g.NewestWrite) g.NewestWrite = f.LastWrite;
            if (Walker.IsPlaceholder(f.Attributes)) g.PlaceholderLogical += f.Logical;
            g.Members.Add(f.Path);
        }
    }

    public class ScanOptions
    {
        public bool UseBackupPrivilege = true;
        public int RecentDays = 7;
        public long RecentMinBytes = 1048576;
        public long BigFileMinBytes = 104857600;
        public List<Rule> Rules = new List<Rule>();
        public bool Progress = false;
    }

    public class DirNode
    {
        public string Path;
        public int Parent;
        public int Depth;
        public long OnDisk;
        public long Logical;
        public long Files;
        public long OwnOnDisk;
        public long OwnLogical;
        public long OwnFiles;
        public long NewestWrite;
        public long PlaceholderLogical;
        public bool Denied;
    }

    public class FileRec
    {
        public string Path;
        public int Dir;
        public long OnDisk;
        public long Logical;
        public long LastWrite;
        public uint Attributes;
        public int RuleIndex;
    }

    public class SkipRecord
    {
        public string Path;
        public uint Tag;
        public string Kind;
        public SkipRecord(string path, uint tag)
        {
            Path = path; Tag = tag;
            if (tag == 0xA0000003u) Kind = "junction/mount point";
            else if (tag == 0xA000000Cu) Kind = "symbolic link";
            else Kind = "reparse point 0x" + tag.ToString("X8");
        }
    }

    public class ScanResult
    {
        public string Root;
        public bool BackupPrivilege;
        public long TotalFiles;
        public long ElapsedMs;
        public List<DirNode> Dirs = new List<DirNode>();
        public List<FileRec> Files = new List<FileRec>();
        public List<string> Denied = new List<string>();
        public List<SkipRecord> Skipped = new List<SkipRecord>();
        public List<string> Errors = new List<string>();
    }

    public class GrowthRec
    {
        public string Path;
        public long Before;
        public long After;
        public long Delta;
    }

    public static class Growth
    {
        public static Dictionary<string, long> ReadTsv(string path)
        {
            Dictionary<string, long> d = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            foreach (string line in File.ReadLines(path))
            {
                int t1 = line.IndexOf('\t');
                if (t1 <= 0) continue;
                int t2 = line.IndexOf('\t', t1 + 1);
                string num = t2 > 0 ? line.Substring(t1 + 1, t2 - t1 - 1) : line.Substring(t1 + 1);
                long v;
                if (long.TryParse(num, out v)) d[line.Substring(0, t1)] = v;
            }
            return d;
        }

        // Folders whose on-disk size grew, largest first. A folder is dropped when one of its
        // descendants grew by at least 90% of the folder's own growth: the descendant is the hotspot.
        public static List<GrowthRec> Compare(string prevTsv, string curTsv, int top)
        {
            Dictionary<string, long> prev = ReadTsv(prevTsv);
            Dictionary<string, long> cur = ReadTsv(curTsv);
            Dictionary<string, GrowthRec> grew = new Dictionary<string, GrowthRec>(StringComparer.OrdinalIgnoreCase);
            foreach (KeyValuePair<string, long> kv in cur)
            {
                long before;
                prev.TryGetValue(kv.Key, out before);
                if (kv.Value <= before) continue;
                GrowthRec g = new GrowthRec();
                g.Path = kv.Key; g.Before = before; g.After = kv.Value; g.Delta = kv.Value - before;
                grew[kv.Key] = g;
            }
            Dictionary<string, long> maxChild = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            foreach (GrowthRec g in grew.Values)
            {
                for (string p = Parent(g.Path); p != null; p = Parent(p))
                {
                    long m;
                    if (!maxChild.TryGetValue(p, out m) || g.Delta > m) maxChild[p] = g.Delta;
                }
            }
            List<GrowthRec> list = new List<GrowthRec>();
            foreach (GrowthRec g in grew.Values)
            {
                long m;
                if (maxChild.TryGetValue(g.Path, out m) && m >= g.Delta * 0.9) continue;
                list.Add(g);
            }
            list.Sort(delegate (GrowthRec a, GrowthRec b) { return b.Delta.CompareTo(a.Delta); });
            if (list.Count > top) list.RemoveRange(top, list.Count - top);
            return list;
        }

        static string Parent(string path)
        {
            string p = path.TrimEnd('\\');
            int i = p.LastIndexOf('\\');
            if (i < 0) return null;
            if (i == 2 && p[1] == ':') return p.Substring(0, 3);
            return p.Substring(0, i);
        }
    }

    public static class ScanStore
    {
        // One row per folder >= minOnDisk: path, on-disk, logical, files, newest write (FILETIME UTC).
        public static int WriteDirsTsv(ScanResult r, string path, long minOnDisk)
        {
            int n = 0;
            using (StreamWriter w = new StreamWriter(path, false, new UTF8Encoding(false)))
            {
                foreach (DirNode d in r.Dirs)
                {
                    if (d.OnDisk < minOnDisk) continue;
                    w.Write(d.Path); w.Write('\t'); w.Write(d.OnDisk); w.Write('\t'); w.Write(d.Logical);
                    w.Write('\t'); w.Write(d.Files); w.Write('\t'); w.Write(d.NewestWrite); w.Write('\n');
                    n++;
                }
            }
            return n;
        }
    }

    public static class Walker
    {
        const uint ATTR_DIRECTORY = 0x10;
        const uint ATTR_REPARSE = 0x400;
        const int BufSize = 64 * 1024;

        // OneDrive Files On-Demand: RecallOnDataAccess, RecallOnOpen, Offline.
        public static bool IsPlaceholder(uint attrs) { return (attrs & (0x400000u | 0x40000u | 0x1000u)) != 0; }

        // Cloud Files reparse tags (0x9000xx1A) are OneDrive folders: descend. Everything else
        // (junctions, symlinks, mount points) is recorded and not followed.
        public static bool IsCloudTag(uint tag) { return (tag & 0xFFFF0FFFu) == 0x9000001Au; }

        public static string Join(string dir, string name)
        {
            return dir.EndsWith("\\") ? dir + name : dir + "\\" + name;
        }

        static string NormalizeRoot(string root)
        {
            string full = System.IO.Path.GetFullPath(root);
            if (full.Length > 3 && full.EndsWith("\\")) full = full.TrimEnd('\\');
            return full;
        }

        public static ScanResult Scan(string root, ScanOptions opt)
        {
            System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
            ScanResult r = new ScanResult();
            r.Root = NormalizeRoot(root);
            if (opt.UseBackupPrivilege) r.BackupPrivilege = Native.EnableBackupPrivilege();
            long recentCutoff = DateTime.UtcNow.AddDays(-opt.RecentDays).ToFileTimeUtc();

            DirNode top = new DirNode();
            top.Path = r.Root; top.Parent = -1; top.Depth = 0;
            r.Dirs.Add(top);
            Stack<int> stack = new Stack<int>();
            stack.Push(0);
            IntPtr buf = Marshal.AllocHGlobal(BufSize);
            long nextProgress = sw.ElapsedMilliseconds + 2000;
            try
            {
                while (stack.Count > 0)
                {
                    EnumerateDir(r, stack.Pop(), buf, opt, recentCutoff, stack);
                    if (opt.Progress && sw.ElapsedMilliseconds >= nextProgress)
                    {
                        nextProgress = sw.ElapsedMilliseconds + 2000;
                        Console.Error.Write(string.Format("\r  walking {0}: {1:N0} folders, {2:N0} files ...   ",
                            r.Root, r.Dirs.Count, r.TotalFiles));
                    }
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            if (opt.Progress) Console.Error.Write("\r" + new string(' ', 90) + "\r");

            // Children always have a higher index than their parent: fold totals upward.
            for (int i = r.Dirs.Count - 1; i > 0; i--)
            {
                DirNode d = r.Dirs[i];
                DirNode p = r.Dirs[d.Parent];
                p.OnDisk += d.OnDisk; p.Logical += d.Logical; p.Files += d.Files;
                p.PlaceholderLogical += d.PlaceholderLogical;
                if (d.NewestWrite > p.NewestWrite) p.NewestWrite = d.NewestWrite;
            }
            r.ElapsedMs = sw.ElapsedMilliseconds;
            return r;
        }

        static void EnumerateDir(ScanResult r, int idx, IntPtr buf, ScanOptions opt, long recentCutoff, Stack<int> stack)
        {
            DirNode d = r.Dirs[idx];
            using (SafeFileHandle h = Native.CreateFileW(Native.Long(d.Path), Native.FILE_LIST_DIRECTORY,
                Native.SHARE_ALL, IntPtr.Zero, Native.OPEN_EXISTING, Native.FLAG_BACKUP_SEMANTICS, IntPtr.Zero))
            {
                if (h.IsInvalid) { RecordFailure(r, d, Marshal.GetLastWin32Error()); return; }
                while (true)
                {
                    if (!Native.GetFileInformationByHandleEx(h, Native.FileFullDirectoryInfo, buf, BufSize))
                    {
                        int err = Marshal.GetLastWin32Error();
                        if (err != Native.ERROR_NO_MORE_FILES) RecordFailure(r, d, err);
                        return;
                    }
                    int off = 0;
                    while (true)
                    {
                        IntPtr p = IntPtr.Add(buf, off);
                        int next = Marshal.ReadInt32(p, 0);
                        long lastWrite = Marshal.ReadInt64(p, 24);
                        long eof = Marshal.ReadInt64(p, 40);
                        long alloc = Marshal.ReadInt64(p, 48);
                        uint attrs = (uint)Marshal.ReadInt32(p, 56);
                        int nameBytes = Marshal.ReadInt32(p, 60);
                        uint tag = (uint)Marshal.ReadInt32(p, 64);
                        string name = Marshal.PtrToStringUni(IntPtr.Add(p, 68), nameBytes / 2);
                        if (name != "." && name != "..")
                            AddEntry(r, idx, d, name, attrs, tag, eof, alloc, lastWrite, opt, recentCutoff, stack);
                        if (next == 0) break;
                        off += next;
                    }
                }
            }
        }

        static void RecordFailure(ScanResult r, DirNode d, int err)
        {
            if (err == Native.ERROR_ACCESS_DENIED) { d.Denied = true; r.Denied.Add(d.Path); }
            else r.Errors.Add(d.Path + " : " + new Win32Exception(err).Message + " (" + err + ")");
        }

        static void AddEntry(ScanResult r, int idx, DirNode d, string name, uint attrs, uint tag, long eof,
            long alloc, long lastWrite, ScanOptions opt, long recentCutoff, Stack<int> stack)
        {
            string full = Join(d.Path, name);
            if ((attrs & ATTR_DIRECTORY) != 0)
            {
                if ((attrs & ATTR_REPARSE) != 0 && !IsCloudTag(tag)) { r.Skipped.Add(new SkipRecord(full, tag)); return; }
                DirNode c = new DirNode();
                c.Path = full; c.Parent = idx; c.Depth = d.Depth + 1;
                stack.Push(r.Dirs.Count);
                r.Dirs.Add(c);
                return;
            }
            r.TotalFiles++;
            d.OwnFiles++; d.Files++;
            d.OwnOnDisk += alloc; d.OnDisk += alloc;
            d.OwnLogical += eof; d.Logical += eof;
            if (IsPlaceholder(attrs)) d.PlaceholderLogical += eof;
            if (lastWrite > d.NewestWrite) d.NewestWrite = lastWrite;

            int rule = opt.Rules.Count > 0 ? Rule.Best(opt.Rules, true, name, full) : -1;
            bool recent = lastWrite >= recentCutoff && alloc >= opt.RecentMinBytes;
            if (rule >= 0 || recent || alloc >= opt.BigFileMinBytes)
            {
                FileRec f = new FileRec();
                f.Path = full; f.Dir = idx; f.OnDisk = alloc; f.Logical = eof;
                f.LastWrite = lastWrite; f.Attributes = attrs; f.RuleIndex = rule;
                r.Files.Add(f);
            }
        }
    }
}
