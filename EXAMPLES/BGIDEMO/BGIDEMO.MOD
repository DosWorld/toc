MODULE BGIDemo;

IMPORT Graph, Crt, Random, Math, Strings, Out;

CONST
  NumFonts = 5;
  NumLineStyles = 5;
  NumFillStyles = 12;
  NumTextDirect = 2;
  NumHorizJust = 3;
  NumVertJust = 3;

TYPE
  NameStr = ARRAY 16 OF CHAR;
  FontNameArr = ARRAY NumFonts OF NameStr;
  LineStyleNameArr = ARRAY NumLineStyles OF NameStr;
  FillStyleNameArr = ARRAY NumFillStyles OF NameStr;
  TextDirectNameArr = ARRAY NumTextDirect OF NameStr;
  JustNameArr = ARRAY NumHorizJust OF NameStr;
  Polygon12 = ARRAY 12 OF Graph.PointType;
  Polygon5 = ARRAY 5 OF Graph.PointType;
  Poly15 = ARRAY 15 OF Graph.PointType;
  BarHeightArr7 = ARRAY 7 OF BYTE;
  BarHeightArr5 = ARRAY 5 OF BYTE;
  StylesArr5 = ARRAY 5 OF BYTE;
  Word5Arr = ARRAY 5 OF WORD;

VAR
  Fonts: FontNameArr;
  LineStyles: LineStyleNameArr;
  FillStyles: FillStyleNameArr;
  TextDirect: TextDirectNameArr;
  HorizJust: JustNameArr;
  VertJust: JustNameArr;

  GraphDriver: INTEGER;
  GraphMode: INTEGER;
  MaxX, MaxY: WORD;
  ErrorCode: INTEGER;
  MaxColor: WORD;

  seed: LONGINT;

PROCEDURE Delay(ms: INTEGER);
  VAR r: SYSTEM.Registers; us: LONGINT;
BEGIN
  IF ms <= 0 THEN RETURN END;
  us := LONGINT(ms) * 1000;
  r.AX := 8600H;
  r.CX := INTEGER(SYSTEM.LSR(us, 16));
  r.DX := INTEGER(SYSTEM.AND(us, 0FFFFH));
  r.DS := SYSTEM.GetDS(); r.ES := SYSTEM.GetES();
  SYSTEM.Intr(15H, r)
END Delay;

PROCEDURE InitTables;
BEGIN
  Fonts[0] := "DefaultFont";
  Fonts[1] := "TriplexFont";
  Fonts[2] := "SmallFont";
  Fonts[3] := "SansSerifFont";
  Fonts[4] := "GothicFont";

  LineStyles[0] := "SolidLn";
  LineStyles[1] := "DottedLn";
  LineStyles[2] := "CenterLn";
  LineStyles[3] := "DashedLn";
  LineStyles[4] := "UserBitLn";

  FillStyles[0] := "EmptyFill";
  FillStyles[1] := "SolidFill";
  FillStyles[2] := "LineFill";
  FillStyles[3] := "LtSlashFill";
  FillStyles[4] := "SlashFill";
  FillStyles[5] := "BkSlashFill";
  FillStyles[6] := "LtBkSlashFill";
  FillStyles[7] := "HatchFill";
  FillStyles[8] := "XHatchFill";
  FillStyles[9] := "InterleaveFill";
  FillStyles[10] := "WideDotFill";
  FillStyles[11] := "CloseDotFill";

  TextDirect[0] := "HorizDir";
  TextDirect[1] := "VertDir";

  HorizJust[0] := "LeftText";
  HorizJust[1] := "CenterText";
  HorizJust[2] := "RightText";

  VertJust[0] := "BottomText";
  VertJust[1] := "CenterText";
  VertJust[2] := "TopText"
END InitTables;

PROCEDURE Int2Str(L: LONGINT; VAR s: ARRAY OF CHAR);
BEGIN
  Strings.Str(L, s)
END Int2Str;

PROCEDURE RandColor(): WORD;
BEGIN
  RETURN Random.SeedValue(seed, MaxColor) + 1
END RandColor;

PROCEDURE DefaultColors;
BEGIN
  Graph.SetColor(MaxColor)
END DefaultColors;

PROCEDURE DrawBorder;
  VAR vp: Graph.ViewPortType;
BEGIN
  DefaultColors;
  Graph.SetLineStyle(Graph.SolidLn, 0, Graph.NormWidth);
  Graph.GetViewSettings(vp);
  Graph.Rectangle(0, 0, vp.x2 - vp.x1, vp.y2 - vp.y1)
END DrawBorder;

PROCEDURE FullPort;
BEGIN
  Graph.SetViewPort(0, 0, INTEGER(MaxX), INTEGER(MaxY), TRUE)
END FullPort;

PROCEDURE MainWindow(Header: ARRAY OF CHAR);
  VAR th: WORD;
BEGIN
  DefaultColors;
  Graph.ClearDevice;
  Graph.SetTextStyle(Graph.DefaultFont, Graph.HorizDir, 1);
  Graph.SetTextJustify(Graph.CenterText, Graph.TopText);
  FullPort;
  Graph.OutTextXY(INTEGER(MaxX DIV 2), 2, Header);
  th := Graph.TextHeight("M");
  Graph.SetViewPort(0, INTEGER(th + 4), INTEGER(MaxX), INTEGER(MaxY - (th + 4)), TRUE);
  DrawBorder;
  Graph.SetViewPort(1, INTEGER(th + 5), INTEGER(MaxX - 1), INTEGER(MaxY - (th + 5)), TRUE)
END MainWindow;

PROCEDURE StatusLine(Msg: ARRAY OF CHAR);
  VAR th: WORD;
BEGIN
  FullPort;
  DefaultColors;
  Graph.SetTextStyle(Graph.DefaultFont, Graph.HorizDir, 1);
  Graph.SetTextJustify(Graph.CenterText, Graph.TopText);
  Graph.SetLineStyle(Graph.SolidLn, 0, Graph.NormWidth);
  Graph.SetFillStyle(Graph.EmptyFill, 0);
  th := Graph.TextHeight("M");
  Graph.Bar(0, INTEGER(MaxY - (th + 4)), INTEGER(MaxX), INTEGER(MaxY));
  Graph.Rectangle(0, INTEGER(MaxY - (th + 4)), INTEGER(MaxX), INTEGER(MaxY));
  Graph.OutTextXY(INTEGER(MaxX DIV 2), INTEGER(MaxY - (th + 2)), Msg);
  Graph.SetViewPort(1, INTEGER(th + 5), INTEGER(MaxX - 1), INTEGER(MaxY - (th + 5)), TRUE)
END StatusLine;

PROCEDURE WaitToGo;
  VAR ch: CHAR;
BEGIN
  StatusLine("Esc aborts or press a key...");
  REPEAT UNTIL Crt.KeyPressed();
  ch := Crt.ReadKey();
  IF ch = 0X THEN ch := Crt.ReadKey() END;
  IF ch = 27X THEN
    SYSTEM.Halt(0)
  ELSE
    Graph.ClearDevice
  END
END WaitToGo;

PROCEDURE GetDriverAndMode(VAR DriveStr, ModeStr: ARRAY OF CHAR);
BEGIN
  Graph.GetDriverName(DriveStr);
  Graph.GetModeName(Graph.GetGraphMode(), ModeStr)
END GetDriverAndMode;

PROCEDURE Initialize;
  VAR PathToDriver: ARRAY 80 OF CHAR;
BEGIN
  Crt.DirectVideo := FALSE;
  PathToDriver := "";
  REPEAT
    GraphDriver := Graph.Detect;
    Graph.InitGraph(GraphDriver, GraphMode, PathToDriver);
    ErrorCode := Graph.GraphResult();
    IF ErrorCode # Graph.grOk THEN
      IF ErrorCode = Graph.grFileNotFound THEN
        SYSTEM.Halt(1)
      ELSE
        SYSTEM.Halt(1)
      END
    END
  UNTIL ErrorCode = Graph.grOk;
  MaxColor := Graph.GetMaxColor();
  MaxX := WORD(Graph.GetMaxX());
  MaxY := WORD(Graph.GetMaxY())
