<#
  脚本: msi-stale-fix.ps1
  用途: 检测并修复 Windows Installer "残留产品注册" 问题
  现象: 安装/升级软件弹窗 "无法访问你试图使用的功能所在的网络位置,
        输入包含 <GUID>.msi 的文件夹路径" (错误 1706 / 2203)；
        根因是旧版产品已卸载/重装过，但注册表仍登记 product 项，
        其源 MSI 已不存在(InstallerCache 或 C:\Windows\Installer 里丢失)。

  流程:
    1) 枚举 HKLM\SOFTWARE\Classes\Installer\Products 及 32位视图
       (WOW6432Node) 下的所有产品注册项；
    2) 对每个产品采集 ProductName / PackageCode / SourceList;
    3) 判定源是否存在: 搜索 C:\Windows\Installer 缓存、InstallerCache、
       SourceList 记录的源目录中的 <PackageCode>.msi 或 <reversed>.msi；
    4) 不存在 -> 标记为"残留候选";
    5) 仅扫描不改动; 指定 -Repair 后逐条确认并删除注册项
       (删除前先 reg export 备份到 -BackupDir)。

  用法:
    powershell -NoProfile -ExecutionPolicy Bypass -File msi-stale-fix.ps1          # 仅扫描
    powershell -NoProfile -ExecutionPolicy Bypass -File msi-stale-fix.ps1 -Repair   # 扫描+修复
    powershell ... -Repair -BackupDir D:\fix_backup                                 # 指定备份目录
#>
[CmdletBinding()]
param(
    [switch]$Repair,
    [string]$BackupDir = ""
)

$ErrorActionPreference = 'Stop'

# ---------- 工具辅助 ----------
function Get-NativePath([string]$psPath) {
    # 把 PowerShell Provider 路径 (HKLM:\) 转成 reg.exe 需要的路径 (HKLM\)
    return $psPath -replace '^HKLM:\\','HKLM\' -replace '^HKCU:\\','HKCU\'
}

function Test-RealMsi([string]$path) {
    # 判定一个文件是否像是真实 MSI(排除 1 字节占位 / 空文件)
    if (-not $path) { return $false }
    if (Test-Path -LiteralPath $path) {
        try {
            $len = (Get-Item -LiteralPath $path -ErrorAction Stop).Length
        } catch { return $false }
        if ($len -and $len -gt 1024) { return $true }
    }
    return $false
}

# ---------- 管理员权限检查(删除注册表需要) ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "错误: 需要管理员权限。请右键以管理员身份运行 .bat 或 PowerShell。" -ForegroundColor Red
    exit 1
}

# ---------- 备份目录 ----------
if (-not $BackupDir) { $BackupDir = Join-Path $PSScriptRoot 'backup' }
if ($Repair) {
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
}

Write-Host "==== MSI 残留产品检测与修复 ====" -ForegroundColor Cyan
Write-Host ""

# ---------- 枚举产品注册根 ----------
$roots = @(
    'HKLM:\SOFTWARE\Classes\Installer\Products',
    'HKLM:\SOFTWARE\WOW6432Node\Classes\Installer\Products',
    'HKCU:\Software\Classes\Installer\Products'
)

# 每个产品代码反序键名对应的 LocalPackage 缓存路径
# (C:\Windows\Installer\<hash>.msi)，位于 UserData\<SID>\Products\<rev>\InstallProperties
$localCacheMap = @{}
foreach ($ud in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData') {
    if (-not (Test-Path -LiteralPath $ud)) { continue }
    foreach ($sid in (Get-ChildItem -LiteralPath $ud -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer })) {
        $prodRoot = Join-Path $sid.PSPath 'Products'
        if (-not (Test-Path -LiteralPath $prodRoot)) { continue }
        foreach ($pr in (Get-ChildItem -LiteralPath $prodRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer })) {
            $ip = Join-Path $pr.PSPath 'InstallProperties'
            if (Test-Path -LiteralPath $ip) {
                $local = (Get-ItemProperty -LiteralPath $ip -ErrorAction SilentlyContinue).LocalPackage
                if ($local) {
                    $localCacheMap[$pr.PSChildName] = $local
                }
            }
        }
    }
}

