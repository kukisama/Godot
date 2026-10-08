# Godot Windows 开发环境安装记录

安装日期：2026-10-08。脚本：[`Install-Godot.ps1`](./Install-Godot.ps1)。

## 本机安装结果

以下为本机实测，不是仅根据文档推断：

| 项目 | 状态 |
| --- | --- |
| 系统 | Windows 11 x64 |
| Godot 编辑器 | `4.7.2.stable.mono.official.ed1daf0bf`，官方 .NET 版 |
| 导出模板 | `4.7.2.stable.mono`，与编辑器匹配 |
| .NET SDK | 复用已有 `10.0.112`；验收选择稳定 SDK，不选择已有的 11 预览版 |
| .NET 运行时 | 复用已有 `Microsoft.NETCore.App 8.0.31`；验收项目目标是 `net8.0` |
| VS Code / Git | 已有，本次没有重复安装 |
| Godot Tools | 新安装 `geequlim.godot-tools`，版本 `2.7.1` |
| C# 扩展 | 复用已有 `ms-dotnettools.csharp`，版本 `2.160.4` |
| 下载校验 | 编辑器 ZIP、.NET 模板 TPZ 均通过官方 SHA512 校验 |
| 编辑器签名 | `Valid`；签名主体 `Prehensile Tales B.V.` |
| GDScript | 实际执行，输出 `GDSCRIPT_ENVIRONMENT_OK` |
| C# | 编译成功，场景实际运行输出 `CSHARP_ENVIRONMENT_OK` |
| Windows 导出 | C# 项目导出 EXE 并实际运行，输出 `WINDOWS_EXPORT_AND_RUN_OK` |
| 脚本兼容性 | PowerShell 7.6.6 和 Windows PowerShell 5.1 均完成端到端验收 |

选择 .NET 版是为了同时保留 GDScript 与 C# 开发入口；C# 开发需要另外具备 [.NET SDK 和 .NET 版 Godot](https://docs.godotengine.org/en/stable/tutorials/scripting/c_sharp/c_sharp_basics.html)。版本来源为 [Godot 官方 Windows 下载页](https://godotengine.org/download/windows/)及 [4.7.2 官方发行页](https://github.com/godotengine/godot/releases/tag/4.7.2-stable)。

## 一条命令执行

在此目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Godot.ps1
```

也可在 PowerShell 7 中运行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install-Godot.ps1
```

这是本次实际使用并验证的安装脚本，不是另一套未执行的示例。默认安装固定版本 `4.7.2`，安装导出模板和 VS Code 扩展，验证后打开项目管理器。

`-ExecutionPolicy Bypass` 只作用于这次 PowerShell 子进程；脚本不会永久修改系统执行策略，也不会申请管理员权限。

### 可选参数

| 参数 | 用途 |
| --- | --- |
| `-NoLaunch` | 完成验收后不打开新窗口，适合重复执行 |
| `-SkipExtensions` | 不安装 VS Code 扩展 |
| `-SkipTemplates` | 不下载模板、不执行 Windows 导出验收；仍验证 GDScript 和 C# |
| `-InstallRoot 'D:\Tools\Godot'` | 自定义编辑器、缓存及日志目录；模板仍在当前用户的 APPDATA 下 |
| `-Version '4.x.y'` | 指定其他正式版本；需要对应发行包和 Godot.NET.Sdk 存在，其他版本未在本机验收 |