END Initialize;

PROCEDURE WriteOut(x: INTEGER; VAR y: WORD; s: ARRAY OF CHAR);
BEGIN
  Graph.OutTextXY(x, INTEGER(y), s);
  INC(y, Graph.TextHeight("M") + 2)
END WriteOut;

PROCEDURE ReportStatus;
  CONST X = 10;
  VAR
    ViewInfo: Graph.ViewPortType;
    LineInfo: Graph.LineSettingsType;
    FillInfo: Graph.FillSettingsType;
    TextInfo: Graph.TextSettingsType;
    Palette: Graph.PaletteType;
    DriverStr, ModeStr: ARRAY 40 OF CHAR;
    Y: WORD;
    line, num1, num2, num3, num4: ARRAY 80 OF CHAR;
BEGIN
  GetDriverAndMode(DriverStr, ModeStr);
  Graph.GetViewSettings(ViewInfo);
  Graph.GetLineSettings(LineInfo);
  Graph.GetFillSettings(FillInfo);
  Graph.GetTextSettings(TextInfo);
  Graph.GetPalette(Palette);

  Y := 4;
  MainWindow("Status report after InitGraph");
  Graph.SetTextJustify(Graph.LeftText, Graph.TopText);

  line := "Graphics device    : "; Strings.Append(DriverStr, line);
  WriteOut(X, Y, line);

  line := "Graphics mode      : "; Strings.Append(ModeStr, line);
  WriteOut(X, Y, line);

  Int2Str(Graph.GetMaxX(), num1); Int2Str(Graph.GetMaxY(), num2);
  line := "Screen resolution  : (0, 0, "; Strings.Append(num1, line);
  Strings.Append(", ", line); Strings.Append(num2, line); Strings.Append(")", line);
  WriteOut(X, Y, line);

  Int2Str(ViewInfo.x1, num1); Int2Str(ViewInfo.y1, num2);
  Int2Str(ViewInfo.x2, num3); Int2Str(ViewInfo.y2, num4);
  line := "Current view port  : ("; Strings.Append(num1, line);
  Strings.Append(", ", line); Strings.Append(num2, line);
  Strings.Append(", ", line); Strings.Append(num3, line);
  Strings.Append(", ", line); Strings.Append(num4, line); Strings.Append(")", line);
  WriteOut(X, Y, line);

  IF ViewInfo.Clip THEN
    WriteOut(X, Y, "Clipping           : ON")
  ELSE
    WriteOut(X, Y, "Clipping           : OFF")
  END;

  Int2Str(Graph.GetX(), num1); Int2Str(Graph.GetY(), num2);
  line := "Current position   : ("; Strings.Append(num1, line);
  Strings.Append(", ", line); Strings.Append(num2, line); Strings.Append(")", line);
  WriteOut(X, Y, line);

  Int2Str(Palette.Size, num1);
  line := "Palette entries    : "; Strings.Append(num1, line);
  WriteOut(X, Y, line);

  Int2Str(Graph.GetMaxColor(), num1);
  line := "GetMaxColor        : "; Strings.Append(num1, line);
  WriteOut(X, Y, line);

  Int2Str(Graph.GetColor(), num1);
  line := "Current color      : "; Strings.Append(num1, line);
  WriteOut(X, Y, line);

  line := "Line style         : "; Strings.Append(LineStyles[LineInfo.LineStyle], line);
  WriteOut(X, Y, line);

  Int2Str(LineInfo.Thickness, num1);
  line := "Line thickness     : "; Strings.Append(num1, line);
  WriteOut(X, Y, line);

  line := "Current fill style : "; Strings.Append(FillStyles[FillInfo.Pattern], line);
  WriteOut(X, Y, line);

  Int2Str(FillInfo.Color, num1);
  line := "Current fill color : "; Strings.Append(num1, line);
  WriteOut(X, Y, line);

  line := "Current font       : "; Strings.Append(Fonts[TextInfo.Font], line);
  WriteOut(X, Y, line);

  line := "Text direction     : "; Strings.Append(TextDirect[TextInfo.Direction], line);
  WriteOut(X, Y, line);

  Int2Str(TextInfo.CharSize, num1);
  line := "Character size     : "; Strings.Append(num1, line);
  WriteOut(X, Y, line);

  line := "Horizontal justify : "; Strings.Append(HorizJust[TextInfo.Horiz], line);
  WriteOut(X, Y, line);

  line := "Vertical justify   : "; Strings.Append(VertJust[TextInfo.Vert], line);
  WriteOut(X, Y, line);

  WaitToGo
END ReportStatus;

PROCEDURE FillEllipsePlay;
  CONST MaxFillStyles = 12;
  VAR MaxRadius: WORD; FillColor: WORD;
BEGIN
  MainWindow("FillEllipse demonstration");
  StatusLine("Esc aborts or press a key");
  MaxRadius := MaxY DIV 10;
  Graph.SetLineStyle(Graph.SolidLn, 0, Graph.NormWidth);
  REPEAT
    FillColor := RandColor();
    Graph.SetColor(FillColor);
    Graph.SetFillStyle(Random.SeedValue(seed, MaxFillStyles), FillColor);
    Graph.FillEllipse(INTEGER(Random.SeedValue(seed, MaxX)), INTEGER(Random.SeedValue(seed, MaxY)),
                       Random.SeedValue(seed, MaxRadius), Random.SeedValue(seed, MaxRadius))
  UNTIL Crt.KeyPressed();
  WaitToGo
END FillEllipsePlay;

PROCEDURE SectorPlay;
  CONST MaxFillStyles = 12;
  VAR MaxRadius: WORD; FillColor: WORD; EndAngle: WORD;
BEGIN
  MainWindow("Sector demonstration");
  StatusLine("Esc aborts or press a key");
  MaxRadius := MaxY DIV 10;
  Graph.SetLineStyle(Graph.SolidLn, 0, Graph.NormWidth);
  REPEAT
    FillColor := RandColor();
    Graph.SetColor(FillColor);
    Graph.SetFillStyle(Random.SeedValue(seed, MaxFillStyles), FillColor);
    EndAngle := Random.SeedValue(seed, 360);
    Graph.Sector(INTEGER(Random.SeedValue(seed, MaxX)), INTEGER(Random.SeedValue(seed, MaxY)),
                 Random.SeedValue(seed, EndAngle), EndAngle,
                 Random.SeedValue(seed, MaxRadius), Random.SeedValue(seed, MaxRadius))
  UNTIL Crt.KeyPressed();
  WaitToGo
END SectorPlay;

PROCEDURE WriteModePlay;
  CONST DelayValue = 50;
  VAR
    ViewInfo: Graph.ViewPortType;
    Color: WORD;
    Left, Top, Right, Bottom: INTEGER;
    Step: INTEGER;
BEGIN
  MainWindow("SetWriteMode demonstration");
  StatusLine("Esc aborts or press a key");
  Graph.GetViewSettings(ViewInfo);
  Left := 0; Top := 0;
  Right := ViewInfo.x2 - ViewInfo.x1;
  Bottom := ViewInfo.y2 - ViewInfo.y1;
  Step := Bottom DIV 50;
  Graph.SetColor(Graph.GetMaxColor());
  Graph.Line(Left, Top, Right, Bottom);
  Graph.Line(Left, Bottom, Right, Top);
  Graph.SetWriteMode(Graph.XORPut);
  REPEAT
    Graph.Line(Left, Top, Right, Bottom);
    Graph.Line(Left, Bottom, Right, Top);
    Graph.Rectangle(Left, Top, Right, Bottom);
    Delay(DelayValue);
    Graph.Line(Left, Top, Right, Bottom);
    Graph.Line(Left, Bottom, Right, Top);
    Graph.Rectangle(Left, Top, Right, Bottom);
    IF (Left + Step < Right) & (Top + Step < Bottom) THEN
      INC(Left, Step); INC(Top, Step); DEC(Right, Step); DEC(Bottom, Step)
    ELSE
      Color := RandColor();
      Graph.SetColor(Color);
      Left := 0; Top := 0;
      Right := ViewInfo.x2 - ViewInfo.x1;
      Bottom := ViewInfo.y2 - ViewInfo.y1
    END
  UNTIL Crt.KeyPressed();
  Graph.SetWriteMode(Graph.CopyPut);
  WaitToGo
