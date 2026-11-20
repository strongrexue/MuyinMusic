import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
// ignore: depend_on_referenced_packages
import 'package:win32/win32.dart';

/// Windows 目录选择框。
///
/// file_picker 8.3.7 的 getDirectoryPath 在平台线程创建带 Finalizer 的 COM
/// 包装对象后又手动 release，导致同一对象被二次释放（UAF），选中目录点确定后
/// 可能触发 0xc0000005（comdlg32.dll）。这里复制其实现并做三处修复：
/// 1. 整个流程跑在后台 isolate，不污染平台线程常驻 COM；
/// 2. 每个 COM 包装对象创建即 detach() 摘掉 win32 的 Finalizer；
/// 3. finally 中先子后父各显式 release 一次 + free 包装指针，
///    GetDisplayName 字符串 CoTaskMemFree，最后按配对 CoUninitialize。
Future<String?> pickWindowsFolder({
  String? initialDirectory,
  String? dialogTitle,
}) => Isolate.run(() => _pickFolderSync(initialDirectory, dialogTitle));

String? _pickFolderSync(String? initialDirectory, String? dialogTitle) {
  final hr = CoInitializeEx(
    nullptr,
    COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE,
  );
  // 8.3.7 忽略 RPC_E_CHANGED_MODE（表示 COM 已初始化）。但那种情况不是我们
  // 建立的 apartment，结束时不能由我们 CoUninitialize，否则配对失衡。
  if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) throw WindowsException(hr);
  final ownsApartment = SUCCEEDED(hr);

  FileOpenDialog? dialog;
  Pointer<COMObject>? dialogPtr;
  IShellItem? initialItem;
  Pointer<Pointer>? initialPpv;
  IShellItem? resultItem;
  Pointer<COMObject>? resultPpsi;
  Pointer<Pointer<Utf16>>? pathPtr;
  Pointer<Utf16>? displayName;

  try {
    dialog = FileOpenDialog.createInstance()..detach();
    dialogPtr = dialog.ptr;

    final optionsPointer = calloc<Uint32>();
    try {
      var h = dialog.getOptions(optionsPointer);
      if (!SUCCEEDED(h)) throw WindowsException(h);
      final options = optionsPointer.value |
          FOS_PICKFOLDERS |
          FOS_FORCEFILESYSTEM |
          FOS_NOCHANGEDIR;
      h = dialog.setOptions(options);
      if (!SUCCEEDED(h)) throw WindowsException(h);
    } finally {
      free(optionsPointer);
    }

    final title = TEXT(dialogTitle ?? '');
    try {
      final h = dialog.setTitle(title);
      if (!SUCCEEDED(h)) throw WindowsException(h);
    } finally {
      free(title);
    }

    if (initialDirectory != null) {
      final folder = TEXT(initialDirectory);
      final riid = convertToIID(IID_IShellItem);
      initialPpv = calloc<Pointer>();
      try {
        var h = SHCreateItemFromParsingName(folder, nullptr, riid, initialPpv);
        if (!SUCCEEDED(h)) throw WindowsException(h);
        initialItem = IShellItem(initialPpv.cast<COMObject>())..detach();
        h = dialog.setFolder(initialItem.ptr.cast<Pointer<COMObject>>().value);
        if (!SUCCEEDED(h)) throw WindowsException(h);
      } finally {
        free(folder);
        free(riid);
      }
    }

    // 不锁定父窗口：hwndOwner = NULL（对应 file_picker lockParentWindow=false）。
    final hShow = dialog.show(NULL);
    if (!SUCCEEDED(hShow)) {
      if (hShow == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return null;
      throw WindowsException(hShow);
    }

    resultPpsi = calloc<COMObject>();
    final String path;
    try {
      var h = dialog.getResult(resultPpsi.cast());
      if (!SUCCEEDED(h)) throw WindowsException(h);
      resultItem = IShellItem(resultPpsi)..detach();
      pathPtr = calloc<Pointer<Utf16>>();
      h = resultItem.getDisplayName(SIGDN_FILESYSPATH, pathPtr);
      if (!SUCCEEDED(h)) throw WindowsException(h);
      displayName = pathPtr.value;
      path = displayName.toDartString();
    } finally {
      if (pathPtr != null) free(pathPtr);
    }
    return path;
  } finally {
    // 严格「先子后父」release：每个包装对象 detach 后只在此处显式 release 一次。
    if (resultItem != null) resultItem.release();
    if (initialItem != null) initialItem.release();
    if (dialog != null) dialog.release();
    // GetDisplayName 返回的字符串由 shell 用 CoTaskMem 分配。
    if (displayName != null && displayName != nullptr) {
      CoTaskMemFree(displayName);
    }
    // 包装指针由 calloc 分配，detach() 后需自行 free（无条件，泄漏兜底）。
    if (resultPpsi != null) free(resultPpsi);
    if (initialPpv != null) free(initialPpv);
    if (dialogPtr != null) free(dialogPtr);
    if (ownsApartment) CoUninitialize();
  }
}
