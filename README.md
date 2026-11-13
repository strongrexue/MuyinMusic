<div align="center">
  <img src="./logo.png" width="112" alt="沐音 Logo">
  <h1>沐音 · MuyinMusic</h1>
  <p>沐音 - 面向 Android 的自定义源音乐播放器</p>
  <p>
    <a href="https://github.com/strongrexue/MuyinMusic"><strong>项目主页 / 源码</strong></a>
    ·
    <a href="https://github.com/strongrexue/MuyinMusic/releases">下载与更新</a>
  </p>
  <p>
    <a href="./LICENSE">MIT License（主体）</a>
    ·
    <a href="./NOTICE">第三方许可与署名（含 GPL-3.0 组件）</a>
  </p>
</div>

<div align="center">
  <img src="./screenshots/showcase-player.png" width="760" alt="沐音播放器展示，蓝色与绿色封面取色界面">
  <br>
  <img src="./screenshots/showcase-lyrics.png" width="760" alt="沐音逐字歌词展示，蓝色与粉色歌词界面">
</div>

## 项目简介

沐音（MuyinMusic）是一个使用 Flutter 构建的 Android 音乐客户端，提供自定义源管理、音乐检索、下载管理、本地歌曲库和播放器能力。项目重点放在移动端体验、本地媒体整理、歌词展示和 Material 3 界面。

