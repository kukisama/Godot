# Windows 初始化

这份初始化用于在一台新的 **Windows x64** 电脑上构建本仓库的三个 Godot 项目。脚本没有安装框架或隐藏服务，本质上就是按顺序安装软件、下载 Godot 导出模板，再安装 VS Code 扩展。

## 一键初始化

在仓库根目录打开 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Initialize-Windows.ps1
```

脚本按顺序安装：

1. Git
2. Visual Studio Code
3. Godot Engine 4.7.2（标准版）
4. .NET 8 SDK
5. Visual Studio 2022 C++ Build Tools，包括 MSVC x64 和 Windows SDK
6. Godot 4.7.2 Windows 导出模板
7. VS Code 的 Godot Tools 和 C# 扩展

`winget` 会跳过已经安装且无需更新的软件，所以可以重复执行。

## 管理员权限

Git、VS Code、Godot 和导出模板通常不需要管理员权限。

Visual Studio C++ Build Tools、Windows SDK 和 .NET SDK 是系统级软件，安装时 Windows 可能显示 UAC 管理员授权窗口。请点击“是”，或输入管理员账户凭据。脚本本身不要求始终以管理员身份运行，也不会关闭 UAC。

如果拒绝 UAC，安装会失败，后续无法编译星灯旅店的 `StarlightAzure.exe`；这不是可忽略的可选步骤。

## 下载量和时间

- Godot 导出模板约 1.3 GB。
- C++ Build Tools 和 Windows SDK 通常还需要数 GB。
- 整体时间取决于网络和磁盘速度，安装 Windows SDK 时可能需要十几分钟。
- 安装过程中不要关闭弹出的 Visual Studio Installer。

下载的 Godot 模板会校验官方 SHA512。模板分别放入当前用户的 Godot 模板目录和项目的 `StarlightInn\tools\godot-standard\templates\`，下载缓存保存在相邻的 `downloads\` 目录。重复初始化可复用已安装的软件，但模板包会重新检查和下载。

## 初始化后构建

初始化完成后，完全退出并重新打开 VS Code，让新安装的软件和 PATH 生效。然后在仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Release.ps1
```

也可以在 VS Code 中运行任务 **发布三个游戏 Release 到 play**。

构建会：

1. 编译并验证星灯旅店的 C++ 原生组件。
2. 导入三个 Godot 项目的资源。
3. 导出三个 Windows x64 Release 到各自项目的 `play\` 目录。
4. 将星灯旅店原生组件、公开配置和说明复制到 `StarlightInn\play\`。

完整产物：

```text
ForestGlow\play\
  ForestGlow.exe
HollowBell\play\
  HollowBell.exe
  Start-HollowBell.cmd
StarlightInn\play\
  StarlightInn.exe
  native\StarlightAzure.exe
  azure-settings.json
  README.md
  API.md
  AAD_SETUP.md
```

复制星灯旅店时必须复制整个 `StarlightInn\play\` 目录，不能只复制 `StarlightInn.exe`。

## 常见问题

### 找不到 `winget`

从 Microsoft Store 安装或更新 **应用安装程序（App Installer）**，重新打开 PowerShell 后再执行初始化脚本。

### 安装完成但找不到 `godot_console.exe` 或 `code`

关闭当前终端并重新打开。若从 VS Code 终端运行，还需要完全退出并重新启动 VS Code。

### C++ Build Tools 安装失败

重新执行初始化脚本并批准 UAC。若 Visual Studio Installer 仍在运行，先让当前安装完成，不要同时启动第二次安装。

### 是否必须安装 .NET

当前三个发布版本主要使用 GDScript，星灯旅店原生组件使用 C++。仓库仍保留 C#/.NET 归档项目和相关开发入口，因此初始化脚本一并安装稳定的 .NET 8 SDK。
