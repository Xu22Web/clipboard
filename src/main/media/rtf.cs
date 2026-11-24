// src/main/media/rtf.cs - the picture blocks of an RTF document (see main/utils/media.ps1).
//
// Every {\pict ...} group becomes a marker, whatever it nests - Word writes the hex behind
// {\*\picprop{\sp{\sn shapeType}...}} chains, which no regex can follow without risking a
// backtracking stall on a 13 MB document. A brace counter is linear and exact.
//
// Compiled through src\main\index.cs; the namespace and the type name are unchanged.
using System;

namespace Cb {
  public static class Rtf {
    // Replaces every {\pict ...} group with a marker paragraph tall enough for the block the
    // card paints over it, and reports each block as a w,rows pair in document order.
    // \picwgoal / \pichgoal are twips (1/20 point) and \picw / \pich are pixels, so a picture
    // that states its size keeps its proportions instead of becoming one fixed rectangle.
    // One pass, no copy of a picture block: the control words are read inside [i,j] of the
    // original string, which is what keeps a 10 MB document off the seconds budget.
    public static string PadPictures(string text, string token, int lineHeight, int maxWidth, int minWidth, int defaultRows, out int[] boxes) {
      boxes = new int[0];
      if (string.IsNullOrEmpty(text) || lineHeight < 1 || maxWidth < 1) { return text; }
      int n = text.Length;
      System.Text.StringBuilder sb = null;
      System.Collections.Generic.List<int> found = new System.Collections.Generic.List<int>();
      int i = 0;
      int start = 0;
      while (i < n) {
        char c = text[i];
        if (c != '{' || i + 6 > n || string.CompareOrdinal(text, i, "{\\pict", 0, 6) != 0) { i++; continue; }
        int depth = 0;
        int j = i;
        while (j < n) {
          char d = text[j];
          if (d == '\\') { j += 2; continue; }
          if (d == '{') { depth++; }
          else if (d == '}') { depth--; if (depth == 0) { break; } }
          j++;
        }
        if (j >= n) { break; }
        if (sb == null) { sb = new System.Text.StringBuilder(n); }
        sb.Append(text, start, i - start);
        int picW = SizeIn(text, i, j, "\\picwgoal", "\\picw", 15);
        int picH = SizeIn(text, i, j, "\\pichgoal", "\\pich", 15);
        int w = maxWidth;
        int rows = defaultRows;
        if (picW > 0 && picH > 0) {
          if (picW < w) { w = picW; }
          if (w < minWidth) { w = minWidth; }
          long h = (long)picH * w / picW;
          rows = (int)((h + lineHeight - 1) / lineHeight);
          if (rows < 1) { rows = 1; }
          if (rows > 24) { rows = 24; }
        }
        if (w < minWidth) { w = minWidth; }
        sb.Append("\\par");
        sb.Append(token);
        for (int k = 0; k < rows; k++) { sb.Append("\\par"); }
        found.Add(w);
        found.Add(rows);
        i = j + 1;
        start = i;
      }
      if (sb == null) { return text; }
      sb.Append(text, start, n - start);
      boxes = found.ToArray();
      return sb.ToString();
    }

    // twips are twip/divisor pixels at 96 dpi (1 pt = 20 twips = 4/3 px), while \picw is
    // already a pixel count - the divisor says which control word answered
    private static int SizeIn(string text, int from, int to, string goal, string plain, int divisor) {
      int v = ValueIn(text, from, to, goal);
      if (v > 0) { return v / divisor; }
      return ValueIn(text, from, to, plain);
    }

    // first occurrence inside [from,to) of the control word followed by a number, so "\picw"
    // does not answer from inside "\picwgoal"
    private static int ValueIn(string text, int from, int to, string word) {
      int at = from;
      while (at < to) {
        at = text.IndexOf(word, at, to - at, System.StringComparison.OrdinalIgnoreCase);
        if (at < 0) { return 0; }
        int p = at + word.Length;
        int digits = p;
        if (p < to && text[p] == '-') { p++; }
        while (p < to && text[p] >= '0' && text[p] <= '9') { p++; }
        if (p > digits) {
          int v;
          if (int.TryParse(text.Substring(digits, p - digits), out v)) { return v; }
        }
        at = p;
      }
      return 0;
    }
  }
}
