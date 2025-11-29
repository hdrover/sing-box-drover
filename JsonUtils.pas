unit JsonUtils;

interface

uses
  System.Classes, System.SysUtils;

function NormalizeJson(const ASource: string): string;

implementation

function NormalizeJson(const ASource: string): string;
var
  i, len: integer;
  ch, nextCh: char;
  inString, escape: boolean;
  inSingleLineComment, inMultiLineComment: boolean;
  pendingComma: boolean;
  sb: TStringBuilder;
begin
  len := Length(ASource);
  sb := TStringBuilder.Create(len);
  try
    i := 1;
    inString := false;
    escape := false;
    inSingleLineComment := false;
    inMultiLineComment := false;
    pendingComma := false;

    while i <= len do
    begin
      ch := ASource[i];

      if inSingleLineComment then
      begin
        if CharInSet(ch, [#10, #13]) then
        begin
          inSingleLineComment := false;
        end;
        Inc(i);
        continue;
      end;

      if inMultiLineComment then
      begin
        if (ch = '*') and (i < len) and (ASource[i + 1] = '/') then
        begin
          inMultiLineComment := false;
          Inc(i, 2);
        end
        else
          Inc(i);
        continue;
      end;

      if inString then
      begin
        sb.Append(ch);
        if escape then
          escape := false
        else
        begin
          if ch = '\' then
            escape := true
          else if ch = '"' then
            inString := false;
        end;
        Inc(i);
        continue;
      end;

      if (ch = '/') and (i < len) then
      begin
        nextCh := ASource[i + 1];
        if nextCh = '/' then
        begin
          inSingleLineComment := true;
          Inc(i, 2);
          continue;
        end
        else if nextCh = '*' then
        begin
          inMultiLineComment := true;
          Inc(i, 2);
          continue;
        end;
      end;

      if ch = ',' then
      begin
        pendingComma := true;
        Inc(i);
        continue;
      end;

      if CharInSet(ch, [' ', #9, #10, #13]) then
      begin
        Inc(i);
        continue;
      end;

      if pendingComma then
      begin
        if not CharInSet(ch, ['}', ']']) then
          sb.Append(',');
        pendingComma := false;
      end;

      if ch = '"' then
      begin
        inString := true;
        escape := false;
        sb.Append(ch);
        Inc(i);
        continue;
      end;

      sb.Append(ch);
      Inc(i);
    end;

    result := sb.ToString;
  finally
    sb.Free;
  end;
end;

end.