本项目是 [CyShineMusic（栖弦）](https://github.com/KevinllBin/CyShineMusic) v1.1.2 的二开分支，用于自用及小范围朋友分享。源码公开发布于 [strongrexue/MuyinMusic](https://github.com/strongrexue/MuyinMusic)。

**项目不内置或分发任何音乐内容。用户需要自行配置可用的自定义源，并自行确认相关内容来源的合法性。**

## 功能特性

- **自定义源**：支持导入、启用、禁用和管理自定义音乐源。
- **音乐检索**：提供关键词搜索、来源筛选和搜索结果分页。
- **下载管理**：支持下载队列、实时进度、完成记录和失败记录。
- **本地歌曲库**：扫描自定义目录，读取本地音频标签，并支持排序、搜索、选择和批量操作。
- **元数据整理**：支持写入歌曲名、歌手、专辑、封面和歌词。
- **歌词体验**：支持逐句歌词、逐字歌词、翻译/音译展示和播放同步。
- **本地播放器**：支持在线播放、本地播放、后台播放、系统媒体通知和耳机按键控制。
- **播放队列**：支持上一首、下一首、随机、循环和播放队列管理。
- **主题外观**：支持浅色、深色、跟随系统和自定义主题色，中性背景搭配强调色；提供可调节的液态玻璃材质（磨砂 / 透明 / 色调）。
- **在线更新**：应用内检查本仓库的 GitHub Releases 并引导下载更新包。
- **调试工具**：提供应用内日志和基础网络设置，方便定位自定义源或下载问题。

## 截图

<table>
  <tr>
    <td align="center"><img src="./screenshots/discovery.jpg" width="180" alt="发现页"><br>发现</td>
    <td align="center"><img src="./screenshots/rankings.jpg" width="180" alt="排行榜列表"><br>排行榜</td>
    <td align="center"><img src="./screenshots/online-playlist-detail.jpg" width="180" alt="在线榜单详情"><br>榜单详情</td>
    <td align="center"><img src="./screenshots/playlist-detail.jpg" width="180" alt="歌单歌曲列表"><br>歌单歌曲</td>
  </tr>
</table>

<table>
  <tr>
    <td align="center"><img src="./screenshots/player-disc.jpg" width="220" alt="粉色播放器圆形封面"><br>圆形封面</td>
    <td align="center"><img src="./screenshots/player-cover.jpg" width="220" alt="蓝色播放器方形封面"><br>方形封面</td>
    <td align="center"><img src="./screenshots/player-cover-green.jpg" width="220" alt="绿色播放器方形封面"><br>封面取色</td>
  </tr>
  <tr>
    <td align="center"><img src="./screenshots/player-lyrics.jpg" width="220" alt="蓝色逐字歌词与翻译"><br>逐字歌词</td>
    <td align="center"><img src="./screenshots/player-lyrics-pink.jpg" width="220" alt="粉色逐字歌词与翻译"><br>歌词取色</td>
    <td align="center"><img src="./screenshots/settings.jpg" width="220" alt="浅色主题设置页"><br>设置</td>
  </tr>
</table>

### 平板视图

<div align="center">
  <img src="./screenshots/player-tablet.jpg" width="760" alt="平板横屏播放器，左侧封面与播放控制，右侧歌词与翻译">
</div>

## 开发环境

- Flutter stable，Dart SDK `>=3.11.4 <4.0.0`（基线使用 Flutter 3.47.9 / Dart 3.13.7 验证）
- Android SDK
- Android 真机或模拟器

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
```

仅构建 `arm64-v8a` 发布包：

```powershell
flutter build apk --target-platform=android-arm64
```

构建渠道由当前 Git 分支自动决定：`main` 生成包名
`com.muyin.muyinmusic`、应用名"沐音"的正式版，`dev` 生成包名
`com.muyin.muyinmusic.dev`、应用名"沐音dev"的开发版，两者可同时安装。Release
构建分别使用固定签名；签名文件配置见 `android/signing/README.md`。签名密钥由
维护者本地保管，不随源码入库。

构建产物位于：

```text
build/app/outputs/flutter-apk/app-release.apk
```


## 项目结构

```text
lib/
├── main.dart                    # 应用入口与依赖初始化
├── app.dart                     # MaterialApp、主题与全局状态
├── router.dart                  # 页面路由
├── core/
│   ├── api/                     # 网络客户端与通用请求封装
│   ├── models/                  # 音乐、歌词、音质与响应模型
│   ├── music_sources/           # 自定义源管理与运行时
│   ├── sdk/                     # 源适配与解析辅助
│   ├── services/                # 下载、标签、歌词、权限与日志
│   ├── storage/                 # 设置与本地持久化
│   └── ui/                      # 通用 UI 组件
├── features/
│   ├── search/                  # 搜索、来源筛选与音质选择
│   ├── downloads/               # 下载队列与历史记录
│   ├── songs/                   # 本地歌曲库
│   ├── player/                  # 播放器与歌词同步
│   ├── music_sources/           # 自定义源导入与管理
│   ├── playlists/               # 歌单与收藏管理
│   ├── settings/                # 下载、网络和外观设置
│   ├── shell/                   # 应用导航框架
│   └── startup/                 # 启动页
└── theme/                       # Material 3 主题与动效
```

## 贡献

欢迎通过本仓库的 Issues 提交问题或建议，也可以直接发起 Pull Request。提交前请至少运行：

```powershell
flutter analyze
flutter test
```

## 许可证

本项目为**混合许可**，详见 [NOTICE](./NOTICE)：

- 应用主体（源自 CyShineMusic，MIT）及本分支的修改： [MIT License](./LICENSE)。上游原始版权行 `Copyright (c) 2026 KevinllBin` 按 MIT 要求原样保留。
- `packages/prism_ui`：**GNU GPL v3.0 only**（[GPLv3 全文](./packages/prism_ui/LICENSE)），是强 copyleft 组件；其内部还包含 Apache-2.0 / MIT 的第三方代码。
- `packages/heroine`、`packages/audio_service`：MIT（各自的 LICENSE 全文随附）。

由于 prism_ui 被静态链接进同一个 APK，分发本应用时适用 GPLv3 的源码可获得要求。为此，本仓库公开发布**完整源码**，每个对外分发的 APK（GitHub Release）都对应本仓库中的一次带标签提交，接收者可据此取得完整的 Corresponding Source。

## 免责声明

本项目仅用于技术研究与学习交流，不提供任何音乐内容，不保证任何自定义源的可用性。使用者应遵守所在地区法律法规、第三方服务条款及著作权要求，并自行承担使用本项目产生的责任。
