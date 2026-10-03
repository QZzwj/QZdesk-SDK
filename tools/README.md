# luckfox-pico-tools

[LuckfoxTECH/luckfox-pico](https://github.com/LuckfoxTECH/luckfox-pico) 国内加速快照镜像的 `tools/` 部分，同步自上游 `824b817f`（2026-03-22）。

本仓库作为主仓库的 **git 子模块**使用（子模块路径 `tools/`）。克隆主仓库时加 `--recursive` 即可自动获取：

```bash
git clone --recursive https://gitee.com/LuckfoxTECH/luckfox-pico.git
```

已克隆过的主仓库，补一次子模块：

```bash
cd luckfox-pico
git submodule update --init
```

## 目录内容

与上游 `tools/` 完全一致：

- `linux/toolchain/` —— 交叉编译工具链（arm-rockchip830），编译 SDK 必需
- `linux/SocToolKit/` —— SoC 工具箱
- `linux/Linux_Pack_Firmware/`、`linux/Linux_Upgrade_Tool/` —— 固件打包 / 升级工具
- `windows/` —— Windows 版工具
