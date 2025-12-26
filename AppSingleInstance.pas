unit AppSingleInstance;

interface

function AcquireSingleInstance(mutexName: string; waitIfExists: boolean; waitMs: cardinal = 10000): boolean;

implementation

uses
  Winapi.Windows,
  System.SysUtils;

function ConvertStringSecurityDescriptorToSecurityDescriptorW(StringSecurityDescriptor: PWideChar;
  StringSDRevision: DWORD; out SecurityDescriptor: PSECURITY_DESCRIPTOR; SecurityDescriptorSize: PULONG): BOOL; stdcall;
  external advapi32 name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';

const
  MUTEX_SDDL = 'D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;AU)';

function AcquireSingleInstance(mutexName: string; waitIfExists: boolean; waitMs: cardinal): boolean;
var
  sa: TSecurityAttributes;
  sd: PSECURITY_DESCRIPTOR;
  err: DWORD;
  wr: DWORD;
  mutex: THandle;
begin
  sd := nil;
  if not ConvertStringSecurityDescriptorToSecurityDescriptorW(PWideChar(MUTEX_SDDL), 1, sd, nil) then
    exit(false);

  try
    ZeroMemory(@sa, SizeOf(sa));
    sa.nLength := SizeOf(sa);
    sa.bInheritHandle := false;
    sa.lpSecurityDescriptor := sd;

    mutex := CreateMutex(@sa, true, PChar(mutexName));
    if mutex = 0 then
      exit(false);

    err := GetLastError;

    if err = ERROR_ALREADY_EXISTS then
    begin
      if not waitIfExists then
      begin
        CloseHandle(mutex);
        exit(false);
      end;

      wr := WaitForSingleObject(mutex, waitMs);
      if not(wr in [WAIT_OBJECT_0, WAIT_ABANDONED]) then
      begin
        CloseHandle(mutex);
        exit(false);
      end;
    end;

    result := true;

  finally
    if sd <> nil then
      LocalFree(HLOCAL(sd));
  end;
end;

end.
