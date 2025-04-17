MODULE watchcat;
IMPORT
  pipes, strTypes, Modules, Platform, Out, Strings := oocStrings, VT100, Files, SYSTEM;

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
  clearScreen, showDiff: BOOLEAN;
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
  Out.String("Options:"); Out.Ln;
  Out.String("  -n, --interval INTERVAL  Update interval (e.g., 2s, 500ms)"); Out.Ln;
  Out.String("  -f, --file FILENAME      Monitor file changes"); Out.Ln;
  Out.String("  -c, --clear              Clear screen between updates"); Out.Ln;
  Out.String("  -d, --diff               Highlight differences"); Out.Ln;
  Out.String("  --help                   Show this help"); Out.Ln;
END ShowHelp;

PROCEDURE ParseArgs*;
VAR
  i, j: INTEGER; (* Use j for the FOR loop *)
  arg: ARRAY cmdArgLen OF CHAR;
  newArgs: StringArray;
BEGIN
  i := 1; (* Start at 1 to skip program name *)
  mode := CommandMode;
  interval := defaultInterval;
  clearScreen := FALSE;
  showDiff := FALSE;
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
    ELSIF (arg = "-c") OR (arg = "--clear") THEN
      clearScreen := TRUE;
      INC(i);
    ELSIF (arg = "-d") OR (arg = "--diff") THEN
      showDiff := TRUE;
      INC(i);
    ELSIF (arg = "--help") THEN
      ShowHelp;
      HALT(0); (* Exit immediately after showing help *)
    ELSE
      Out.String("Unknown option: "); Out.String(arg); Out.Ln;
      HALT(1);
    END;
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
BEGIN
  IF clearScreen THEN
    VT100.ED(2);     (* Clear entire screen *)
    VT100.CUP(1, 1); (* Move cursor to top-left *)
  END;

  IF showDiff & (Strings.Compare(new, old) # 0) THEN
    VT100.SetAttr(VT100.Reverse);
    Out.String("[CHANGED]");
    VT100.SetAttr(VT100.ResetAll);
    Out.String(new);
  ELSE
    Out.String(new);
  END;
  Out.Ln;
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

  lastOutput := GetCommandOutput(cmd);
  IF lastOutput # NIL THEN
    DisplayOutput(lastOutput^, "");
  END;
  WHILE running DO
    Platform.Delay(interval);
    newOutput := GetCommandOutput(cmd);
    DisplayOutput(newOutput^, lastOutput^);
    lastOutput := newOutput;
  END;
END MonitorCommand;

PROCEDURE MonitorFile;
VAR
  file: Files.File;
  rider: Files.Rider;
  pos, size, lastSize: LONGINT;
  buf, lastBuf: ARRAY 4096 OF CHAR;  (* Add lastBuf to store previous content *)
  i: INTEGER;
  checkDelay: INTEGER;
  readLen: LONGINT;
BEGIN
  pos := 0;
  lastSize := 0;
  (* Initialize lastBuf as empty *)
  lastBuf[0] := 0X;
  
  (* Short delay between file checks to prevent excessive CPU usage *)
  checkDelay := 100; (* 100ms *)
  
  WHILE running DO
    (* First check if file exists *)
    file := Files.Old(filename);
    IF file = NIL THEN
      Out.String("File not found: "); Out.String(filename); Out.Ln;
      Platform.Delay(interval);
    ELSE
      (* Get file size *)
      size := Files.Length(file);
      
      (* Check for changes by size *)
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
        
        (* Call DisplayOutput instead of direct output *)
        DisplayOutput(buf, lastBuf);
        
        (* Save current content for next comparison *)
        COPY(buf, lastBuf);
        
        pos := size;
        lastSize := size;
      END;
      
      Files.Close(file);
    END;
    
    (* Rest of the code remains the same... *)
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