$all = [System.Collections.Generic.List[object]]::new()
foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer })) {
        $reversed      = $k.PSChildName   # 注册表键名是 ProductCode 的"反序"形式
        $productKey    = "HKLM:\SOFTWARE\Classes\Installer\Products\$reversed"
        $sourceKey     = "$productKey\SourceList"
        $netKey        = "$sourceKey\Net"

        $name    = (Get-ItemProperty -LiteralPath $productKey -ErrorAction SilentlyContinue).ProductName
        $pkgCode = (Get-ItemProperty -LiteralPath $productKey -ErrorAction SilentlyContinue).PackageCode
        if (-not $name) { $name = '(未命名产品)' }

        $pkgName      = $null
        $lastUsedSrc  = $null
        $netFirst     = $null
        if (Test-Path -LiteralPath $sourceKey) {
            $pkgName     = (Get-ItemProperty -LiteralPath $sourceKey -ErrorAction SilentlyContinue).PackageName
            $lastUsedSrc = (Get-ItemProperty -LiteralPath $sourceKey -ErrorAction SilentlyContinue).LastUsedSource
        }
        if (Test-Path -LiteralPath $netKey) {
            $netFirst = (Get-ItemProperty -LiteralPath $netKey -ErrorAction SilentlyContinue).'1'
        }

        # 组装候选源路径(真实 MSI 应有 >1KB 大小)
        $candidates = [System.Collections.Generic.List[string]]::new()
        # 1) UserData 缓存 LocalPackage (C:\Windows\Installer\<hash>.msi) —— 最可靠的本地源
        if ($localCacheMap.ContainsKey($reversed)) {
            $candidates.Add($localCacheMap[$reversed])
        }
        # 2) C:\Windows\Installer\{PackageCode}.msi (按完整 GUID 命名的缓存占位/本体)
        if ($pkgCode) {
            $b = "{" + $pkgCode + "}"
            $candidates.Add((Join-Path $env:SystemRoot "Installer\$b.msi"))
        }
        # 3) SourceList\Net 记录的网络/本地目录 + PackageName / 反序键名
        $netDirs = @($netFirst, $lastUsedSrc) | Where-Object { $_ }
        foreach ($nd in $netDirs) {
            $nd = $nd -replace '^[nm];?\d*;', ''   # 去掉 "n;1;" / "m;" 前缀
            if ($nd) {
                if ($pkgName) { $candidates.Add((Join-Path $nd $pkgName)) }
                $candidates.Add((Join-Path $nd "$reversed.msi"))
            }
        }
        # 4) 常见 InstallerCache 目录里找 <PackageName>
        if ($pkgName) {
            $candidates.Add((Join-Path 'C:\Program Files (x86)\Common Files\VMware\InstallerCache' $pkgName))
        }

        $found = $false
        foreach ($c in $candidates) {
            if (Test-RealMsi $c) { $found = $true; break }
        }

        $all.Add([PSCustomObject]@{
            Reversed = $reversed
            Name     = $name
            PkgCode  = $pkgCode
            PkgName  = $pkgName
            LocalCached = if ($localCacheMap.ContainsKey($reversed)) { $localCacheMap[$reversed] } else { '' }
            Source   = ($candidates -join ' | ')
            Missing  = -not $found
        })
    }
    # 32 位视图枚举的键名与 64 位相同, 去重
    $all = [System.Collections.Generic.List[object]]::new(
        @($all | Sort-Object Reversed -Unique)
    )
}

