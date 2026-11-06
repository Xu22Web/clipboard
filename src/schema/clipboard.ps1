# schema/clipboard.ps1 - what clipboard.ini may contain.
#
# The field names are the ones utils/schema.ps1 documents; "Ref" points at the variable the
# value drives, so Apply-Config (lib/config.ps1) writes through it and there is no second
# table of defaults. The schema file is dot-sourced, which is why a Ref can name the tool's
# own variables - the minifier renames them, so a name string would address nothing.
#
# Default is the value in its file spelling (1 / 0, a plain number): it is what `config init`
# writes and what every reader falls back to.
@{
  Name        = 'clipboard'
  File        = 'clipboard.ini'
  Description = 'the program settings: capture, storage, panel and panel behaviour'
  Version     = 1
  Properties  = [ordered]@{
    DataDir           = @{ Type = 'string'; Default = ''; Description = 'write location, empty = <script dir>\data' }
    Hotkey            = @{ Type = 'hotkey'; Ref = [ref]$script:Hotkey; Default = 'Ctrl+Alt+V'; Description = 'global hotkey' }
    HotkeyFallbacks   = @{ Type = 'string'; Ref = [ref]$script:HotkeyFallbacks; Default = ''; Description = 'comma separated fallback chain, empty = the built-in chain' }
    PasteKeys         = @{ Type = 'string'; Ref = [ref]$script:PasteKeys; Default = '^v'; Description = 'SendKeys sent after picking' }
    ModReleaseTimeout = @{ Type = 'int'; Ref = [ref]$script:ModReleaseTimeout; Default = 1200; Minimum = 0; Maximum = 60000; Description = 'ms to wait for the modifiers to be released' }
    PasteSettle       = @{ Type = 'int'; Ref = [ref]$script:PasteSettle; Default = 80; Minimum = 0; Maximum = 10000; Description = 'ms to wait before sending PasteKeys' }
    MaxItems          = @{ Type = 'int'; Ref = [ref]$script:MaxItems; Default = 300; Minimum = 1; Maximum = 100000; Description = 'entry cap (rows a mark protects are exempt)' }
    MaxBytes          = @{ Type = 'int'; Ref = [ref]$script:MaxBytes; Default = 204800; Minimum = 1; Maximum = 104857600; Description = 'per entry size cap' }
    MaxTotal          = @{ Type = 'int'; Ref = [ref]$script:MaxTotal; Default = 4194304; Minimum = 1024; Maximum = 1073741824; Description = 'total store size cap in bytes' }
    MaxMediaTotal     = @{ Type = 'int'; Ref = [ref]$script:MaxMediaTotal; Default = 134217728; Minimum = 0; Maximum = 2147483647; Description = 'size budget for images and formatted-text files in bytes, 0 = unlimited' }
    CaptureImages     = @{ Type = 'bool'; Ref = [ref]$script:CaptureImages; Default = 1; Description = '1 = capture pictures from the clipboard' }
    MaxImageBytes     = @{ Type = 'int'; Ref = [ref]$script:MaxImageBytes; Default = 16777216; Minimum = 1024; Maximum = 104857600; Description = 'per image cap in bytes; larger pictures are not captured' }
    CaptureRich       = @{ Type = 'bool'; Ref = [ref]$script:CaptureRich; Default = 1; Description = '1 = remember the html / rtf of formatted text' }
    MaxRichBytes      = @{ Type = 'int'; Ref = [ref]$script:MaxRichBytes; Default = 20971520; Minimum = 1024; Maximum = 67108864; Description = 'cap per block (html and rtf counted apart); a block over it is dropped on its own' }
    MaxRichImages     = @{ Type = 'int'; Ref = [ref]$script:MaxRichImages; Default = 4194304; Minimum = 0; Maximum = 10485760; Description = 'inline a temp-file picture in the html when it is at most this large, 0 = never' }
    PasteRich         = @{ Type = 'bool'; Ref = [ref]$script:PasteRich; Default = 1; Description = '1 = paste the formatting back, 0 = always paste plain text' }
    PasteFilesAsText  = @{ Type = 'bool'; Ref = [ref]$script:PasteFilesAsText; Default = 1; Description = '1 = a file list also goes on the clipboard as text (paths), 0 = file list only' }
    AppRules          = @{ Type = 'apprule'; Ref = [ref]$script:AppRules; Default = ''; Description = 'per program paste behaviour: name:plain|rich|no-paste, separated by ; (a name is a process, * is the rest)' }
    BlobThreshold     = @{ Type = 'int'; Ref = [ref]$script:BlobChars; Default = 32768; Minimum = 0; Maximum = 1048576; Description = 'payloads above this many chars live in data\blobs, 0 = never' }
    Interval          = @{ Type = 'int'; Ref = [ref]$script:Interval; Default = 300; Minimum = 50; Maximum = 60000; Description = 'clipboard poll interval in ms' }
    NoPaste           = @{ Type = 'bool'; Ref = [ref]$script:NoPaste; Default = 0; Description = '1 = clipboard only, never inject a paste' }
    Balloon           = @{ Type = 'bool'; Ref = [ref]$script:ShowBalloon; Default = 1; Description = '1 = tray balloon on startup' }
    Theme             = @{ Type = 'theme'; Ref = [ref]$script:Theme; Default = 'win11-dark'; Description = 'theme name = the file in themes\ (win11-dark.ini / win11-light.ini)' }
    ExcludePattern    = @{ Type = 'regex'; Ref = [ref]$script:ExcludePattern; Default = ''; Description = 'matching text is never saved' }
    WindowWidth       = @{ Type = 'int'; Ref = [ref]$script:WinWidth; Default = 700; Minimum = 460; Maximum = 4000; Description = 'panel width (96 dpi baseline)' }
    Rows              = @{ Type = 'int'; Ref = [ref]$script:Rows; Default = 10; Minimum = 3; Maximum = 50; Description = 'visible rows; the height follows from it (rows x 40 + 110)' }
    WindowLeft        = @{ Type = 'int'; Ref = [ref]$script:WinLeft; Default = ''; Minimum = -32768; Maximum = 32767; Description = 'panel left, empty = centred' }
    WindowTop         = @{ Type = 'int'; Ref = [ref]$script:WinTop; Default = ''; Minimum = -32768; Maximum = 32767; Description = 'panel top, empty = centred' }
    SaveWindowWidth   = @{ Type = 'bool'; Ref = [ref]$script:SaveWinWidth; Default = 0; Description = '1 = write the width you dragged back to this file' }
    SaveWindowPos     = @{ Type = 'bool'; Ref = [ref]$script:SaveWinPos; Default = 0; Description = '1 = write the moved panel back to this file' }
    ShowTime          = @{ Type = 'bool'; Ref = [ref]$script:ShowTime; Default = 1; Description = '1 = relative time column' }
    ShowTypeIcon      = @{ Type = 'bool'; Ref = [ref]$script:ShowTypeIcon; Default = 1; Description = '1 = show the row icon a plugin provides (none without one)' }
    ShowThumbnails    = @{ Type = 'bool'; Ref = [ref]$script:ShowThumbnails; Default = 1; Description = '1 = show a small picture in the icon slot of a picture or formatted-text row' }
    Highlight         = @{ Type = 'bool'; Ref = [ref]$script:HighlightOn; Default = 1; Description = '1 = highlight search matches' }
    HighlightMaxBytes = @{ Type = 'int'; Ref = [ref]$script:HighlightMax; Default = 8192; Minimum = 0; Maximum = 1048576; Description = 'skip highlight above this size (0 = always)' }
    ShowNewlineMarker = @{ Type = 'bool'; Ref = [ref]$script:ShowNewlineMarker; Default = 1; Description = '1 = show <NL> for line breaks, 0 = collapse to a space' }
    PreviewHover      = @{ Type = 'bool'; Ref = [ref]$script:PreviewHover; Default = 1; Description = '1 = hover preview card, 0 = no card at all' }
    PreviewDelay      = @{ Type = 'int'; Ref = [ref]$script:PreviewDelay; Default = 350; Minimum = 0; Maximum = 5000; Description = 'ms the cursor rests on a row before the card appears' }
    PreviewChars      = @{ Type = 'int'; Ref = [ref]$script:PreviewChars; Default = 6000; Minimum = 200; Maximum = 200000; Description = 'characters of an entry the card reads' }
    Undo              = @{ Type = 'bool'; Ref = [ref]$script:UndoOn; Default = 1; Description = '1 = Ctrl+Z undoes the last delete' }
    DpiAware          = @{ Type = 'bool'; Ref = [ref]$script:DpiAware; Default = 1; Description = '1 = per-monitor DPI aware rendering' }
    ScrollLines       = @{ Type = 'int'; Ref = [ref]$script:ScrollLines; Default = 0; Minimum = -1; Maximum = 50; Description = 'wheel step in rows (0 = follow the system)' }
    Animations        = @{ Type = 'bool'; Ref = [ref]$script:Animations; Default = 1; Description = '1 = hover / selection / scrollbar transitions, 0 = instant' }
    Autostart         = @{ Type = 'bool'; Ref = [ref]$script:Autostart; Default = 1; Description = '1 = install creates the logon shortcut (serve)' }
    DesktopShortcut   = @{ Type = 'bool'; Ref = [ref]$script:DesktopShortcut; Default = 1; Description = '1 = install creates the desktop shortcut (ui)' }
    Plugins           = @{ Type = 'list'; Default = ''; Description = 'comma separated plugin names to load (default: every plugin in the plugins folder)' }
  }
  # a plugin declares its own Settings and registers them as <plugin>.<Key> when it loads
  ExtraSections = @{ Type = 'any'; Description = 'plugin settings: <plugin>.<Key>, or [<plugin>] + <Key>' }
}
