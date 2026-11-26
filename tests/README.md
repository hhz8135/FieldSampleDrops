# 离线回归测试

从仓库根目录构建并运行回归。省略 ZIP 路径时，脚本按 `VERSION` 选择 `build/FieldSampleDrops-<VERSION>.zip`。

```powershell
.\build.ps1
python tests/run_regression.py
python tests/run_regression.py --harness tests/compatibility.lua
```

脚本依次查找仓库及其父目录下的 `.tools/sdk`。独立克隆可以用 `--sdk-dir` 指向解压后的 HD2Runtime SDK 根目录，其中应包含 `tools/hd2_archive.py`。LuaJIT 默认取本机 HellForge 游戏目录下的 `lua51.dll`，其他安装位置可用 `--lua-dll` 指定。

```powershell
$sdk = 'C:\path\to\HD2Runtime-sdk'
$lua = 'C:\path\to\HellForge\game\bin\lua51.dll'
python tests/run_regression.py --sdk-dir $sdk --lua-dll $lua
python tests/run_regression.py .\build\FieldSampleDrops-1.2.1.zip --sdk-dir $sdk --lua-dll $lua
```

测试先原样加载 ZIP 内的 `mods/custom/field_sample_drops`，确认独立设置菜单和实体击杀事件。随后替换生成和样本策略两个适配器，验证距离边界、尸体位置、档位、设置、去重、房主权限、队友击杀、旧版共存和任务重置。Bingus、HD2Runtime、`FieldSampleDrops_CONFIG.ini` 和日志由 fixture 提供，生成调用由 fixture 记录。

`compatibility.lua` 检查构建号、原生签名、难度布局不匹配时的停用流程，以及暂未就绪后的恢复和可选 Treasure Map 回退。SDK 20 测试覆盖移动后的房主与增援位置、30 米边界、包驻留重试、样本及联机 ID 回读。

`--harness` 可指定其他 Lua 脚本，脚本通过 `...` 接收 addon 源码和资源名。离线回归覆盖掉落请求。拾取和撤离结算以游戏内实际结果为准。