END WriteModePlay;

PROCEDURE AdjAsp(Value, Xasp, Yasp: INTEGER): INTEGER;
BEGIN
  RETURN INTEGER((LONGINT(Value) * LONGINT(Xasp)) DIV LONGINT(Yasp))
END AdjAsp;

PROCEDURE AspectRatioPlay;
  VAR
    ViewInfo: Graph.ViewPortType;
    CenterX, CenterY: INTEGER;
    Radius: WORD;
    Xasp, Yasp: WORD;
    i: INTEGER;
    RadiusStep: WORD;
BEGIN
  MainWindow("SetAspectRatio demonstration");
  Graph.GetViewSettings(ViewInfo);
  CenterX := (ViewInfo.x2 - ViewInfo.x1) DIV 2;
  CenterY := (ViewInfo.y2 - ViewInfo.y1) DIV 2;
  Radius := WORD(3 * ((ViewInfo.y2 - ViewInfo.y1) DIV 5));
  RadiusStep := Radius DIV 30;
  Graph.Circle(CenterX, CenterY, Radius);
  Graph.GetAspectRatio(Xasp, Yasp);
  FOR i := 1 TO 30 DO
    Graph.SetAspectRatio(Xasp, WORD(INTEGER(Yasp) + (i * INTEGER(MaxX))));
    Graph.Circle(CenterX, CenterY, Radius);
    DEC(Radius, RadiusStep)
  END;
  INC(Radius, RadiusStep * 30);
  FOR i := 1 TO 30 DO
    Graph.SetAspectRatio(WORD(INTEGER(Xasp) + (i * INTEGER(MaxX))), Yasp);
    IF Radius > RadiusStep THEN DEC(Radius, RadiusStep) END;
    Graph.Circle(CenterX, CenterY, Radius)
  END;
  Graph.SetAspectRatio(Xasp, Yasp);
  WaitToGo
END AspectRatioPlay;

PROCEDURE TextPlay;
  VAR
    Size: INTEGER;
    W, H, X, Y: WORD;
    ViewInfo: Graph.ViewPortType;
    numstr: ARRAY 16 OF CHAR;
    s: ARRAY 40 OF CHAR;
BEGIN
  MainWindow("SetTextJustify / SetUserCharSize demo");
  Graph.GetViewSettings(ViewInfo);
  Graph.SetTextStyle(Graph.TriplexFont, Graph.VertDir, 4);
  Y := WORD(ViewInfo.y2 - ViewInfo.y1) - 2;
  Graph.SetTextJustify(Graph.CenterText, Graph.BottomText);
  Graph.OutTextXY(INTEGER(2 * Graph.TextWidth("M")), INTEGER(Y), "Vertical");
  Graph.SetTextStyle(Graph.TriplexFont, Graph.HorizDir, 4);
  Graph.SetTextJustify(Graph.LeftText, Graph.TopText);
  Graph.OutTextXY(INTEGER(2 * Graph.TextWidth("M")), 2, "Horizontal");
  Graph.SetTextJustify(Graph.CenterText, Graph.CenterText);
  X := WORD(ViewInfo.x2 - ViewInfo.x1) DIV 2;
  Y := Graph.TextHeight("H");
  H := 0;
  FOR Size := 1 TO 4 DO
    Graph.SetTextStyle(Graph.TriplexFont, Graph.HorizDir, WORD(Size));
    H := Graph.TextHeight("M");
    W := Graph.TextWidth("M");
    INC(Y, H);
    s := "Size "; Int2Str(Size, numstr); Strings.Append(numstr, s);
    Graph.OutTextXY(INTEGER(X), INTEGER(Y), s)
  END;
  INC(Y, H DIV 2);
  Graph.SetTextJustify(Graph.CenterText, Graph.TopText);
  Graph.SetUserCharSize(5, 6, 3, 2);
  Graph.SetTextStyle(Graph.TriplexFont, Graph.HorizDir, Graph.UserCharSize);
  Graph.OutTextXY(INTEGER(WORD(ViewInfo.x2 - ViewInfo.x1) DIV 2), INTEGER(Y), "User defined size!");
  WaitToGo
END TextPlay;

PROCEDURE TextDump;
  VAR
    CGASizes, NormSizes: Word5Arr;
    Font: INTEGER;
    ViewInfo: Graph.ViewPortType;
    Ch: CHAR;
    chs: ARRAY 2 OF CHAR;
    gx, gy: INTEGER;
BEGIN
  CGASizes[0] := 1; CGASizes[1] := 3; CGASizes[2] := 7; CGASizes[3] := 3; CGASizes[4] := 3;
  NormSizes[0] := 1; NormSizes[1] := 4; NormSizes[2] := 7; NormSizes[3] := 4; NormSizes[4] := 4;

  FOR Font := 0 TO 4 DO
    MainWindow(Fonts[Font]);
    Graph.GetViewSettings(ViewInfo);
    Graph.SetTextJustify(Graph.LeftText, Graph.TopText);
    Graph.MoveTo(2, 3);
    IF Font = Graph.DefaultFont THEN
      Graph.SetTextStyle(WORD(Font), Graph.HorizDir, 1);
      Ch := 0X;
      REPEAT
        chs[0] := Ch; chs[1] := 0X;
        Graph.OutText(chs);
        gx := Graph.GetX(); gy := Graph.GetY();
        IF (gx + INTEGER(Graph.TextWidth("M"))) > (ViewInfo.x2 - ViewInfo.x1) THEN
          Graph.MoveTo(2, gy + INTEGER(Graph.TextHeight("M")) + 3)
        END;
        Ch := CHR(ORD(Ch) + 1)
      UNTIL ORD(Ch) >= 255
    ELSE
      IF MaxY < 200 THEN
        Graph.SetTextStyle(WORD(Font), Graph.HorizDir, CGASizes[Font])
      ELSE
        Graph.SetTextStyle(WORD(Font), Graph.HorizDir, NormSizes[Font])
      END;
      Ch := "!";
      REPEAT
        chs[0] := Ch; chs[1] := 0X;
        Graph.OutText(chs);
        gx := Graph.GetX(); gy := Graph.GetY();
        IF (gx + INTEGER(Graph.TextWidth("M"))) > (ViewInfo.x2 - ViewInfo.x1) THEN
          Graph.MoveTo(2, gy + INTEGER(Graph.TextHeight("M")) + 3)
        END;
        Ch := CHR(ORD(Ch) + 1)
      UNTIL ORD(Ch) >= 255
    END;
    WaitToGo
  END
END TextDump;

PROCEDURE LineToPlay;
  CONST MaxPoints = 15;
  VAR
    Points: Poly15;
    ViewInfo: Graph.ViewPortType;
    I, J: INTEGER;
    CenterX, CenterY: INTEGER;
    Radius: WORD;
    StepAngle: WORD;
    Xasp, Yasp: WORD;
    Radians: REAL;
BEGIN
  MainWindow("MoveTo, LineTo demonstration");
  Graph.GetAspectRatio(Xasp, Yasp);
  Graph.GetViewSettings(ViewInfo);
  CenterX := (ViewInfo.x2 - ViewInfo.x1) DIV 2;
  CenterY := (ViewInfo.y2 - ViewInfo.y1) DIV 2;
  Radius := WORD(CenterY);
  WHILE (CenterY + AdjAsp(INTEGER(Radius), INTEGER(Xasp), INTEGER(Yasp))) < (ViewInfo.y2 - ViewInfo.y1) - 20 DO
    INC(Radius)
  END;
  StepAngle := 360 DIV MaxPoints;
  FOR I := 0 TO MaxPoints - 1 DO
    Radians := REAL(INTEGER(StepAngle) * I) * 3.14159265 / 180.0;
    Points[I].X := CenterX + Math.Round(Math.Cos(Radians) * REAL(Radius));
    Points[I].Y := CenterY - AdjAsp(Math.Round(Math.Sin(Radians) * REAL(Radius)), INTEGER(Xasp), INTEGER(Yasp))
  END;
  Graph.Circle(CenterX, CenterY, Radius);
  FOR I := 0 TO MaxPoints - 1 DO
    FOR J := I TO MaxPoints - 1 DO
      Graph.MoveTo(Points[I].X, Points[I].Y);
      Graph.LineTo(Points[J].X, Points[J].Y)
    END
  END;
  WaitToGo
