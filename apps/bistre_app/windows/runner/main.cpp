#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

std::wstring ReadEnvVar(const wchar_t* name) {
  wchar_t buf[64] = {};
  DWORD len = ::GetEnvironmentVariableW(name, buf, 64);
  if (len == 0 || len >= 64) {
    return L"";
  }
  return std::wstring(buf, len);
}

void ConfigureWindowsRenderer(flutter::DartProject& project) {
  // Default to Skia GLES + merged UI/platform thread on Windows for tear-free DWM
  // composition and lower shader/working-set footprint on integrated GPUs; opt-in env
  // overrides remain available for live A/B profiling (`BISTRE_IMPELLER`,
  // `BISTRE_UI_THREAD`, `BISTRE_GPU_PREF`, `BISTRE_ANGLE_PLATFORM`).
  const std::wstring angle = ReadEnvVar(L"BISTRE_ANGLE_PLATFORM");
  if (!angle.empty()) {
    ::SetEnvironmentVariableW(L"ANGLE_DEFAULT_PLATFORM", angle.c_str());
  }

  const std::wstring impeller = ReadEnvVar(L"BISTRE_IMPELLER");
  if (impeller == L"on" || impeller == L"true" || impeller == L"1") {
    project.set_impeller_switch(flutter::ImpellerSwitch::Enabled);
  } else if (impeller == L"default") {
    project.set_impeller_switch(flutter::ImpellerSwitch::Default);
  } else {
    project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
  }

  const std::wstring ui_thread = ReadEnvVar(L"BISTRE_UI_THREAD");
  if (ui_thread == L"separate") {
    project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnSeparateThread);
  } else if (ui_thread == L"default") {
    project.set_ui_thread_policy(flutter::UIThreadPolicy::Default);
  } else {
    project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnPlatformThread);
  }

  const std::wstring gpu = ReadEnvVar(L"BISTRE_GPU_PREF");
  if (gpu == L"high") {
    project.set_gpu_preference(flutter::GpuPreference::HighPerformancePreference);
  } else if (gpu == L"low") {
    project.set_gpu_preference(flutter::GpuPreference::LowPowerPreference);
  } else {
    project.set_gpu_preference(flutter::GpuPreference::NoPreference);
  }
}

}  // namespace

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
  ConfigureWindowsRenderer(project);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(48, 40);
  Win32Window::Size size(1320, 820);
  if (!window.Create(L"Bistre", origin, size)) {
    return EXIT_FAILURE;
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