重复执行的完整验收命令（本机已实测）：

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Install-Godot.ps1 -NoLaunch -SkipExtensions
```

## 新机器的前置条件

脚本面向 Windows x64，不适用于 ARM64。需要联网、稳定版 .NET 8+ SDK、.NET 8 运行时；默认扩展安装还需要 VS Code 的 `code` 命令可用。脚本检测缺失后停止并提示，不会自动安装系统级 SDK。

以下是供新机器使用的前置安装命令，**本机已有这些依赖，本次没有执行**。SDK 8 安装包含对应运行时；安装后重新打开终端。

```powershell
winget install --id Microsoft.DotNet.SDK.8 --exact --source winget
winget install --id Microsoft.VisualStudioCode --exact --source winget --scope user
dotnet --list-sdks
dotnet --list-runtimes
code --version
```

若安装系统级 SDK 时 Windows 请求管理员授权，由操作者在本机确认；Godot 本身采用当前用户目录的便携安装。Godot 官方说明其 Windows 编辑器为[解压即可运行的自包含程序](https://godotengine.org/download/windows/)。

## 安装位置与命令

| 内容 | 默认位置 |
| --- | --- |
| 安装根目录 | `%LOCALAPPDATA%\Programs\Godot` |
| 编辑器 | `%LOCALAPPDATA%\Programs\Godot\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64.exe` |
| 命令入口 | `%LOCALAPPDATA%\Programs\Godot\bin\godot.cmd` |
| .NET 导出模板 | `%APPDATA%\Godot\export_templates\4.7.2.stable.mono` |
| 下载缓存 | 安装根目录下的 `downloads` |
| 安装日志 | 安装根目录下的 `install-*.log` |
| 验收项目、导出 EXE 和运行日志 | 安装根目录下的 `validation-*` |
| 快捷方式 | 当前用户桌面 `Godot .NET`，以及开始菜单 `Godot/Godot .NET` |

脚本保留官方 EXE 文件名与旁边的 `GodotSharp` 目录，通过 `godot.cmd` 转发参数；将 `bin` 加入用户 PATH，并将用户变量 `GODOT4` 指向真实 GUI EXE。重复执行不会重复添加同一 PATH 条目。

安装后重新打开终端；已启动的 VS Code 需要完全退出后重新打开，才能继承新的环境变量。也可在当前 PowerShell 显式刷新这两个变量：

```powershell
$env:GODOT4 = [Environment]::GetEnvironmentVariable('GODOT4', 'User')
$env:Path += ';' + (Join-Path $env:LOCALAPPDATA 'Programs\Godot\bin')
godot --version
Start-Process -FilePath $env:GODOT4 -ArgumentList '--project-manager'
```

打开已有项目、运行项目的命令如下；将路径替换为实际项目根目录。`--path` 的目录应包含 `project.godot`，详见[官方命令行说明](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html)。

```powershell
godot --editor --path 'D:\Projects\MyGame'
godot --path 'D:\Projects\MyGame'
```

## VS Code 开发接入

扩展已安装；本次没有覆盖 VS Code 全局设置或 Godot 编辑器个人偏好，也没有在此仓库创建游戏项目。

- GDScript 可直接使用 Godot 内置编辑器。若使用 VS Code，在项目设置中将 `godotTools.editorPath.godot4` 设置为上表的真实编辑器 EXE 路径；不要填 `godot.cmd`。配置项见 [Godot Tools 扩展说明](https://marketplace.visualstudio.com/items?itemName=geequlim.godot-tools)。
- GDScript 外部编辑器可在 Godot 的 `Editor > Editor Settings > Text Editor > External` 中启用；Exec Path 指向 `Code.exe`，Exec Flags 填 `{project} --goto {file}:{line}:{col}`，见[扩展配置说明](https://marketplace.visualstudio.com/items?itemName=geequlim.godot-tools)。
- C# 外部编辑器在 Godot 的 `Dotnet > Editor > External Editor` 中选择 Visual Studio Code；具体调试配置见[官方 C# / VS Code 接入说明](https://docs.godotengine.org/en/stable/tutorials/scripting/c_sharp/c_sharp_basics.html#visual-studio-code)。

## 安装命令的组成和验收证据

`Install-Godot.ps1` 完整记录了以下实际步骤，修改参数即可复跑，无需手动逐条复制：

1. `dotnet --list-sdks` / `dotnet --list-runtimes`：检测并复用依赖。
2. `Invoke-WebRequest`：获取官方 `SHA512-SUMS.txt`。
3. `curl.exe --fail --location --retry 3 --retry-all-errors`：下载发行包；GitHub 下载失败时切换官方镜像。
4. `Get-FileHash -Algorithm SHA512`：下载包及已有缓存校验；失败不解压。
5. `[IO.Compression.ZipFile]::ExtractToDirectory(...)`：解压编辑器及 .NET TPZ 模板。
6. `[Environment]::SetEnvironmentVariable(...)` / `WScript.Shell.CreateShortcut(...)`：配置命令、用户变量与快捷方式。
7. `code --install-extension geequlim.godot-tools` / `code --install-extension ms-dotnettools.csharp`：安装或复用扩展。
8. Godot `--headless --script`、`dotnet new sln`、`dotnet sln add`、`dotnet build`、Godot `--import`：执行 GDScript 和 C# 运行验收。
9. Godot `--headless --export-release` 与 `Start-Process -Wait`：导出并运行 Windows C# 游戏，同时验证退出码和输出标记。
10. `Start-Process ... --project-manager`：打开开发环境。

本机成功日志：

- PowerShell 7：`%LOCALAPPDATA%\Programs\Godot\install-20261008-201927-285.log`。
- PowerShell 5.1：`%LOCALAPPDATA%\Programs\Godot\install-20261008-202253-040.log`。
- 最近一次成功导出与运行证据：`%LOCALAPPDATA%\Programs\Godot\validation-6090d92715ff45c688621ff5f4270711`。

模板版本标识实测带 `.mono`，不能安装到标准版的目录。验收项目明确设置 `dotnet/project/assembly_name`，并创建 `.sln`；.NET 10 默认的 `.slnx` 不作为本次 Godot 验收输入。

## 网络及安装范围

编辑器下载约 111 MiB，.NET 全平台模板包约 1.12 GiB；脚本保留下载缓存与验收记录，因此安装目录与 APPDATA 需要额外解压和导出空间。重复执行复用已校验缓存，但仍需联网获取官方校验清单并还原 NuGet 依赖。

本次实测 GitHub 模板下载遇到连接重置，官方镜像重试后成功。失败的下载先写入 `.part` 文件，只有 SHA512 正确才改为正式缓存文件；日志保留在安装根目录。

本次完成的是 GDScript / C# 编辑器开发与 Windows 桌面导出环境，没有安装 Android SDK、JDK、iOS 工具链或 C++ GDExtension 工具链，也没有测试这些平台。其他平台可能需要额外 SDK，见[官方项目导出说明](https://docs.godotengine.org/en/stable/tutorials/export/exporting_projects.html)。C# 项目的 Web 导出限制见[官方 C# 平台说明](https://docs.godotengine.org/en/stable/tutorials/scripting/c_sharp/c_sharp_basics.html)。