END LineToPlay;

PROCEDURE DrawTesseract(VAR Poly: Polygon12);
  VAR
    CurrPort: Graph.ViewPortType;
    CheckerBoard: Graph.FillPatternType;
    X, Y, W, H: INTEGER;
    gx, gy: INTEGER;
BEGIN
  CheckerBoard[0] := 0; CheckerBoard[1] := 010H; CheckerBoard[2] := 028H; CheckerBoard[3] := 044H;
  CheckerBoard[4] := 028H; CheckerBoard[5] := 010H; CheckerBoard[6] := 0; CheckerBoard[7] := 0;

  Graph.GetViewSettings(CurrPort);
  W := (CurrPort.x2 - CurrPort.x1) DIV 9;
  H := (CurrPort.y2 - CurrPort.y1) DIV 8;
  X := ((CurrPort.x2 - CurrPort.x1) DIV 2) - Math.Round(2.5 * REAL(W));
  Y := ((CurrPort.y2 - CurrPort.y1) DIV 2) - (3 * H);

  Poly[0].X := 0;                        Poly[0].Y := 0;
  Poly[1].X := CurrPort.x2 - CurrPort.x1; Poly[1].Y := 0;
  Poly[2].X := CurrPort.x2 - CurrPort.x1; Poly[2].Y := CurrPort.y2 - CurrPort.y1;
  Poly[3].X := 0;                        Poly[3].Y := CurrPort.y2 - CurrPort.y1;
  Poly[4].X := 0;                        Poly[4].Y := 0;
  Graph.MoveTo(X, Y);

  Graph.MoveRel(0, H);      gx := Graph.GetX(); gy := Graph.GetY(); Poly[5].X := gx; Poly[5].Y := gy;
  Graph.MoveRel(W, -H);     gx := Graph.GetX(); gy := Graph.GetY(); Poly[6].X := gx; Poly[6].Y := gy;
  Graph.MoveRel(4*W, 0);    gx := Graph.GetX(); gy := Graph.GetY(); Poly[7].X := gx; Poly[7].Y := gy;
  Graph.MoveRel(0, 5*H);    gx := Graph.GetX(); gy := Graph.GetY(); Poly[8].X := gx; Poly[8].Y := gy;
  Graph.MoveRel(-W, H);     gx := Graph.GetX(); gy := Graph.GetY(); Poly[9].X := gx; Poly[9].Y := gy;
  Graph.MoveRel(-4*W, 0);   gx := Graph.GetX(); gy := Graph.GetY(); Poly[10].X := gx; Poly[10].Y := gy;
  Graph.MoveRel(0, -5*H);   gx := Graph.GetX(); gy := Graph.GetY(); Poly[11].X := gx; Poly[11].Y := gy;

  Graph.SetFillPattern(CheckerBoard, MaxColor);
  Graph.FillPoly(12, Poly);

  Graph.MoveRel(W, -H);
  Graph.LineRel(0, 5*H);   Graph.LineRel(2*W, 0);    Graph.LineRel(0, -3*H);
  Graph.LineRel(W, -H);    Graph.LineRel(0, 5*H);    Graph.MoveRel(0, -5*H);
  Graph.LineRel(-2*W, 0);  Graph.LineRel(0, 3*H);    Graph.LineRel(-W, H);
  Graph.MoveRel(W, -H);    Graph.LineRel(W, 0);      Graph.MoveRel(0, -2*H);
  Graph.LineRel(-W, 0);

  Graph.FloodFill((CurrPort.x2 - CurrPort.x1) DIV 2, (CurrPort.y2 - CurrPort.y1) DIV 2, MaxColor)
END DrawTesseract;

PROCEDURE LineRelPlay;
  VAR Poly: Polygon12; CurrPort: Graph.ViewPortType;
BEGIN
  MainWindow("LineRel / MoveRel demonstration");
  Graph.GetViewSettings(CurrPort);
  Graph.SetViewPort(CurrPort.x1 - 1, CurrPort.y1 - 1, CurrPort.x2 + 1, CurrPort.y2 + 1, TRUE);
  DrawTesseract(Poly);
  WaitToGo
END LineRelPlay;

PROCEDURE GetTextCoords(AngleInDegrees, Radius: WORD; VAR X, Y: INTEGER);
  VAR Radians: REAL;
BEGIN
  Radians := REAL(INTEGER(AngleInDegrees)) * 3.14159265 / 180.0;
  X := Math.Round(Math.Cos(Radians) * REAL(Radius));
  Y := Math.Round(Math.Sin(Radians) * REAL(Radius))
END GetTextCoords;

PROCEDURE PiePlay;
  VAR
    ViewInfo: Graph.ViewPortType;
    CenterX, CenterY: INTEGER;
    Radius: WORD;
    Xasp, Yasp: WORD;
    X, Y: INTEGER;
BEGIN
  MainWindow("PieSlice / GetAspectRatio demonstration");
  Graph.GetAspectRatio(Xasp, Yasp);
  Graph.GetViewSettings(ViewInfo);
  CenterX := (ViewInfo.x2 - ViewInfo.x1) DIV 2;
  CenterY := ((ViewInfo.y2 - ViewInfo.y1) DIV 2) + 20;
  Radius := WORD((ViewInfo.y2 - ViewInfo.y1) DIV 3);
  WHILE AdjAsp(INTEGER(Radius), INTEGER(Xasp), INTEGER(Yasp)) < Math.Round(REAL(ViewInfo.y2 - ViewInfo.y1) / 3.6) DO
    INC(Radius)
  END;
  Graph.SetTextStyle(Graph.TriplexFont, Graph.HorizDir, 4);
  Graph.SetTextJustify(Graph.CenterText, Graph.TopText);
  Graph.OutTextXY(CenterX, 0, "This is a pie chart!");

  Graph.SetTextStyle(Graph.TriplexFont, Graph.HorizDir, 3);

  Graph.SetFillStyle(Graph.SolidFill, RandColor());
  Graph.PieSlice(CenterX + 10, CenterY - AdjAsp(10, INTEGER(Xasp), INTEGER(Yasp)), 0, 90, Radius);
  GetTextCoords(45, Radius, X, Y);
  Graph.SetTextJustify(Graph.LeftText, Graph.BottomText);
  Graph.OutTextXY(CenterX + 10 + X + INTEGER(Graph.TextWidth("H")), CenterY - AdjAsp(10 + Y, INTEGER(Xasp), INTEGER(Yasp)), "25 %");

  Graph.SetFillStyle(Graph.HatchFill, RandColor());
  Graph.PieSlice(CenterX, CenterY, 225, 360, Radius);
  GetTextCoords(293, Radius, X, Y);
  Graph.SetTextJustify(Graph.LeftText, Graph.TopText);
  Graph.OutTextXY(CenterX + X + INTEGER(Graph.TextWidth("H")), CenterY - AdjAsp(Y, INTEGER(Xasp), INTEGER(Yasp)), "37.5 %");

  Graph.SetFillStyle(Graph.InterleaveFill, RandColor());
  Graph.PieSlice(CenterX - 10, CenterY, 135, 225, Radius);
  GetTextCoords(180, Radius, X, Y);
  Graph.SetTextJustify(Graph.RightText, Graph.CenterText);
  Graph.OutTextXY(CenterX - 10 + X - INTEGER(Graph.TextWidth("H")), CenterY - AdjAsp(Y, INTEGER(Xasp), INTEGER(Yasp)), "25 %");

  Graph.SetFillStyle(Graph.WideDotFill, RandColor());
  Graph.PieSlice(CenterX, CenterY, 90, 135, Radius);
  GetTextCoords(112, Radius, X, Y);
  Graph.SetTextJustify(Graph.RightText, Graph.BottomText);
  Graph.OutTextXY(CenterX + X - INTEGER(Graph.TextWidth("H")), CenterY - AdjAsp(Y, INTEGER(Xasp), INTEGER(Yasp)), "12.5 %");

  WaitToGo
