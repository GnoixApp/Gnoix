# WFTVIOS（晚风 TV + 小说）

WFTVIOS 是一个 iOS 聚合内容应用，集成了三类核心能力：

- 影视点播：多内容源分类浏览、搜索、详情与分集播放
- 电视直播：支持 M3U/TXT 直播源导入、分组浏览、全屏播放
- 小说阅读（Legado）：书架、发现、搜索、阅读器、书源管理与服务器解析

## 当前功能概览

### 1) 视频（首页 Tab）
- 点播分类浏览与分页加载
- 多源切换（内容源选择）
- 跨源搜索聚合
- 播放历史续播
- 详情页多播放源/多分集切换

### 2) 直播（首页内切换）
- 在首页右上角点击 `tv/film` 图标可在「点播/直播」之间切换
- 支持导入 M3U/TXT 直播源
- 按分组筛选频道
- 全屏直播播放

### 3) 小说（小说/发现 Tab）
- 书架管理（含管理模式、导入本地 TXT/EPUB）
- 小说搜索、发现、阅读进度记录
- 支持两种解析模式：`服务器 API` / `本地解析`
- 阅读配套：TTS、替换净化、RSS、书签、阅读记录、分组管理

### 4) 设置能力
- 外观主题（浅色/深色/跟随系统）
- 降低透明效果（提升低端设备流畅性）
- 内容源/直播源管理
- 自定义网页 Tab
- 缓存清理

## 开发环境要求

- macOS 14+
- Xcode 15+
- iOS 16+
- CocoaPods（建议最新稳定版）

说明：`Podfile` 中 `platform :ios, '16.0'`，建议至少使用 iOS 16 模拟器或真机。

## 快速启动

```bash
git clone https://github.com/oilycn/WFTVIOS.git
cd WFTVIOS
pod install
open WFTVIOS.xcworkspace
```

然后在 Xcode 中：

1. 选择 Scheme：`WFTVIOS`
2. 选择 iOS 模拟器或真机
3. `Cmd + R` 运行

## 首次使用建议

### 视频点播
- 应用首次启动会自动注入一个默认影视源
- 如需新增或导入：`设置 -> 内容源管理`

### 电视直播
- 进入：`设置 -> 直播源管理 -> 添加直播源`
- 填写 M3U/TXT 地址后，在首页切到「直播」即可浏览

### 小说阅读
- 进入：`设置 -> 小说解析`
- 可切换 `服务器API` 或 `本地解析`
- 若使用服务器模式：
  - 打开 `阅读服务器`
  - 输入 `https://你的服务地址:端口#账号#密码`
  - 也支持只填 URL（不带账号密码）

## 阅读服务器（可选）

示例（Docker）：

```bash
docker run -d \
  -p 7443:3000 \
  --name legado-reader \
  oilyc/legado-reader
```

应用内可配置：`https://<你的主机>:7443`

## 构建与测试

### 使用脚本

```bash
./build.sh clean
./build.sh build
./build.sh test
```

### 使用 xcodebuild

```bash
xcodebuild -workspace WFTVIOS.xcworkspace \
  -scheme WFTVIOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
```

## 项目结构

```text
WFTVIOS/
├── App/                  # App 启动与生命周期
├── Views/                # SwiftUI 页面（视频、直播、设置等）
├── Players/              # 播放器桥接与容器
├── Loaders/              # 内容加载与解析适配
├── Managers/             # 主题、偏好、源管理、历史管理
├── Models/               # 业务模型
└── Legado/Sources/       # 小说阅读核心（UI/网络/解析/数据库）
```

## 常见问题

### 1) `pod install` 失败
- 确认 CocoaPods 已安装
- 尝试 `pod repo update` 后重试

### 2) 首页无视频内容
- 检查网络
- 到 `设置 -> 内容源管理` 确认至少有一个可用影视源

### 3) 直播页没有频道
- 确认已添加并启用直播源
- 检查源地址是否可访问，格式是否为 M3U/TXT

### 4) 小说搜索为空或加载失败
- 检查当前解析模式（服务器/本地）
- 服务器模式下确认「阅读服务器」地址和账号配置正确

## License

MIT
