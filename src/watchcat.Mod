MODULE watchcat;
IMPORT
  pipes, strTypes, time, Modules, Platform, Out, Strings := oocStrings, VT100, Files, SYSTEM;

CONST
  CommandMode = 0; FileMode = 1;
  defaultInterval = 2000; (* 2 seconds in milliseconds *)
  VERSION = "watchcat 1.0";
  cmdArgNum=16; cmdArgLen=256;

TYPE
  pstring = strTypes.pstring;
  StringArray = POINTER TO ARRAY OF pstring;

VAR
  mode: INTEGER; (* CommandMode or FileMode *)
  interval: INTEGER;
  filename: ARRAY 256 OF CHAR;
  clearScreen, showDiff, showTimestamp: BOOLEAN;
  commandArgs: StringArray;
  cmdCount: INTEGER;
  running: BOOLEAN;

PROCEDURE HandleInterrupt(signal: SYSTEM.INT32);
BEGIN
  running := FALSE;
  Out.String("Exiting watchcat..."); Out.Ln;
END HandleInterrupt;

PROCEDURE ParseInterval*(in: ARRAY OF CHAR): INTEGER;
VAR
  i: INTEGER; num: REAL; ch: CHAR;
BEGIN
  i := 0; num := 0.0;
  WHILE (in[i] >= "0") & (in[i] <= "9") OR (in[i] = ".") DO
    IF in[i] = "." THEN num := num * 10 + (ORD(in[i]) - 30H) / 10
    ELSE num := num * 10 + (ORD(in[i]) - 30H) END;
    INC(i)
  END;
  ch := CAP(in[i]);
  IF ch = "S" THEN num := num * 1000
  ELSIF ch = "M" THEN num := num * 60 * 1000
  ELSIF ch = "H" THEN num := num * 60 * 60 * 1000
  END;
  RETURN SHORT(ENTIER(num + 0.5))
END ParseInterval;

PROCEDURE ShowHelp;
BEGIN
  Out.String(VERSION); Out.Ln;
  Out.String("Usage: watchcat [OPTIONS] -- COMMAND [ARGS...]"); Out.Ln;
  Out.String("       watchcat [OPTIONS] -f FILENAME"); Out.Ln;
  Out.String("Options:"); Out.Ln;
  Out.String("  -n, --interval INTERVAL  Update interval (e.g., 2s, 500ms)"); Out.Ln;
  Out.String("  -f, --file FILENAME      Monitor file changes"); Out.Ln;
  Out.String("      --clear              Clear screen between updates"); Out.Ln;
  Out.String("      --no-clear           Do not clear screen between updates"); Out.Ln;
  Out.String("                           (In command mode, clear is default)"); Out.Ln;
  Out.String("                           (In file mode, no-clear is default)"); Out.Ln;
  Out.String("  -d, --diff               Highlight differences (useful for commands)"); Out.Ln;
  Out.String("  -t, --timestamp          Show timestamp when changes occur"); Out.Ln;
  Out.String("  --help                   Show this help"); Out.Ln;
END ShowHelp;

PROCEDURE ParseArgs*;
VAR
  i, j: INTEGER;
  arg: ARRAY cmdArgLen OF CHAR;
  newArgs: StringArray;
  clearScreenExplicit: BOOLEAN; (* if --clear/--no-clear was set *)