END PiePlay;

PROCEDURE Bar3DPlay;
  CONST NumBars = 7; YTicks = 5;
  VAR
    BarHeight: BarHeightArr7;
    ViewInfo: Graph.ViewPortType;
    H: WORD;
    XStep, YStep: REAL;
    I, J: INTEGER;
    Depth: WORD;
    Color: WORD;
    numstr: ARRAY 16 OF CHAR;
BEGIN
  BarHeight[0] := 1; BarHeight[1] := 3; BarHeight[2] := 2; BarHeight[3] := 5;
  BarHeight[4] := 4; BarHeight[5] := 2; BarHeight[6] := 1;

  MainWindow("Bar3D / Rectangle demonstration");
  H := 3 * Graph.TextHeight("M");
  Graph.GetViewSettings(ViewInfo);
  Graph.SetTextJustify(Graph.CenterText, Graph.TopText);
  Graph.SetTextStyle(Graph.TriplexFont, Graph.HorizDir, 4);
  Graph.OutTextXY(INTEGER(MaxX DIV 2), 6, "These are 3D bars !");
  Graph.SetTextStyle(Graph.DefaultFont, Graph.HorizDir, 1);
  Graph.SetViewPort(ViewInfo.x1 + 50, ViewInfo.y1 + 40, ViewInfo.x2 - 50, ViewInfo.y2 - 10, TRUE);
  Graph.GetViewSettings(ViewInfo);

  Graph.Line(INTEGER(H), INTEGER(H), INTEGER(H), (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H));
  Graph.Line(INTEGER(H), (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H), (ViewInfo.x2 - ViewInfo.x1) - INTEGER(H), (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H));
  YStep := REAL((ViewInfo.y2 - ViewInfo.y1) - (2 * INTEGER(H))) / REAL(YTicks);
  XStep := REAL((ViewInfo.x2 - ViewInfo.x1) - (2 * INTEGER(H))) / REAL(NumBars);
  J := (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H);
  Graph.SetTextJustify(Graph.CenterText, Graph.CenterText);

  FOR I := 0 TO YTicks DO
    Graph.Line(INTEGER(H) DIV 2, J, INTEGER(H), J);
    Int2Str(I, numstr);
    Graph.OutTextXY(0, J, numstr);
    J := Math.Round(REAL(J) - YStep)
  END;

  Depth := WORD(Math.Trunc(0.25 * XStep));

  Graph.SetTextJustify(Graph.CenterText, Graph.TopText);
  J := INTEGER(H);
  FOR I := 1 TO NumBars + 1 DO
    Graph.SetColor(MaxColor);
    Graph.Line(J, (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H), J, (ViewInfo.y2 - ViewInfo.y1 - 3) - (INTEGER(H) DIV 2));
    Int2Str(I - 1, numstr);
    Graph.OutTextXY(J, (ViewInfo.y2 - ViewInfo.y1) - (INTEGER(H) DIV 2), numstr);
    IF I # NumBars + 1 THEN
      Color := RandColor();
      Graph.SetFillStyle(WORD(I), Color);
      Graph.SetColor(Color);
      Graph.Bar3D(J, Math.Round(REAL((ViewInfo.y2 - ViewInfo.y1 - INTEGER(H))) - (REAL(BarHeight[I-1]) * YStep)),
                  Math.Round(REAL(J) + XStep - REAL(Depth)), (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H) - 1, Depth, TRUE);
      J := Math.Round(REAL(J) + XStep)
    END
  END;
  WaitToGo
END Bar3DPlay;

PROCEDURE BarPlay;
  CONST NumBars = 5;
  VAR
    BarHeight: BarHeightArr5;
    Styles: StylesArr5;
    ViewInfo: Graph.ViewPortType;
    H: WORD;
    XStep, YStep: REAL;
    I, J: INTEGER;
    Color: WORD;
    numstr: ARRAY 16 OF CHAR;
BEGIN
  BarHeight[0] := 1; BarHeight[1] := 3; BarHeight[2] := 5; BarHeight[3] := 2; BarHeight[4] := 4;
  Styles[0] := 1; Styles[1] := 3; Styles[2] := 10; Styles[3] := 5; Styles[4] := 9;

  MainWindow("Bar / Rectangle demonstration");
  H := 3 * Graph.TextHeight("M");
  Graph.GetViewSettings(ViewInfo);
  Graph.SetTextJustify(Graph.CenterText, Graph.TopText);
  Graph.SetTextStyle(Graph.TriplexFont, Graph.HorizDir, 4);
  Graph.OutTextXY(INTEGER(MaxX DIV 2), 6, "These are 2D bars !");
  Graph.SetTextStyle(Graph.DefaultFont, Graph.HorizDir, 1);
  Graph.SetViewPort(ViewInfo.x1 + 50, ViewInfo.y1 + 30, ViewInfo.x2 - 50, ViewInfo.y2 - 10, TRUE);
  Graph.GetViewSettings(ViewInfo);

  Graph.Line(INTEGER(H), INTEGER(H), INTEGER(H), (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H));
  Graph.Line(INTEGER(H), (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H), (ViewInfo.x2 - ViewInfo.x1) - INTEGER(H), (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H));
  YStep := REAL((ViewInfo.y2 - ViewInfo.y1) - (2 * INTEGER(H))) / REAL(NumBars);
  XStep := REAL((ViewInfo.x2 - ViewInfo.x1) - (2 * INTEGER(H))) / REAL(NumBars);
  J := (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H);
  Graph.SetTextJustify(Graph.CenterText, Graph.CenterText);

  FOR I := 0 TO NumBars DO
    Graph.Line(INTEGER(H) DIV 2, J, INTEGER(H), J);
    Int2Str(I, numstr);
    Graph.OutTextXY(0, J, numstr);
    J := Math.Round(REAL(J) - YStep)
  END;

  J := INTEGER(H);
  Graph.SetTextJustify(Graph.CenterText, Graph.TopText);
  FOR I := 1 TO NumBars + 1 DO
    Graph.SetColor(MaxColor);
    Graph.Line(J, (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H), J, (ViewInfo.y2 - ViewInfo.y1 - 3) - (INTEGER(H) DIV 2));
    Int2Str(I, numstr);
    Graph.OutTextXY(J, (ViewInfo.y2 - ViewInfo.y1) - (INTEGER(H) DIV 2), numstr);
    IF I # NumBars + 1 THEN
      Color := RandColor();
      Graph.SetFillStyle(Styles[I-1], Color);
      Graph.SetColor(Color);
      Graph.Bar(J, Math.Round(REAL(ViewInfo.y2 - ViewInfo.y1 - INTEGER(H)) - (REAL(BarHeight[I-1]) * YStep)), Math.Round(REAL(J) + XStep), (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H) - 1);
      Graph.Rectangle(J, Math.Round(REAL(ViewInfo.y2 - ViewInfo.y1 - INTEGER(H)) - (REAL(BarHeight[I-1]) * YStep)), Math.Round(REAL(J) + XStep), (ViewInfo.y2 - ViewInfo.y1) - INTEGER(H) - 1)
    END;
    J := Math.Round(REAL(J) + XStep)
  END;
  WaitToGo
END BarPlay;

PROCEDURE CirclePlay;
  VAR MaxRadius: WORD;
BEGIN
  MainWindow("Circle demonstration");
  StatusLine("Esc aborts or press a key");
  MaxRadius := MaxY DIV 10;
  Graph.SetLineStyle(Graph.SolidLn, 0, Graph.NormWidth);
  REPEAT
    Graph.SetColor(RandColor());
    Graph.Circle(INTEGER(Random.SeedValue(seed, MaxX)), INTEGER(Random.SeedValue(seed, MaxY)), Random.SeedValue(seed, MaxRadius))
  UNTIL Crt.KeyPressed();
  WaitToGo
END CirclePlay;

PROCEDURE RandBarPlay;
  VAR
    MaxWidth, MaxHeight: INTEGER;
    ViewInfo: Graph.ViewPortType;
    Color: WORD;
