#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1500, 900);
  if (!window.Create(L"\u6c90\u97f3", origin, size)) {
    return EXIT_FAILURE;
  }

  // Center on the primary monitor's work area (physical pixels, not DPI-scaled).
  HWND hwnd = window.GetHandle();
  if (hwnd != nullptr) {
    RECT rect;
    if (::GetWindowRect(hwnd, &rect)) {
      const int width = rect.right - rect.left;
      const int height = rect.bottom - rect.top;
      HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      MONITORINFO info{};
      info.cbSize = sizeof(info);
      if (::GetMonitorInfo(monitor, &info)) {
        const RECT& work = info.rcWork;
        const int x = work.left + (work.right - work.left - width) / 2;
        const int y = work.top + (work.bottom - work.top - height) / 2;
        ::SetWindowPos(hwnd, nullptr, x, y, 0, 0,
                       SWP_NOSIZE | SWP_NOZORDER);
      }
    }
  }

  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
