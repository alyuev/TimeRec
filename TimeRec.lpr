program TimeRec;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, Forms, umain;

{$R TimeRec.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'TimeRec';
  Application.Scaled := True;
  Application.MainFormOnTaskBar := False;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