BEGIN
  MainWindow("Random Bars");
  StatusLine("Esc aborts or press a key");
  Graph.GetViewSettings(ViewInfo);
  MaxWidth := ViewInfo.x2 - ViewInfo.x1;
  MaxHeight := ViewInfo.y2 - ViewInfo.y1;
  REPEAT
    Color := RandColor();
    Graph.SetColor(Color);
    Graph.SetFillStyle(Random.SeedValue(seed, Graph.CloseDotFill) + 1, Color);
    Graph.Bar3D(INTEGER(Random.SeedValue(seed, WORD(MaxWidth))), INTEGER(Random.SeedValue(seed, WORD(MaxHeight))),
                INTEGER(Random.SeedValue(seed, WORD(MaxWidth))), INTEGER(Random.SeedValue(seed, WORD(MaxHeight))), 0, FALSE)
  UNTIL Crt.KeyPressed();
  WaitToGo
END RandBarPlay;

PROCEDURE ArcPlay;
  VAR MaxRadius: WORD; EndAngle: WORD; ArcInfo: Graph.ArcCoordsType;
BEGIN
  MainWindow("Arc / GetArcCoords demonstration");
  StatusLine("Esc aborts or press a key");
  MaxRadius := MaxY DIV 10;
  REPEAT
    Graph.SetColor(RandColor());
    EndAngle := Random.SeedValue(seed, 360);
    Graph.SetLineStyle(Graph.SolidLn, 0, Graph.NormWidth);
    Graph.Arc(INTEGER(Random.SeedValue(seed, MaxX)), INTEGER(Random.SeedValue(seed, MaxY)), Random.SeedValue(seed, EndAngle), EndAngle, Random.SeedValue(seed, MaxRadius));
    Graph.GetArcCoords(ArcInfo);
    Graph.Line(ArcInfo.X, ArcInfo.Y, ArcInfo.Xstart, ArcInfo.Ystart);
    Graph.Line(ArcInfo.X, ArcInfo.Y, ArcInfo.Xend, ArcInfo.Yend)
  UNTIL Crt.KeyPressed();
  WaitToGo
END ArcPlay;

PROCEDURE PutPixelPlay;
  CONST SeedVal = 1962; NumPts = 2000;
  VAR
    I: WORD;
    X, Y, Color: WORD;
    XMax, YMax: INTEGER;
    ViewInfo: Graph.ViewPortType;
BEGIN
  MainWindow("PutPixel / GetPixel demonstration");
  StatusLine("Esc aborts or press a key...");

  Graph.GetViewSettings(ViewInfo);
  XMax := ViewInfo.x2 - ViewInfo.x1 - 1;
  YMax := ViewInfo.y2 - ViewInfo.y1 - 1;

  WHILE ~Crt.KeyPressed() DO
    seed := SeedVal;
    I := 0;
    WHILE (~Crt.KeyPressed()) & (I < NumPts) DO
      INC(I);
      Graph.PutPixel(INTEGER(Random.SeedValue(seed, WORD(XMax))) + 1, INTEGER(Random.SeedValue(seed, WORD(YMax))) + 1, RandColor())
    END;

    seed := SeedVal;
    I := 0;
    WHILE (~Crt.KeyPressed()) & (I < NumPts) DO
      INC(I);
      X := Random.SeedValue(seed, WORD(XMax)) + 1;
      Y := Random.SeedValue(seed, WORD(YMax)) + 1;
      Color := Graph.GetPixel(INTEGER(X), INTEGER(Y));
      IF Color = RandColor() THEN Graph.PutPixel(INTEGER(X), INTEGER(Y), 0) END
    END
  END;
  WaitToGo
END PutPixelPlay;

PROCEDURE MoveSaucer(VAR X, Y: INTEGER; Width, Height: INTEGER; VAR CurPort: Graph.ViewPortType);
  VAR Step: INTEGER;
BEGIN
  Step := INTEGER(Random.SeedValue(seed, 40));
  IF ODD(Step) THEN Step := -Step END;
  X := X + Step;
  Step := INTEGER(Random.SeedValue(seed, 20));
  IF ODD(Step) THEN Step := -Step END;
  Y := Y + Step;

  IF (CurPort.x1 + X + Width - 1 > CurPort.x2) THEN
    X := CurPort.x2 - CurPort.x1 - Width + 1
  ELSIF X < 0 THEN
    X := 0
  END;
  IF (CurPort.y1 + Y + Height - 1 > CurPort.y2) THEN
    Y := CurPort.y2 - CurPort.y1 - Height + 1
  ELSIF Y < 0 THEN
    Y := 0
  END
END MoveSaucer;

PROCEDURE PutImagePlay;
  CONST r = 20; StartX = 100; StartY = 50;
  VAR
    CurPort: Graph.ViewPortType;
    Pausetime: WORD;
    Saucer: SYSTEM.ADDRESS;
    X, Y: INTEGER;
    ulx, uly, lrx, lry: WORD;
    Size: WORD;
    I: INTEGER;
BEGIN
  Graph.ClearDevice;
  FullPort;

  Graph.ClearDevice;
  MainWindow("GetImage / PutImage Demonstration");
  StatusLine("Esc aborts or press a key...");
  Graph.GetViewSettings(CurPort);

  Graph.Ellipse(StartX, StartY, 0, 360, r, (r DIV 3) + 2);
  Graph.Ellipse(StartX, StartY - 4, 190, 357, r, r DIV 3);
  Graph.Line(StartX + 7, StartY - 6, StartX + 10, StartY - 12);
  Graph.Circle(StartX + 10, StartY - 12, 2);
  Graph.Line(StartX - 7, StartY - 6, StartX - 10, StartY - 12);
  Graph.Circle(StartX - 10, StartY - 12, 2);
  Graph.SetFillStyle(Graph.SolidFill, MaxColor);
  Graph.FloodFill(StartX + 1, StartY + 4, Graph.GetColor());

  ulx := WORD(StartX - (r + 1));
  uly := WORD(StartY - 14);
  lrx := WORD(StartX + (r + 1));
  lry := WORD(StartY + (r DIV 3) + 3);

  Size := Graph.ImageSize(INTEGER(ulx), INTEGER(uly), INTEGER(lrx), INTEGER(lry));
  Saucer := SYSTEM.Alloc(Size);
  Graph.GetImage(INTEGER(ulx), INTEGER(uly), INTEGER(lrx), INTEGER(lry), Saucer);
  Graph.PutImage(INTEGER(ulx), INTEGER(uly), Saucer, Graph.XORPut);

  FOR I := 1 TO 1000 DO
    Graph.PutPixel(INTEGER(Random.SeedValue(seed, MaxX)), INTEGER(Random.SeedValue(seed, MaxY)), RandColor())
  END;
  X := INTEGER(MaxX) DIV 2;
  Y := INTEGER(MaxY) DIV 2;
  Pausetime := 70;

  REPEAT
    Graph.PutImage(X, Y, Saucer, Graph.XORPut);
    Delay(INTEGER(Pausetime));
    Graph.PutImage(X, Y, Saucer, Graph.XORPut);
    MoveSaucer(X, Y, INTEGER(lrx - ulx) + 1, INTEGER(lry - uly) + 1, CurPort)
  UNTIL Crt.KeyPressed();
  SYSTEM.Free(Saucer);
  WaitToGo
END PutImagePlay;

PROCEDURE PolyPlay;
  CONST MaxPts = 5;
  VAR Poly: Polygon5; I: INTEGER; Color: WORD;
BEGIN
  MainWindow("FillPoly demonstration");
  StatusLine("Esc aborts or press a key...");
  REPEAT
    Color := RandColor();
    Graph.SetFillStyle(Random.SeedValue(seed, 11) + 1, Color);
    Graph.SetColor(Color);
    FOR I := 0 TO MaxPts - 1 DO
      Poly[I].X := INTEGER(Random.SeedValue(seed, MaxX));
      Poly[I].Y := INTEGER(Random.SeedValue(seed, MaxY))
    END;
    Graph.FillPoly(MaxPts, Poly)
  UNTIL Crt.KeyPressed();
  WaitToGo
END PolyPlay;

