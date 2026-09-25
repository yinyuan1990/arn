# Arm · 合约

Circle Arc 链（USDC 原生 gas）上的代币发射平台合约。发币即在 Uniswap V3 建 1% 池、LP 永久锁定；每笔交易 1% 池子手续费按 **78 / 16 / 5 / 1** 分给 创作者 / 储备 / 回购 / 技术团队；发币免费；创作者可开启推广分佣。

| 合约 | 作用 |
|---|---|
| `LaunchFactory` | 一笔交易完成：部署代币 → 建池 → 单边注入全部供应 → LP 锁进 FeeLocker → 给该币建分账合约 → 可选首购 |
| `LaunchToken` | 固定 10 亿供应，保护期限购 / 限仓，可选买卖税 |
| `FeeLocker` | 永久持有 LP；`distribute` 收手续费、代币侧卖成 USDC，78% 推给该币的分账合约、22% 推 Treasury |
| `Treasury` | 平台 22% 每 7 天结算一次：16/22 储备、5/22 回购、1/22 技术团队（三个地址部署时写死） |
| `ReferralHub` | 给每个币创建 `CreatorFeeSplitter`（EIP-1167 克隆），保存可结算的 Keeper 地址 |
| `CreatorFeeSplitter` | 推广分佣（方案乙）：到账 USDC 按 `referralBps` 预留奖池、其余当场给创作者；Keeper 按推广成交占比结算给推广者，剩余退回创作者；7 天没结算创作者可自取；可随时改比例 / 退出 |

推广奖池 = 创作者 78% × 分佣比例 × 推广成交占比；自然流量部分一分不动。分佣比例默认 0（不开），最高 50%。

## 构建与测试

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git
forge test
```

`vendor/uniswap-v3/` 是 Uniswap V3 官方字节码（测试和自部署路由用）。

## 部署（Arc 主网）

```bash
PRIVATE_KEY=0x... \
UNI_FACTORY=0xf0db7b58379503491d857dB50AC9ece64c653918 \
UNI_NFPM=0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377 \
forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.arc.io --broadcast
```

默认 owner 和 Keeper 都是部署钱包；储备 / 回购 / 技术团队地址写在 `script/Deploy.s.sol` 顶部。结果写入 `deployments/arc-mainnet.json`。Arc 的 USDC 转账会调用黑名单预编译，本地 EVM 模拟会失败，所以发币、交易等冒烟测试用 `cast send` 直发。