BEGIN
  i := 1; (* Start at 1 to skip program name *)
  mode := CommandMode;
  interval := defaultInterval;
  clearScreen := TRUE;
  clearScreenExplicit := FALSE;
  showDiff := FALSE;
  showTimestamp := FALSE;
  cmdCount := 0;
  NEW(commandArgs, cmdArgNum);
  FOR j := 0 TO cmdArgNum-1 DO NEW(commandArgs[j], cmdArgLen); END; (* Use j, not i *)

  WHILE i < Modules.ArgCount DO
    Modules.GetArg(i, arg);
    IF arg = "--" THEN
      (* Process command after -- *)
      i := i + 1;
      WHILE i < Modules.ArgCount DO
        Modules.GetArg(i, commandArgs[cmdCount]^);
        INC(cmdCount); INC(i);
        IF cmdCount >= LEN(commandArgs^) THEN
          (* Expand array if needed *)
          NEW(newArgs, cmdCount + cmdArgNum);
          FOR j := 0 TO cmdCount-1 DO newArgs[j] := commandArgs[j]; END;
          FOR j := cmdCount TO cmdCount + cmdArgNum-1 DO NEW(newArgs[j], cmdArgLen); END;
          commandArgs := newArgs;
        END;
      END;
    ELSIF (arg = "-n") OR (arg = "--interval") THEN
      INC(i);
      IF i < Modules.ArgCount THEN
        Modules.GetArg(i, arg);
        interval := ParseInterval(arg);
        INC(i);
      ELSE
        Out.String("Missing value for interval"); Out.Ln; HALT(1);
      END;
    ELSIF (arg = "-f") OR (arg = "--file") THEN
      INC(i);
      IF i < Modules.ArgCount THEN
        Modules.GetArg(i, filename);
        mode := FileMode;
        INC(i);
      ELSE
        Out.String("Missing filename"); Out.Ln; HALT(1);
      END;
    ELSIF (arg = "--no-clear") THEN
      clearScreen := FALSE;
      INC(i);
    ELSIF (arg = "--clear") THEN  (* Add a new explicit clear option *)
      clearScreen := TRUE;
      clearScreenExplicit := TRUE;
      INC(i);
    ELSIF (arg = "-d") OR (arg = "--diff") THEN
      showDiff := TRUE;
      INC(i);
    ELSIF (arg = "-t") OR (arg = "--timestamp") THEN
      showTimestamp := TRUE;
      INC(i);
    ELSIF (arg = "--help") THEN
      ShowHelp;
      HALT(0); (* Exit immediately after showing help *)
    ELSE
      Out.String("Unknown option: "); Out.String(arg); Out.Ln;
      HALT(1);
    END;
  END;
   IF (mode = FileMode) & ~clearScreenExplicit THEN
     clearScreen := FALSE; (* Default for file mode - no clear, like tail -f *)
  END;
END ParseArgs;

PROCEDURE GetCommandOutput(cmd: ARRAY OF CHAR): pstring;
VAR
  text: pipes.Text;
  buf: pstring;
  ch: CHAR;
  len: INTEGER;
  res: LONGINT;
BEGIN
  text := pipes.Popen(cmd, 'r');
  NEW(buf, 4096); len := 0;
  WHILE ~text.eof & (len < LEN(buf^) - 1) DO
    pipes.Read(text, ch);
    buf[len] := ch; INC(len);
  END;
  buf[len] := 0X;
  res := pipes.Pclose(text);
  RETURN buf;
END GetCommandOutput;

PROCEDURE DisplayOutput(new, old: ARRAY OF CHAR);
VAR
  year, month, day, hour, min, sec: LONGINT;
  areEqual: BOOLEAN;
BEGIN
  (* First check if strings are equal *)
  areEqual := Strings.Compare(new, old) = 0;
  
  IF clearScreen THEN
    VT100.ED(2);     (* Clear entire screen *)
    VT100.CUP(1, 1); (* Move cursor to top-left *)
  END;

  (* Show diff indicator if requested and content changed *)
  IF showDiff & (~areEqual) THEN
    (* Add timestamp if requested *)
    IF showTimestamp THEN
      time.Now(year, month, day, hour, min, sec);
      VT100.SetAttr(VT100.Reverse);
      Out.String("[Updated at ");
      Out.Int(hour, 2); Out.String(":");
      Out.Int(min, 2); Out.String(":");
      Out.Int(sec, 2);
      Out.String("]");
      VT100.SetAttr(VT100.ResetAll);
      Out.Ln;
    ELSE
      VT100.SetAttr(VT100.Reverse);
      Out.String("[CHANGED]");
      VT100.SetAttr(VT100.ResetAll);
      Out.Ln;
    END;
  END;

  Out.String(new);
  Out.Flush; (* Make sure output is displayed immediately *)
END DisplayOutput;

PROCEDURE MonitorCommand;
VAR
  lastOutput, newOutput: pstring;
  cmd: ARRAY 256 OF CHAR;
  i: INTEGER;
