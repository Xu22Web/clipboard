// src\main\reactivity\reactive.cs - the scheduler behind the bag (see renderer\src\core\reactive.ps1).
//
// Effects do not run where the write happens. A write enqueues the effects that read that key, a
// flush runs each of them once, and a batch of writes costs one flush - the shape Vue's job queue
// has, with the flush driven by the caller (a posted window message, a paint, a test) instead of
// by a promise. Nothing here allocates on a read: a read that tracks is one dictionary lookup and
// one list add, and only while an effect is running.
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
using System;
using System.Collections.Generic;

namespace Cb {
  public static class Reactive {
    private sealed class EffectRecord {
      public Action Run;
      public Action Scheduler;
      public List<object[]> Deps;
    }

    private sealed class Job {
      public int Id;
    }

    private static readonly Dictionary<int, EffectRecord> effects = new Dictionary<int, EffectRecord>();
    // target -> key -> the effects that read it. Held by reference and pruned the moment an
    // effect lets go, so a bag that is done with cannot keep the graph alive.
    private static readonly Dictionary<object, Dictionary<string, List<int>>> deps = new Dictionary<object, Dictionary<string, List<int>>>();
    private static readonly List<Job> queue = new List<Job>();
    private static readonly HashSet<int> queued = new HashSet<int>();
    private static int active;
    private static int next = 1;
    private static int flushes;
    private static int runs;

    public static int Count { get { return effects.Count; } }
    public static int Targets { get { return deps.Count; } }
    public static int Pending { get { return queue.Count; } }
    public static int Flushes { get { return flushes; } }
    public static int Runs { get { return runs; } }

    // Runs now, tracking what it reads. The handle is what a window keeps so it can stop the
    // effect when it closes: an effect left behind holds the ScriptBlock, which holds the form.
    public static int Effect(Action run) { return Effect(run, null); }

    public static int Effect(Action run, Action scheduler) {
      if (run == null) { return 0; }
      int id = next++;
      EffectRecord record = new EffectRecord();
      record.Run = run;
      record.Scheduler = scheduler;
      record.Deps = new List<object[]>(4);
      effects[id] = record;
      RunPrepared(id);
      return id;
    }

    public static void Stop(int id) {
      if (id <= 0) { return; }
      Unlink(id);
      effects.Remove(id);
      if (queued.Remove(id)) {
        for (int i = queue.Count - 1; i >= 0; i--) {
          if (queue[i].Id == id) { queue.RemoveAt(i); }
        }
      }
    }

    // Everything a window started, gone in one call: a closed window must not leave a single
    // effect or dependency behind.
    public static void StopAll() {
      effects.Clear();
      deps.Clear();
      queue.Clear();
      queued.Clear();
      active = 0;
    }

    public static void StopTarget(object target) {
      if (target == null) { return; }
      deps.Remove(target);
    }

    // Runs an effect again with the tracking it had; a computed uses this when it is read while
    // dirty, which is why reading it costs nothing when nothing changed.
    public static void Rerun(int id) { RunPrepared(id); }

    public static int Flush() {
      if (queue.Count == 0) { return 0; }
      flushes++;
      int ran = 0;
      // a job can enqueue another (an effect that writes), so the queue is drained, not copied
      for (int guard = 0; guard < 100000 && queue.Count > 0; guard++) {
        Job job = queue[0];
        queue.RemoveAt(0);
        queued.Remove(job.Id);
        EffectRecord record;
        if (!effects.TryGetValue(job.Id, out record)) { continue; }
        RunPrepared(job.Id);
        ran++;
      }
      return ran;
    }

    internal static void Track(object target, string key) {
      if (active == 0 || target == null || key == null) { return; }
      Dictionary<string, List<int>> bag;
      if (!deps.TryGetValue(target, out bag)) {
        bag = new Dictionary<string, List<int>>(StringComparer.Ordinal);
        deps[target] = bag;
      }
      List<int> list;
      if (!bag.TryGetValue(key, out list)) {
        list = new List<int>(2);
        bag[key] = list;
      }
      if (list.Contains(active)) { return; }
      list.Add(active);
      EffectRecord record;
      if (effects.TryGetValue(active, out record) && record.Deps != null) {
        record.Deps.Add(new object[] { target, key });
      }
    }

    internal static void Trigger(object target, string key) {
      if (target == null || key == null) { return; }
      Dictionary<string, List<int>> bag;
      if (!deps.TryGetValue(target, out bag)) { return; }
      List<int> list;
      if (!bag.TryGetValue(key, out list)) { return; }
      // a copy: an effect may stop itself from inside its own run
      int[] ids = list.ToArray();
      for (int i = 0; i < ids.Length; i++) { Enqueue(ids[i]); }
    }

    private static void Enqueue(int id) {
      if (id <= 0 || queued.Contains(id)) { return; }
      EffectRecord record;
      if (!effects.TryGetValue(id, out record)) { return; }
      if (record.Scheduler != null) {
        // A computed marks itself dirty the moment a value it read moves, so a read that follows
        // the write answers the new value; only its readers are queued. Deferring this would let
        // a read between the write and the flush answer a value that is already stale.
        record.Scheduler();
        return;
      }
      Job job = new Job();
      job.Id = id;
      queue.Add(job);
      queued.Add(id);
    }

    private static void RunPrepared(int id) {
      EffectRecord record;
      if (!effects.TryGetValue(id, out record)) { return; }
      Unlink(id);
      runs++;
      int outer = active;
      active = id;
      try { record.Run(); }
      finally { active = outer; }
    }

    // Drops what the effect read last time and prunes the tables it leaves empty: this is what
    // keeps a long lived window from collecting keys it no longer reads.
    private static void Unlink(int id) {
      EffectRecord record;
      if (!effects.TryGetValue(id, out record)) { return; }
      if (record.Deps == null || record.Deps.Count == 0) { return; }
      for (int i = 0; i < record.Deps.Count; i++) {
        object[] pair = record.Deps[i];
        Dictionary<string, List<int>> bag;
        if (!deps.TryGetValue(pair[0], out bag)) { continue; }
        List<int> list;
        if (!bag.TryGetValue((string)pair[1], out list)) { continue; }
        list.Remove(id);
        if (list.Count == 0) { bag.Remove((string)pair[1]); }
        if (bag.Count == 0) { deps.Remove(pair[0]); }
      }
      record.Deps.Clear();
    }
  }
}