PROCEDURE DrawBoxStyle(X, Y: WORD; VAR Style: WORD; Width, Height: WORD);
  VAR numstr: ARRAY 16 OF CHAR;
BEGIN
  Graph.SetFillStyle(Style, MaxColor);
  Graph.Bar(INTEGER(X), INTEGER(Y), INTEGER(X + Width), INTEGER(Y + Height));
  Graph.Rectangle(INTEGER(X), INTEGER(Y), INTEGER(X + Width), INTEGER(Y + Height));
  Int2Str(Style, numstr);
  Graph.OutTextXY(INTEGER(X + (Width DIV 2)), INTEGER(Y + Height + 4), numstr);
  INC(Style)
END DrawBoxStyle;

PROCEDURE FillStylePlay;
  VAR
    Style, Width, Height, X, Y: WORD;
    I, J: INTEGER;
    ViewInfo: Graph.ViewPortType;
BEGIN
  MainWindow("Pre-defined fill styles");
  Graph.GetViewSettings(ViewInfo);
  Width := WORD(2 * ((ViewInfo.x2 + 1) DIV 13));
  Height := WORD(2 * ((ViewInfo.y2 - 10) DIV 10));
  X := Width DIV 2;
  Y := Height DIV 2;
  Style := 0;
  FOR J := 1 TO 3 DO
    FOR I := 1 TO 4 DO
      DrawBoxStyle(X, Y, Style, Width, Height);
      INC(X, (Width DIV 2) * 3)
    END;
    X := Width DIV 2;
    INC(Y, (Height DIV 2) * 3)
  END;
  Graph.SetTextJustify(Graph.LeftText, Graph.TopText);
  WaitToGo
END FillStylePlay;

PROCEDURE DrawBoxPattern(X, Y: WORD; VAR Style: WORD; VAR Patterns: ARRAY OF Graph.FillPatternType; Width, Height: WORD);
BEGIN
  Graph.SetFillPattern(Patterns[Style], MaxColor);
  Graph.Bar(INTEGER(X), INTEGER(Y), INTEGER(X + Width), INTEGER(Y + Height));
  Graph.Rectangle(INTEGER(X), INTEGER(Y), INTEGER(X + Width), INTEGER(Y + Height));
  INC(Style)
END DrawBoxPattern;

PROCEDURE FillPatternPlay;
  VAR
    Patterns: ARRAY 12 OF Graph.FillPatternType;
    Style, Width, Height, X, Y: WORD;
    I, J: INTEGER;
    ViewInfo: Graph.ViewPortType;
BEGIN
  Patterns[0][0] := 0AAH; Patterns[0][1] := 055H; Patterns[0][2] := 0AAH; Patterns[0][3] := 055H;
  Patterns[0][4] := 0AAH; Patterns[0][5] := 055H; Patterns[0][6] := 0AAH; Patterns[0][7] := 055H;

  Patterns[1][0] := 033H; Patterns[1][1] := 033H; Patterns[1][2] := 0CCH; Patterns[1][3] := 0CCH;
  Patterns[1][4] := 033H; Patterns[1][5] := 033H; Patterns[1][6] := 0CCH; Patterns[1][7] := 0CCH;

  Patterns[2][0] := 0F0H; Patterns[2][1] := 0F0H; Patterns[2][2] := 0F0H; Patterns[2][3] := 0F0H;
  Patterns[2][4] := 0FH; Patterns[2][5] := 0FH; Patterns[2][6] := 0FH; Patterns[2][7] := 0FH;

  Patterns[3][0] := 0; Patterns[3][1] := 010H; Patterns[3][2] := 028H; Patterns[3][3] := 044H;
  Patterns[3][4] := 028H; Patterns[3][5] := 010H; Patterns[3][6] := 0; Patterns[3][7] := 0;

  Patterns[4][0] := 0; Patterns[4][1] := 070H; Patterns[4][2] := 020H; Patterns[4][3] := 027H;
  Patterns[4][4] := 025H; Patterns[4][5] := 027H; Patterns[4][6] := 04H; Patterns[4][7] := 04H;

  Patterns[5][0] := 0; Patterns[5][1] := 0; Patterns[5][2] := 0; Patterns[5][3] := 018H;
  Patterns[5][4] := 018H; Patterns[5][5] := 0; Patterns[5][6] := 0; Patterns[5][7] := 0;

  Patterns[6][0] := 0; Patterns[6][1] := 0; Patterns[6][2] := 03CH; Patterns[6][3] := 03CH;
  Patterns[6][4] := 03CH; Patterns[6][5] := 03CH; Patterns[6][6] := 0; Patterns[6][7] := 0;

  Patterns[7][0] := 0; Patterns[7][1] := 07EH; Patterns[7][2] := 07EH; Patterns[7][3] := 07EH;
  Patterns[7][4] := 07EH; Patterns[7][5] := 07EH; Patterns[7][6] := 07EH; Patterns[7][7] := 0;

  Patterns[8][0] := 0; Patterns[8][1] := 0; Patterns[8][2] := 022H; Patterns[8][3] := 08H;
  Patterns[8][4] := 0; Patterns[8][5] := 022H; Patterns[8][6] := 01CH; Patterns[8][7] := 0;

  Patterns[9][0] := 0FFH; Patterns[9][1] := 07EH; Patterns[9][2] := 03CH; Patterns[9][3] := 018H;
  Patterns[9][4] := 018H; Patterns[9][5] := 03CH; Patterns[9][6] := 07EH; Patterns[9][7] := 0FFH;

  Patterns[10][0] := 0; Patterns[10][1] := 010H; Patterns[10][2] := 010H; Patterns[10][3] := 07CH;
  Patterns[10][4] := 010H; Patterns[10][5] := 010H; Patterns[10][6] := 0; Patterns[10][7] := 0;

  Patterns[11][0] := 0; Patterns[11][1] := 042H; Patterns[11][2] := 024H; Patterns[11][3] := 018H;
  Patterns[11][4] := 018H; Patterns[11][5] := 024H; Patterns[11][6] := 042H; Patterns[11][7] := 0;

  MainWindow("User defined fill styles");
  Graph.GetViewSettings(ViewInfo);
  Width := WORD(2 * ((ViewInfo.x2 + 1) DIV 13));
  Height := WORD(2 * ((ViewInfo.y2 - 10) DIV 10));
  X := Width DIV 2;
  Y := Height DIV 2;
  Style := 0;
  FOR J := 1 TO 3 DO
    FOR I := 1 TO 4 DO
      DrawBoxPattern(X, Y, Style, Patterns, Width, Height);
      INC(X, (Width DIV 2) * 3)
    END;
    X := Width DIV 2;
    INC(Y, (Height DIV 2) * 3)
  END;
  Graph.SetTextJustify(Graph.LeftText, Graph.TopText);
  WaitToGo
END FillPatternPlay;

PROCEDURE DrawBoxColor(X, Y: WORD; VAR Color: WORD; Width, Height: WORD);
  VAR numstr: ARRAY 16 OF CHAR;
BEGIN
  Graph.SetFillStyle(Graph.SolidFill, Color);
  Graph.SetColor(Color);
  Graph.Bar(INTEGER(X), INTEGER(Y), INTEGER(X + Width), INTEGER(Y + Height));
  Graph.Rectangle(INTEGER(X), INTEGER(Y), INTEGER(X + Width), INTEGER(Y + Height));
  Color := Graph.GetColor();
  IF Color = 0 THEN
    Graph.SetColor(MaxColor);
    Graph.Rectangle(INTEGER(X), INTEGER(Y), INTEGER(X + Width), INTEGER(Y + Height))
  END;
  Int2Str(Color, numstr);
  Graph.OutTextXY(INTEGER(X + (Width DIV 2)), INTEGER(Y + Height + 4), numstr);
  Color := (Color + 1) MOD (MaxColor + 1)
END DrawBoxColor;

PROCEDURE ColorPlay;
  VAR
    Color, Width, Height, X, Y: WORD;
    I, J: INTEGER;
    ViewInfo: Graph.ViewPortType;