BEGIN
  cmd := "";
  FOR i := 0 TO cmdCount-1 DO
    IF i > 0 THEN Strings.Append(" ", cmd) END;
    Strings.Append(commandArgs[i]^, cmd);
  END;

  (* Initialize with first command execution *)
  lastOutput := GetCommandOutput(cmd);
  IF lastOutput # NIL THEN
    DisplayOutput(lastOutput^, "");
  END;
  
  WHILE running DO
    Platform.Delay(interval);
    newOutput := GetCommandOutput(cmd);
    
    IF newOutput # NIL THEN
      DisplayOutput(newOutput^, lastOutput^);
      lastOutput := newOutput;
    END;
  END;
END MonitorCommand;

PROCEDURE MonitorFile;
VAR
  file: Files.File;
  rider: Files.Rider;
  pos, size, lastSize: LONGINT;
  buf: ARRAY 4096 OF CHAR;
  lastBuf: ARRAY 4096 OF CHAR; (* Store previous content for diff comparison *)
  checkDelay: INTEGER;
  readLen, safeLen: LONGINT;
  idx: INTEGER;
BEGIN
  pos := 0;
  lastSize := 0;
  lastBuf[0] := 0X; (* Initialize as empty *)
  
  (* Short delay between file checks to prevent excessive CPU usage *)
  checkDelay := 100; (* 100ms *)
  
  IF clearScreen THEN
    VT100.ED(2);     (* Clear entire screen *)
    VT100.CUP(1, 1); (* Move cursor to top-left *)
  END;
  
  WHILE running DO
    file := Files.Old(filename);
    IF file = NIL THEN
      IF ~clearScreen THEN (* Only show error if not clearing screen *)
        Out.String("File not found: "); Out.String(filename); Out.Ln;
      END;
      Platform.Delay(interval);
    ELSE
      (* Get file size *)
      size := Files.Length(file);
      
      (* Check for changes *)
      IF size > pos THEN
        Files.Set(rider, file, pos);
        (* Calculate how many bytes to read safely *)
        IF size - pos > LEN(buf) - 1 THEN
          readLen := LEN(buf) - 1;
        ELSE
          readLen := size - pos;
        END;
        
        Files.ReadBytes(rider, buf, readLen);
        buf[readLen] := 0X;
        
        (* Direct output for file mode *)
        IF clearScreen THEN
          VT100.ED(2);
          VT100.CUP(1, 1);
          (* Read from beginning *)
          Files.Set(rider, file, 0);
          (* Calculate safe length for full file read *)
          IF size > LEN(buf) - 1 THEN
            safeLen := LEN(buf) - 1;
          ELSE
            safeLen := size;
          END;
          Files.ReadBytes(rider, buf, safeLen);
          buf[safeLen] := 0X;
          
          (* For clear mode, show full content with diff if requested *)
          DisplayOutput(buf, lastBuf);
          COPY(buf, lastBuf);
        ELSE
          (* Append mode - only output new content *)
          IF showDiff THEN
            (* In append mode with diff, show changes *)
            DisplayOutput(buf, lastBuf);
          ELSE
            (* Just append the new content without formatting *)
            idx := 0;
            WHILE idx < readLen DO
              Out.Char(buf[idx]);
              INC(idx);
            END;
            Out.Flush;
          END;
          COPY(buf, lastBuf);
        END;
        
        pos := size;
        lastSize := size;
      ELSIF size < lastSize THEN
        (* File was truncated, reset position *)
        pos := 0;
        lastSize := 0;
        IF clearScreen THEN
          VT100.ED(2);
          VT100.CUP(1, 1);
        ELSE
          VT100.SetAttr(VT100.Reverse);
          Out.String("[File truncated]");
          VT100.SetAttr(VT100.ResetAll);
          Out.Ln;
        END;
      END;
      
      Files.Close(file);
    END;
    
    Platform.Delay(checkDelay);
  END;
END MonitorFile;

BEGIN
  running := TRUE;
  Platform.SetInterruptHandler(HandleInterrupt);
  ParseArgs;

  IF mode = FileMode THEN
    MonitorFile;
  ELSIF cmdCount > 0 THEN
    MonitorCommand;
  ELSE
    Out.String("Error: No command or file specified"); Out.Ln;
    HALT(1);
  END;
END watchcat.
