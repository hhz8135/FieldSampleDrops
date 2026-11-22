# FieldSampleDrops

**FieldSampleDrops** is a **HellForge** mod that turns nearby enemy kills into collectible sample drops. When a kill threshold is reached, a sample spawns at the enemy's death location—pick it up and extract with it just like a regular sample.

## Features

- **Host Proximity Tracking:** Only enemy kills credited to the host within the configured distance limit count toward progress.
- **Separate Sample Counters:** Common, Rare, and Super samples each track independently with their own kill thresholds.
- **In-Game Configuration:** Adjust all three kill thresholds and the distance limit (`1–300 m`) via the **Mod Options Menu**. Changes take effect on the **next mission**.
- **Session Persistence:** Kill progress carries over when the host is reinforced and resets at the start of each mission.
- **Difficulty & Treasure Map Support:**
  - Falls back to mission difficulty when sample types are not explicitly confirmed: Common on **D1–D11**, Rare on **D4–D11**, and Super on **D6–D11** (`N11` supported).
  - Optional **Treasure Map 1.4.0** integration: uses Treasure Map data when it can confirm a sample type for the current mission, and falls back to difficulty otherwise. Opening the tactical map is optional.

## Default Configuration

| Setting | Default | Adjustable Range / Behavior |
| --- | --- | --- |
| Kill Range | `30 m` | `1–300 m` from the host (next mission) |
| Common Sample Threshold | `20` kills | Configurable in Mod Options Menu (next mission) |
| Rare Sample Threshold | `40` kills | Configurable in Mod Options Menu (next mission) |
| Super Sample Threshold | `75` kills | Configurable in Mod Options Menu (next mission) |
| Difficulty Enablement | D1–D11 / D4–D11 / D6–D11 | Uses Treasure Map 1.4.0 data when confirmed |

## Requirements & Installation

- **Compatibility:** HellForge **0.4.0-beta**, game build **25480438**.
- **Required:** Bingus Shared Loader **v20+** and HD2Runtime **0.50.1**. [Bingus Shared Loader](https://ayakamods.com/mods/bingus-shared-loader.3861/) · [HD2Runtime 0.50.1](https://github.com/SkyeShade/HD2Runtime/releases/tag/v0.50.1)
- **Optional:** Mod Options Menu for in-game settings and Treasure Map **1.4.0** for sample type detection.
- **Multiplayer preview:** The host must have the mod installed to spawn drops. Teammate visibility, pickup, and extraction credit are pending two-player verification.

1. Download the [v1.2.0 installer ZIP](https://raw.githubusercontent.com/hhz8135/FieldSampleDrops/v1.2.0/releases/FieldSampleDrops-1.2.0.zip) or get it from [AyakaMods](https://ayakamods.com/mods/fieldsampledrops.6166/).
2. Import and enable the ZIP in the **HellForge Launcher** under **Mods**, then restart the game session. If you use a mod manager such as HDArsenal, select your HellForge installation as the deployment target.
3. With Mod Options Menu installed, go to **Esc → MODS → 战地样本掉落 · 联机版** to adjust the thresholds and range. Changes apply from the next mission.

## Changelog

- **v1.2.0** adds configurable kill thresholds (`20 / 40 / 75` by default), adjustable range (`1–300 m`), N11 support, and optional Treasure Map `1.4.0` integration.

## Credits

Thanks to **kugua**, the author of **MonsterSampleDrop**, for the inspiration and foundation. See [NOTICE.md](NOTICE.md) for additional credits.

## License

Project-wide MIT licensing is pending confirmation of the terms for code adapted from MonsterSampleDrop.

---

# FieldSampleDrops（中文说明）

**FieldSampleDrops** 是一款 **HellForge** 模组，可将房主附近的击杀转化为可拾取的样本掉落。达到击杀阈值后，样本会在怪物死亡位置生成，正常拾取并带走撤离即可。

## 主要功能

- **房主近距离统计：** 仅统计房主本人在设定距离上限内的有效击杀，默认 **30 米**，可在菜单中调整为 **1–300 米**。
- **三档独立计数：** 普通、稀有、超级样本分别独立计数，默认每 **20 / 40 / 75** 次有效击杀掉落 1 个。
- **菜单自定义：** 支持通过 **Mod Options Menu** 分别调整三档阈值与距离上限，修改后**下一局生效**。
- **进度规则：** 房主阵亡增援后保留当前击杀进度，每局任务开始时重置。
- **难度与联动支持：**
  - 支持 **D1–D11（N11）**。按难度默认开启范围为普通 D1–D11、稀有 D4–D11、超级 D6–D11。
  - 可选联动 **Treasure Map 1.4.0**。能确认当前任务样本类型时优先采用其数据，否则按难度判定。不开战术地图也可以使用。

## 安装与使用

- **版本支持：** HellForge **0.4.0-beta**，游戏构建 **25480438**。
- **必需前置：** Bingus Shared Loader **v20+** 和 HD2Runtime **0.50.1**。
- **可选前置：** Mod Options Menu 提供游戏内设置。Treasure Map **1.4.0** 用于辅助判断样本类型。
- **联机预览：** 由安装模组的房主生成掉落。队友能否看到并拾取样本，以及撤离后是否正确结算，仍待双人实测。

1. 下载 [v1.2.0 安装包](https://raw.githubusercontent.com/hhz8135/FieldSampleDrops/v1.2.0/releases/FieldSampleDrops-1.2.0.zip)，也可从 [AyakaMods](https://ayakamods.com/mods/fieldsampledrops.6166/) 下载。
2. 在 **HellForge 启动器 → Mods** 中导入并启用 ZIP，重启游戏会话。使用 HDArsenal 等模组管理器时，请将部署目标设为 HellForge 安装目录。
3. 如果装了 Mod Options Menu，在 **Esc → MODS → 战地样本掉落 · 联机版** 调整阈值与距离，下一局生效。

## 致谢

感谢 **MonsterSampleDrop** 作者 **kugua** 的创意与基础实现。其他署名见 [NOTICE.md](NOTICE.md)。

## 许可证

全项目采用 MIT 许可证仍待确认 MonsterSampleDrop 衍生代码的授权范围。
