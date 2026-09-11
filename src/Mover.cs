// Mover.cs - the only code in Reclaim that changes files. It moves, it never deletes user data:
// a source file is removed only after a byte-for-byte verified copy exists at the destination.
// The one thing it deletes is a failed partial copy that it created itself a moment earlier.
// Destinations are never overwritten. C# 5 only.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Reclaim
{
    public class MoveResult
    {
        public string Source;
        public string Dest;
        public string Status;   // ok | failed | skipped-placeholder | skipped-reparse | copied-source-locked | moved-hash-changed
        public string Sha256;
        public long Bytes;
        public string Error;
    }

    public class MoveSummary
    {
        public int Files;
        public int Moved;
        public int Failed;
        public int Skipped;
        public int Locked;
        public int Conflicts;
        public long Bytes;
        public long OnDisk;
    }

    public class FileList
    {
        public List<FileRec> Files = new List<FileRec>();
        public List<string> Skipped = new List<string>();
        public List<string> Denied = new List<string>();
        public List<string> Errors = new List<string>();
    }

    public static class Mover
    {
        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 0x1;
        const uint CREATE_NEW = 1;
        const uint OPEN_EXISTING = 3;
        const uint FLAG_SEQUENTIAL = 0x08000000;
        const uint FLAG_BACKUP = 0x02000000;
        const uint INVALID_ATTRS = 0xFFFFFFFF;
        const uint ATTR_READONLY = 0x1;
        const uint ATTR_DIRECTORY = 0x10;
        const uint ATTR_REPARSE = 0x400;
        const uint ATTR_KEEP = 0x1 | 0x2 | 0x4 | 0x20;   // read-only, hidden, system, archive
        const int ERROR_NOT_SAME_DEVICE = 17;
        const int ERROR_ALREADY_EXISTS = 183;
        const int BufSize = 64 * 1024;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFileAttributesW(string path);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool SetFileAttributesW(string path, uint attrs);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool MoveFileExW(string from, string to, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool DeleteFileW(string path);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateDirectoryW(string path, IntPtr sa);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileTime(SafeFileHandle h, out long created, out long accessed, out long written);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileTime(SafeFileHandle h, ref long created, ref long accessed, ref long written);

        static string Msg(int err) { return new Win32Exception(err).Message + " (" + err + ")"; }

        public static bool Exists(string path) { return GetFileAttributesW(Native.Long(path)) != INVALID_ATTRS; }

        static string ParentOf(string path)
        {
            string p = path.TrimEnd('\\');
            int i = p.LastIndexOf('\\');
            if (i < 0) return null;
            if (i == 2 && p[1] == ':') return p.Substring(0, 3);
            return p.Substring(0, i);
        }

        public static void EnsureDir(string dir)
        {
            if (dir == null || Exists(dir)) return;
            EnsureDir(ParentOf(dir));
            if (!CreateDirectoryW(Native.Long(dir), IntPtr.Zero))
            {
                int e = Marshal.GetLastWin32Error();
                if (e != ERROR_ALREADY_EXISTS) throw new Win32Exception(e);
            }
        }

        static SafeFileHandle Open(string path, uint access, uint share, uint disposition, uint flags)
        {
            return Native.CreateFileW(Native.Long(path), access, share, IntPtr.Zero, disposition, flags, IntPtr.Zero);
        }

        static string Hex(byte[] b)
        {
            StringBuilder sb = new StringBuilder(b.Length * 2);
            foreach (byte x in b) sb.Append(x.ToString("x2"));
            return sb.ToString();
        }

        public static string HashFile(string path)
        {
            SafeFileHandle h = Open(path, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING, FLAG_SEQUENTIAL | FLAG_BACKUP);
            if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            using (FileStream fs = new FileStream(h, FileAccess.Read, 1 << 20))
            using (SHA256 sha = SHA256.Create())
                return Hex(sha.ComputeHash(fs));
        }

        static MoveResult Fail(MoveResult r, string error) { r.Status = "failed"; r.Error = error; return r; }

        static bool SameDrive(string a, string b)
        {
            return a.Length > 2 && b.Length > 2 && a[1] == ':' && b[1] == ':' &&
                char.ToUpperInvariant(a[0]) == char.ToUpperInvariant(b[0]);
        }

        public static MoveResult MoveFile(string src, string dst)
        {
            MoveResult r = new MoveResult();
            r.Source = src; r.Dest = dst;
            try
            {
                uint a = GetFileAttributesW(Native.Long(src));
                if (a == INVALID_ATTRS) return Fail(r, "source not found: " + Msg(Marshal.GetLastWin32Error()));
                if ((a & ATTR_DIRECTORY) != 0) return Fail(r, "source is a folder");
                if (Walker.IsPlaceholder(a)) { r.Status = "skipped-placeholder"; r.Error = "cloud-only file: moving it would download it"; return r; }
                if ((a & ATTR_REPARSE) != 0) { r.Status = "skipped-reparse"; r.Error = "link (reparse point): not moved"; return r; }
                if (Exists(dst)) return Fail(r, "destination exists; never overwritten");
                EnsureDir(ParentOf(dst));
                if (SameDrive(src, dst)) return MoveSameVolume(r, a);
                return MoveAcrossVolumes(r, a, null);
            }
            catch (Exception e) { return Fail(r, e.Message); }
        }

        static MoveResult MoveSameVolume(MoveResult r, uint attrs)
        {
            string before = HashFile(r.Source);   // fails while another process writes the file
            if (!MoveFileExW(Native.Long(r.Source), Native.Long(r.Dest), 0))
            {
                int e = Marshal.GetLastWin32Error();
                if (e == ERROR_NOT_SAME_DEVICE) return MoveAcrossVolumes(r, attrs, before);   // mounted folder
                return Fail(r, "move failed: " + Msg(e));
            }
            string after = HashFile(r.Dest);
            r.Sha256 = after;
            r.Bytes = new FileInfoLite(r.Dest).Length;
            r.Status = after == before ? "ok" : "moved-hash-changed";
            return r;
        }

        static MoveResult MoveAcrossVolumes(MoveResult r, uint attrs, string expectHash)
        {
            string tmp = r.Dest + ".reclaim-partial";
            if (Exists(tmp)) return Fail(r, "a partial copy from an earlier attempt is in the way: " + tmp);
            long ct, at, wt;
            string srcHash;
            long bytes = 0;
            SafeFileHandle hs = Open(r.Source, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING, FLAG_SEQUENTIAL | FLAG_BACKUP);
            if (hs.IsInvalid) return Fail(r, "cannot open source (in use?): " + Msg(Marshal.GetLastWin32Error()));
            using (FileStream fin = new FileStream(hs, FileAccess.Read, 1 << 20))
            {
                GetFileTime(hs, out ct, out at, out wt);
                SafeFileHandle hd = Open(tmp, GENERIC_WRITE, 0, CREATE_NEW, FLAG_SEQUENTIAL);
                if (hd.IsInvalid) return Fail(r, "cannot create destination: " + Msg(Marshal.GetLastWin32Error()));
                try
                {
                    using (FileStream fout = new FileStream(hd, FileAccess.Write, 1 << 20))
                    using (SHA256 sha = SHA256.Create())
                    {
                        byte[] buf = new byte[1 << 20];
                        int n;
                        while ((n = fin.Read(buf, 0, buf.Length)) > 0)
                        {
                            sha.TransformBlock(buf, 0, n, null, 0);
                            fout.Write(buf, 0, n);
                            bytes += n;
                        }
                        sha.TransformFinalBlock(buf, 0, 0);
                        srcHash = Hex(sha.Hash);
                        fout.Flush(true);
                        SetFileTime(hd, ref ct, ref at, ref wt);
                    }
                }
                catch (Exception e) { TryDeleteOwnPartial(tmp); return Fail(r, "copy failed: " + e.Message); }
            }
            if (expectHash != null && expectHash != srcHash) { TryDeleteOwnPartial(tmp); return Fail(r, "source changed while copying"); }
            string dstHash = HashFile(tmp);
            if (dstHash != srcHash) { TryDeleteOwnPartial(tmp); return Fail(r, "copy verification failed (hash mismatch)"); }
            if (!MoveFileExW(Native.Long(tmp), Native.Long(r.Dest), 0))
            {
                int e = Marshal.GetLastWin32Error();
                TryDeleteOwnPartial(tmp);
                return Fail(r, "could not finalize the copy: " + Msg(e));
            }
            r.Sha256 = srcHash;
            r.Bytes = bytes;
            // A verified copy exists; only now does the source go.
            if ((attrs & ATTR_READONLY) != 0) SetFileAttributesW(Native.Long(r.Source), attrs & ~ATTR_READONLY);
            if (!DeleteFileW(Native.Long(r.Source)))
            {
                int e = Marshal.GetLastWin32Error();
                if ((attrs & ATTR_READONLY) != 0) SetFileAttributesW(Native.Long(r.Source), attrs);
                r.Status = "copied-source-locked";
                r.Error = "verified copy made, but the source could not be removed: " + Msg(e);
                return r;
            }
            SetFileAttributesW(Native.Long(r.Dest), attrs & ATTR_KEEP);
            r.Status = "ok";
            return r;
        }

        // Only ever called on a ".reclaim-partial" file this process created and failed to verify.
        static void TryDeleteOwnPartial(string tmp)
        {
            if (tmp.EndsWith(".reclaim-partial")) DeleteFileW(Native.Long(tmp));
        }

        // Every file under root, not following links, skipping any path inside an excluded one.
        public static FileList ListFiles(string root, string[] exclude)
        {
            FileList fl = new FileList();
            List<string> ex = new List<string>();
            if (exclude != null) foreach (string e in exclude) if (!string.IsNullOrEmpty(e)) ex.Add(e.TrimEnd('\\'));
            Stack<string> stack = new Stack<string>();
            stack.Push(root.TrimEnd('\\'));
            IntPtr buf = Marshal.AllocHGlobal(BufSize);
            try
            {
                while (stack.Count > 0)
                {
                    string dir = stack.Pop();
                    using (SafeFileHandle h = Native.CreateFileW(Native.Long(dir), Native.FILE_LIST_DIRECTORY,
                        Native.SHARE_ALL, IntPtr.Zero, Native.OPEN_EXISTING, Native.FLAG_BACKUP_SEMANTICS, IntPtr.Zero))
                    {
                        if (h.IsInvalid)
                        {
                            int e = Marshal.GetLastWin32Error();
                            if (e == Native.ERROR_ACCESS_DENIED) fl.Denied.Add(dir); else fl.Errors.Add(dir + " : " + Msg(e));
                            continue;
                        }
                        while (Native.GetFileInformationByHandleEx(h, Native.FileFullDirectoryInfo, buf, BufSize))
                        {
                            int off = 0;
                            while (true)
                            {
                                IntPtr p = IntPtr.Add(buf, off);
                                int next = Marshal.ReadInt32(p, 0);
                                uint attrs = (uint)Marshal.ReadInt32(p, 56);
                                string name = Marshal.PtrToStringUni(IntPtr.Add(p, 68), Marshal.ReadInt32(p, 60) / 2);
                                if (name != "." && name != "..")
                                {
                                    string full = Walker.Join(dir, name);
                                    if (!IsExcluded(full, ex))
                                    {
                                        if ((attrs & ATTR_DIRECTORY) != 0)
                                        {
                                            uint tag = (uint)Marshal.ReadInt32(p, 64);
                                            if ((attrs & ATTR_REPARSE) != 0 && !Walker.IsCloudTag(tag)) fl.Skipped.Add(full);
                                            else stack.Push(full);
                                        }
                                        else
                                        {
                                            FileRec f = new FileRec();
                                            f.Path = full; f.Dir = -1; f.RuleIndex = -1; f.Attributes = attrs;
                                            f.LastWrite = Marshal.ReadInt64(p, 24);
                                            f.Logical = Marshal.ReadInt64(p, 40);
                                            f.OnDisk = Marshal.ReadInt64(p, 48);
                                            fl.Files.Add(f);
                                        }
                                    }
                                }
                                if (next == 0) break;
                                off += next;
                            }
                        }
                    }
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return fl;
        }

        static bool IsExcluded(string path, List<string> ex)
        {
            foreach (string e in ex)
                if (string.Equals(path, e, StringComparison.OrdinalIgnoreCase) ||
                    path.StartsWith(e + "\\", StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        // C:\a\b.txt -> <destRoot>\C\a\b.txt
        public static string DestFor(string destRoot, string src)
        {
            return destRoot.TrimEnd('\\') + "\\" + char.ToUpperInvariant(src[0]) + src.Substring(2);
        }

        static string Clean(string s) { return s == null ? "" : s.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' '); }

        // Moves every file, one row per file in the manifest TSV, flushed as it goes so the manifest
        // is accurate even if the run is interrupted.
        public static MoveSummary MoveAll(List<FileRec> files, string destRoot, string tsvPath)
        {
            MoveSummary s = new MoveSummary();
            using (StreamWriter w = new StreamWriter(tsvPath, false, new UTF8Encoding(false)))
            {
                w.Write("status\tsha256\tbytes\tondisk\tsource\tdest\terror\n");
                foreach (FileRec f in files)
                {
                    s.Files++;
                    MoveResult m = MoveFile(f.Path, DestFor(destRoot, f.Path));
                    if (m.Status == "ok") { s.Moved++; s.Bytes += m.Bytes; s.OnDisk += f.OnDisk; }
                    else if (m.Status == "copied-source-locked") s.Locked++;
                    else if (m.Status.StartsWith("skipped")) s.Skipped++;
                    else s.Failed++;
                    w.Write(m.Status + "\t" + (m.Sha256 ?? "") + "\t" + m.Bytes + "\t" + f.OnDisk + "\t" +
                        m.Source + "\t" + m.Dest + "\t" + Clean(m.Error) + "\n");
                    w.Flush();
                }
            }
            return s;
        }

        // Moves quarantined files back to their original paths. Anything now present at an original
        // path is left alone (conflict). Rows whose source never left are skipped.
        public static MoveSummary Restore(string tsvPath, string undoTsvPath)
        {
            MoveSummary s = new MoveSummary();
            using (StreamWriter w = new StreamWriter(undoTsvPath, false, new UTF8Encoding(false)))
            {
                w.Write("status\tsha256\tfrom\tto\terror\n");
                bool header = true;
                foreach (string line in File.ReadLines(tsvPath))
                {
                    if (header) { header = false; continue; }
                    string[] c = line.Split('\t');
                    if (c.Length < 6) continue;
                    string status = c[0], sha = c[1], orig = c[4], q = c[5];
                    string outStatus, err = "";
                    if (status == "copied-source-locked") { s.Skipped++; outStatus = "skipped-source-never-left"; }
                    else if (status != "ok" && status != "moved-hash-changed") continue;
                    else
                    {
                        s.Files++;
                        if (Exists(orig)) { s.Conflicts++; outStatus = "conflict"; err = "something exists at the original path; not overwritten"; }
                        else
                        {
                            MoveResult m = MoveFile(q, orig);
                            if (m.Status == "ok" && (sha.Length == 0 || string.Equals(m.Sha256, sha, StringComparison.OrdinalIgnoreCase)))
                            { s.Moved++; s.Bytes += m.Bytes; outStatus = "restored"; }
                            else if (m.Status == "ok") { s.Failed++; outStatus = "restored-hash-differs"; err = "restored, but the hash differs from the manifest"; }
                            else { s.Failed++; outStatus = m.Status; err = m.Error; }
                        }
                    }
                    w.Write(outStatus + "\t" + sha + "\t" + q + "\t" + orig + "\t" + Clean(err) + "\n");
                    w.Flush();
                }
            }
            return s;
        }
    }

    // File length through a directory listing (works for long paths on .NET Framework).
    public class FileInfoLite
    {
        public long Length;
        public FileInfoLite(string path)
        {
            FileRec f = Walker.StatFile(path);
            Length = f == null ? 0 : f.Logical;
        }
    }
}
