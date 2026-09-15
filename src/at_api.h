// at_api.h — export/import decoration for the native core.
//
// build.bat compiles the DLL with /DAT_CORE_BUILD, so the same headers declare
// dllexport while building the core and dllimport for at_cli.exe.
#ifndef AT_API_H
#define AT_API_H

#ifdef AT_CORE_BUILD
#define AT_API __declspec(dllexport)
#else
#define AT_API __declspec(dllimport)
#endif

#endif // AT_API_H