BEGIN
  MainWindow("Color demonstration");
  Color := 1;
  Graph.GetViewSettings(ViewInfo);
  Width := WORD(2 * ((ViewInfo.x2 + 1) DIV 16));
  Height := WORD(2 * ((ViewInfo.y2 - 10) DIV 10));
  X := Width DIV 2;
  Y := Height DIV 2;
  FOR J := 1 TO 3 DO
    FOR I := 1 TO 5 DO
      DrawBoxColor(X, Y, Color, Width, Height);
      INC(X, (Width DIV 2) * 3)
    END;
    X := Width DIV 2;
    INC(Y, (Height DIV 2) * 3)
  END;
  WaitToGo
END ColorPlay;

PROCEDURE PalettePlay;
  CONST XBars = 15; YBars = 10;
  VAR
    I, J: INTEGER;
    X, Y: WORD;
    Color: WORD;
    ViewInfo: Graph.ViewPortType;
    Width, Height: WORD;
    OldPal: Graph.PaletteType;
BEGIN
  Graph.GetPalette(OldPal);
  MainWindow("Palette demonstration");
  StatusLine("Press any key...");
  Graph.GetViewSettings(ViewInfo);
  Width := WORD(ViewInfo.x2 - ViewInfo.x1) DIV XBars;
  Height := WORD(ViewInfo.y2 - ViewInfo.y1) DIV YBars;
  X := 0; Y := 0;
  Color := 0;
  FOR J := 1 TO YBars DO
    FOR I := 1 TO XBars DO
      Graph.SetFillStyle(Graph.SolidFill, Color);
      Graph.Bar(INTEGER(X), INTEGER(Y), INTEGER(X + Width), INTEGER(Y + Height));
      INC(X, Width + 1);
      INC(Color);
      Color := Color MOD (MaxColor + 1)
    END;
    X := 0;
    INC(Y, Height + 1)
  END;
  REPEAT
    Graph.SetPalette(Random.SeedValue(seed, Graph.GetMaxColor() + 1), INTEGER(Random.SeedValue(seed, 65)))
  UNTIL Crt.KeyPressed();
  Graph.SetAllPalette(OldPal);
  WaitToGo
END PalettePlay;

PROCEDURE CrtModePlay;
  VAR ViewInfo: Graph.ViewPortType; Ch: CHAR;
BEGIN
  MainWindow("SetGraphMode / RestoreCrtMode demo");
  Graph.GetViewSettings(ViewInfo);
  Graph.SetTextJustify(Graph.CenterText, Graph.CenterText);
  Graph.OutTextXY((ViewInfo.x2 - ViewInfo.x1) DIV 2, (ViewInfo.y2 - ViewInfo.y1) DIV 2, "Now you are in graphics mode");
  StatusLine("Press any key for text mode...");
  REPEAT UNTIL Crt.KeyPressed();
  Ch := Crt.ReadKey();
  IF Ch = 0X THEN Ch := Crt.ReadKey() END;
  Graph.RestoreCrtMode;
  Out.String("Now you are in text mode."); Out.Ln;
  Out.String("Press any key to go back to graphics...");
  REPEAT UNTIL Crt.KeyPressed();
  Ch := Crt.ReadKey();
  IF Ch = 0X THEN Ch := Crt.ReadKey() END;
  Graph.SetGraphMode(Graph.GetGraphMode());
  MainWindow("SetGraphMode / RestoreCrtMode demo");
  Graph.SetTextJustify(Graph.CenterText, Graph.CenterText);
  Graph.OutTextXY((ViewInfo.x2 - ViewInfo.x1) DIV 2, (ViewInfo.y2 - ViewInfo.y1) DIV 2, "Back in graphics mode...");
  WaitToGo
END CrtModePlay;

PROCEDURE LineStylePlay;
  VAR
    Style: INTEGER;
    Step: WORD;
    X, Y: WORD;
    ViewInfo: Graph.ViewPortType;
    numstr: ARRAY 16 OF CHAR;
BEGIN
  Graph.ClearDevice;
  DefaultColors;
  MainWindow("Pre-defined line styles");
  Graph.GetViewSettings(ViewInfo);
  X := 35;
  Y := 10;
  Step := WORD(ViewInfo.x2 - ViewInfo.x1) DIV 11;
  Graph.SetTextJustify(Graph.LeftText, Graph.TopText);
  Graph.OutTextXY(INTEGER(X), INTEGER(Y), "NormWidth");
  Graph.SetTextJustify(Graph.CenterText, Graph.TopText);
  FOR Style := 0 TO 3 DO
    Graph.SetLineStyle(WORD(Style), 0, Graph.NormWidth);
    Graph.Line(INTEGER(X), INTEGER(Y) + 20, INTEGER(X), ViewInfo.y2 - 40);
    Int2Str(Style, numstr);
    Graph.OutTextXY(INTEGER(X), ViewInfo.y2 - 30, numstr);
    INC(X, Step)
  END;
  INC(X, 2 * Step);
  Graph.SetTextJustify(Graph.LeftText, Graph.TopText);
  Graph.OutTextXY(INTEGER(X), INTEGER(Y), "ThickWidth");
  Graph.SetTextJustify(Graph.CenterText, Graph.TopText);
  FOR Style := 0 TO 3 DO
    Graph.SetLineStyle(WORD(Style), 0, Graph.ThickWidth);
    Graph.Line(INTEGER(X), INTEGER(Y) + 20, INTEGER(X), ViewInfo.y2 - 40);
    Int2Str(Style, numstr);
    Graph.OutTextXY(INTEGER(X), ViewInfo.y2 - 30, numstr);
    INC(X, Step)
  END;
  Graph.SetTextJustify(Graph.LeftText, Graph.TopText);
  WaitToGo
END LineStylePlay;

PROCEDURE UserLineStylePlay;
  VAR
    Style: WORD;
    X, Y, I: WORD;
    ViewInfo: Graph.ViewPortType;
BEGIN
  MainWindow("User defined line styles");
  Graph.GetViewSettings(ViewInfo);
  X := 4;
  Y := 10;
  Style := 0;
  I := 0;
  WHILE X < WORD(ViewInfo.x2) - 4 DO
    Style := SYSTEM.IOR(Style, SYSTEM.LSL(1, I MOD 16));
    Graph.SetLineStyle(Graph.UserBitLn, Style, Graph.NormWidth);
    Graph.Line(INTEGER(X), INTEGER(Y), INTEGER(X), (ViewInfo.y2 - ViewInfo.y1) - INTEGER(Y));
    INC(X, 5);
    INC(I);
    IF Style = 65535 THEN
      I := 0;
      Style := 0
    END
  END;
  WaitToGo
END UserLineStylePlay;

PROCEDURE SayGoodbye;
  VAR ViewInfo: Graph.ViewPortType;
BEGIN
  MainWindow("");
  Graph.GetViewSettings(ViewInfo);
  Graph.SetTextStyle(Graph.TriplexFont, Graph.HorizDir, 4);
  Graph.SetTextJustify(Graph.CenterText, Graph.CenterText);
  Graph.OutTextXY((ViewInfo.x2 - ViewInfo.x1) DIV 2, (ViewInfo.y2 - ViewInfo.y1) DIV 2, "That's all folks!");
  StatusLine("Press any key to quit...");
  REPEAT UNTIL Crt.KeyPressed()
END SayGoodbye;

PROCEDURE Run*;
BEGIN
  InitTables;
  Initialize;
  ReportStatus;

  AspectRatioPlay;
  FillEllipsePlay;
  SectorPlay;
  WriteModePlay;

  ColorPlay;
  IF (GraphDriver = Graph.EGA) OR (GraphDriver = Graph.EGA64) OR (GraphDriver = Graph.VGA) THEN
    PalettePlay
  END;
  PutPixelPlay;
  PutImagePlay;
  RandBarPlay;
  BarPlay;
  Bar3DPlay;
  ArcPlay;
  CirclePlay;
  PiePlay;
  LineToPlay;
  LineRelPlay;
  LineStylePlay;
  UserLineStylePlay;
  TextDump;
  TextPlay;
  CrtModePlay;
  FillStylePlay;
  FillPatternPlay;
  PolyPlay;
  SayGoodbye;
  Graph.CloseGraph
END Run;

END BGIDemo.
