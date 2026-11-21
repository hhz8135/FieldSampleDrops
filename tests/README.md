# 离线回归测试

从包含 `build.ps1` 的源码目录运行。参数是要测试的 FieldSampleDrops ZIP，`--lua-dll` 可指定另一处安装的 LuaJIT。默认使用本机 HellForge 游戏目录下的 `lua51.dll`，压缩包读取复用工作区 `.tools/sdk` 的归档工具。

```powershell
$python = 'python'
$package = '.\build\FieldSampleDrops-1.2.0.zip'
& $python -B -X utf8 .\tests\run_regression.py $package
```

测试先原样加载 ZIP 内的 `mods/custom/field_sample_drops`，确认独立设置菜单和实体击杀事件。随后替换生成和样本策略两个适配器，验证距离边界、尸体位置、档位、设置、去重、房主权限、队友击杀、旧版共存和任务重置。Bingus、HD2Runtime、`FieldSampleDrops_CONFIG.ini` 和日志由 fixture 提供，生成调用由 fixture 记录。

`--harness` 可指定其他 Lua 脚本，脚本通过 `...` 接收 addon 源码和资源名。样本是否可拾取并进入撤离结算，仍需实机验证。
