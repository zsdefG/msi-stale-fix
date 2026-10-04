# msi-stale-fix

检测并修复 Windows Installer (MSI) 残留产品注册的小工具。纯 Windows 原生脚本（`.bat` + `.ps1`），无需安装任何运行时。

## 解决什么问题

安装或升级软件时弹出如下对话框（MSI 错误 **1706** / **2203**）：

```
无法访问你试图使用的功能所在的网络位置。
单击"确定"重试，或在下面的框中输入包含安装程序包 '<GUID>.msi' 的文件夹的路径。
```

典型场景：

- 旧版软件（如 VMware Workstation）安装在很久以前，其源 MSI 已从 `InstallerCache` 或 `C:\Windows\Installer` 中被删除；
- 但 Windows Installer 注册表里仍登记着该产品；
- 新安装包的 `FindRelatedProducts` 检测到旧版本，进入 `RemoveExistingProducts` 尝试卸载旧版；
- 卸载旧版需要源 MSI，源已丢失 → 弹出 1706 源缺失对话框，安装中断。

**这与 Hyper-V / 虚拟机 / 杀毒软件无关**，纯粹是「注册残留 + 源文件丢失」问题。

## 特性

- **检测**：枚举全部 MSI 产品注册（64/32 位视图 + HKCU），从三处来源核实源文件是否真实存在；
- **修复**：对每条残留先 `reg export` 备份到 `backup\` 目录，逐条确认后才删除注册项；
- **安全**：不指定 `-Repair` 时绝不修改系统；备份文件支持一键回滚；
- **零依赖**：只需要 Windows 自带的 PowerShell 5.1+，双击即用。

## 前置条件

- Windows 10 / 11（PowerShell 5.1+）；
- 需要**管理员权限**（脚本会自动通过 UAC 请求提权）。

## 使用方法

1. 下载 `msi-stale-fix.bat` 和 `msi-stale-fix.ps1` 放到同一目录；
2. 双击 `msi-stale-fix.bat`：

   - 默认 **仅扫描**，列出所有产品并标记「缺失/正常」，不做任何修改；
   - 扫描结果有「缺失」条目时，按提示输入 `y` 对该条执行修复（先备份再删除）。

命令行方式（可选）：

```bat
msi-stale-fix.bat                 REM 仅扫描
msi-stale-fix.bat -Repair         REM 扫描 + 修复
msi-stale-fix.bat -Repair -BackupDir D:\fix_backup   REM 指定备份目录
```

## 工作原理

产品注册位于 `HKLM\SOFTWARE\Classes\Installer\Products\<反序GUID>`，脚本对每个产品从以下三处核实源文件（真实 MSI 需 > 1KB，排除 1 字节占位）：

1. **LocalPackage 缓存**：`UserData\<SID>\Products\<反序GUID>\InstallProperties\LocalPackage`（对应 `C:\Windows\Installer\<短哈希>.msi`）——最可靠的本地源；
2. `C:\Windows\Installer\{PackageCode}.msi`；
3. `SourceList` 登记的目录中的 `<PackageName>.msi` / `<反序GUID>.msi`。

三者均不存在 → 判定为「源缺失（残留候选）」，修复时备份后删除：

- `Products` 键（覆盖 64/32 位、HKCU 视图）；
- `UpgradeCodes` 中对该产品的引用。

## 实测验证

本机扫描 84 个已注册产品，准确识别出 1 个真实残留（Metasploit-framework v6.4.19 —— 已卸载但注册未清、源已丢失，与 VMware 1706 案例同形态），其余 83 个全部正确判为正常。

## 输出示例

```
==== MSI 残留产品检测与修复 ====

扫描完成: 共 84 个产品, 其中源缺失 1 个

[缺失] Metasploit-framework v6.4.19  (600A1AB30E4DBD74AA4C6CC46818C459)
        源搜索范围: ...
[正常] VMware Workstation  (92D145E69D1230846AFFF3E286052D48)
...
仅扫描模式(-Repair 未指定), 未做任何修改。
```

## 免责声明

操作 Windows Installer 注册表有一定风险，脚本已内置「先备份、再修改、逐条确认」的保护机制。请确认你清楚每条待清理产品的用途后再执行删除，或先用默认模式扫描观察。

## License

MIT