# ---------- 输出扫描结果 ----------
$missing = @($all | Where-Object { $_.Missing })
Write-Host ("扫描完成: 共 {0} 个产品, 其中源缺失 {1} 个" -f $all.Count, $missing.Count) -ForegroundColor Yellow
Write-Host ""
foreach ($p in ($all | Sort-Object Missing -Descending)) {
    $flag = if ($p.Missing) { '[缺失]' } else { '[正常]' }
    $flagColor = if ($p.Missing) { 'Red' } else { 'Green' }
    Write-Host ("{0} {1}  ({2})" -f $flag, $p.Name, $p.Reversed) -ForegroundColor $flagColor
    if ($p.Missing) {
        Write-Host ("        源搜索范围: {0}" -f $p.Source) -ForegroundColor DarkGray
    }
}
Write-Host ""

# ---------- 仅扫描模式 ----------
if (-not $Repair) {
    Write-Host "仅扫描模式(-Repair 未指定), 未做任何修改。" -ForegroundColor Cyan
    exit 0
}

if ($missing.Count -eq 0) {
    Write-Host "没有需要清理的残留, 无需修改。" -ForegroundColor Green
    exit 0
}

# ---------- 修复模式: 逐条确认 → 备份 → 删除 ----------
Write-Host "进入修复模式。对每个缺失源的产品会先备份再删除注册项。" -ForegroundColor DarkYellow
Write-Host ""
foreach ($p in $missing) {
    Write-Host ("待清理: {0} (键: {1})" -f $p.Name, $p.Reversed) -ForegroundColor Yellow
    Write-Host ("        包代码: {0}  包名: {1}" -f $p.PkgCode, $p.PkgName)
    $ans = Read-Host "        确认删除该注册项? [y/N]"
    if ($ans -notin @('y','Y','yes','YES')) {
        Write-Host ("        已跳过 {0}" -f $p.Name) -ForegroundColor Gray
        continue
    }

    $regKey = "HKLM:\SOFTWARE\Classes\Installer\Products\$($p.Reversed)"
    $backFile = Join-Path $BackupDir "product_$($p.Reversed).reg"
    try {
        reg export (Get-NativePath $regKey) $backFile /y 2>&1 | Out-Null
    } catch {
        Write-Host ("        备份失败: {0}" -f $_) -ForegroundColor Red
        continue
    }
    if (-not (Test-Path -LiteralPath $backFile)) {
        Write-Host "        备份文件未生成, 中止删除该条。" -ForegroundColor Red
        continue
    }
    Write-Host ("        已备份 -> {0}" -f $backFile) -ForegroundColor Green

    # 删除 Products 注册项(覆盖该产品出现的所有视图)
    foreach ($root in $roots) {
        $cand = "$root\$($p.Reversed)"
        if (Test-Path -LiteralPath $cand) {
            reg delete (Get-NativePath $cand) /f 2>&1 | Out-Null
            Write-Host ("        已删除注册项: {0}" -f (Get-NativePath $cand)) -ForegroundColor Green
        }
    }

    # 清理 UpgradeCodes 中指向该产品的引用(值名为反序键名)
    $ucRoots = @(
        'HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes',
        'HKLM:\SOFTWARE\WOW6432Node\Classes\Installer\UpgradeCodes'
    )
    foreach ($uc in $ucRoots) {
        if (-not (Test-Path -LiteralPath $uc)) { continue }
        foreach ($u in (Get-ChildItem -LiteralPath $uc -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer })) {
            $ucPath = $u.PSPath
            $props = Get-ItemProperty -LiteralPath $ucPath -ErrorAction SilentlyContinue
            if ($props -and $props.PSObject.Properties.Name -contains $p.Reversed) {
                reg delete (Get-NativePath $ucPath) /v $p.Reversed /f 2>&1 | Out-Null
                Write-Host ("        已清除 UpgradeCodes 引用: {0}\{1}" -f (Get-NativePath $ucPath), $p.Reversed) -ForegroundColor Green
            }
        }
    }
    Write-Host ""
}

Write-Host "==== 修复完成 ====" -ForegroundColor Cyan
Write-Host "建议: 重新运行目标软件的安装程序; 如需回滚, 双击 backup 目录下对应 .reg 即可。"