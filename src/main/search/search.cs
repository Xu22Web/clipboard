// src\main\search\search.cs - the filter behind the search box (see lib\query.ps1).
//
// The panel asks for an answer on every typed character, and the PowerShell loop over the rows
// was the one part of that answer it could not make cheap: the same loop costs a couple of
// milliseconds warm and tens of them the first time a fresh process runs it. The heads arrive
// already cut to the length a row shows, so a match is an ordinal-ignore-case IndexOf over
// strings - the same rule Invoke-Query's plain path spells out.
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged, so nothing
// that calls Cb.Search had to be touched when the library was split into one file per block.
namespace Cb {
  public class Search {
    public const int HeadChars = 4096;

    // indices of the heads that contain every term and none of the excludes, in order
    public static int[] Match(string[] heads, string[] terms, string[] excludes) {
      if (heads == null) { return new int[0]; }
      System.Collections.Generic.List<int> keep = new System.Collections.Generic.List<int>(heads.Length);
      for (int i = 0; i < heads.Length; i++) {
        string head = heads[i];
        if (head == null) { head = ""; }
        bool ok = true;
        if (terms != null) {
          for (int t = 0; t < terms.Length; t++) {
            string term = terms[t];
            if (term == null || term.Length == 0) { continue; }
            if (head.IndexOf(term, System.StringComparison.OrdinalIgnoreCase) < 0) { ok = false; break; }
          }
        }
        if (ok && excludes != null) {
          for (int t = 0; t < excludes.Length; t++) {
            string term = excludes[t];
            if (term == null || term.Length == 0) { continue; }
            if (head.IndexOf(term, System.StringComparison.OrdinalIgnoreCase) >= 0) { ok = false; break; }
          }
        }
        if (ok) { keep.Add(i); }
      }
      return keep.ToArray();
    }

    // the rows those indices name, in the same order; the caller keeps its own array
    public static object[] Pick(object[] rows, int[] indices) {
      if (rows == null || indices == null) { return new object[0]; }
      object[] picked = new object[indices.Length];
      for (int i = 0; i < indices.Length; i++) { picked[i] = rows[indices[i]]; }
      return picked;
    }
  }
}
