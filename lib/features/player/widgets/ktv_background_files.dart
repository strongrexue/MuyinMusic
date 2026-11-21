import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用文档目录下存放 KTV 自定义背景图实体的子目录。
Future<Directory> ktvBackgroundsDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'ktv_backgrounds'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// 图库条目 [fileName] 对应的图片文件（不保证存在）。
Future<File> ktvBackgroundFile(String fileName) async {
  final dir = await ktvBackgroundsDirectory();
  return File(p.join(dir.path, fileName));
}
